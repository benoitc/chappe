#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The entry point of the cluster demo's image (docker-compose.yml):
#   build        copy /host (the chappe tree, read-only) into /work and
#                compile it, the SIP engine included, with the demo modules
#   node         run this container as demo@<hostname>: demo_cluster:start/0
#   trunk        run the trunk (demo_cluster_trunk) as trunk@<hostname>
#   ctl          stay up; smoke.sh runs `ctl-run CMD...' in it
#   ctl-run ...  one demo_cluster_ctl command
#   shell NODE   a remote shell on NODE (n1, n2, n3)
set -eu

COOKIE=${COOKIE:-chappe-demo-cluster}
PA="-kernel prevent_overlapping_partitions false -pa /work/src/_build/default/lib/*/ebin /work/demo_ebin"

case "${1:-}" in
    build)
        # the host's macOS build outputs must not reach the Linux build
        rsync -a --delete \
            --exclude=/_build --exclude=c_src/build --exclude=priv/lib \
            --exclude=node_modules --exclude=/.claude --exclude=/.git \
            /host/ /work/src/
        cd /work/src
        sh scripts/fetch_deps.sh
        rebar3 compile
        mkdir -p /work/demo_ebin
        erlc -o /work/demo_ebin demo/cluster/src/*.erl
        echo "demo build done"
        ;;
    node)
        mkdir -p /data
        cd /data
        # shellcheck disable=SC2086
        exec erl -noshell -sname "demo@$(hostname)" -setcookie "$COOKIE" $PA \
            -eval "ok = demo_cluster:start()."
        ;;
    trunk)
        # shellcheck disable=SC2086
        exec erl -noshell -sname "trunk@$(hostname)" -setcookie "$COOKIE" $PA \
            -eval "ok = demo_cluster_trunk:start()."
        ;;
    ctl)
        exec sleep infinity
        ;;
    ctl-run)
        shift
        ARGS=$(printf '"%s",' "$@")
        # shellcheck disable=SC2086
        exec erl -noshell -sname "ctl$$@$(hostname)" -setcookie "$COOKIE" $PA \
            -eval "demo_cluster_ctl:main([${ARGS%,}])."
        ;;
    shell)
        exec erl -sname "shell$$@$(hostname)" -setcookie "$COOKIE" \
            -remsh "demo@${2:?usage: shell n1|n2|n3}"
        ;;
    *)
        echo "usage: run.sh build | node | trunk | ctl | ctl-run CMD... | shell NODE" >&2
        exit 2
        ;;
esac
