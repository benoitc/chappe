#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs chappe_mix_live_SUITE against the rtpengine from
# apps/chappe_rtpengine/interop/docker-compose.yml (the same stack as
# `make interop`, brought up and torn down on its own). RTPENGINE_MEDIA_IP,
# the address rtpengine can send media back to, is discovered from inside
# the container.
#
# RTPE_PROJECT, RTPE_NAME and the RTPE_* ports move the lab out of the way
# of another one, as for apps/chappe_rtpengine/test/e2e.sh.
#
# Usage: apps/chappe_mix/test/interop.sh   (or: make interop-mix)
set -u

: "${RTPE_NAME:=rtpe-e2e}" "${RTPE_NG_PORT:=12222}"
export RTPE_NAME RTPE_NG_PORT
NAME=$RTPE_NAME
NG_PORT=$RTPE_NG_PORT

cd "$(dirname "$0")/../../.."
COMPOSE="docker compose -p ${RTPE_PROJECT:-interop} -f apps/chappe_rtpengine/interop/docker-compose.yml"

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
        "the live mixer suite will be skipped" >&2
fi

RTPENGINE_HOST=127.0.0.1 \
    RTPENGINE_PORT=$NG_PORT \
    RTPENGINE_MEDIA_IP="$MEDIA_IP" \
    rebar3 ct --dir apps/chappe_mix/test --suite chappe_mix_live_SUITE
RC=$?

$COMPOSE down >/dev/null 2>&1
exit $RC
