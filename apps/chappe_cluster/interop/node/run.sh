#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Entry point of a cluster lab node: write the cookie from CLB_COOKIE to
# ~/.erlang.cookie (it never reaches the command line or the log), then run
# the node as lab@<hostname> and boot it (chappe_cluster_lab_node).
# CLB_TICKTIME sets net_ticktime (10 s): a partition that drops packets
# leaves the connection open until the tick notices.
set -eu

if [ -z "${CLB_COOKIE:-}" ]; then
    echo "CLB_COOKIE is not set" >&2
    exit 1
fi
umask 077
printf '%s' "$CLB_COOKIE" > "$HOME/.erlang.cookie"
unset CLB_COOKIE
umask 022
mkdir -p "${CLB_LOG_DIR:-/logs}" "${CLB_DATA_DIR:-/data}"

PA=""
for dir in /lab/lib/*/ebin; do
    [ -d "$dir" ] && PA="$PA -pa $dir"
done

# shellcheck disable=SC2086
exec erl -sname lab -noshell -noinput \
    -kernel net_ticktime "${CLB_TICKTIME:-10}" \
    $PA -pa /lab/ebin \
    -eval 'ok = chappe_cluster_lab_node:start().'
