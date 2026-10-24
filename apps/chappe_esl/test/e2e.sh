#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs chappe_esl_live_SUITE against the FreeSWITCH from
# apps/chappe_esl/interop/docker-compose.yml, brought up and torn down here.
# `docker compose up --wait' blocks on the container healthcheck (fs_cli
# status), so the Event Socket is listening before the suite connects, and
# FS_REQUIRED=1 makes an unreachable socket a failure, not a skip.
#
# Docker Desktop for Mac can reset the published ESL connection (an empty
# banner); run this on Linux, as CI does.
#
# Usage: apps/chappe_esl/test/e2e.sh   (or: make interop-esl)
set -u

cd "$(dirname "$0")/../../.."
COMPOSE="docker compose -f apps/chappe_esl/interop/docker-compose.yml"

if ! $COMPOSE up -d --wait --wait-timeout 120; then
    echo "FreeSWITCH did not become healthy:" >&2
    $COMPOSE logs >&2
    $COMPOSE down >/dev/null 2>&1
    exit 1
fi

FS_HOST=127.0.0.1 FS_PORT=8021 FS_PASSWORD=ClueCon FS_REQUIRED=1 \
    rebar3 ct --dir apps/chappe_esl/test --suite chappe_esl_live_SUITE
RC=$?

$COMPOSE down >/dev/null 2>&1
exit $RC
