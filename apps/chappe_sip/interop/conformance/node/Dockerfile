# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# Test image for the conformance lab: OTP 29 and the toolchain to build
# sofia-sip and the NIF. The chappe tree is not baked in: entry.sh build
# copies it into a volume and compiles it there, so a rebuild after a
# change only recompiles what changed. The node runs on the lab network
# next to SIPp and pjsua, because Docker Desktop on macOS cannot send UDP
# from the host to container addresses.
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

COPY entry.sh /usr/local/bin/chappe-conf
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/chappe-conf"]
