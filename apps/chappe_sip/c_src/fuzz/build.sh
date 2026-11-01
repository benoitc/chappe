#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Builds the libFuzzer targets in this directory into c_src/build/fuzz/bin.
# Linux with clang and libFuzzer (the test/asan image).
#
# libFuzzer steers by the coverage of the code it runs, so the sofia linked
# here is a second static build, instrumented for coverage and built with
# ASan and UBSan, beside the plain one the NIF links. It is configured like
# build.sh's (no zlib, static, -DNDEBUG as shipped), from the same patched
# copy of the vendored tree (prepare_sofia.sh), and stamped on that tree,
# the patches and the flags below.
#
# CLANG names the compiler (default clang-19, else clang).
set -e

FUZZ="$(cd "$(dirname "$0")" && pwd)"
CSRC="$(dirname "$FUZZ")"
OUT="$CSRC/build/fuzz"
DIST="$OUT/dist"
CLANG=${CLANG:-$(command -v clang-19 || command -v clang)}

# The harness: every UBSan check fatal. sofia: UBSan recoverable, so an
# undefined behaviour found in it can be suppressed (ubsan.supp, each entry
# explained) until its patch lands, while run.sh still halts on any other
# (halt_on_error).
SAN="-fsanitize=address,undefined -fno-sanitize-recover=undefined"
CFLAGS_SOFIA="-O1 -g -DNDEBUG -fno-omit-frame-pointer"
CFLAGS_SOFIA="$CFLAGS_SOFIA -fsanitize=address,undefined"
CFLAGS_SOFIA="$CFLAGS_SOFIA -fsanitize=fuzzer-no-link"
# sofia calls every header decoder and encoder through a generic function
# pointer type (msg_parser.c); clang's -fsanitize=function
# (part of undefined since clang 17) reports each call. It is how sofia is
# built, on every ABI it targets, so that one check is off for sofia only.
CFLAGS_SOFIA="$CFLAGS_SOFIA -fno-sanitize=function"
CFLAGS_SOFIA="$CFLAGS_SOFIA -Wno-error=implicit-function-declaration"
CFLAGS_SOFIA="$CFLAGS_SOFIA -Wno-error=implicit-int -Wno-error=int-conversion"

SRC_KEY=$(sh "$CSRC/prepare_sofia.sh" --key)
KEY=$(printf '%s %s %s' "$SRC_KEY" "$CLANG" "$CFLAGS_SOFIA" | cksum | awk '{print $1}')
STAMP="$OUT/.sofia.stamp"
SOFIA_COPY="$OUT/sofia-src"

if [ ! -f "$DIST/lib/libsofia-sip-ua.a" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$KEY" ]; then
    echo "==> building instrumented sofia-sip for fuzzing"
    # the patched copy with its autotools mtimes pinned, as build.sh does
    mkdir -p "$OUT"
    sh "$CSRC/prepare_sofia.sh" "$SOFIA_COPY"
    rm -rf "$OUT/sofia" "$DIST"
    mkdir -p "$OUT/sofia"
    ( cd "$OUT/sofia" && \
      "$SOFIA_COPY/configure" --prefix="$DIST" \
          --disable-shared --enable-static --with-pic \
          --disable-glib ac_cv_lib_z_compress=no \
          CC="$CLANG" CFLAGS="$CFLAGS_SOFIA" ) \
        >"$OUT/sofia-configure.log" 2>&1 || {
        echo "error: fuzz sofia configure failed:" >&2
        tail -n 40 "$OUT/sofia-configure.log" >&2
        exit 1
    }
    ( cd "$OUT/sofia" && make -j"$(nproc 2>/dev/null || echo 4)" && make install ) \
        >"$OUT/sofia-make.log" 2>&1 || {
        echo "error: fuzz sofia make failed:" >&2
        tail -n 40 "$OUT/sofia-make.log" >&2
        exit 1
    }
    echo "$KEY" >"$STAMP"
fi

INC=$(ls -d "$DIST"/include/sofia-sip-* | head -1)
LIBS=$(PKG_CONFIG_PATH="$DIST/lib/pkgconfig" pkg-config --static --libs sofia-sip-ua)
mkdir -p "$OUT/bin"
for src in "$FUZZ"/fuzz_*.c; do
    t=$(basename "$src" .c)
    echo "==> $t"
    "$CLANG" -O1 -g -fno-omit-frame-pointer $SAN -fsanitize=fuzzer \
        -I"$INC" -o "$OUT/bin/$t" "$src" $LIBS
done
