#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Entry point of a cluster lab node: write the cookie from CLB_COOKIE to
# ~/.erlang.cookie (it never reaches the command line or the log), then run
# the node as lab@<hostname> and boot it (chappe_cluster_lab_node).
# CLB_TICKTIME sets net_ticktime (10 s): a partition that drops packets
# leaves the connection open until the tick notices.
#
# With libfaketime in the image the beam's wall clock is the real one plus
# the offset in /lab/faketime ("+1.5", "-0.7", seconds), which the
# controller rewrites to skew this node while it runs; the monotonic clock
# stays real. CLB_TIME_WARP=multi (the default) runs the beam with
# +C multi_time_warp, so erlang:system_time follows the shift; default runs
# it in the runtime's default mode (no_time_warp), where only os:system_time
# does.
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

FT=$(find /usr/lib -name libfaketime.so.1 2>/dev/null | head -n 1)
if [ -n "$FT" ] && [ "${CLB_FAKETIME:-1}" != "0" ]; then
    echo "+0" > /lab/faketime
    LD_PRELOAD=$FT
    FAKETIME_TIMESTAMP_FILE=/lab/faketime
    FAKETIME_DONT_FAKE_MONOTONIC=1
    FAKETIME_CACHE_DURATION=1
    export LD_PRELOAD FAKETIME_TIMESTAMP_FILE FAKETIME_DONT_FAKE_MONOTONIC \
        FAKETIME_CACHE_DURATION
fi

case "${CLB_TIME_WARP:-multi}" in
    multi) WARP="+C multi_time_warp" ;;
    *) WARP="" ;;
esac

# shellcheck disable=SC2086
exec erl -sname lab -noshell -noinput $WARP \
    -kernel net_ticktime "${CLB_TICKTIME:-10}" \
    $PA -pa /lab/ebin \
    -eval 'ok = chappe_cluster_lab_node:start().'
