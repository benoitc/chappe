#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# One SIPp call through the SBC, inside the SIPp container, printing every
# message exchanged. Exits 0 only if the call succeeded.
#
# Usage: sipp.sh SCEN USER PAUSE_MS CALL_ID SBC_IP
#   SCEN      /sbc/SCEN.xml (this lab's scenarios), else /scenarios/SCEN.xml
#             (the conformance scenarios, reused as they are)
#   USER      the Request-URI user ([service]): anchor..., direct..., glare
#   PAUSE_MS  how long the call stays up where the scenario pauses
#   CALL_ID   the call's Call-ID, so the suite can find it at the SBC
set -u

SCEN="$1" USER="$2" PAUSE="$3" CID="$4" SBC="$5"
OUT=/tmp/out
mkdir -p "$OUT"
cd "$OUT"

if [ -f "/sbc/$SCEN.xml" ]; then
    FILE="/sbc/$SCEN.xml"
else
    FILE="/scenarios/$SCEN.xml"
fi

rc=0
sipp -sf "$FILE" -s "$USER" -d "$PAUSE" -cid_str "$CID" \
    -m 1 -l 1 -t u1 -p 5060 -nostdin -recv_timeout 20000 -timeout 200 \
    -timeout_error -trace_msg -trace_err "$SBC:5060" > "$OUT/main.out" 2>&1 \
    || rc=$?

for f in "$OUT"/*_messages.log "$OUT"/*_errors.log; do
    [ -f "$f" ] || continue
    echo "===== $(basename "$f")"
    cat "$f"
done
echo "===== result $SCEN rc=$rc"
exit "$rc"
