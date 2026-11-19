#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Fetch the rebar3 dependencies, retrying. hex.pm now and then answers
# "Package not found in any repo" for a package it has (seen in CI for
# webtransport 0.5.11, a dependency of ws); refreshing the registry index
# and trying again gets past it. Run from the umbrella root.
set -u

for attempt in 1 2 3 4; do
    if rebar3 get-deps; then
        exit 0
    fi
    echo "fetch_deps: attempt $attempt failed, refreshing the hex index" >&2
    rebar3 update || true
    sleep $((attempt * 10))
done
echo "fetch_deps: giving up" >&2
exit 1
