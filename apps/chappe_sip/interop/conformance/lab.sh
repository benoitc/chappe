#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The conformance lab: a chappe node, SIPp, pjsua and a dnsmasq server on
# one docker network (10.253.7.0/24). Everything runs in containers because
# Docker Desktop on macOS cannot send UDP from the host to container
# addresses. The node resolves through dnsmasq (10.253.7.53, records in
# dns/dnsmasq.conf), and SIPp runs the dns_* cases at 10.253.7.30, the
# address those records point at.
#
#   lab.sh images         build the node, SIPp, pjsua and DNS images
#   lab.sh build          compile this chappe tree into the node volume and
#                         make the lab's TLS certificates
#   lab.sh up             (re)start the node at 10.253.7.10:5060 (TLS on
#                         5061), and the DNS server if it is not running
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
CERTS=chappe_conf_certs
DNS=chappe-conf-dns
DNS_IP=10.253.7.53
DNS_CASE_IP=10.253.7.30

net() {
    docker network inspect "$NET" >/dev/null 2>&1 \
        || docker network create --subnet "$SUBNET" "$NET" >/dev/null
}

dns() {
    [ "$(docker inspect -f '{{.State.Running}}' "$DNS" 2>/dev/null)" = true ] \
        && return 0
    docker rm -f "$DNS" >/dev/null 2>&1 || true
    docker run -d --name "$DNS" --network "$NET" --ip "$DNS_IP" \
        chappe-conf-dns >/dev/null
}

case "${1:-}" in
    images)
        docker build -q -t chappe-conf-node "$HERE/node" >/dev/null
        docker build -q -t chappe-conf-sipp "$INTEROP/sipp" >/dev/null
        docker build -q -t chappe-conf-pjsua "$INTEROP/pjsua" >/dev/null
        docker build -q -t chappe-conf-dns "$HERE/dns" >/dev/null
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
        docker run --rm -v "$CERTS":/certs \
            -v "$HERE/dns/certs.sh":/certs.sh:ro \
            --entrypoint /bin/sh chappe-conf-node /certs.sh /certs
        ;;
    up)
        net
        dns
        docker rm -f "$NODE" >/dev/null 2>&1 || true
        docker run -d --name "$NODE" --network "$NET" --ip "$NODE_IP" \
            -v "$HERE/dns/resolv.conf":/etc/resolv.conf:ro \
            -v "$CERTS":/certs:ro \
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
        # the dns_* cases play the targets the lab's DNS records name
        case "$2" in
            dns_*) AT="--ip $DNS_CASE_IP -v $CERTS:/certs:ro" ;;
            *) AT="" ;;
        esac
        # shellcheck disable=SC2086
        docker run --rm --network "$NET" $AT \
            -v "$INTEROP/sipp":/scenarios:ro chappe-conf-sipp "$2" "$NODE_IP"
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
        sed -n '5,25p' "$0" >&2
        exit 2
        ;;
esac
