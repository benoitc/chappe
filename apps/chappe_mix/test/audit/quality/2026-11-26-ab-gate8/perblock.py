#!/usr/bin/env python3
"""Per block of the gate-8 run: the waits and the 1 min load at each
trial start (the builds' load.log), the load sampled every 10 s while
the block ran (hostload.log), the mixer's late ticks and overruns, and
the candidate and baseline captures with a gap over 40 ms in speech
into rtpengine and out of it.

Usage: perblock.py GATE8_DIR TRACES_DIR
"""
import json, sys, re, statistics
from pathlib import Path
from datetime import datetime, timezone
G = Path(sys.argv[1])
T = Path(sys.argv[2])
host = []
for l in (G / "hostload.log").read_text().splitlines():
    p = l.replace("{", "").replace("}", "").split()
    host.append((p[0], float(p[1])))
blocks = {1: ("old", "0", ["block1-old-s1"]), 2: ("new", "0", ["block2-new-s1", "block2-new-s2"]),
          3: ("old", "1", ["block3-old-s1"]), 4: ("new", "1", ["block4-new-s1"])}
for n, (b, rep, sess) in blocks.items():
    ll = [l for l in (G / b / "load.log").read_text().splitlines() if " start waited " in l and re.search(rf" [bc]{rep}-", l)]
    la = [float(re.search(r"load ([\d.]+)", l).group(1)) for l in ll]
    w = [int(re.search(r"waited (\d+) s", l).group(1)) for l in ll]
    # load during the block's trials: samples between first start and last end
    t0, t1 = ll[0].split()[0], [l for l in (G / b / "load.log").read_text().splitlines() if re.search(rf" [bc]{rep}-", l)][-1].split()[0]
    hl = [v for t, v in host if t0 <= t <= t1]
    rtp = [x for s in sess for x in json.load(open(T / f"{s}-rtp.json"))]
    mix = [x for s in sess for x in json.load(open(T / f"{s}-mix.json"))]
    cand = [x for x in rtp if x["arm"] == "candidate"]
    base = [x for x in rtp if x["arm"] == "baseline"]
    g40 = lambda xs, h: sum(1 for x in xs if x["hops"].get(h, {}).get("talk", {}).get("max_interarrival_ms", 0) > 40)
    r = [ro for x in mix for ro in x["rooms"]]
    print(f"block {n} {b}: {len(ll)} starts, waits total {sum(w)} s max {max(w)}; 1 min load at start {min(la)}-{max(la)} median {statistics.median(la):.2f}; "
          f"during {t0}-{t1}: {min(hl)}-{max(hl)} median {statistics.median(hl):.2f}, samples over 8: {sum(v > 8 for v in hl)}/{len(hl)}")
    print(f"   mixer ({len(mix)} windows): late>10ms {sum(ro['late_over_10ms'] for ro in r)} late>20ms {sum(ro['late_over_20ms'] for ro in r)} overruns {sum(ro['overruns'] for ro in r)}; "
          f"talk gaps >40 ms: candidate into_rtpengine {g40(cand,'into_rtpengine')} rtpengine_out {g40(cand,'rtpengine_out')}; baseline (FS) into_rtpengine {g40(base,'into_rtpengine')} rtpengine_out {g40(base,'rtpengine_out')}")
