#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Replays the demo with SIPp, for when you have no softphone: bob
# registers and waits, alice calls him, holds and unholds, then keeps the
# call up 20 s (switch its media from `make demo-shell' meanwhile) and
# hangs up. Run it while `make demo` is up; watch the demo's log.
#
# Usage: demo/sbc/run-sipp.sh [CALLEE]
#   CALLEE   who alice calls (default bob); 1000, 1001 or 1002 calls the
#            FreeSWITCH pool and plays no bob
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CALLEE=${1:-bob}
PORT=${DEMO_SIP_PORT:-5060}
IMAGE=chappe-conf-sipp

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || docker build -q -t "$IMAGE" "$ROOT/apps/chappe_sip/interop/sipp" >/dev/null

# the demo node runs on this machine
case "$(uname -s)" in
    Linux) NET="--network host" TARGET=127.0.0.1 ;;
    *) NET="--add-host=host.docker.internal:host-gateway" TARGET=host.docker.internal ;;
esac

docker rm -f chappe-demo-bob chappe-demo-alice >/dev/null 2>&1 || true
rc=0
if [ "$CALLEE" = bob ]; then
# shellcheck disable=SC2086
docker run --rm --name chappe-demo-bob $NET -v "$HERE/sipp":/demo:ro \
    --entrypoint /bin/sh "$IMAGE" /demo/bob.sh "$TARGET:$PORT" \
    > /tmp/chappe-demo-bob.out 2>&1 &
BOB=$!
i=0
until grep -q "bob registered" /tmp/chappe-demo-bob.out 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 20 ]; then
        cat /tmp/chappe-demo-bob.out >&2
        exit 1
    fi
    sleep 0.5
done
echo "bob registered"
fi
echo "alice calls $CALLEE"
# shellcheck disable=SC2086
docker run --rm --name chappe-demo-alice $NET -v "$HERE/sipp":/demo:ro \
    --entrypoint sipp "$IMAGE" -sf /demo/alice.xml -m 1 -l 1 -t u1 -p 5091 \
    -nostdin -trace_err -s "$CALLEE" "$TARGET:$PORT" \
    > /tmp/chappe-demo-alice.out 2>&1 || rc=$?
if [ "$CALLEE" = bob ]; then
    wait "$BOB" || rc=$((rc + $?))
fi
echo "done rc=$rc"
exit "$rc"
