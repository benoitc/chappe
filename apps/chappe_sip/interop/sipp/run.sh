#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs one conformance scenario inside the SIPp container against the
# chappe node, prints every message exchanged, and exits 0 only if every
# SIPp instance of the case succeeded.
#
# Usage: run.sh CASE NODE_IP
#
# Most cases are one SIPp instance running scenarios/CASE.xml. Two shapes
# need more than one:
#   refer_*       a second instance on port 5070 plays the transfer
#                 target (scenarios/refer_target.xml); its outcome is not
#                 the case's
#   replaces_confirmed, replaces_early
#                 two twin instances (SIPp 3PCC mode): CASE-a.xml holds
#                 the first dialog, CASE-b.xml sends the INVITE with
#                 Replaces built from the tags CASE-a.xml hands it
set -u

CASE="$1"
NODE="$2"
SCEN=/scenarios/scenarios
OUT=/tmp/out
mkdir -p "$OUT"
cd "$OUT"

# -recv_timeout fails a call that waits more than 10 s for a message (a
# recv with its own timeout overrides it); -timeout bounds the whole run
COMMON="-m 1 -l 1 -t u1 -nostdin -recv_timeout 10000 -timeout 200 \
    -timeout_error -trace_msg -trace_err"

show() {
    for f in "$OUT"/*_messages.log "$OUT"/*_errors.log; do
        [ -f "$f" ] || continue
        echo "===== $(basename "$f")"
        cat "$f"
    done
}

rc=0
case "$CASE" in
    refer_*)
        # one transfer per REFER: refer_event_id sends two
        CALLS=1
        [ "$CASE" = refer_event_id ] && CALLS=2
        # shellcheck disable=SC2086
        sipp $COMMON -m "$CALLS" -l "$CALLS" \
            -sf "$SCEN/refer_target.xml" -p 5070 "$NODE:5060" \
            > "$OUT/target.out" 2>&1 &
        TARGET=$!
        # shellcheck disable=SC2086
        sipp $COMMON -sf "$SCEN/$CASE.xml" -p 5060 "$NODE:5060" \
            > "$OUT/main.out" 2>&1 || rc=$?
        kill "$TARGET" 2>/dev/null
        wait "$TARGET" 2>/dev/null
        ;;
    replaces_confirmed | replaces_early)
        # the instance that waits for the twin command listens first
        # shellcheck disable=SC2086
        sipp $COMMON -sf "$SCEN/$CASE-b.xml" -p 5070 \
            -3pcc 127.0.0.1:5678 "$NODE:5060" > "$OUT/b.out" 2>&1 &
        B=$!
        sleep 1
        # shellcheck disable=SC2086
        sipp $COMMON -sf "$SCEN/$CASE-a.xml" -p 5060 \
            -3pcc 127.0.0.1:5678 "$NODE:5060" > "$OUT/a.out" 2>&1 || rc=$?
        wait "$B" || rc=$((rc + $?))
        ;;
    *)
        # shellcheck disable=SC2086
        sipp $COMMON -sf "$SCEN/$CASE.xml" -p 5060 "$NODE:5060" \
            > "$OUT/main.out" 2>&1 || rc=$?
        ;;
esac

show
echo "===== result $CASE rc=$rc"
exit "$rc"
