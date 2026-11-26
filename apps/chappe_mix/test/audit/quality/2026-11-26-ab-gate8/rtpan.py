#!/usr/bin/env python3
"""RTP into bob, hop by hop, for every trial of a block.

For each trial (a run directory with run.json, bob.sdp, bob.pjsua.log)
whose start falls inside the trace, it finds in the RTP trace (tcpdump -i
any, linux-sll2) the stream rtpengine sends to bob, the stream that feeds
it (chappe_mix or FreeSWITCH into rtpengine, the leg of bob), and, when
the docker proxy relays it, the same stream as bob's socket gets it on lo.
Per stream: packets, sequence gaps, RTP timestamp jumps, the longest
inter-arrival gap, the RFC 3550 interarrival jitter, and the spread of
arrival time minus RTP time (p1 to p99 and max). Per jitter buffer empty
event of bob's pjsua: the longest arrival gap in the 100 ms before it at
each hop.

Usage: rtpan.py RTP_PCAP RUN_DIR [RUN_DIR ...] > out.json
"""

import json
import re
import struct
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

CLOCK = {"G722": 8000, "opus": 48000, "L16": 16000, "PCMU": 8000}
BOB_PORT = 40100


def ip4(b):
    return ".".join(str(x) for x in b)


def read(path):
    """Yield (t, ifindex, src, sport, dst, dport, ulen, pt, seq, ts, ssrc)."""
    with open(path, "rb") as f:
        gh = f.read(24)
        magic = struct.unpack("<I", gh[:4])[0]
        e = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
        nano = magic in (0xA1B23C4D, 0x4D3CB2A1)
        link = struct.unpack(e + "I", gh[20:24])[0]
        while True:
            h = f.read(16)
            if len(h) < 16:
                return
            s, u, incl, _ = struct.unpack(e + "IIII", h)
            d = f.read(incl)
            t = s + u / (1e9 if nano else 1e6)
            if link == 276:
                proto = struct.unpack(">H", d[0:2])[0]
                ifx = struct.unpack(">I", d[4:8])[0]
                off = 20
            elif link == 113:
                proto = struct.unpack(">H", d[14:16])[0]
                ifx = 0
                off = 16
            else:
                raise SystemExit(f"link type {link} not handled")
            if proto != 0x0800 or len(d) < off + 20:
                continue
            ip = d[off:]
            if ip[9] != 17:
                continue
            ihl = (ip[0] & 15) * 4
            udp = ip[ihl:]
            if len(udp) < 20:
                continue
            sport, dport, ulen = struct.unpack(">HHH", udp[:6])
            r = udp[8:]
            if r[0] >> 6 != 2 or 200 <= r[1] <= 207:
                continue  # not RTP, or RTCP
            seq, ts, ssrc = struct.unpack(">HII", r[2:12])
            yield (t, ifx, ip4(ip[12:16]), sport, ip4(ip[16:20]), dport, ulen, r[1] & 0x7F,
                   seq, ts, ssrc)


def sdp_port_codec(p):
    txt = p.read_text()
    port = int(re.search(r"^m=audio (\d+)", txt, re.M).group(1))
    pt = re.search(r"^m=audio \d+ \S+ (\d+)", txt, re.M).group(1)
    codec = re.search(rf"^a=rtpmap:{pt} ([^/\s]+)", txt, re.M).group(1)
    return port, codec


