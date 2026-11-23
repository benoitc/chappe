#!/usr/bin/env bash
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Build an app's docs and Hex package the way `rebar3 hex publish` does,
# so a broken doc, a dependency missing from the package or a package that
# does not build shows up before publishing (which cannot be undone).
#
#   1. Docs, against the in-repo sibling apps: a copy of the app gets them
#      in _checkouts, so this runs even when a sibling's new version is not
#      on Hex yet.
#   2. The package, with dependencies from Hex, then
#      check_hex_requirements.py and the Hex size limits (8 MB compressed,
#      64 MB uncompressed). A dependency version not on Hex yet means the
#      siblings must be published first: that is reported as a warning, not
#      a failure.
#   3. An app with a C build (c_src/build.sh, chappe_sip): the package's
#      contents unpacked in a clean directory, outside any git tree, and the
#      NIF built from them, as a Hex user's rebar3 does.
#
# The Erlang build of steps 1 and 2 skips the C build (SKIP_ENGINE_BUILD):
# step 3 builds it from the package itself.
#
# Usage: scripts/check_package.sh <app>

set -euo pipefail

APP=$1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/apps/$APP"
[ -f "$DIR/rebar.config" ] || { echo "no app $APP"; exit 2; }

MAX_TAR=$((8 * 1024 * 1024))
MAX_CONTENTS=$((64 * 1024 * 1024))

# rebar3 hex publish leaves out every dependency found in the app's own
# _checkouts: a package published from such a directory lacks those
# requirements and does not build from Hex.
if [ -e "$DIR/_checkouts" ]; then
    echo "error: $DIR/_checkouts exists; remove it before publishing $APP" >&2
    exit 1
fi

# In-repo apps the app depends on, directly or through another in-repo app.
siblings() {
    python3 -I - "$ROOT" "$APP" <<'EOF'
import os, sys
root, app = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "scripts"))
sys.dont_write_bytecode = True
from check_hex_requirements import rebar_config_deps
def deps(a):
    names = rebar_config_deps(os.path.join(root, "apps", a))
    return [n for n in names if os.path.isfile(os.path.join(root, "apps", n, "rebar.config"))]
seen, todo = set(), deps(app)
while todo:
    n = todo.pop()
    if n not in seen:
        seen.add(n); todo += deps(n)
print(" ".join(sorted(seen)))
EOF
}

copy_app() {  # copy_app <app> <dest>: the sources, without build output
    # or a local lock, so dependencies resolve as in a fresh checkout
    mkdir -p "$2"
    tar -C "$ROOT/apps/$1" --exclude=_build --exclude=_checkouts --exclude=doc \
        --exclude=rebar.lock --exclude=./c_src/build --exclude=./priv/lib \
        -cf - . | tar -C "$2" -xf -
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SKIP_ENGINE_BUILD=1

echo "--- $APP: docs"
copy_app "$APP" "$WORK/$APP"
for s in $(siblings); do
    copy_app "$s" "$WORK/$APP/_checkouts/$s"
done
(cd "$WORK/$APP" && rebar3 ex_doc)

echo "--- $APP: Hex package"
PKG="$WORK/pkg/$APP"
copy_app "$APP" "$PKG"
LOG="$WORK/hex-build.log"
if ! (cd "$PKG" && rebar3 hex build) >"$LOG" 2>&1; then
    # only an in-repo sibling may be missing from Hex (not published yet):
    # any other missing package is a real failure
    missing="$(grep -o 'Package not found in any repo: [a-z_0-9]*' "$LOG" |
        sed 's/.*: //' | sort -u || true)"
    others=""
    for m in $missing; do
        case "$m" in
            chappe_*) [ -f "$ROOT/apps/$m/rebar.config" ] || others="$others $m" ;;
            *) others="$others $m" ;;
        esac
    done
    if [ -n "$missing" ] && [ -z "$others" ]; then
        grep "Package not found" "$LOG"
        echo "::warning title=$APP package not checked::$(grep -o 'Package not found in any repo: .*' "$LOG" | head -1). Publish that sibling first, then rerun."
        exit 0
    fi
    cat "$LOG"
    exit 1
fi
python3 -I "$ROOT/scripts/check_hex_requirements.py" "$PKG"

TAR="$(find "$PKG/_build" -name "$APP-*.tar" ! -name '*-docs*' | head -1)"
X="$WORK/unpacked"
mkdir -p "$X/contents"
tar -C "$X" -xf "$TAR"
tar_size=$(wc -c <"$TAR" | tr -d ' ')
contents_size=$(gzip -dc "$X/contents.tar.gz" | wc -c | tr -d ' ')
echo "  size:         $tar_size bytes compressed, $contents_size uncompressed"
if [ "$tar_size" -gt "$MAX_TAR" ] || [ "$contents_size" -gt "$MAX_CONTENTS" ]; then
    echo "  error: over the Hex limits (8 MB compressed, 64 MB uncompressed)" >&2
    exit 1
fi
tar -C "$X/contents" -xzf "$X/contents.tar.gz"
echo "  files:"
(cd "$X/contents" && find . -mindepth 1 -maxdepth 1 && find . -path './c_src/*' \
    -maxdepth 2) | sort | sed 's/^/    /'

if [ -f "$X/contents/c_src/build.sh" ]; then
    echo "--- $APP: the NIF from the package"
    # outside any git tree, with git hidden, run as the pre_hooks of
    # rebar.config runs it (so its mode must survive the package)
    SRC="$WORK/hexuser/$APP"
    mkdir -p "$SRC" "$WORK/nogit"
    cp -Rp "$X/contents/." "$SRC"
    printf '#!/bin/sh\necho "git is not available here" >&2\nexit 127\n' \
        >"$WORK/nogit/git"
    chmod +x "$WORK/nogit/git"
    # no network when the runner can take it away (Linux user namespaces)
    NONET=""
    if command -v unshare >/dev/null 2>&1 && unshare -rn true 2>/dev/null; then
        NONET="unshare -rn"
    fi
    (cd "$SRC" && env -u SKIP_ENGINE_BUILD PATH="$WORK/nogit:$PATH" \
        GIT_CEILING_DIRECTORIES="$WORK" $NONET ./c_src/build.sh)
    ls -l "$SRC"/priv/lib/*.so
fi
