#!/usr/bin/env bash
# One block of the A/B: for each clip and direction, one baseline trial
# (room 1004) then one candidate trial (room 1003), at rep REP, into
# RUN_DIR (the build's directory), through taq's run1.sh (load-gated).
# - A trial the load gate refuses (nothing run) is tried again, up to
#   RETRIES (4) more times; one still refused stops the block (exit 3).
#   With STOP_ON_FIRST_REFUSAL set, a refusal before any trial of RUN_DIR
#   has started stops the block at once (exit 3).
# - When the demo has lost rtpengine (DEMO_LOG holds "node demo_rtpe down":
#   its NG requests time out), the block stops (exit 4) before the next
#   trial; a trial that failed with it is moved to failed-ng/ to run again.
# - A trial whose run directory exists (captured, or failed otherwise) is
#   skipped, so a stopped block can be resumed.
# - With DEADLINE set (epoch seconds), no trial and no retry starts after
#   it: the block stops (exit 5).
# Every other trial runs, and the block exits 1 if any failed.
# CLIPS (space separated) replaces the eight clips, for a smoke run.
# Usage: RUN_DIR=... CHAPPE_DIR=... DEMO_LOG=... DEMO_SIP_PORT=5080 block.sh REP
set -euo pipefail
REP=$1
RUN1=${RUN1:-${TAQ_DIR:?TAQ_DIR}/scripts/campaign/run1.sh}
RETRIES=${RETRIES:-4}
DEMO_LOG=${DEMO_LOG:?DEMO_LOG}
CLIPS=${CLIPS:-"vctk092-p225-01 vctk092-p226-01 vctk092-p234-01 vctk092-p237-01 vctk092-p245-01 vctk092-p248-01 vctk092-p294-01 vctk092-p326-01"}
FAILED=()
ng_down() { grep -q 'node demo_rtpe down' "$DEMO_LOG"; }
past_deadline() { [ -n "${DEADLINE:-}" ] && [ "$(date +%s)" -ge "$DEADLINE" ]; }
for c in $CLIPS; do
    for d in g722-to-opus opus-to-g722; do
        for arm in baseline candidate; do
            id=${arm:0:1}$REP-$d-$c
            if [ -e "$RUN_DIR/$id" ]; then echo "$id: already run"; continue; fi
            if ng_down; then echo "block stopped: the demo lost rtpengine before $id" >&2; exit 4; fi
            if past_deadline; then echo "block stopped: the deadline passed before $id" >&2; exit 5; fi
            n=0
            until "$RUN1" "$arm" "$REP" "$d" "$c"; do
                if ng_down; then
                    mkdir -p "$RUN_DIR/failed-ng"
                    mv "$RUN_DIR/$id" "$RUN_DIR/$id.live.log" "$RUN_DIR/failed-ng/" 2>/dev/null || true
                    echo "block stopped: the demo lost rtpengine during $id" >&2
                    exit 4
                fi
                if ! tail -n 1 "$RUN_DIR/load.log" | grep -q ' not run: '; then
                    FAILED+=("$arm $REP $d $c"); break
                fi
                n=$((n + 1))
                # the campaign's first trial refused: the host cannot be quiet
                if [ -n "${STOP_ON_FIRST_REFUSAL:-}" ] && ! grep -q ' start waited ' "$RUN_DIR/load.log"; then
                    echo "block stopped: the first trial ($id) was refused by the load gate" >&2
                    exit 3
                fi
                if [ "$n" -gt "$RETRIES" ]; then
                    echo "block stopped: the host did not get quiet for $id" >&2
                    exit 3
                fi
                if past_deadline; then
                    echo "block stopped: the deadline passed before a retry of $id" >&2
                    exit 5
                fi
                echo "$id refused by the load gate, trying again ($n of $RETRIES)" >&2
            done
        done
    done
done
if [ "${#FAILED[@]}" -ne 0 ]; then
    echo "block failed: ${#FAILED[@]} trial(s)" >&2
    printf '  %s\n' "${FAILED[@]}" >&2
    exit 1
fi
echo block done
