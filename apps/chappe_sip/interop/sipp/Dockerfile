# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# Test image: SIPp from the Ubuntu 24.04 archive (package sip-tester,
# SIPp 3.7.2), for amd64 and arm64 alike. The scenarios and run.sh are
# mounted at /scenarios.
FROM ubuntu:24.04
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends sip-tester \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
ENTRYPOINT ["/bin/sh", "/scenarios/run.sh"]
