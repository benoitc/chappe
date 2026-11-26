#!/usr/bin/env python3
"""Per build and arm, from the rtpan.py and mixan.py results of every
demo session (TRACES_DIR/<session>-rtp.json and -mix.json): the longest
arrival gap in alice's speech at each hop, its spread, steps and
timestamp jumps, bob's jitter buffer empties, the lasting delay steps at
bob, the mixer's late ticks and overruns, and every capture with a gap
over 40 ms in speech at any hop.

Usage: tracesum.py TRACES_DIR
"""
import json, sys, glob, statistics
from pathlib import Path
d = Path(sys.argv[1])
rtp = {}
for f in sorted(d.glob("*-rtp.json")):
    b = "old" if "-old-" in f.name else "new"
    for x in json.load(open(f)):
        rtp[(b, x["trial"])] = x
mix = {}
for f in sorted(d.glob("*-mix.json")):
    b = "old" if "-old-" in f.name else "new"
    for x in json.load(open(f)):
        mix[(b, x["trial"])] = x
for b in ("old", "new"):
    for arm in ("baseline", "candidate"):
        xs = [x for (bb, t), x in rtp.items() if bb == b and x["arm"] == arm]
        out = [f"{b} {arm}: {len(xs)} traced"]
        for h in ("into_rtpengine", "rtpengine_out", "at_bob"):
            ia = [x["hops"][h]["talk"]["max_interarrival_ms"] for x in xs if h in x["hops"] and x["hops"][h].get("talk")]
            o40 = sum(1 for v in ia if v > 40)
            sp = [x["hops"][h]["talk"]["spread_ms_max"] for x in xs if h in x["hops"] and x["hops"][h].get("talk")]
            st = sum(x["hops"][h]["talk"].get("steps", 0) for x in xs if h in x["hops"] and x["hops"][h].get("talk"))
            tj = sum(x["hops"][h]["talk"].get("ts_jumps", 0) for x in xs if h in x["hops"] and x["hops"][h].get("talk"))
            sg = sum(x["hops"][h]["talk"].get("seq_gaps", 0) for x in xs if h in x["hops"] and x["hops"][h].get("talk"))
            ns = [x["hops"][h]["talk"].get("net_shift_ms", 0) for x in xs if h in x["hops"] and x["hops"][h].get("talk")]
            out.append(f"  {h}: n {len(ia)} max gap {min(ia):.1f}-{max(ia):.1f} median {statistics.median(ia):.1f} (>40: {o40}) spread max {min(sp):.1f}-{max(sp):.1f} steps {st} ts_jumps {tj} seq_gaps {sg} net shift {min(ns):+.1f} to {max(ns):+.1f}")
        emp = sum(x["pjsua"]["empty"] for x in xs)
        empt = sum(1 for x in xs for e in x.get("empty_events", []) if e["in_talk"])
        out.append(f"  pjsua empty {emp} (in talk {empt}); lost {sum(x['pjsua']['lost'] for x in xs)}")
        bs = [s for x in xs for s in x.get("bob_steps", []) if s["in_talk"] and abs(s["change_ms"]) >= 15]
        out.append(f"  lasting steps at bob in talk >= 15 ms: {len(bs)}: " + ", ".join(f"{s['change_ms']:+.0f}" for s in bs))
        if arm == "candidate":
            ms = [x for (bb, t), x in mix.items() if bb == b]
            r = [ro for x in ms for ro in x["rooms"]]
            out.append(f"  mixer: {len(ms)} windows, ticks {sum(ro['ticks'] for ro in r)}, late>10ms {sum(ro['late_over_10ms'] for ro in r)}, late>20ms {sum(ro['late_over_20ms'] for ro in r)}, overruns {sum(ro['overruns'] for ro in r)}; windows with an overrun: " + ", ".join(x['trial'] for x in ms if any(ro['overruns'] for ro in x['rooms'])))
            lg = [l for x in ms for l in x["legs"]]
            out.append(f"  mixer legs: lost {sum(l['lost'] for l in lg)} late {sum(l['late'] for l in lg)} dropped {sum(l['dropped'] for l in lg)} underruns {sum(l['underruns'] for l in lg)}")
        print("\n".join(out))
    print("  captures with a gap > 40 ms in talk at any hop:")
    for (bb, t), x in sorted(rtp.items()):
        if bb != b: continue
        g = {h: x["hops"][h]["talk"]["max_interarrival_ms"] for h in x["hops"] if x["hops"][h].get("talk")}
        if any(v > 40 for v in g.values()):
            print(f"    {t}: " + " ".join(f"{h} {v:.1f}" for h, v in g.items()) + f" net at bob {x['hops'].get('at_bob',{}).get('talk',{}).get('net_shift_ms')}")
