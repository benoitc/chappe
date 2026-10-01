# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# Test image for the conformance lab: OTP 29 and the toolchain to build
# sofia-sip and the NIF. The chappe tree is not baked in: entry.sh build
# copies it into a volume and compiles it there, so a rebuild after a
# change only recompiles what changed. The node runs on the lab network
# next to SIPp and pjsua, because Docker Desktop on macOS cannot send UDP
# from the host to container addresses.
FROM erlang:29

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake libtool pkg-config libssl-dev cmake rsync \
    && rm -rf /var/lib/apt/lists/*

COPY entry.sh /usr/local/bin/chappe-conf
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/chappe-conf"]
