#!/usr/bin/env python3
"""The mixer's own timing per trial, from mixprobe's samples.

For each trial of a build directory whose start falls inside the samples:
the ticks of the room in that window, how many fired more than 2, 5, 10 or
20 ms late (the room's tick lateness histogram, differenced between the
sample before the trial and the sample after it), the overruns (ticks more
than a period late, whose frames were skipped), and, per leg that came and
went in the window, its jitter buffer counters at its last sample
(received, lost, late, dropped, underruns, prefill).

Usage: mixan.py MIX_LOG RUN_DIR [RUN_DIR ...] > out.json
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

TOKEN = re.compile(r'\s*(#\{|<<|>>|=>|[{}\[\],]|"(?:[^"\\]|\\.)*"|#Ref<[^>]*>|#Fun<[^>]*>|'
                   r'#Port<[^>]*>|<[0-9.]+>|-?\d+\.\d+(?:e[+-]?\d+)?|-?\d+|\'(?:[^\'\\]|\\.)*\'|'
                   r'[a-z][A-Za-z0-9_@]*)')


def tokens(s):
    pos = 0
    out = []
    while pos < len(s):
        m = TOKEN.match(s, pos)
        if not m:
            if s[pos:].strip() in ("", "."):
                break
            raise ValueError(f"cannot read at {pos}: {s[pos:pos + 40]!r}")
        out.append(m.group(1))
        pos = m.end()
    return out


def parse(toks, i=0):
    t = toks[i]
    if t == "{":
        items, i = seq(toks, i + 1, "}")
        return tuple(items), i
    if t == "[":
        items, i = seq(toks, i + 1, "]")
        return items, i
    if t == "#{":
        d = {}
        i += 1
        while toks[i] != "}":
            k, i = parse(toks, i)
            assert toks[i] == "=>"
            v, i = parse(toks, i + 1)
            d[k if not isinstance(k, (list, dict)) else str(k)] = v
            if toks[i] == ",":
                i += 1
        return d, i + 1
    if t == "<<":
        parts = []
        i += 1
        while toks[i] != ">>":
            parts.append(toks[i])
            i += 1
        return "".join(p.strip('"') for p in parts if p != ","), i + 1
    if re.fullmatch(r"-?\d+", t):
        return int(t), i + 1
    if re.fullmatch(r"-?\d+\.\d+(?:e[+-]?\d+)?", t):
        return float(t), i + 1
    return t.strip("'\""), i + 1


def seq(toks, i, close):
    items = []
    while toks[i] != close:
        v, i = parse(toks, i)
        items.append(v)
        if toks[i] == ",":
            i += 1
    return items, i + 1


def samples(path):
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        v, _ = parse(tokens(line.rstrip(".")))
        yield v


def late_over(h, us):
    return sum(n for b, n in h.items() if b == "infinity" or (isinstance(b, int) and b > us))


def main(argv):
    ss = [s for s in samples(argv[0]) if isinstance(s[1], list)]
    out = []
    for rd in (Path(p) for p in argv[1:]):
        rj = json.loads((rd / "run.json").read_text())
        t0 = datetime.strptime(rj["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc).timestamp() * 1000
        before = [s for s in ss if s[0] <= t0 - 500]
        after = [s for s in ss if s[0] >= t0 + 32000]
        if not before or not after:
            continue
        b, a = before[-1], after[0]
        rec = {"trial": rd.name, "arm": rj["arm"], "window_s": round((a[0] - b[0]) / 1000, 1)}
        conf_b = {c[0]: c[1] for c in b[1]}
        conf_a = {c[0]: c[1] for c in a[1]}
        rooms = []
        for pid, sa in conf_a.items():
            if sa.get("rate") != 16000:
                continue
            # a room made inside the window starts from nothing
            sb = conf_b.get(pid) or {"ticks": 0, "overruns": 0, "late_histogram_us": {}}
            hb, ha = sb["late_histogram_us"], sa["late_histogram_us"]
            rooms.append({
                "conf": pid, "ticks": sa["ticks"] - sb["ticks"],
                "overruns": sa["overruns"] - sb["overruns"],
                **{f"late_over_{ms}ms": late_over(ha, ms * 1000) - late_over(hb, ms * 1000)
                   for ms in (2, 5, 10, 20)},
                "late_max_us_so_far": sa["late_max_us"],
                "created_in_window": pid not in conf_b,
            })
        rec["rooms"] = rooms
        # legs seen in the window, at their last sample, in order of appearance
        legs = {}
        for s in ss:
            if not (b[0] <= s[0] <= a[0]):
                continue
            for _, st, ls in s[1]:
                if not isinstance(ls, list) or st.get("rate") != 16000:
                    continue
                for leg in ls:
                    lid = leg.get("id")
                    if lid not in legs:
                        legs[lid] = {"first_s": round((s[0] - t0) / 1000, 1)}
                    legs[lid].update(
                        last_s=round((s[0] - t0) / 1000, 1),
                        remote=str(leg.get("remote")), port=leg.get("port"),
                        **{k: leg.get(k) for k in ("received", "lost", "late", "dropped",
                                                   "underruns", "prefill", "prefill_shrunk",
                                                   "tx")})
        rec["legs"] = sorted(legs.values(), key=lambda x: x["first_s"])
        out.append(rec)
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main(sys.argv[1:])
