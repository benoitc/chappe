#!/usr/bin/env bash
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Check the C NIF (c_src/nif/) in a Linux container.
# macOS strips sanitizer interceptors for a dlopen'd NIF loaded into a
# non-instrumented BEAM and has no libFuzzer or clang-tidy; Linux +
# LD_PRELOAD installs the interceptors.
#
# Usage: test/asan/run.sh [MODE] [suite,...]
#   asan    (default) every chappe_sip suite (all of them start the NIF
#           engine) under ASan + UBSan, LeakSanitizer on, with the BEAM's
#           allocators off (+Mea min) so enif_alloc'd memory is checked too
#   tsan    the lifecycle stress and smoke suites under ThreadSanitizer
#   lint-c  clang-tidy and gcc -fanalyzer on each shim file, and a check
#           that the .so exports no shim symbol but nif_init
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
# The umbrella is rsynced into the named volume (excluding the host's macOS
# build artifacts) and the suites run from its root, so the sibling apps a
# suite needs (chappe_rtpengine for the SIPREC and media suites) are there,
# and the sofia-sip build is cached across runs. Reports and fuzz crash
# inputs are copied to apps/chappe_sip/_build/nif-check/<mode> on the host.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
app=$(cd "$here/../.." && pwd)
root=$(cd "$app/../.." && pwd)

mode=asan
case "${1:-}" in
    asan | tsan | lint-c | fuzz) mode=$1; shift ;;
esac
[ $# -gt 0 ] && SUITES=$1

# The asan suites: every suite of the app, as each one starts the NIF
# engine (engine_mod defaults to chappe_sip_nif) and a bug only one of them
# reaches (two bound addresses, forking, TLS, the SIPREC taps) is otherwise
# never under ASan. The NIF fuzz suite runs in fuzz mode. A suite listed
# for tsan or fuzz that does not exist yet is skipped.
asan_suites=$(cd "$app/test" && ls -- *_SUITE.erl | sed -e 's/\.erl$//' |
    grep -v '^chappe_sip_nif_fuzz_SUITE$')
tsan_suites="chappe_sip_engine_lifecycle_SUITE chappe_sip_engine_smoke_SUITE"
fuzz_suites="chappe_sip_nif_fuzz_SUITE"

suite_list() {
    local out="" s
    extra=${EXTRA_SUITES:-}
    for s in $1 ${extra//,/ }; do
        [ -f "$app/test/$s.erl" ] || { echo "skip $s (absent)" >&2; continue; }
        out="${out:+$out,}apps/chappe_sip/test/$s"
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
out="$app/_build/nif-check/$mode"
mkdir -p "$out"

echo "==> building $img image"
docker build -q -t "$img" "$here" >/dev/null

echo "==> $mode${suites:+: $(printf '%s' "$suites" | tr ',' '\n' | wc -l) suite(s)}"
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
    # NIF under priv/lib) so the Linux build is not clobbered; the deps are
    # public and fetch over the network
    rsync -a --delete \
        --exclude=.git --exclude=_build --exclude=c_src/build \
        --exclude=priv/lib \
        /host/ /work/
    cd /work
    exec apps/chappe_sip/test/asan/in_container.sh
  '
