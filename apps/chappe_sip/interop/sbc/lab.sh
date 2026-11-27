#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The SBC interop lab (docker-compose.yml): a chappe SBC node, two
# FreeSWITCH peers, rtpengine and Kamailio on 10.253.9.0/24, with SIPp
# run per case on the same network.
#
#   lab.sh images          build the node, rtpengine and SIPp images
#   lab.sh build           compile this chappe tree into the node volume
#   lab.sh up              (re)start the lab and wait for both FreeSWITCH
#                          peers to be up at the SBC
#   lab.sh sipp SCEN USER PAUSE_MS CALL_ID
#                          run one SIPp call: scenarios/SCEN.xml here, or
#                          ../sipp/scenarios/SCEN.xml, as USER@sbc
#   lab.sh sipp-nat SCEN USER PAUSE_MS CALL_ID [IP]
#                          the same call to the node's NAT address
#                          (10.253.10.10, advertised as 203.0.113.10),
#                          from IP when given
#   lab.sh ctl FUN [ARGS]  call chappe_sbc_node:FUN(ARGS) on the node
#                          (erl_call -a syntax: ARGS is an Erlang list)
#   lab.sh fs N CMD        run CMD with fs_cli on fsN
#   lab.sh stop|start SVC  stop or start one service (fs1, fs2, ...)
#   lab.sh kam             Kamailio's dispatcher list (kamcmd)
#   lab.sh logs [SVC]      print the node's (or SVC's) output
#   lab.sh down            remove the lab (keeps the build volume)
#   lab.sh clean           remove the lab and its build volume
#
# SBC_LAB names the compose project (default chappe-sbc), so a second
# copy of the lab can run next to this one.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
INTEROP=$(dirname "$HERE")
ROOT=$(cd "$INTEROP/../../.." && pwd)
PROJECT=${SBC_LAB:-chappe-sbc}
VOLUME=${PROJECT}-work
export SBC_VOLUME="$VOLUME"
NODE=sbc@10.253.9.10
COOKIE=chappe-sbc

dc() {
    docker compose -p "$PROJECT" -f "$HERE/docker-compose.yml" "$@"
}

ctl() {
    FUN="$1"
    ARGS="${2:-[]}"
    dc exec -T sbc /usr/local/lib/erlang/bin/erl_call -name "$NODE" \
        -c "$COOKIE" -a "chappe_sbc_node $FUN $ARGS"
}

wait_peers() {
    i=0
    until ctl peers 2>/dev/null | grep -Eq "\{fs1, *up\}" \
        && ctl peers 2>/dev/null | grep -Eq "\{fs2, *up\}"; do
        i=$((i + 1))
        if [ "$i" -gt 90 ]; then
            dc logs sbc >&2
            exit 1
        fi
        sleep 1
    done
}

case "${1:-}" in
    images)
        "$ROOT/scripts/lab_image.sh" rtpengine
        "$ROOT/scripts/lab_image.sh" conf-node
        "$ROOT/scripts/lab_image.sh" sipp
        ;;
    build)
        docker volume create "$VOLUME" >/dev/null
        docker run --rm -v "$ROOT":/host:ro -v "$VOLUME":/work \
            -v "$HERE/node":/sbc:ro --entrypoint /bin/sh chappe-conf-node \
            /sbc/entry.sh build
        ;;
    up)
        dc up -d --force-recreate
        i=0
        until dc logs sbc 2>&1 | grep -q "chappe_sbc_node up"; do
            i=$((i + 1))
            if [ "$i" -gt 120 ]; then
                dc logs sbc >&2
                exit 1
            fi
            sleep 0.5
        done
        wait_peers
        ;;
    sipp)
        SCEN="$2" USER="$3" PAUSE="$4" CID="$5"
        docker run --rm --network "${PROJECT}_lab" \
            -v "$INTEROP/sipp/scenarios":/scenarios:ro \
            -v "$HERE/scenarios":/sbc:ro \
            -v "$HERE/sipp.sh":/sipp.sh:ro \
            --entrypoint /bin/sh chappe-conf-sipp /sipp.sh \
            "$SCEN" "$USER" "$PAUSE" "$CID" 10.253.9.10
        ;;
    sipp-nat)
        # the same, on the NAT network, to the node's NAT address; IP
        # pins SIPp's address (inside 10.253.10.0/26: the local network)
        SCEN="$2" USER="$3" PAUSE="$4" CID="$5" IP="${6:-}"
        docker run --rm --network "${PROJECT}_nat" ${IP:+--ip "$IP"} \
            -v "$INTEROP/sipp/scenarios":/scenarios:ro \
            -v "$HERE/scenarios":/sbc:ro \
            -v "$HERE/sipp.sh":/sipp.sh:ro \
            --entrypoint /bin/sh chappe-conf-sipp /sipp.sh \
            "$SCEN" "$USER" "$PAUSE" "$CID" 10.253.10.10
        ;;
    ctl)
        ctl "$2" "${3:-[]}"
        ;;
    fs)
        dc exec -T "fs$2" /usr/local/freeswitch/bin/fs_cli -x "$3"
        ;;
    stop | start)
        dc "$1" "$2"
        ;;
    kam)
        dc exec -T kamailio kamcmd -s unix:/tmp/kamailio_ctl dispatcher.list
        ;;
    logs)
        dc logs "${2:-sbc}" 2>&1
        ;;
    down)
        dc down --remove-orphans
        ;;
    clean)
        dc down --remove-orphans
        docker volume rm "$VOLUME" >/dev/null 2>&1 || true
        ;;
    *)
        sed -n '5,30p' "$0" >&2
        exit 2
        ;;
esac
