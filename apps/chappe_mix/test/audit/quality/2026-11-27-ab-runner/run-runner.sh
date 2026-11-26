#!/usr/bin/env bash
# The four blocks, old, new, old, new, on a Linux runner at the declared
# gate (MAX_LOAD 4.0, LOAD_QUIET 30 s, MAXWAIT 1800 s), into OUT_DIR. As
# 2026-11-26-ab-gate8/run-gate8.sh, whose ab.sh and block.sh it runs, with
# three changes:
# - each trial is this directory's trial.sh (RUN1), as taq does not run
#   on the runner;
# - every 10 s, OUT_DIR/hostload.log gets the 1, 5 and 15 min load
#   averages (/proc/loadavg) and the cumulative CPU steal and total, in
#   jiffies, from /proc/stat: "HH:MM:SS L1 L5 L15 steal S total T";
# - no trial starts after DEADLINE (epoch s, default 300 min after the
#   start): the run stops at a trial boundary (exit 5).
# A refused trial is tried again up to four more times (block.sh's
# RETRIES); one still refused stops the run (exit 3). The rtpengine-loss
# sessions stay (exit 4 when they run out). BLOCKS ("N BUILD REP", comma
# separated, default the four) narrows the blocks, for a smoke run; FIRST
# and SESS0_FIRST resume a run, as in run-gate8.sh. Exits 1 when a block
# ended with a failed trial, 0 when every trial is captured.
# Usage: WT=... PADDED_DIR=... [OUT_DIR=...] run-runner.sh
set -uo pipefail
R=$(cd "$(dirname "$0")" && pwd)
G=$(cd "$R/../2026-11-26-ab-gate8" && pwd)
[ -r /proc/loadavg ] || { echo "run-runner.sh: no /proc/loadavg (Linux only)" >&2; exit 2; }
export MAX_LOAD=${MAX_LOAD:-4.0} LOAD_QUIET=${LOAD_QUIET:-30} MAXWAIT=${MAXWAIT:-1800}
export OUT_DIR=${OUT_DIR:-$R/runner}
export RUN1=$R/trial.sh
export WT=${WT:?WT, the directory holding the ab-<sha> worktrees}
export PADDED_DIR=${PADDED_DIR:?PADDED_DIR, the directory pad.py wrote}
export DEADLINE=${DEADLINE:-$(($(date +%s) + 300 * 60))}
unset STOP_ON_FIRST_REFUSAL
mkdir -p "$OUT_DIR"
steal() {
    awk '$1 == "cpu" { t = 0; for (i = 2; i <= 9; i++) t += $i; print "steal", $9, "total", t }' /proc/stat
}
while :; do
    echo "$(date -u +%H:%M:%S) $(cut -d' ' -f1-3 /proc/loadavg) $(steal)"
    sleep 10
done >> "$OUT_DIR/hostload.log" &
SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null || true' EXIT
say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$OUT_DIR/blocks.log"; }
say "MAX_LOAD $MAX_LOAD LOAD_QUIET $LOAD_QUIET MAXWAIT $MAXWAIT," \
    "no trial after $(date -u -d "@$DEADLINE" +%FT%TZ), RUN1 $RUN1"
IFS=, read -r -a LIST <<< "${BLOCKS:-1 old 0,2 new 0,3 old 1,4 new 1}"
FAILED=0
for b in "${LIST[@]}"; do
    # shellcheck disable=SC2086
    set -- $b
    [ "$1" -lt "${FIRST:-1}" ] && continue
    if [ "$1" -eq "${FIRST:-1}" ]; then s0=${SESS0_FIRST:-1}; else s0=1; fi
    SESS0=$s0 MAXSESS=$((s0 + 3)) bash "$G/ab.sh" "$1" "$2" "$3"; rc=$?
    [ "$rc" -eq 3 ] && { say "stopped at block $1: gate refused"; exit 3; }
    [ "$rc" -eq 4 ] && { say "stopped at block $1: the demo kept losing rtpengine"; exit 4; }
    [ "$rc" -eq 5 ] && { say "stopped at block $1: the deadline passed"; exit 5; }
    if [ "$rc" -ne 0 ]; then say "block $1 ended rc=$rc, going on"; FAILED=$((FAILED + 1)); fi
done
if [ "$FAILED" -ne 0 ]; then say "all blocks done, $FAILED with a failed trial"; exit 1; fi
say "all blocks done"
