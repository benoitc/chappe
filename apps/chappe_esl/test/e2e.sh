#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs chappe_esl_live_SUITE against the two FreeSWITCH nodes of
# apps/chappe_esl/interop/docker-compose.yml, brought up and torn down here.
# The image is built from interop/freeswitch (cached after the first run).
# `docker compose up --wait' blocks on the healthchecks (fs_cli sofia
# status), so both event sockets listen before the suite connects, and
# FS_REQUIRED=1 makes an unreachable socket a failure, not a skip. The suite
# stops and starts fs1 itself through FS_COMPOSE.
#
# ESL_PROJECT (compose project, default chappe-esl), FS1_ESL_PORT (18021)
# and FS2_ESL_PORT (18022) move the stack out of the way of another one.
# ESL_SOCKET_PORT (18084) is the outbound listener the socket extension
# connects back to, on ESL_SOCKET_IP (0.0.0.0) taking the peers of
# ESL_SOCKET_ALLOW (loopback and docker's pools, comma-separated CIDRs); ESL_MEDIA_DIR (_build/esl-media) is shared with both
# nodes as /media for prompts and recordings. chappe_audio_live_SUITE then
# forks fs1's audio into a chappe_audio listener on AUDIO_PORT (18085).
#
# Usage: apps/chappe_esl/test/e2e.sh   (or: make interop-esl)
set -u

cd "$(dirname "$0")/../../.."
FS1_ESL_PORT=${FS1_ESL_PORT:-18021}
FS2_ESL_PORT=${FS2_ESL_PORT:-18022}
ESL_SOCKET_PORT=${ESL_SOCKET_PORT:-18084}
AUDIO_PORT=${AUDIO_PORT:-18085}
# created here, before docker would create it owned by root
ESL_MEDIA_DIR=${ESL_MEDIA_DIR:-$(pwd)/_build/esl-media}
mkdir -p "$ESL_MEDIA_DIR"
export FS1_ESL_PORT FS2_ESL_PORT ESL_SOCKET_PORT ESL_MEDIA_DIR
# absolute: the suite runs it from the CT log directory
COMPOSE="docker compose -p ${ESL_PROJECT:-chappe-esl} -f $(pwd)/apps/chappe_esl/interop/docker-compose.yml"

if ! $COMPOSE up -d --build --wait --wait-timeout 120; then
    echo "FreeSWITCH did not become healthy:" >&2
    $COMPOSE logs >&2
    $COMPOSE down >/dev/null 2>&1
    exit 1
fi

FS_HOST=127.0.0.1 FS_PORT=$FS1_ESL_PORT FS2_PORT=$FS2_ESL_PORT \
    FS_PASSWORD=ClueCon FS_REQUIRED=1 FS_COMPOSE="$COMPOSE" \
    rebar3 ct --dir apps/chappe_esl/test --suite chappe_esl_live_SUITE
RC=$?

FS_HOST=127.0.0.1 FS_PORT=$FS1_ESL_PORT FS_PASSWORD=ClueCon \
    AUDIO_PORT=$AUDIO_PORT \
    rebar3 ct --dir apps/chappe_audio/test --suite chappe_audio_live_SUITE
[ $? -eq 0 ] || RC=1

$COMPOSE down >/dev/null 2>&1
exit $RC
