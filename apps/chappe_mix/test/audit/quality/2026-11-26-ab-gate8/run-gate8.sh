#!/usr/bin/env bash
# The four blocks, old, new, old, new, at the maintainer's gate of
# 2026-11-26 (MAX_LOAD 8.0, LOAD_QUIET 30 s, MAXWAIT 1800 s), into OUT_DIR
# (gate8/). As run-all.sh, except that the campaign's first trial is tried
# again like any other (block.sh's RETRIES), and that no trial starts after
# DEADLINE (8 h after the start): the run stops at a trial boundary (exit
# 5). The 1 min, 5 min and 15 min load averages are sampled every 10 s into
# OUT_DIR/hostload.log while it runs.
set -uo pipefail
R=$(cd "$(dirname "$0")" && pwd)
export MAX_LOAD=${MAX_LOAD:-8.0} LOAD_QUIET=${LOAD_QUIET:-30} MAXWAIT=${MAXWAIT:-1800}
export OUT_DIR=${OUT_DIR:-$R/gate8}
export DEADLINE=${DEADLINE:-$(($(date +%s) + 8 * 3600))}
unset STOP_ON_FIRST_REFUSAL
mkdir -p "$OUT_DIR"
while :; do
    echo "$(date -u +%H:%M:%S) $(sysctl -n vm.loadavg)"
    sleep 10
done >> "$OUT_DIR/hostload.log" &
SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null || true' EXIT
echo "$(date -u +%FT%TZ) MAX_LOAD $MAX_LOAD LOAD_QUIET $LOAD_QUIET MAXWAIT $MAXWAIT," \
    "no trial after $(date -u -r "$DEADLINE" +%FT%TZ)" | tee -a "$OUT_DIR/blocks.log"
for b in "1 old 0" "2 new 0" "3 old 1" "4 new 1"; do
    set -- $b
    [ "$1" -lt "${FIRST:-1}" ] && continue
    if [ "$1" -eq "${FIRST:-1}" ]; then s0=${SESS0_FIRST:-1}; else s0=1; fi
    SESS0=$s0 MAXSESS=$((s0 + 3)) bash "$R/ab.sh" "$1" "$2" "$3"; rc=$?
    [ "$rc" -eq 3 ] && { echo "stopped at block $1: gate refused"; exit 3; }
    [ "$rc" -eq 4 ] && { echo "stopped at block $1: the demo kept losing rtpengine"; exit 4; }
    [ "$rc" -eq 5 ] && { echo "stopped at block $1: the 8 h limit passed"; exit 5; }
    [ "$rc" -ne 0 ] && echo "block $1 ended rc=$rc, going on"
done
echo all blocks done
