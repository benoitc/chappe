#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
# Builds sofia-sip (static) and links priv/lib/chappe_sip_engine_nif.so.
# Two-stage stamps: sofia rebuilds only when its vendored tree changes,
# the NIF recompiles only when the shim or this script changes.
# SKIP_ENGINE_BUILD=1 skips everything (pure Erlang work).
set -e

[ -n "$SKIP_ENGINE_BUILD" ] && exit 0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSRC="$ROOT/c_src"
SOFIA="$CSRC/sofia-sip"
BUILD="$CSRC/build"
DIST="$BUILD/dist"
PRIV="$ROOT/priv/lib"
NIF_SRC="$CSRC/chappe_sip_engine_nif.c"
NIF_SO="$PRIV/chappe_sip_engine_nif.so"

if [ ! -f "$SOFIA/configure.ac" ]; then
    echo "error: vendored sofia-sip missing under $SOFIA" >&2
    exit 1
fi

# sofia is vendored, not a submodule: HEAD would be the umbrella's commit and
# rebuild sofia on every commit, so key on the hash of its tree instead
SOFIA_SHA=$(git -C "$SOFIA" rev-parse HEAD:./ 2>/dev/null || echo unknown)

# The NIF stamp must change when anything that affects the built object does:
# the shim source, this script, the sanitizer, the target arch/OS, and the
# ERTS version (a .so built against a different erl_nif.h can crash the VM).
ERTS_VSN=$(erl -noshell -eval \
    'io:format("~ts", [erlang:system_info(version)]), halt().' 2>/dev/null || echo unknown)
NIF_ENV="san=${ENGINE_SANITIZE:-none};plat=$(uname -sm);erts=${ERTS_VSN}"
NIF_SUM=$(cksum "$NIF_SRC" "$0" | cksum | awk '{print $1}')
NIF_SUM="$NIF_SUM-$(printf '%s' "$NIF_ENV" | cksum | awk '{print $1}')"

# --- stage 1: sofia-sip static build ---
SOFIA_STAMP="$BUILD/.sofia.stamp"
if [ ! -f "$DIST/lib/libsofia-sip-ua.a" ] || [ "$(cat "$SOFIA_STAMP" 2>/dev/null)" != "$SOFIA_SHA" ]; then
    echo "==> building sofia-sip ($SOFIA_SHA)"
    mkdir -p "$BUILD/sofia"

    if [ ! -x "$SOFIA/configure" ]; then
        ( cd "$SOFIA" && \
          LIBTOOLIZE=$(command -v glibtoolize || command -v libtoolize) \
          autoreconf -fiv ) >"$BUILD/sofia-autoreconf.log" 2>&1 || {
            echo "error: autoreconf failed, see $BUILD/sofia-autoreconf.log" >&2
            exit 1
        }
    fi

    # We vendor the autoreconf output (configure, Makefile.in, etc.). A fresh
    # git checkout gives every file the same mtime, so autotools' maintainer
    # rules may think the .ac/.am sources are newer and try to regenerate
    # configure/Makefile.in -- which fails when autoconf/automake are absent.
    # Touch the generated files last so make treats them as up to date.
    find "$SOFIA" \( -name configure -o -name aclocal.m4 -o -name config.h.in \
       -o -name "Makefile.in" -o -path "*/m4/*.m4" \) -exec touch {} +

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
    ( cd "$BUILD/sofia" && \
      "$SOFIA/configure" --prefix="$DIST" \
          --disable-shared --enable-static --with-pic \
          --disable-glib $SSL_OPT \
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
    echo "$SOFIA_SHA" > "$SOFIA_STAMP"
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

cc -O2 -g -Wall -Wextra -fPIC $SAN \
    -I"$ERTS_INCLUDE" -I"$SOFIA_INCLUDE" \
    $SO_LDFLAGS -o "$NIF_SO" "$NIF_SRC" $SOFIA_LIBS

echo "$NIF_SUM" > "$NIF_STAMP"
