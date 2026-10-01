#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The conformance lab: a chappe node, SIPp and pjsua on one docker network
# (10.253.7.0/24). Everything runs in containers because Docker Desktop on
# macOS cannot send UDP from the host to container addresses.
#
#   lab.sh images         build the node, SIPp and pjsua images
#   lab.sh build          compile this chappe tree into the node volume
#   lab.sh up             (re)start the node at 10.253.7.10:5060
#   lab.sh sipp CASE      run one SIPp case against the node
#   lab.sh pjsua NAME IP [OPTS]
#                         start a pjsua agent (see pjsua/agent.sh)
#   lab.sh cmd NAME KEYS  type console keys into a pjsua agent
#   lab.sh logs [NAME]    print the node's (or an agent's) output
#   lab.sh alive          exit 0 if the node is still running
#   lab.sh down           remove every container and the network
#
# chappe_sip_conformance_SUITE drives it; you can too, by hand.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
INTEROP=$(dirname "$HERE")
ROOT=$(cd "$INTEROP/../../.." && pwd)
NET=chappe-conf
SUBNET=10.253.7.0/24
NODE_IP=10.253.7.10
NODE=chappe-conf-node
VOL=chappe_conf_work

net() {
    docker network inspect "$NET" >/dev/null 2>&1 \
        || docker network create --subnet "$SUBNET" "$NET" >/dev/null
}

case "${1:-}" in
    images)
        docker build -q -t chappe-conf-node "$HERE/node" >/dev/null
        docker build -q -t chappe-conf-sipp "$INTEROP/sipp" >/dev/null
        docker build -q -t chappe-conf-pjsua "$INTEROP/pjsua" >/dev/null
        ;;
    build)
        # LAB_PROXY: an HTTP proxy the build container reaches hex through,
        # e.g. http://host.docker.internal:8888
        # shellcheck disable=SC2046
        docker run --rm -v "$ROOT":/host:ro -v "$VOL":/work \
            $(if [ -n "${LAB_PROXY:-}" ]; then
                echo "-e HTTPS_PROXY=$LAB_PROXY -e HTTP_PROXY=$LAB_PROXY -e https_proxy=$LAB_PROXY -e http_proxy=$LAB_PROXY"
            fi) \
            chappe-conf-node build
        ;;
    up)
        net
        docker rm -f "$NODE" >/dev/null 2>&1 || true
        docker run -d --name "$NODE" --network "$NET" --ip "$NODE_IP" \
            -v "$VOL":/work chappe-conf-node run "$NODE_IP" >/dev/null
        i=0
        until docker logs "$NODE" 2>&1 | grep -q "chappe_conf_node up"; do
            i=$((i + 1))
            if [ "$i" -gt 60 ]; then
                docker logs "$NODE" >&2
                exit 1
            fi
            sleep 0.5
        done
        ;;
    sipp)
        net
        docker run --rm --network "$NET" -v "$INTEROP/sipp":/scenarios:ro \
            chappe-conf-sipp "$2" "$NODE_IP"
        ;;
    pjsua)
        net
        NAME="$2" IP="$3"
        shift 3
        docker rm -f "chappe-conf-$NAME" >/dev/null 2>&1 || true
        # a terminal makes pjsua's console output line-buffered
        docker run -d -t --name "chappe-conf-$NAME" --network "$NET" \
            --ip "$IP" -v "$INTEROP/pjsua/agent.sh":/agent.sh:ro \
            --entrypoint /bin/sh chappe-conf-pjsua /agent.sh "$NAME" "$@" \
            >/dev/null
        ;;
    cmd)
        docker exec "chappe-conf-$2" sh -c "printf '$3' > /tmp/cmd"
        ;;
    logs)
        docker logs "${2:+chappe-conf-}${2:-$NODE}" 2>&1
        ;;
    alive)
        [ "$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null)" \
            = true ]
        ;;
    down)
        for c in $(docker ps -aq --filter "name=^chappe-conf-"); do
            docker rm -f "$c" >/dev/null
        done
        docker network rm "$NET" >/dev/null 2>&1 || true
        ;;
    *)
        sed -n '5,20p' "$0" >&2
        exit 2
        ;;
esac
