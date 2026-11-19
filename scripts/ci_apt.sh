#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Install packages on a CI runner without hanging on a stalled mirror.
# apt's own timeouts only end a connection that goes silent; one that
# trickles, or stalls in TLS, can hold apt for hours (seen in CI: an
# apt-get update stuck for 84 minutes on the Ubuntu mirror). Each attempt
# is bounded by timeout(1) and apt drops dead connections after 30 s;
# a failed attempt is tried again. Usage: scripts/ci_apt.sh PKG...
set -u

APT_OPTS="-o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
-o Acquire::https::Timeout=30"

for attempt in 1 2 3; do
    # shellcheck disable=SC2086
    if timeout 300 sudo apt-get $APT_OPTS update &&
        timeout 600 sudo apt-get $APT_OPTS install -y "$@"; then
        exit 0
    fi
    echo "ci_apt: attempt $attempt failed" >&2
    sleep $((attempt * 15))
done
echo "ci_apt: giving up" >&2
exit 1
