# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# The cluster demo's image: OTP 29 and the toolchain that builds sofia-sip
# and the SIP engine NIF (the cluster lab image has no SIP engine). The
# chappe tree is not baked in: `run.sh build' copies it into the shared
# /work volume and compiles it there once; the nodes, the trunk and ctl
# run from that volume.
FROM erlang:29.1.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake libtool pkg-config libssl-dev cmake rsync \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /usr/local/bin/demo-node
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/demo-node"]
