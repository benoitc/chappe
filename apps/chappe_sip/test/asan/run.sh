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
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
suites=${1:-test/chappe_sip_engine_smoke_SUITE,test/chappe_sip_dialog_ops_SUITE,test/chappe_sip_engine_lifecycle_SUITE}
img=chappe-asan

echo "==> building $img image"
docker build -q -t "$img" "$here" >/dev/null

echo "==> running $suites under AddressSanitizer"
docker run --rm \
  -v "$root":/host:ro \
  -v chappe_asan_work:/work \
  -e "SUITES=$suites" \
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
    ENGINE_SANITIZE=address rebar3 compile
    export LD_PRELOAD=$(gcc -print-file-name=libasan.so)
    # LSan is too noisy against the BEAM; focus on UAF / overflow / bad-free.
    export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1
    rebar3 ct --suite "$SUITES"
  '
