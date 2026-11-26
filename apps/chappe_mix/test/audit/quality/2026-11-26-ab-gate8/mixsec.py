#!/usr/bin/env python3
"""The 16 kHz room's counters second by second over one trial, from
mixprobe's samples: each second in which a tick fired more than 10 or
20 ms late or a frame was skipped (an overrun), with the time from the
trial's start (the origin rtpan.py uses). It reads the samples with
mixan.py's parser.

Usage: mixsec.py MIXAN_PY MIX_LOG RUN_DIR
"""
import importlib.util, json, sys
from datetime import datetime, timezone
from pathlib import Path
spec = importlib.util.spec_from_file_location("mixan", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ss = [s for s in m.samples(sys.argv[2]) if isinstance(s[1], list)]
rd = Path(sys.argv[3]); rj = json.loads((rd / "run.json").read_text())
t0 = datetime.strptime(rj["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp() * 1000
prev = None
for s in ss:
    if not (t0 - 1500 <= s[0] <= t0 + 25000): continue
    rooms = {c[0]: c[1] for c in s[1] if isinstance(c[1], dict) and c[1].get("rate") == 16000}
    cur = {p: (st["ticks"], st["overruns"], m.late_over(st["late_histogram_us"], 10000), m.late_over(st["late_histogram_us"], 20000), st["late_max_us"]) for p, st in rooms.items()}
    if prev is not None:
        for p, v in cur.items():
            pv = prev.get(p, (0, 0, 0, 0, 0))
            d = [v[i] - pv[i] for i in range(4)]
            if d[1] or d[2] or d[3]:
                print(f"  t={(s[0]-t0)/1000:6.2f}s {datetime.fromtimestamp(s[0]/1000, timezone.utc).strftime('%H:%M:%S')} {p} ticks+{d[0]} overruns+{d[1]} late>10ms+{d[2]} late>20ms+{d[3]} late_max_us {v[4]}")
    prev = cur
