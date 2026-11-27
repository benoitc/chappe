#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Build a lab image only when its build context changed. The key is the
# sha256 of every file in the context, paths and contents (the files git
# sees, so an uncommitted edit or a new untracked file counts; every file
# outside a git tree). The image carries it as the label chappe.lab.key;
# when the image under TAG already has this key, nothing is built. An
# image built from another checkout's context, or by hand, has another
# key (or none) and is rebuilt. CI keeps the images in its cache under
# the same key (.github/actions/lab-image).
#
# Usage: scripts/lab_image.sh NAME [TAG]   build NAME as TAG unless up to date
#        scripts/lab_image.sh --key NAME   print NAME's key
#        scripts/lab_image.sh --tag NAME   print NAME's default tag
# NAME: rtpengine, pjsua, sipp, esl-fs, conf-node, conf-dns, demo-cluster.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

usage() {
    sed -n '14,17p' "$0" >&2
    exit 2
}

# lookup NAME: its default TAG and its context CTX, relative to ROOT
lookup() {
    case $1 in
        rtpengine) TAG=chappe-rtpengine-interop CTX=apps/chappe_rtpengine/interop ;;
        pjsua) TAG=chappe-conf-pjsua CTX=apps/chappe_sip/interop/pjsua ;;
        sipp) TAG=chappe-conf-sipp CTX=apps/chappe_sip/interop/sipp ;;
        esl-fs) TAG=chappe-esl-fs:lab CTX=apps/chappe_esl/interop/freeswitch ;;
        conf-node) TAG=chappe-conf-node CTX=apps/chappe_sip/interop/conformance/node ;;
        conf-dns) TAG=chappe-conf-dns CTX=apps/chappe_sip/interop/conformance/dns ;;
        demo-cluster) TAG=chappe-demo-cluster CTX=demo/cluster/node ;;
        *)
            echo "lab_image: unknown image $1" >&2
            usage
            ;;
    esac
}

if command -v sha256sum >/dev/null 2>&1; then
    sha() { sha256sum "$@"; }
else
    sha() { shasum -a 256 "$@"; }
fi

# the context's files, relative to it, one per line
files() {
    if command -v git >/dev/null 2>&1 &&
        git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -c core.quotePath=false ls-files -co --exclude-standard -- .
    else
        find . -type f | sed 's|^\./||'
    fi
}

# key CTX: the sha256 of the list of `sha256  path' lines of its files
key() {
    (
        cd "$ROOT/$1"
        files | LC_ALL=C sort -u | while IFS= read -r f; do
            # a tracked file deleted in the work tree is not in the context
            [ -f "$f" ] && sha "$f"
        done | sha | cut -d' ' -f1
    )
}

case ${1:-} in
    --key)
        [ $# -eq 2 ] || usage
        lookup "$2"
        key "$CTX"
        ;;
    --tag)
        [ $# -eq 2 ] || usage
        lookup "$2"
        echo "$TAG"
        ;;
    -* | "")
        usage
        ;;
    *)
        [ $# -le 2 ] || usage
        NAME=$1
        lookup "$NAME"
        TAG=${2:-$TAG}
        KEY=$(key "$CTX")
        HAVE=$(docker image inspect \
            -f '{{ index .Config.Labels "chappe.lab.key" }}' "$TAG" \
            2>/dev/null || true)
        if [ "$HAVE" = "$KEY" ]; then
            echo "$NAME ($TAG) up to date"
        else
            docker build -q --label "chappe.lab.key=$KEY" -t "$TAG" \
                "$ROOT/$CTX" >/dev/null
            echo "$NAME ($TAG) built"
        fi
        ;;
esac
