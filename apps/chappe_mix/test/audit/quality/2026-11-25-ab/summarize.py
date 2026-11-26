#!/usr/bin/env python3
"""The rows of a QUALITY.md results table from a taq results.json.

Usage: summarize.py RESULTS_JSON
"""

import json
import statistics
import sys


def f(x, n=3, sign=True):
    return "-" if x is None else (f"{x:+.{n}f}" if sign else f"{x:.{n}f}")


def main(path):
    r = json.load(open(path))
    print(f"verdict {r['verdict']} exit {r['exit_code']}; margins sha256 {r['margins']['sha256']}")
    caps = r["captures"]
    for c in r["conditions"]:
        cid = c["condition_id"]
        d = cid.split("/")[1]
        print(f"\n## {cid}: {c['verdict']}")
        for name in ("visqol", "nisqa"):
            s = c["scorers"].get(name, {})
            p = s.get("paired_difference") or {}
            rv = s.get("reference_variation") or {}
            print(f"| {d} | {name} | {f(s.get('baseline_mean'), sign=False)} | "
                  f"{f(s.get('candidate_mean'), sign=False)} | {f(p.get('mean'))} "
                  f"[{f(p.get('ci_low'))}, {f(p.get('ci_high'))}] | {f(rv.get('mean'))} "
                  f"[{f(rv.get('ci_low'))}, {f(rv.get('ci_high'))}] | -{s.get('drop_max')} | "
                  f"{s.get('verdict')} |")
            clips = p.get("clips") or {}
            print("    per clip:", ", ".join(f"{k.split('-')[1]} {v:+.2f}" for k, v in clips.items()))
        mine = [x for x in caps if x["condition_id"] == cid]
        for arm in ("baseline", "candidate"):
            a = [x for x in mine if x["arm"] == arm]
            bw = [x["measures"]["bandwidth"]["high_band_db"] for x in a if "bandwidth" in x["measures"]]
            edge = [x["measures"]["bandwidth"]["edge_hz"] for x in a if "bandwidth" in x["measures"]]
            gaps = [x["measures"]["dropouts"]["longest_ms"] for x in a if "dropouts" in x["measures"]]
            lv = [x["measures"]["level"]["change_db"] for x in a if "level" in x["measures"]]
            clip = [x["measures"]["clipping"]["fraction"] for x in a]
            sp = [x["measures"]["delay"]["local_ms"]["spread_ms"] for x in a
                  if x["measures"].get("delay", {}).get("local_ms")]
            if not a:
                continue
            print(f"  {arm}: {len(a)} captures; bandwidth median {statistics.median(bw):.2f} worst "
                  f"{min(bw):.2f} edge {min(edge) / 1000:.2f} kHz; level {min(lv):+.2f} to "
                  f"{max(lv):+.2f}; longest gap {min(gaps):.0f} to {max(gaps):.0f} ms "
                  f"({sum(g > 40 for g in gaps)} over 40); clipping max {max(clip):g}; "
                  f"local delay spread {min(sp):.1f} to {max(sp):.1f} ms "
                  f"({sum(s > 30 for s in sp)} over 30)")
        for k in ("bandwidth", "level_vs_baseline", "dropouts", "clipping"):
            ch = c["checks"][k]
            line = f"  check {k}: {ch['verdict']} worst {ch.get('worst_candidate')} limit {ch.get('limit')}"
            if ch.get("candidate_failures"):
                line += " failing " + ", ".join(f"{x['capture'].split('.')[0]} {x['value']}"
                                                for x in ch["candidate_failures"])
            pd = ch.get("paired_difference") or {}
            if pd.get("mean") is not None:
                line += f" mean {pd['mean']:+.2f} [{f(pd.get('ci_low'), 2)}, {f(pd.get('ci_high'), 2)}]"
            if k == "level_vs_baseline" and ch.get("worst_pair"):
                wp = ch["worst_pair"]
                line += f" worst pair {wp['difference_db']:+.2f} ({wp['source']})"
            print(line)
        for p in c.get("problems", []):
            print("  note:", p)
    print("\nper capture (nisqa, visqol, local delay spread, longest gap):")
    for x in sorted(caps, key=lambda x: (x["condition_id"], x["source"]["id"], x["arm"], x["rep"])):
        m = x["measures"]
        print(f"  {x['trial_id'].split('.')[0]:48s} {x['condition_id'].split('/')[1]} "
              f"{(x['scores'].get('nisqa') or {}).get('score', float('nan')):.2f} "
              f"{(x['scores'].get('visqol') or {}).get('score', float('nan')):.2f} "
              f"{m.get('delay', {}).get('local_ms', {}).get('spread_ms')} "
              f"{m.get('dropouts', {}).get('longest_ms')}")


if __name__ == "__main__":
    main(sys.argv[1])
