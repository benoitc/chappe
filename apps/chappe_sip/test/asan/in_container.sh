#!/usr/bin/env bash
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The container side of test/asan/run.sh: runs in /work (a copy of the
# umbrella) with MODE, SUITES, DETECT_LEAKS and FUZZ_* set, and writes its
# reports under /out. rebar3 runs at the umbrella root, the C tools in
# apps/chappe_sip.
set -euo pipefail

cd /work
app=/work/apps/chappe_sip
supp=$app/test/asan
arch=$(uname -m)

# Build both profiles with the NIF sanitized, then keep ct from relinking
# it: its hook would rebuild it without the sanitizer, and run the compiler
# under the preloaded runtime. build.sh's NIF stamp keys on ENGINE_SANITIZE,
# CC and ENGINE_EXTRA_CFLAGS, so a volume shared between modes relinks the
# NIF but keeps sofia.
build_nif() {
    export ENGINE_SANITIZE=$1
    export ENGINE_EXTRA_CFLAGS=${2:-}
    rebar3 compile
    rebar3 as test compile
    export SKIP_ENGINE_BUILD=1
}

# ASan + UBSan, every UBSan check fatal at compile time
# (-fno-sanitize-recover) and at run time (halt_on_error). gcc links
# libubsan as a dependency of the NIF; libasan must come first, hence the
# preload. +Mea min turns the BEAM's own allocators off, so what the NIF
# takes with enif_alloc comes from malloc and ASan sees a use after
# enif_free or an overflow of it.
run_asan_suites() {
    build_nif address,undefined -fno-sanitize-recover=undefined
    export LSAN_OPTIONS=suppressions=$supp/lsan.supp
    export ASAN_OPTIONS=detect_leaks=$DETECT_LEAKS:abort_on_error=1:halt_on_error=1
    export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
    local start=$SECONDS rc=0
    # the suites that start peer nodes need epmd; started here, outside
    # the preload, as the BEAM would otherwise start it under libasan
    epmd -daemon
    ERL_FLAGS="+Mea min" LD_PRELOAD=$(gcc -print-file-name=libasan.so) \
        rebar3 ct --suite "$1" || rc=$?
    echo "==> asan: ct exit $rc in $((SECONDS - start)) s"
    return $rc
}

# TSan with clang: gcc 14's libtsan crashes any non-instrumented program it
# is preloaded into on arm64 (even sh), clang's runtime does not. build.sh
# compiles the shim with $CC, so CC is clang for this build only.
run_tsan_suites() {
    CC=clang-19 build_nif thread
    # ignore_noninstrumented_modules: the libc calls the BEAM makes (uname,
    # strlen on its own buffers) are not checked; its locks still order the
    # NIF's accesses. detect_deadlocks=0: the BEAM holds more than the 64
    # locks at once that the lock-order detector tracks, which aborts it
    # (CHECK failed in sanitizer_deadlock_detector.h) and hangs the VM.
    # halt_on_error stays off so one run lists every race;
    # any report still fails the run (counted below from the log).
    export TSAN_OPTIONS="suppressions=$supp/tsan.supp \
ignore_noninstrumented_modules=1 detect_deadlocks=0 history_size=4 \
log_path=/out/tsan exitcode=66"
    rm -rf /out/tsan.* /out/ct
    mkdir -p /out/ct
    # ct_run straight from erl, not rebar3: rebar3 forks git and the like at
    # startup, and the BEAM hangs in that fork under TSan
    local suites
    suites=$(printf '%s' "$1" | sed -e 's|apps/chappe_sip/test/||g')
    set +e
    LD_PRELOAD=$(clang-19 -print-file-name="libclang_rt.tsan-$arch.so") \
        setarch "$arch" -R erl -noshell -pa /work/_build/test/lib/*/ebin \
        -pa /work/_build/test/lib/chappe_sip/test -eval "
            Suites = [list_to_atom(S) || S <- string:split(\"$suites\", \",\", all)],
            R = ct:run_test([{dir, \"/work/_build/test/lib/chappe_sip/test\"},
                             {suite, Suites}, {logdir, \"/out/ct\"},
                             {auto_compile, false}]),
            io:format(\"ct: ~p~n\", [R]),
            case R of
                {_, 0, {_, 0}} -> halt(0);
                _ -> halt(1)
            end."
    rc=$?
    set -e
    reports=$(cat /out/tsan.* 2>/dev/null | grep -c '^WARNING: ThreadSanitizer' || true)
    echo "==> tsan: ct exit $rc, $reports report(s) in _build/nif-check/tsan"
    cat /out/tsan.* 2>/dev/null | head -400 || true
    [ "$rc" -eq 0 ] && [ "$reports" -eq 0 ]
}

lint_c() {
    unset ENGINE_SANITIZE
    cd "$app"
    c_src/build.sh
    local erts sofia_inc src=$app/c_src/chappe_sip_engine_nif.c
    erts=$(erl -noshell -eval \
        'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
    sofia_inc=$(ls -d "$app"/c_src/build/dist/include/sofia-sip-* | head -1)
    # the shim's own flags (build.sh), as a compilation database
    local flags=(-std=gnu17 -O2 -fPIC -Wall -Wextra "-I$erts" "-I$sofia_inc")
    {
        printf '[{"directory":"%s/c_src","file":"%s","arguments":["cc"' "$app" "$src"
        for f in "${flags[@]}" -c "$src"; do printf ',"%s"' "$f"; done
        printf ']}]\n'
    } >"$app"/c_src/build/compile_commands.json
    cp "$app"/c_src/build/compile_commands.json /out/
    local rc=0
    echo "==> clang-tidy (c_src/.clang-tidy)"
    clang-tidy-19 -p "$app"/c_src/build --quiet "$src" \
        >/out/clang-tidy.txt 2>&1 || rc=1
    cat /out/clang-tidy.txt
    echo "==> gcc -fanalyzer"
    gcc -fanalyzer -fdiagnostics-plain-output "${flags[@]}" -c "$src" \
        -o /dev/null >/out/fanalyzer.txt 2>&1 || rc=1
    cat /out/fanalyzer.txt
    # gcc reports analyzer findings as warnings: any one fails the job
    if grep -q '\[-Wanalyzer-' /out/fanalyzer.txt; then rc=1; fi
    echo "==> lint-c: $(grep -c 'warning:\|error:' /out/clang-tidy.txt || true) clang-tidy," \
        "$(grep -c '\[-Wanalyzer-' /out/fanalyzer.txt || true) analyzer finding(s)"
    return $rc
}

fuzz() {
    local rc=0
    unset ENGINE_SANITIZE
    "$app"/c_src/fuzz/build.sh
    "$app"/c_src/fuzz/run.sh "$FUZZ_TIME" /out || rc=1
    if [ -n "$SUITES" ]; then
        export FUZZ=1
        run_asan_suites "$SUITES" || rc=1
    fi
    return $rc
}

case "$MODE" in
    asan) run_asan_suites "$SUITES" ;;
    tsan) run_tsan_suites "$SUITES" ;;
    lint-c) lint_c ;;
    fuzz) fuzz ;;
    *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
