# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# The cluster demo's image: OTP 29 and the toolchain that builds sofia-sip
# and the SIP engine NIF (the cluster lab image has no SIP engine). The
# chappe tree is not baked in: `run.sh build' copies it into the shared
# /work volume and compiles it there once; the nodes, the trunk and ctl
# run from that volume.
FROM erlang:29.1.2

# apt as scripts/ci_apt.sh runs it: a stalled mirror or a stale index fails
# one bounded attempt, and the next one fetches the index again
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-retries \
    && for i in 1 2 3; do \
        timeout 300 apt-get update \
        && timeout 900 apt-get install -y --no-install-recommends \
            autoconf automake libtool pkg-config libssl-dev cmake rsync \
        && break; \
        [ "$i" -lt 3 ] || exit 1; sleep $((i * 15)); \
    done \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /usr/local/bin/demo-node
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/demo-node"]
