# HD room A/B on a GitHub runner

This directory runs the HD room A/B of `../2026-11-26-ab-gate8` (old
`821870c` against new `840bb74`, blocks old, new, old, new) on a
GitHub-hosted runner, where the declared load gate (1 min load at most 4.0)
can be met. The runner only captures: taq does not run there. You import the
captures with `taq live-import` and score them with `taq compare` on your
machine. You need it when a capture must come from a quiet host. The decisions
behind the run are in [`gate-decision.txt`](gate-decision.txt).

| File | What it does |
| --- | --- |
| `trial.sh` | one trial: the load gate of taq's `run1.sh`, then taq live's two calls through `hd.sh`, then `trial.json` |
| `trial.py` | writes `trial.json` and checks the trial (exit codes, recordings, SDP answers) |
| `pad.py` | checks the clips against `clips/SHA256SUMS` and writes the played files (2 s of silence added) |
| `run-runner.sh` | the blocks, through the gate-8 `ab.sh` and `block.sh`, with `trial.sh` as `RUN1` |
| `rtpan-runner.py` | the gate-8 `rtpan.py` on these trials, alice's speech taken from `trial.json` (no played file is kept) |
| `perblock-runner.py` | per block: waits, load, CPU steal, mixer ticks and RTP gaps over 40 ms |
| [`traces/`](traces/) | the hop-by-hop results of the A/B of 2026-11-27, one trial per line |
| [`clips/`](clips/README.md) | the eight prepared VCTK clips (CC BY 4.0) |

## Start a run

Push a branch under `quality/`. The workflow (`.github/workflows/quality.yml`)
runs one job at a time.

```sh
# a pipeline check: one block of the new build, clip p225, both directions
git push origin HEAD:quality/hd-ab-runner-smoke
# the A/B: four blocks, 128 trials, about 1 h 55 min after 7 min of setup
git push origin HEAD:quality/hd-ab-runner
```

A branch whose name ends in `-smoke` runs the smoke; any other runs the A/B.
No trial starts after 285 min of the job, so the upload always happens.

## Fetch the captures

```sh
gh run list --workflow quality.yml --limit 5
gh run download RUN_ID -n hd-ab-full \
    -D ~/Projects/telephony-audio-quality/runs/hd-room-ab-runner/full
```

The artifact (`hd-ab-smoke` or `hd-ab-full`) holds one directory per build
(`old/`, `new/`) with a directory per trial, `load.log`, the `ID.live.log`
files, `hostload.log`, `blocks.log`, the demo logs and versions per session,
the mixer probe logs, `pcap/` and `padded.json`.

## Import them with taq

Make each build's manifest from the gate-8 run's
(`runs/hd-room-ab-2026-11-25/gate8/old/manifest.json` and `new/`, at the
same depth, so the clip list resolves) with no trials, and copy that
build's `meta-baseline.json` and `meta-candidate.json` next to it, with
`rtpengine.digest` set to the runner's image (each session's `.versions`
gives it). Then run `taq live-import` per build and arm, with the arm's
meta file, on the trial directories only (the `ID.live.log` files would
match `b?-*`):

```sh
cd ~/Projects/telephony-audio-quality
F=runs/hd-room-ab-runner/full
for b in old new; do
    uv run taq live-import $F/$b/b?-*[0-9] --meta $F/$b/meta-baseline.json \
        --into $F/$b/manifest.json
    uv run taq live-import $F/$b/c?-*[0-9] --meta $F/$b/meta-candidate.json \
        --into $F/$b/manifest.json
done
```

`taq live-import` validates each `trial.json` against taq's
`schema/trial.schema.json` and refuses a trial with a problem. Then build
the A/B manifest with `../2026-11-26-ab-gate8/makeab.py`, which refuses a
margins block other than the declared one.

## Run it by hand

On a Linux host with Docker and the two worktrees built (as the workflow
does):

```sh
python3 pad.py clips /tmp/padded
WT=/tmp/wt PADDED_DIR=/tmp/padded OUT_DIR=/tmp/out HD_SKIP_BUILD=1 ./run-runner.sh
```

One trial against a running `make demo` (any host; on a busy one,
`MAX_LOAD=100 LOAD_QUIET=0` lets it start at once):

```sh
RUN_DIR=/tmp/hd PADDED_DIR=/tmp/padded ./trial.sh candidate 0 g722-to-opus vctk092-p225-01
```

## Notes

- `trial.json` (schema `chappe-hd-trial/1`) records the clip and its sha256,
  each call's codec, rate, ports, duration, start and end epochs and exit
  code, the pjsua image id, the host and its clock source, and the chappe
  SHA. `taq live-import` reads it.
- The pjsua image is chappe's lab image, not taq's, and the host is a VM:
  absolute scores do not compare with the Mac runs.
- `hostload.log` lines are `HH:MM:SS L1 L5 L15 steal S total T`, the CPU
  times in jiffies since boot.
