#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# entry.sh build   copy /host (the chappe tree, read-only) into /work and
#                  compile it with the SBC node module
# entry.sh run IP  start the SBC node on IP:5060 in the foreground, as the
#                  distributed node sbc@IP (cookie chappe-sbc) the suite
#                  drives with erl_call
set -eu

case "${1:-}" in
    build)
        # the host's macOS build outputs must not reach the Linux build
        rsync -a --delete \
            --exclude=/_build --exclude=c_src/build --exclude=priv/lib \
            --exclude=node_modules --exclude=/.claude --exclude=/.git \
            /host/ /work/src/
        cd /work/src
        rebar3 compile
        mkdir -p /work/sbc_ebin
        erlc -o /work/sbc_ebin /sbc/chappe_sbc_node.erl
        ;;
    run)
        IP="${2:?usage: entry.sh run IP}"
        cd /work/src
        exec erl -noshell -name "sbc@$IP" -setcookie chappe-sbc \
            -pa _build/default/lib/*/ebin /work/sbc_ebin \
            -eval "ok = chappe_sbc_node:start(\"$IP\")."
        ;;
    *)
        echo "usage: entry.sh build | run IP" >&2
        exit 2
        ;;
esac
