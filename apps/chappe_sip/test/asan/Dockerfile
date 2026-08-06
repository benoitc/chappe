# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# AddressSanitizer test image: OTP 29 (matches the project) plus the toolchain
# to build sofia-sip, the ASan NIF, and the livery dep. macOS cannot install
# ASan interceptors into a dlopen'd NIF; Linux + LD_PRELOAD can.
FROM erlang:29

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake libtool pkg-config libssl-dev cmake rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
