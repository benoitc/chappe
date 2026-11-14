#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs the gated live and e2e suites against the rtpengine from
# interop/docker-compose.yml. RTPENGINE_MEDIA_IP (the address rtpengine
# can send media back to) is discovered from inside the container.
#
# RTPE_PROJECT (compose project), RTPE_NAME (container, rtpe-e2e) and the
# RTPE_*_PORT, RTPE_RTP_MIN and RTPE_RTP_MAX ports move the lab out of the
# way of another one.
#
# Usage: test/e2e.sh   (or: make interop)
set -u

: "${RTPE_NAME:=rtpe-e2e}" "${RTPE_NG_PORT:=12222}" "${RTPE_TCP_PORT:=12223}"
: "${RTPE_HTTP_PORT:=12224}" "${RTPE_HTTPS_PORT:=12225}"
: "${RTPE_RTP_MIN:=30000}" "${RTPE_RTP_MAX:=30100}"
export RTPE_NAME RTPE_NG_PORT RTPE_TCP_PORT RTPE_HTTP_PORT RTPE_HTTPS_PORT \
    RTPE_RTP_MIN RTPE_RTP_MAX
NAME=$RTPE_NAME
NG_PORT=$RTPE_NG_PORT
NG_TCP_PORT=$RTPE_TCP_PORT
NG_HTTP_PORT=$RTPE_HTTP_PORT
NG_HTTPS_PORT=$RTPE_HTTPS_PORT

cd "$(dirname "$0")/.."
COMPOSE="docker compose -p ${RTPE_PROJECT:-interop} -f interop/docker-compose.yml"

$COMPOSE up -d --build --force-recreate || exit 1
sleep 2
if ! docker ps --format '{{.Names}}' | grep -q "^$NAME\$"; then
    echo "rtpengine container failed to start:" >&2
    $COMPOSE logs >&2
    $COMPOSE down >/dev/null 2>&1
    exit 1
fi

MEDIA_IP="$(docker exec "$NAME" getent hosts host.docker.internal \
    2>/dev/null | awk '{print $1}')" || MEDIA_IP=""
if [ -z "$MEDIA_IP" ]; then
    echo "warning: cannot resolve host.docker.internal;" \
        "the media relay cases will be skipped" >&2
fi

RTPENGINE_HOST=127.0.0.1 \
    RTPENGINE_PORT=$NG_PORT \
    RTPENGINE_TCP_PORT=$NG_TCP_PORT \
    RTPENGINE_HTTP_PORT=$NG_HTTP_PORT \
    RTPENGINE_HTTPS_PORT=$NG_HTTPS_PORT \
    RTPENGINE_MEDIA_IP="$MEDIA_IP" \
    rebar3 ct --suite chappe_rtpengine_live_SUITE,chappe_rtpengine_e2e_SUITE,chappe_rtpengine_siprec_SUITE
RC=$?

$COMPOSE down >/dev/null 2>&1
exit $RC
