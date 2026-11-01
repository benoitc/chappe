#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Prepare a buildable sofia-sip source tree from the vendored one.
#
# Usage:
#   prepare_sofia.sh DEST    copy c_src/sofia-sip to DEST (replacing it),
#                            apply c_src/sofia-patches/*.patch in name order,
#                            and pin the autotools mtimes of the copy
#   prepare_sofia.sh --key   print the key of what DEST would hold: the
#                            vendored tree's hash and the patches' checksum
#
# The vendored tree is never written to: it stays as upstream ships it, and
# every fix we carry is a patch (see sofia-patches/README.md). A hunk that
# does not apply fails the script. build.sh and the fuzz build both call it.
set -eu

CSRC=$(cd "$(dirname "$0")" && pwd)
SOFIA="$CSRC/sofia-sip"
PATCHES="$CSRC/sofia-patches"

if [ ! -f "$SOFIA/configure.ac" ]; then
    echo "error: vendored sofia-sip missing under $SOFIA" >&2
    exit 1
fi

# the patches, in name order (none is fine)
patch_list() {
    for p in "$PATCHES"/*.patch; do
        [ -f "$p" ] && echo "$p"
    done
    return 0
}

if [ "${1:-}" = "--key" ]; then
    # sofia is vendored, not a submodule: HEAD would be the umbrella's
    # commit, so key on the hash of its tree instead
    sha=$(git -C "$SOFIA" rev-parse HEAD:./ 2>/dev/null || echo unknown)
    list=$(patch_list)
    if [ -n "$list" ]; then
        # shellcheck disable=SC2086
        sum=$(cat $list | cksum | awk '{print $1}')
    else
        sum=none
    fi
    echo "$sha-$sum"
    exit 0
fi

DEST=${1:?usage: prepare_sofia.sh DEST | --key}
case "$DEST" in
    "$SOFIA"|"$SOFIA"/*)
        echo "error: DEST must not be the vendored tree" >&2
        exit 1 ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST"
# a plain copy: the trailing /. takes dotfiles too
cp -R "$SOFIA/." "$DEST/"

for p in $(patch_list); do
    echo "==> sofia patch $(basename "$p")"
    patch -d "$DEST" -p1 --forward --batch < "$p" || {
        echo "error: sofia patch $(basename "$p") does not apply" >&2
        exit 1
    }
done
# a patch that half applied leaves rejects behind
if find "$DEST" -name '*.rej' | grep -q .; then
    echo "error: sofia patches left rejected hunks in $DEST" >&2
    exit 1
fi

if [ ! -x "$DEST/configure" ]; then
    ( cd "$DEST" && \
      LIBTOOLIZE=$(command -v glibtoolize || command -v libtoolize) \
      autoreconf -fiv ) >"$DEST/.autoreconf.log" 2>&1 || {
        echo "error: autoreconf failed, see $DEST/.autoreconf.log" >&2
        exit 1
    }
fi

# the copied and patched autoreconf output must look up to date to make
sh "$CSRC/pin_autotools_mtimes.sh" "$DEST" "$DEST/.autotools-mtime"
