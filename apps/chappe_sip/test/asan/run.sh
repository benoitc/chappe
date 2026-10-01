#!/usr/bin/env bash
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Run the engine-lifecycle CT suites under AddressSanitizer in a Linux
# container. macOS strips ASan interceptors for a dlopen'd NIF loaded into a
# non-instrumented BEAM ("interceptors are not working"); Linux + LD_PRELOAD
# installs them. Use this to validate the C NIF (c_src/chappe_sip_engine_nif.c)
# after changes to its memory / thread lifecycle.
#
# Usage: test/asan/run.sh [suite,...]
#   default suites: the engine start/stop/restart lifecycle (m0 + m7)
#
# The source is rsynced into a named volume (excluding the host's macOS build
# artifacts), so the sofia-sip build is cached across runs.
#
# LeakSanitizer is on: test/asan/lsan.supp suppresses the helper programs,
# the compiler and OTP's crypto NIF, never a stack through
# chappe_sip_engine_nif.c. ASAN_DETECT_LEAKS=0 turns leak checking off.
# ASAN_VOLUME names the build volume (default chappe_asan_work).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
suites=${1:-test/chappe_sip_engine_smoke_SUITE,test/chappe_sip_dialog_ops_SUITE,test/chappe_sip_engine_lifecycle_SUITE}
img=chappe-asan
detect_leaks=${ASAN_DETECT_LEAKS:-1}
volume=${ASAN_VOLUME:-chappe_asan_work}

echo "==> building $img image"
docker build -q -t "$img" "$here" >/dev/null

echo "==> running $suites under AddressSanitizer"
docker run --rm \
  -v "$root":/host:ro \
  -v "$volume":/work \
  -e "SUITES=$suites" \
  -e "DETECT_LEAKS=$detect_leaks" \
  "$img" bash -euc '
    # exclude host build outputs (macOS _build, sofia build, and the Mach-O
    # NIF under priv/lib) so the Linux build is not clobbered
    rsync -a --delete \
      --exclude=_build --exclude=c_src/build --exclude=priv/lib \
      /host/ /work/
    # The media deps are private git repos that cannot be fetched offline in
    # this container; reuse the host'\''s already-fetched sources so rebar3 does
    # not try to re-fetch them (public deps still fetch over the network).
    mkdir -p /work/_build/default/lib
    for d in chappe_rtpengine chappe_esl; do
      if [ -d "/host/_build/default/lib/$d" ]; then
        rsync -a --delete "/host/_build/default/lib/$d/" \
          "/work/_build/default/lib/$d/"
      fi
    done
    cd /work
    # force a fresh NIF relink against the current source (the volume caches
    # the previous stamp)
    rm -f c_src/build/.nif.stamp
    # build both profiles before the preload, and keep ct from relinking
    # the NIF: its hook would rebuild it without the sanitizer, and run the
    # compiler under LSan
    ENGINE_SANITIZE=address rebar3 compile
    ENGINE_SANITIZE=address rebar3 as test compile
    export SKIP_ENGINE_BUILD=1
    export LD_PRELOAD=$(gcc -print-file-name=libasan.so)
    export LSAN_OPTIONS=suppressions=/work/test/asan/lsan.supp
    export ASAN_OPTIONS=detect_leaks=$DETECT_LEAKS:abort_on_error=1:halt_on_error=1
    rebar3 ct --suite "$SUITES"
  '
