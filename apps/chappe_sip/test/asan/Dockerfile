# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0

# The C NIF checking image: OTP 29 (matches the project), the toolchain to
# build sofia-sip, the NIF and the livery dep, plus the C tools test/asan/
# drives: gcc 14 (ASan, UBSan, TSan runtimes and -fanalyzer), clang 19 with
# libFuzzer and clang-tidy. macOS cannot install sanitizer interceptors into
# a dlopen'd NIF and has no libFuzzer or clang-tidy; Linux + LD_PRELOAD can.
FROM erlang:29.1.2

# apt as scripts/ci_apt.sh runs it: a stalled mirror or a stale index fails
# one bounded attempt, and the next one fetches the index again
RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-retries \
    && for i in 1 2 3; do \
        timeout 300 apt-get update \
        && timeout 900 apt-get install -y --no-install-recommends \
            autoconf automake libtool pkg-config libssl-dev cmake rsync \
            clang-19 clang-tidy-19 libclang-rt-19-dev llvm-19 \
        && break; \
        [ "$i" -lt 3 ] || exit 1; sleep $((i * 15)); \
    done \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
