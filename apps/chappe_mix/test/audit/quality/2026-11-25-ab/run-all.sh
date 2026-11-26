#!/usr/bin/env bash
# The four blocks, old, new, old, new, at the declared gate (MAX_LOAD 4.0,
# LOAD_QUIET 30 s, MAXWAIT 1800 s), into OUT_DIR (strict/). FIRST (1) is
# the block to start from and SESS0_FIRST its first session (to resume).
# Stops when the gate refuses a trial (exit 3): the first trial of the
# campaign at once, any other after its retries.
set -uo pipefail
R=$(cd "$(dirname "$0")" && pwd)
export MAX_LOAD=${MAX_LOAD:-4.0} LOAD_QUIET=${LOAD_QUIET:-30} MAXWAIT=${MAXWAIT:-1800}
export OUT_DIR=${OUT_DIR:-$R/strict}
for b in "1 old 0" "2 new 0" "3 old 1" "4 new 1"; do
    set -- $b
    [ "$1" -lt "${FIRST:-1}" ] && continue
    if [ "$1" -eq "${FIRST:-1}" ]; then s0=${SESS0_FIRST:-1}; else s0=1; fi
    if [ "$1" -eq 1 ]; then first=1; else first=""; fi
    STOP_ON_FIRST_REFUSAL=$first SESS0=$s0 MAXSESS=$((s0 + 3)) \
        bash "$R/ab.sh" "$1" "$2" "$3"; rc=$?
    [ "$rc" -eq 3 ] && { echo "stopped at block $1: gate refused"; exit 3; }
    [ "$rc" -eq 4 ] && { echo "stopped at block $1: the demo kept losing rtpengine"; exit 4; }
done
echo all blocks done