def pct(v, q):
    v = sorted(v)
    if not v:
        return None
    k = (len(v) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def stream_stats(pk, clock):
    """pk: list of (t, seq, ts, ssrc, ulen) in arrival order."""
    if len(pk) < 2:
        return {"packets": len(pk)}
    step = clock // 50
    gaps = jumps = ssrc_changes = 0
    max_jump_ms = 0.0
    ia = []
    rel = []
    j = 0.0
    jmax = 0.0
    base_ts = None
    unwrap = 0
    prev = None
    for t, seq, ts, ssrc, _ in pk:
        if prev is not None:
            pt_, pseq, pts, pssrc, _ = prev
            if ssrc != pssrc:
                ssrc_changes += 1
                base_ts = None
            else:
                ds = (seq - pseq) & 0xFFFF
                if ds > 1 and ds < 1000:
                    gaps += ds - 1
                dts = (ts - pts) & 0xFFFFFFFF
                if dts != step * ds and ds < 1000:
                    jumps += 1
                    max_jump_ms = max(max_jump_ms, abs(dts - step * ds) * 1000 / clock)
                # RFC 3550 A.8 interarrival jitter, in ms
                d = (t - pt_) * 1000 - ((ts - pts) & 0xFFFFFFFF) * 1000 / clock
                j += (abs(d) - j) / 16
                jmax = max(jmax, j)
            ia.append((t - pt_) * 1000)
        if base_ts is None:
            base_ts, base_t, unwrap, last_ts = ts, t, 0, ts
        else:
            if ts < last_ts and last_ts - ts > 0x7FFFFFFF:
                unwrap += 1 << 32
            last_ts = ts
        rel.append((t - base_t) * 1000 - (ts + unwrap - base_ts) * 1000 / clock)
        prev = (t, seq, ts, ssrc, None)
    lo = pct(rel, 0.01)
    st = steps([p[0] for p in pk], rel)
    return {
        "packets": len(pk),
        "duration_s": round(pk[-1][0] - pk[0][0], 2),
        "seq_gaps": gaps,
        "ts_jumps": jumps,
        "max_ts_jump_ms": round(max_jump_ms, 1),
        "ssrc_changes": ssrc_changes,
        "max_interarrival_ms": round(max(ia), 1),
        "interarrival_over_30ms": sum(1 for x in ia if x > 30),
        "interarrival_over_40ms": sum(1 for x in ia if x > 40),
        "jitter_ms_final": round(j, 2),
        "jitter_ms_max": round(jmax, 2),
        "spread_ms_p99": round(pct(rel, 0.99) - lo, 1),
        "spread_ms_max": round(max(rel) - lo, 1),
        "lasting_shift_ms": round(max((x[2] for x in st), default=0.0), 1),
        "net_shift_ms": round(_median(rel[-W:]) - _median(rel[:W]), 1) if len(rel) > 2 * W else None,
        "_steps": st,
    }


W = 25  # packets, 0.5 s


def _median(v):
    return pct(v, 0.5)


def steps(times, rel):
    """Lasting changes of arrival minus RTP time: where the median of the
    next W packets differs from the median of the previous W by more than
    8 ms. (t, signed change ms, size ms), one per change."""
    out = []
    i = W
    while i < len(rel) - W:
        a, b = _median(rel[i - W:i]), _median(rel[i:i + W])
        if abs(b - a) > 8:
            # the packet where it moves the most
            j = max(range(i, min(i + W, len(rel) - W)),
                    key=lambda k: abs(_median(rel[k:k + W]) - _median(rel[k - W:k])))
            d = _median(rel[j:j + W]) - _median(rel[j - W:j])
            out.append((times[j], round(d, 1), round(abs(d), 1)))
            i = j + W
        else:
            i += 1
    return out


def longest_gap(times, t0, t1):
    """Longest gap between consecutive arrivals that ends in [t0, t1], ms."""
    best = 0.0
    for a, b in zip(times, times[1:]):
        if t0 <= b <= t1:
            best = max(best, (b - a) * 1000)
    return round(best, 1)


def pjsua_events(log, day):
    ev, summary = [], {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.match(r"(\d\d):(\d\d):(\d\d)\.(\d{3}) .*Jitter buffer empty", line)
        if m:
            h, mi, s, ms = (int(x) for x in m.groups())
            ev.append(day + h * 3600 + mi * 60 + s + ms / 1000)
        m = re.search(r"lost=(\d+) discard=(\d+) empty=(\d+)", line)
        if m:
            summary.update(lost=int(m[1]), discard=int(m[2]), empty=int(m[3]))
        m = re.search(r"burst \(min/max/avg/dev\)=(\d+)/(\d+)/", line)
        if m:
            summary["burst_max_frames"] = int(m[2])
        m = re.search(r"delay \(min/max/avg/dev\)=(\d+)/(\d+)/(\d+)/", line)
        if m:
            summary["jb_delay_ms"] = [int(m[1]), int(m[2]), int(m[3])]
    return ev, summary


def talk_window(rd, day):
    """(start, end) epoch of alice's speech: her call confirmed, then the
    clip (the tx file less its 2 s of trailing silence)."""
    import wave
    t = None
    for line in (rd / "alice.pjsua.log").read_text(errors="replace").splitlines():
        m = re.match(r"(\d\d):(\d\d):(\d\d)\.(\d{3}) .*state changed to CONFIRMED", line)
        if m:
            h, mi, sec, ms = (int(x) for x in m.groups())
            t = day + h * 3600 + mi * 60 + sec + ms / 1000
            break
    with wave.open(str(rd / "alice.tx.wav")) as w:
        dur = w.getnframes() / w.getframerate() - 2.0
    return (t, t + dur) if t else (None, None)


def main(argv):
    pcap, runs = argv[0], [Path(p) for p in argv[1:]]
    flows = defaultdict(list)
    tmin = tmax = None
    for t, ifx, src, sp, dst, dp, ulen, pt, seq, ts, ssrc in read(pcap):
        flows[(ifx, src, sp, dst, dp)].append((t, seq, ts, ssrc, ulen))
        tmin = t if tmin is None else min(tmin, t)
        tmax = t if tmax is None else max(tmax, t)
    out = []
    for rd in runs:
        rj = json.loads((rd / "run.json").read_text())
        t0 = datetime.strptime(rj["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc).timestamp()
        if tmin is None or not (tmin - 5 <= t0 <= tmax):
            continue
        w0, w1 = t0 - 2, t0 + 40
        port, codec = sdp_port_codec(rd / "bob.sdp")
        clock = CLOCK[codec]

        def win(key):
            return [p for p in flows[key] if w0 <= p[0] <= w1]

        out_keys = [k for k in flows if k[2] == port and k[1] != "127.0.0.1"
                    and len(win(k)) >= 50]
        rec = {"trial": rd.name, "arm": rj["arm"], "rep": rj["rep"], "codec_to_bob": codec,
               "rtpengine_port": port}
        if not out_keys:
            rec["problem"] = "no stream from rtpengine to bob in the trace"
            out.append(rec)
            continue
        # the main stream (most packets); of its copies, the first interface
        main_t = max({k[1:] for k in out_keys}, key=lambda t: max(len(win(k)) for k in out_keys
                                                                   if k[1:] == t))
        copies = [k for k in out_keys if k[1:] == main_t]
        k_out = min(copies, key=lambda k: (_median([p[0] for p in win(k)]), k[0]))
        lo_keys = [k for k in flows if k[1] == "127.0.0.1" and k[2] == port
                   and k[4] == BOB_PORT and len(win(k)) >= 50]
        if lo_keys:
            k_bob, path = lo_keys[0], "docker proxy (lo)"
        else:
            k_bob, path = k_out, "kernel NAT (bridge)"
        s_out = win(k_out)
        # the feeder: into rtpengine on another port, not from bob or alice,
        # starting closest to bob's stream
        cands = []
        for k in flows:
            ifx, src, sp, dst, dp = k
            if dp == port or not (31000 <= dp <= 31100) or src in ("127.0.0.1",):
                continue
            if sp in (BOB_PORT, BOB_PORT - 100) or dp % 2:
                continue
            ps = win(k)
            if len(ps) < 50:
                continue
            cands.append((abs(ps[0][0] - s_out[0][0]), ps[0][0], k))
        feed = None
        if cands:
            # same start within 0.5 s; of the interfaces, the earliest copy
            best = min(c[0] for c in cands)
            near = [c for c in cands if c[0] <= best + 0.5 and c[0] < 1.0]
            if near:
                kf = min(near, key=lambda c: (c[0], c[1]))[2]
                same = [c for c in near if c[2][2] == kf[2] and c[2][4] == kf[4]]
                feed = min(same, key=lambda c: c[1])[2]
        fclock = 16000 if rj["arm"] == "candidate" else clock
        rec["path_to_bob"] = path
        rec["hops"] = {}
        if feed:
            rec["feeder"] = {"ifindex": feed[0], "from": f"{feed[1]}:{feed[2]}",
                             "to": f"{feed[3]}:{feed[4]}"}
            rec["hops"]["into_rtpengine"] = stream_stats(win(feed), fclock)
        rec["hops"]["rtpengine_out"] = stream_stats(s_out, clock)
        if k_bob != k_out:
            rec["hops"]["at_bob"] = stream_stats(win(k_bob), clock)
        day = datetime.fromtimestamp(t0, timezone.utc).replace(
            hour=0, minute=0, second=0, microsecond=0).timestamp()
        ev, summ = pjsua_events(rd / "bob.pjsua.log", day)
        ta, tb = talk_window(rd, day)
        if ta:
            rec["talk_s"] = [round(ta - t0, 2), round(tb - t0, 2)]
            for h, k in (("into_rtpengine", feed), ("rtpengine_out", k_out),
                         ("at_bob", k_bob if k_bob != k_out else None)):
                if not k:
                    continue
                ps = [p for p in flows[k] if ta <= p[0] <= tb]
                st = stream_stats(ps, fclock if h == "into_rtpengine" else clock)
                rec["hops"][h]["talk"] = {x: st.get(x) for x in (
                    "packets", "max_interarrival_ms", "interarrival_over_40ms", "spread_ms_p99",
                    "spread_ms_max", "net_shift_ms", "seq_gaps", "ts_jumps")}
                rec["hops"][h]["talk"]["steps"] = len(st.get("_steps", []))
        rec["pjsua"] = summ
        times = {h: [p[0] for p in win(k)] for h, k in
                 (("into_rtpengine", feed), ("rtpengine_out", k_out), ("at_bob", k_bob)) if k}
        rec["empty_events"] = [
            {"t": round(te - t0, 3), "in_talk": bool(ta and ta <= te <= tb),
             **{f"gap_{h}_ms": longest_gap(ts_, te - 0.1, te) for h, ts_ in times.items()}}
            for te in ev]
        # each lasting change at bob: the longest gap of each hop in the 300 ms before
        bob_hop = "at_bob" if "at_bob" in rec["hops"] else "rtpengine_out"
        rec["bob_steps"] = [
            {"t": round(t - t0, 3), "change_ms": d, "in_talk": bool(ta and ta <= t <= tb),
             **{f"gap_{h}_ms": longest_gap(ts_, t - 0.3, t + 0.05) for h, ts_ in times.items()}}
            for t, d, _ in rec["hops"][bob_hop]["_steps"]]
        for h in rec["hops"].values():
            h.pop("_steps", None)
        out.append(rec)
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main(sys.argv[1:])
