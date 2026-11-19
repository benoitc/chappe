#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# chappe-conf build   copy /host (the chappe tree, read-only) into /work
#                     and compile it with the conformance node module
# chappe-conf run IP  start the node on IP:5060 in the foreground
# chappe-conf hepcalls IP
#                     call the node at IP once over UDP, TCP, TLS and WS
set -eu

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
        mkdir -p /work/conf_ebin
        erlc -o /work/conf_ebin \
            apps/chappe_sip/interop/conformance/node/chappe_conf_node.erl
        ;;
    run)
        IP="${2:?usage: chappe-conf run IP}"
        cd /work/src
        exec erl -noshell -pa _build/default/lib/*/ebin /work/conf_ebin \
            -eval "ok = chappe_conf_node:start(\"$IP\")."
        ;;
    hepcalls)
        IP="${2:?usage: chappe-conf hepcalls IP}"
        cd /work/src
        exec erl -noshell -pa _build/default/lib/*/ebin /work/conf_ebin \
            -eval "ok = chappe_conf_node:hep_calls(\"$IP\"), halt()."
        ;;
    *)
        echo "usage: chappe-conf build | run IP | hepcalls IP" >&2
        exit 2
        ;;
esac
