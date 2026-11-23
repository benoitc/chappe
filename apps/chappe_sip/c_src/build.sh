#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
# Builds sofia-sip (static) and links priv/lib/chappe_sip_engine_nif.so.
# Two-stage stamps: sofia rebuilds only when its vendored tree or its
# patches (sofia-patches/) change, from a patched copy under build/sofia-src
# (the vendored tree is never written to); the NIF recompiles only when the
# shim (any file under nif/), this script or its build environment change.
# SKIP_ENGINE_BUILD=1 skips everything (pure Erlang work).
set -e

[ -n "$SKIP_ENGINE_BUILD" ] && exit 0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSRC="$ROOT/c_src"
SOFIA="$CSRC/sofia-sip"
BUILD="$CSRC/build"
DIST="$BUILD/dist"
PRIV="$ROOT/priv/lib"
# the shim: every nif/*.c, compiled into the one .so; nif/engine.h is
# their private header
NIF_DIR="$CSRC/nif"
NIF_SRCS=$(ls "$NIF_DIR"/*.c)
NIF_SO="$PRIV/chappe_sip_engine_nif.so"

if [ ! -f "$SOFIA/configure.ac" ]; then
    echo "error: vendored sofia-sip missing under $SOFIA" >&2
    exit 1
fi

# sofia is built from a patched copy of the vendored tree (prepare_sofia.sh):
# its key is the vendored tree's hash and the patches' checksum, so a new
# patch rebuilds sofia.
SOFIA_SRC_KEY=$(sh "$CSRC/prepare_sofia.sh" --key)
# bump SOFIA_CONF when the configure options change, so a tree built with
# the old ones is reconfigured
SOFIA_CONF=nozlib-nonth
SOFIA_KEY="$SOFIA_SRC_KEY-$SOFIA_CONF"
SOFIA_COPY="$BUILD/sofia-src"

# The NIF stamp must change when anything that affects the built object does:
# the shim's sources and headers, this script, the sanitizer, the target arch/OS, and the
# ERTS version (a .so built against a different erl_nif.h can crash the VM).
ERTS_VSN=$(erl -noshell -eval \
    'io:format("~ts", [erlang:system_info(version)]), halt().' 2>/dev/null || echo unknown)
# CC picks the compiler and ENGINE_EXTRA_CFLAGS adds flags to the shim (a
# sanitizer option, a tool's instrumentation); both are in the stamp.
CC="${CC:-cc}"
NIF_ENV="san=${ENGINE_SANITIZE:-none};werror=${ENGINE_WERROR:-0};cc=${CC}"
NIF_ENV="$NIF_ENV;extra=${ENGINE_EXTRA_CFLAGS:-};plat=$(uname -sm);erts=${ERTS_VSN}"
# the shim links sofia statically: a rebuilt sofia relinks it
NIF_ENV="$NIF_ENV;sofia=$SOFIA_KEY"
NIF_SUM=$(cksum "$NIF_DIR"/*.c "$NIF_DIR"/*.h "$0" 2>/dev/null | cksum |
    awk '{print $1}')
NIF_SUM="$NIF_SUM-$(printf '%s' "$NIF_ENV" | cksum | awk '{print $1}')"

# --- stage 1: sofia-sip static build ---
SOFIA_STAMP="$BUILD/.sofia.stamp"
if [ ! -f "$DIST/lib/libsofia-sip-ua.a" ] || [ "$(cat "$SOFIA_STAMP" 2>/dev/null)" != "$SOFIA_KEY" ]; then
    echo "==> building sofia-sip ($SOFIA_KEY)"
    # the patched copy, and a clean build directory: objects from another
    # source tree or other patches must not survive
    sh "$CSRC/prepare_sofia.sh" "$SOFIA_COPY"
    rm -rf "$BUILD/sofia"
    mkdir -p "$BUILD/sofia"

    # OpenSSL via pkg-config (homebrew on macOS); disable TLS if absent.
    SSL_OPT=""
    if [ -d /opt/homebrew/opt/openssl@3/lib/pkgconfig ]; then
        PKG_CONFIG_PATH="/opt/homebrew/opt/openssl@3/lib/pkgconfig:$PKG_CONFIG_PATH"
        export PKG_CONFIG_PATH
    fi
    pkg-config --exists openssl 2>/dev/null || SSL_OPT="--with-openssl=no"

    # macOS: su_os_nw.c needs these frameworks
    DARWIN_FRAMEWORKS=""
    [ "$(uname -s)" = "Darwin" ] && \
        DARWIN_FRAMEWORKS="-framework CoreFoundation -framework SystemConfiguration"

    # gcc >= 14 (e.g. Ubuntu 24.04) makes implicit-function-declaration,
    # implicit-int, and int-conversion hard errors by default; sofia is old C,
    # so relax them back to warnings. Harmless on older compilers.
    RELAX="-Wno-error=implicit-function-declaration -Wno-error=implicit-int"
    RELAX="$RELAX -Wno-error=int-conversion"
    # No zlib: with it nta inflates gzip and deflate bodies with uncompress()
    # (which only reads zlib framing), rewrites Content-Encoding to deflate,
    # and deflates responses to compressed requests whatever their
    # Accept-Encoding. chappe applies no content coding; the request worker
    # answers 415 to an encoded INVITE body instead.
    # No nth: it is the only switch for sofia's ws, wss and HTTP CONNECT
    # transports (tport_type_ws.c, ws.c) and the http and nth modules.
    # chappe serves WebSocket in Erlang and links none of them.
    ( cd "$BUILD/sofia" && \
      "$SOFIA_COPY/configure" --prefix="$DIST" \
          --disable-shared --enable-static --with-pic \
          --disable-glib --disable-nth $SSL_OPT ac_cv_lib_z_compress=no \
          CFLAGS="-O2 -g -DNDEBUG $RELAX" LDFLAGS="$DARWIN_FRAMEWORKS" ) \
        >"$BUILD/sofia-configure.log" 2>&1 || {
        echo "error: sofia configure failed:" >&2
        tail -n 40 "$BUILD/sofia-configure.log" >&2
        exit 1
    }
    NCPU=$( (sysctl -n hw.ncpu || nproc) 2>/dev/null | head -1 )
    ( cd "$BUILD/sofia" && make -j"${NCPU:-4}" && make install ) \
        >"$BUILD/sofia-make.log" 2>&1 || {
        echo "error: sofia make failed:" >&2
        tail -n 40 "$BUILD/sofia-make.log" >&2
        exit 1
    }
    # Upstream's own test that a DNS name whose compression pointers loop
    # is refused instead of spinning the resolver (CVE-2026-116792). It
    # needs no network and builds from the objects above in seconds. It
    # runs on the build host, so it is skipped when configure's host is not
    # its build system (cross-compiling: the program could not run here) or
    # when SOFIA_SKIP_CHECK=1.
    CONF_LOG="$BUILD/sofia/config.log"
    SOFIA_HOST=$(sed -n "s/^host='\(.*\)'$/\1/p" "$CONF_LOG" | head -1)
    SOFIA_BUILD=$(sed -n "s/^build='\(.*\)'$/\1/p" "$CONF_LOG" | head -1)
    if [ "${SOFIA_SKIP_CHECK:-0}" = "1" ]; then
        echo "==> sofia check skipped (SOFIA_SKIP_CHECK=1)"
    elif [ "$SOFIA_HOST" != "$SOFIA_BUILD" ]; then
        echo "==> sofia check skipped (cross-compiling for $SOFIA_HOST)"
    else
        ( cd "$BUILD/sofia/libsofia-sip-ua/sresolv" && \
          make torture_sres_domain && ./torture_sres_domain ) \
            >"$BUILD/sofia-check.log" 2>&1 || {
            echo "error: sofia check torture_sres_domain failed:" >&2
            tail -n 40 "$BUILD/sofia-check.log" >&2
            exit 1
        }
    fi
    echo "$SOFIA_KEY" > "$SOFIA_STAMP"
fi

# --- stage 2: NIF shim ---
NIF_STAMP="$BUILD/.nif.stamp"
if [ -f "$NIF_SO" ] && [ "$(cat "$NIF_STAMP" 2>/dev/null)" = "$NIF_SUM" ]; then
    exit 0
fi
echo "==> building chappe_sip_engine_nif.so"
mkdir -p "$PRIV"

ERTS_INCLUDE=$(erl -noshell -eval \
    'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
SOFIA_INCLUDE=$(ls -d "$DIST"/include/sofia-sip-* | head -1)

PKG_CONFIG_PATH="$DIST/lib/pkgconfig:$PKG_CONFIG_PATH"
export PKG_CONFIG_PATH
SOFIA_LIBS=$(pkg-config --static --libs sofia-sip-ua 2>/dev/null \
    || echo "-L$DIST/lib -lsofia-sip-ua -lpthread")

case "$(uname -s)" in
    Darwin) SO_LDFLAGS="-bundle -undefined dynamic_lookup -framework CoreFoundation -framework SystemConfiguration" ;;
    *)      SO_LDFLAGS="-shared" ;;
esac

# ENGINE_SANITIZE=address|undefined builds the shim with the sanitizer.
# The BEAM that loads the .so must preload the sanitizer runtime, e.g.:
#   ENGINE_SANITIZE=address rebar3 compile
#   DYLD_INSERT_LIBRARIES=$(cc -print-file-name=libclang_rt.asan_osx_dynamic.dylib) \
#     rebar3 ct    (Linux: LD_PRELOAD=$(cc -print-file-name=libasan.so))
SAN=""
[ -n "$ENGINE_SANITIZE" ] && SAN="-fsanitize=$ENGINE_SANITIZE -fno-omit-frame-pointer"

# Hardening flags for the shim only (sofia keeps its own). Each one is kept
# only when this compiler takes it without a diagnostic, so older and newer
# gcc and clang all build. ENGINE_WERROR=1 (set by CI) turns the shim's
# warnings into errors; a local build on a newer compiler only warns.
PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chappe_nif_probe.XXXXXX")
trap 'rm -rf "$PROBE_DIR"' EXIT
printf 'int chappe_probe(void);\nint chappe_probe(void) { return 0; }\n' \
    > "$PROBE_DIR/p.c"

# cflag_ok FLAGS: the compiler takes FLAGS without a diagnostic
cflag_ok() {
    "$CC" -Werror $1 -c -o "$PROBE_DIR/p.o" "$PROBE_DIR/p.c" >/dev/null 2>&1
}
# ldflag_ok FLAGS: a shared object links with FLAGS
ldflag_ok() {
    "$CC" -Werror -fPIC $SO_LDFLAGS $1 -o "$PROBE_DIR/p.so" "$PROBE_DIR/p.c" \
        >/dev/null 2>&1
}

HARDEN=""
# -fvisibility=hidden keeps every shim function out of the .so's dynamic
# symbols (ERL_NIF_INIT exports nif_init with default visibility), so none
# can clash with sofia's or another NIF's; -Wmissing-prototypes makes a
# function another file calls declare itself in nif/engine.h.
for f in -std=gnu17 \
         -Wall -Wextra -Wformat=2 -Wconversion -Wsign-conversion -Wshadow \
         -Wnull-dereference -Wimplicit-fallthrough -Wmissing-prototypes \
         -fvisibility=hidden \
         -fstack-protector-strong -fstack-clash-protection \
         -ftrivial-auto-var-init=zero; do
    cflag_ok "$f" && HARDEN="$HARDEN $f"
done
# FORTIFY needs the optimizer and gets in the way of the sanitizers'
# interceptors; some toolchains predefine it, so undefine it first
FORTIFY="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3"
if [ -z "$ENGINE_SANITIZE" ] && cflag_ok "-O2 $FORTIFY"; then
    HARDEN="$HARDEN $FORTIFY"
fi
case "$(uname -m)" in
    x86_64|amd64)
        cflag_ok -fcf-protection && HARDEN="$HARDEN -fcf-protection" ;;
    arm64|aarch64)
        cflag_ok -mbranch-protection=standard &&
            HARDEN="$HARDEN -mbranch-protection=standard" ;;
esac
HARDEN_LD=""
RELRO="-Wl,-z,relro,-z,now,-z,noexecstack"
if [ "$(uname -s)" = "Linux" ] && ldflag_ok "$RELRO"; then
    HARDEN_LD="$RELRO"
fi
[ "$ENGINE_WERROR" = "1" ] && HARDEN="$HARDEN -Werror"
echo "==> shim flags:$HARDEN $HARDEN_LD"

# erts and sofia headers are -isystem: their warnings are not the shim's
"$CC" -O2 -g -fPIC $HARDEN $SAN ${ENGINE_EXTRA_CFLAGS:-} \
    -isystem "$ERTS_INCLUDE" -isystem "$SOFIA_INCLUDE" \
    $SO_LDFLAGS $HARDEN_LD -o "$NIF_SO" $NIF_SRCS $SOFIA_LIBS

echo "$NIF_SUM" > "$NIF_STAMP"
