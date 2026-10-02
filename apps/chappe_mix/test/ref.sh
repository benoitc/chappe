#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# chappe_mix against its reference, FreeSWITCH mod_conference, from
# apps/chappe_mix/interop/freeswitch/docker-compose.yml (native on arm64
# and amd64). Brings FreeSWITCH up, waits for its SIP profile, exports the
# environment chappe_mix_ref reads, runs, and tears it down.
#
# Usage:
#   ref.sh suite                  chappe_mix_ref_SUITE      (make interop-ref)
#   ref.sh host ARM [ARGS...]     a bench arm on this machine (make bench-ref)
#   ref.sh vm ARM [ARGS...]       a bench arm in an erlang:29 container on
#                                 FreeSWITCH's network: on macOS, the same
#                                 Linux VM, so neither side pays the
#                                 host-to-VM hop
#
# KEEP=1 leaves FreeSWITCH running and reuses a running one, to interleave
# several launches against one instance. The arms refuse to run above the
# load limit (see apps/chappe_mix/bench/README.md).
set -u

MODE="${1:-suite}"
[ $# -gt 0 ] && shift

cd "$(dirname "$0")/../../.."
COMPOSE="docker compose -f apps/chappe_mix/interop/freeswitch/docker-compose.yml"
FS=chappe-mix-fs
BENCH=chappe-mix-bench

case "$MODE" in
suite | host | vm) ;;
*)
    echo "usage: $0 suite | host ARM [ARGS] | vm ARM [ARGS]" >&2
    exit 2
    ;;
esac

# the capacity ramp needs more RTP ports than the published default range;
# it only runs inside the docker network, which needs none published
case "${1:-}" in
ref_capacity) export FS_RTP_END="${FS_RTP_END:-32767}" ;;
esac

PROFILE=""
[ "$MODE" = vm ] && PROFILE="--profile bench"

down() {
    [ "${KEEP:-0}" = 1 ] || $COMPOSE --profile bench down >/dev/null 2>&1
}

if ! $COMPOSE $PROFILE up -d --wait; then
    echo "FreeSWITCH failed to start:" >&2
    $COMPOSE logs freeswitch >&2
    down
    exit 1
fi

build_bench() {
    rebar3 compile >/dev/null || return 1
    mkdir -p _build/bench
    erlc -o _build/bench -pa _build/default/lib/chappe_mix/ebin \
        apps/chappe_mix/bench/*.erl \
        apps/chappe_mix/test/chappe_mix_test_tone.erl \
        apps/chappe_mix/test/chappe_mix_probe.erl \
        apps/chappe_mix/test/chappe_mix_sip_ua.erl \
        apps/chappe_mix/test/chappe_mix_ref.erl
}

uptime
case "$MODE" in
suite)
    MEDIA_IP="$(docker exec "$FS" getent hosts host.docker.internal \
        2>/dev/null | awk '{print $1}')"
    FREESWITCH_HOST=127.0.0.1 FREESWITCH_MEDIA_IP="$MEDIA_IP" \
        rebar3 ct --dir apps/chappe_mix/test --suite chappe_mix_ref_SUITE
    RC=$?
    ;;
host)
    build_bench || { down; exit 1; }
    MEDIA_IP="$(docker exec "$FS" getent hosts host.docker.internal \
        2>/dev/null | awk '{print $1}')"
    SOCK="$(docker context inspect --format '{{.Endpoints.docker.Host}}' |
        sed 's|^unix://||')"
    FREESWITCH_HOST=127.0.0.1 FREESWITCH_MEDIA_IP="$MEDIA_IP" \
        DOCKER_SOCK="$SOCK" \
        erl -noshell +S 1 -pa _build/default/lib/chappe_mix/ebin \
        -pa _build/bench -run chappe_mix_bench main "$@"
    RC=$?
    ;;
vm)
    # the arm checks the VM's load, which on macOS leaves out everything
    # running on the host: check the host's here, with the arm's limit
    CPUS="$(getconf _NPROCESSORS_ONLN)"
    LOAD="$(uptime | sed 's/.*load averages*: *//; s/,/ /g' | awk '{print $1}')"
    LIMIT="${CHAPPE_MIX_BENCH_MAX_LOAD:-$(awk -v c="$CPUS" \
        'BEGIN { l = c / 4; if (l < 1) l = 1; print l }')}"
    if awk -v l="$LOAD" -v m="$LIMIT" 'BEGIN { exit !(l > m) }'; then
        if [ "${CHAPPE_MIX_BENCH_FORCE:-}" != 1 ]; then
            echo "host load $LOAD above $LIMIT, refusing" \
                "(CHAPPE_MIX_BENCH_FORCE=1 runs anyway, marked VOID)" >&2
            down
            exit 2
        fi
        # a zero limit makes the arm mark every line VOID
        export CHAPPE_MIX_BENCH_MAX_LOAD=0.0
    fi
    build_bench || { down; exit 1; }
    ip_of() {
        docker inspect -f \
            '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"
    }
    # pass the load overrides through only when they are set
    docker exec -e FREESWITCH_HOST="$(ip_of "$FS")" \
        -e FREESWITCH_MEDIA_IP="$(ip_of "$BENCH")" \
        ${CHAPPE_MIX_BENCH_MAX_LOAD:+-e CHAPPE_MIX_BENCH_MAX_LOAD} \
        ${CHAPPE_MIX_BENCH_FORCE:+-e CHAPPE_MIX_BENCH_FORCE} \
        "$BENCH" erl -noshell +S 1 \
        -pa _build/default/lib/chappe_mix/ebin -pa _build/bench \
        -run chappe_mix_bench main "$@"
    RC=$?
    ;;
esac

down
exit $RC
