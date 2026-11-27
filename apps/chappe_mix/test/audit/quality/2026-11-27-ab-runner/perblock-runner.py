#!/usr/bin/env python3
"""Per block of the runner's A/B (one demo session per block, as
blocks.log says): the waits and the 1 min load at each trial start (the
builds' load.log), the 1 min load and the CPU steal sampled every 10 s
while the block ran (hostload.log: HH:MM:SS L1 L5 L15 steal S total T),
the mixer's late ticks and overruns, and the captures with a gap over
40 ms in speech into rtpengine and out of it. The last line covers the
whole run. The gate-8 perblock.py names gate-8's sessions and reads no
steal, hence this one.

Usage: perblock-runner.py RUN_DIR TRACES_DIR
"""
import json
import re
import statistics
import sys
from pathlib import Path

G = Path(sys.argv[1])
T = Path(sys.argv[2])
host = []
for line in (G / "hostload.log").read_text().splitlines():
    p = line.split()
    host.append((p[0], float(p[1]), int(p[5]), int(p[7])))


def steal(rows):
    if len(rows) < 2:
        return 0, 0.0
    ds, dt = rows[-1][2] - rows[0][2], rows[-1][3] - rows[0][3]
    return ds, (100.0 * ds / dt if dt else 0.0)


def g40(xs, h):
    return sum(1 for x in xs
               if x["hops"].get(h, {}).get("talk", {}).get("max_interarrival_ms", 0) > 40)


blocks = {1: ("old", "0", "block1-old-s1"), 2: ("new", "0", "block2-new-s1"),
          3: ("old", "1", "block3-old-s1"), 4: ("new", "1", "block4-new-s1")}
for n, (b, rep, sess) in blocks.items():
    lines = [x for x in (G / b / "load.log").read_text().splitlines()
             if re.search(rf" [bc]{rep}-", x)]
    starts = [x for x in lines if " start waited " in x]
    la = [float(re.search(r"load ([\d.]+)", x).group(1)) for x in starts]
    w = [int(re.search(r"waited (\d+) s", x).group(1)) for x in starts]
    t0, t1 = starts[0].split()[0], lines[-1].split()[0]
    hl = [r for r in host if t0 <= r[0] <= t1]
    l1 = [r[1] for r in hl]
    ds, sp = steal(hl)
    rtp = json.load(open(T / f"{sess}-rtp.json"))
    mix = json.load(open(T / f"{sess}-mix.json"))
    cand = [x for x in rtp if x["arm"] == "candidate"]
    base = [x for x in rtp if x["arm"] == "baseline"]
    r = [ro for x in mix for ro in x["rooms"]]
    print(f"block {n} {b} {t0}-{t1}: {len(starts)} starts, waits {sum(w)} s, longest {max(w)} s; "
          f"1 min load at start {min(la)}-{max(la)} median {statistics.median(la):.2f}; "
          f"while it ran {min(l1)}-{max(l1)} median {statistics.median(l1):.2f} "
          f"({len(l1)} samples, over 4.0: {sum(v > 4.0 for v in l1)}); steal {ds} jiffies ({sp:.3f}%)")
    print(f"   mixer ({len(mix)} windows, {sum(ro['ticks'] for ro in r)} ticks): "
          f"late>10ms {sum(ro['late_over_10ms'] for ro in r)} "
          f"late>20ms {sum(ro['late_over_20ms'] for ro in r)} "
          f"overruns {sum(ro['overruns'] for ro in r)}; talk gaps >40 ms: candidate into_rtpengine "
          f"{g40(cand, 'into_rtpengine')} rtpengine_out {g40(cand, 'rtpengine_out')} of {len(cand)}; "
          f"baseline (FS) into_rtpengine {g40(base, 'into_rtpengine')} "
          f"rtpengine_out {g40(base, 'rtpengine_out')} of {len(base)}")
l1 = [r[1] for r in host]
ds, sp = steal(host)
print(f"run {host[0][0]}-{host[-1][0]}: {len(host)} samples, 1 min load {min(l1)}-{max(l1)} "
      f"median {statistics.median(l1):.2f}, over 4.0: {sum(v > 4.0 for v in l1)}; "
      f"5 min max {max(float(x.split()[2]) for x in (G / 'hostload.log').read_text().splitlines())}; "
      f"steal {ds} jiffies ({sp:.3f}%), samples with steal moving: "
      f"{sum(1 for a, c in zip(host, host[1:]) if c[2] != a[2])}")
