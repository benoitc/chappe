#!/usr/bin/env bash
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Check the C NIF (c_src/chappe_sip_engine_nif.c) in a Linux container.
# macOS strips sanitizer interceptors for a dlopen'd NIF loaded into a
# non-instrumented BEAM and has no libFuzzer or clang-tidy; Linux +
# LD_PRELOAD installs the interceptors.
#
# Usage: test/asan/run.sh [MODE] [suite,...]
#   asan    (default) the engine suites under ASan + UBSan, LeakSanitizer on
#   tsan    the lifecycle stress and smoke suites under ThreadSanitizer
#   lint-c  clang-tidy and gcc -fanalyzer on the shim
#   fuzz    the libFuzzer targets (c_src/fuzz) then the NIF fuzz suite
#           (chappe_sip_nif_fuzz_SUITE) under ASan + UBSan
# A first argument that is not a mode is taken as the suite list (asan).
#
# Environment:
#   SUITES             comma-separated suite list (overrides the default)
#   EXTRA_SUITES       added to the default list
#   ASAN_DETECT_LEAKS  0 turns leak checking off (asan, fuzz)
#   FUZZ_TIME          seconds per libFuzzer target (fuzz, default 60)
#   FUZZ_ITERS         NIF fuzz suite iterations per case (fuzz)
#   FUZZ_SEED          NIF fuzz suite seed (fuzz, default: random, logged)
#   NIF_IMAGE          image tag (default chappe-nif)
#   NIF_VOLUME         build volume (default chappe_nif_<mode>; ASAN_VOLUME
#                      is still honoured for asan)
#
# The source is rsynced into the named volume (excluding the host's macOS
# build artifacts), so the sofia-sip build is cached across runs. Reports and
# fuzz crash inputs are copied to _build/nif-check/<mode> on the host.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

mode=asan
case "${1:-}" in
    asan | tsan | lint-c | fuzz) mode=$1; shift ;;
esac
[ $# -gt 0 ] && SUITES=$1

# The asan suites; a suite listed here that does not exist yet is skipped,
# so a new one only needs adding to the list.
asan_suites="chappe_sip_engine_smoke_SUITE chappe_sip_dialog_ops_SUITE
chappe_sip_engine_lifecycle_SUITE chappe_sip_core_SUITE
chappe_sip_nif_boundary_SUITE"
tsan_suites="chappe_sip_engine_lifecycle_SUITE chappe_sip_engine_smoke_SUITE"
fuzz_suites="chappe_sip_nif_fuzz_SUITE"

suite_list() {
    local out="" s
    extra=${EXTRA_SUITES:-}
    for s in $1 ${extra//,/ }; do
        [ -f "$root/test/$s.erl" ] || { echo "skip $s (absent)" >&2; continue; }
        out="${out:+$out,}test/$s"
    done
    printf '%s' "$out"
}

case "$mode" in
    asan) default=$(suite_list "$asan_suites") ;;
    tsan) default=$(suite_list "$tsan_suites") ;;
    fuzz) default=$(suite_list "$fuzz_suites") ;;
    *) default="" ;;
esac
suites=${SUITES:-$default}

img=${NIF_IMAGE:-chappe-nif}
if [ "$mode" = asan ]; then
    volume=${NIF_VOLUME:-${ASAN_VOLUME:-chappe_nif_asan}}
else
    volume=${NIF_VOLUME:-chappe_nif_$mode}
fi
out="$root/_build/nif-check/$mode"
mkdir -p "$out"

echo "==> building $img image"
docker build -q -t "$img" "$here" >/dev/null

echo "==> $mode${suites:+: $suites}"
# TSan maps its shadow at fixed addresses; ASLR with 32 random mmap bits
# (recent kernels) breaks that, so tsan runs under setarch -R, which the
# default seccomp profile refuses.
sec=()
[ "$mode" = tsan ] && sec=(--security-opt seccomp=unconfined)
docker run --rm "${sec[@]}" \
    -v "$root":/host:ro \
    -v "$volume":/work \
    -v "$out":/out \
    -e "MODE=$mode" \
    -e "SUITES=$suites" \
    -e "DETECT_LEAKS=${ASAN_DETECT_LEAKS:-1}" \
    -e "FUZZ_TIME=${FUZZ_TIME:-60}" \
    -e "FUZZ_ITERS=${FUZZ_ITERS:-}" \
    -e "FUZZ_SEED=${FUZZ_SEED:-}" \
    "$img" bash -euc '
    # exclude host build outputs (macOS _build, sofia build, and the Mach-O
    # NIF under priv/lib) so the Linux build is not clobbered
    rsync -a --delete \
        --exclude=_build --exclude=c_src/build --exclude=priv/lib \
        /host/ /work/
    # The media deps are private git repos that cannot be fetched offline in
    # this container; reuse the host'\''s already-fetched sources so rebar3
    # does not try to re-fetch them (public deps still fetch over the
    # network).
    mkdir -p /work/_build/default/lib
    for d in chappe_rtpengine chappe_esl; do
        if [ -d "/host/_build/default/lib/$d" ]; then
            rsync -a --delete "/host/_build/default/lib/$d/" \
                "/work/_build/default/lib/$d/"
        fi
    done
    cd /work
    exec test/asan/in_container.sh
  '
