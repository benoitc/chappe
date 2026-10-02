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
#   dns_*         a second listener plays the destination the lab's DNS
#                 records name (lab.sh runs this container at their
#                 address), and CASE.xml asks the node to dial it. For
#                 dns_srv it is SIPp on UDP 5080 (dns_srv-target.xml); for
#                 dns_sips_failover socat takes TLS on 5061 and
#                 tls_target.sh answers. Both sides must succeed.
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
    dns_sips_failover)
        # SIPp's TLS listener drops its answers (wolfssl), so socat takes
        # TLS on 5061 and tls_target.sh answers the one request
        LISTEN="OPENSSL-LISTEN:5061,reuseaddr,verify=0"
        LISTEN="$LISTEN,cert=/certs/sipp.pem,key=/certs/sipp.key"
        socat -T 15 "$LISTEN" EXEC:"/bin/sh /scenarios/tls_target.sh" \
            > "$OUT/target.out" 2>&1 &
        TARGET=$!
        sleep 1
        # shellcheck disable=SC2086
        sipp $COMMON -sf "$SCEN/$CASE.xml" -p 5060 "$NODE:5060" \
            > "$OUT/main.out" 2>&1 || rc=$?
        kill "$TARGET" 2>/dev/null
        wait "$TARGET" 2>/dev/null
        echo "===== tls_target.sh"
        cat "$OUT/target.out"
        grep -q "^answered 200" "$OUT/target.out" || rc=$((rc + 1))
        ;;
    dns_*)
        # shellcheck disable=SC2086
        sipp $COMMON -t u1 -p 5080 -sf "$SCEN/$CASE-target.xml" \
            > "$OUT/target.out" 2>&1 &
        TARGET=$!
        sleep 1
        # shellcheck disable=SC2086
        sipp $COMMON -sf "$SCEN/$CASE.xml" -p 5060 "$NODE:5060" \
            > "$OUT/main.out" 2>&1 || rc=$?
        wait "$TARGET" || rc=$((rc + $?))
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
