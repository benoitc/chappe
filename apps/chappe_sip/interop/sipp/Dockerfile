# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# Test image: SIPp from the Ubuntu 24.04 archive (package sip-tester,
# SIPp 3.7.2), for amd64 and arm64 alike, and socat for the TLS listener
# of dns_sips_failover. The scenarios and run.sh are mounted at
# /scenarios.
FROM ubuntu:24.04
# apt as scripts/ci_apt.sh runs it: a stalled mirror or a stale index fails
# one bounded attempt, and the next one fetches the index again
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-retries \
    && for i in 1 2 3; do \
        timeout 300 apt-get update \
        && DEBIAN_FRONTEND=noninteractive timeout 900 apt-get install -y \
            --no-install-recommends sip-tester socat \
        && break; \
        [ "$i" -lt 3 ] || exit 1; sleep $((i * 15)); \
    done \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
ENTRYPOINT ["/bin/sh", "/scenarios/run.sh"]
