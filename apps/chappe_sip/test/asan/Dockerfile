# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# The C NIF checking image: OTP 29 (matches the project), the toolchain to
# build sofia-sip, the NIF and the livery dep, plus the C tools test/asan/
# drives: gcc 14 (ASan, UBSan, TSan runtimes and -fanalyzer), clang 19 with
# libFuzzer and clang-tidy. macOS cannot install sanitizer interceptors into
# a dlopen'd NIF and has no libFuzzer or clang-tidy; Linux + LD_PRELOAD can.
FROM erlang:29.1.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake libtool pkg-config libssl-dev cmake rsync \
    clang-19 clang-tidy-19 libclang-rt-19-dev llvm-19 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
