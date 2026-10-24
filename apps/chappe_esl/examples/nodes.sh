#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Starts the two FreeSWITCH nodes of apps/chappe_esl/interop/docker-compose.yml
# and an Erlang shell with chappe_esl monitoring them (examples/nodes.config).
# The nodes are stopped when the shell exits. See examples/README.md.
#
# Usage: apps/chappe_esl/examples/nodes.sh   (or: make demo-esl)
set -eu

cd "$(dirname "$0")/../../.."
COMPOSE="docker compose -p ${ESL_PROJECT:-chappe-esl-demo} -f apps/chappe_esl/interop/docker-compose.yml"

rebar3 compile
$COMPOSE up -d --wait --wait-timeout 120
trap '$COMPOSE down >/dev/null 2>&1' EXIT

echo
echo "fs1 and fs2 are up. In another terminal:"
echo "  $COMPOSE stop fs1"
echo "  $COMPOSE start fs1"
echo

erl -pa _build/default/lib/chappe_esl/ebin \
    -config apps/chappe_esl/examples/nodes.config \
    -eval 'application:ensure_all_started(chappe_esl)'
