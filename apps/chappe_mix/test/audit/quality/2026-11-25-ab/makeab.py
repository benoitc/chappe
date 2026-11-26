#!/usr/bin/env python3
"""Fill the A/B manifest (manifest.json of this directory) from the two
builds' manifests: old's chappe_mix (candidate) trials become its baseline
arm, new's its candidate arm, each trial renamed <build>-<trial_id>, with
its capture paths under <build>/. The margins block is not touched; the
script refuses to run when it differs from the one declared (its sha256).

Usage: makeab.py DIR DECLARED_SHA256
"""

import copy
import hashlib
import json
import sys
from pathlib import Path


def sha(margins):
    return hashlib.sha256(json.dumps(margins, sort_keys=True).encode()).hexdigest()


def main(d, declared):
    d = Path(d)
    ab = json.loads((d / "manifest.json").read_text())
    if sha(ab["margins"]) != declared:
        raise SystemExit("manifest.json: margins differ from the declared block")
    trials = []
    for build, arm in (("old", "baseline"), ("new", "candidate")):
        m = json.loads((d / build / "manifest.json").read_text())
        if sha(m["margins"]) != declared:
            raise SystemExit(f"{build}/manifest.json: margins differ from the declared block")
        for t in m["trials"]:
            if t["arm"] != "candidate":
                continue
            t = copy.deepcopy(t)
            t["trial_id"] = f"{build}-{t['trial_id']}"
            t["arm"] = arm
            for c in t["captures"]:
                c["path"] = f"{build}/{c['path']}"
            if t.get("run_dir"):
                t["run_dir"] = f"{build}/{t['run_dir']}"
            trials.append(t)
    ab["trials"] = trials
    (d / "manifest.json").write_text(json.dumps(ab, indent=2) + "\n")
    print(f"{len(trials)} trial(s): "
          f"{sum(t['arm'] == 'baseline' for t in trials)} old, "
          f"{sum(t['arm'] == 'candidate' for t in trials)} new")


if __name__ == "__main__":
    main(*sys.argv[1:])
