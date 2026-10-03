#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# One measuring pass over the chappe_mix arms, the PERF.md rows that need
# a quiet box, interleaved and repeated so the minimum of five can be
# taken. Run it from anywhere; it works from the umbrella root.
#
# Usage: pass.sh GROUP [OUT]
#
#   cost      null; mix_cost 4 64 and mix_cost fit 4 64 on this tree and
#             on BASE; mix_cost talk and nohear 1 / nohear 4
#   timer     jitter idle 30 and jitter capacity 100 30, tick_ceiling
#             false against true
#   prefill   latency 100 and loss 100 2, prefill_shrink false against true
#   events    framing 10 60, framing 30 60, dtmf 20, talk 20
#   capacity  capacity 25 5 1000
#   ref       ref_latency and ref_capacity against mod_conference (ref.sh vm)
#   all       every group above but ref, one after the other
#
# OUT (default _build/bench-pass) gets GROUP.log. Environment:
#   ROUNDS   launches of each arm (default 5); an A/B swaps which side
#            goes first every round
#   BASE     a commit to run mix_cost against in the cost group (unset:
#            skipped); its chappe_mix sources are built beside this tree
#   MAXWAIT  seconds one launch may wait for the load (default 1800)
#
# Each launch waits until the 1-minute load is at most the arms' own
# limit (a quarter of the CPUs, never below 1.0, or
# CHAPPE_MIX_BENCH_MAX_LOAD), then starts the arm, which checks again and
# refuses (exit 2) above it. A refusal is logged and the launch waits
# again; a launch that waits MAXWAIT seconds in all is logged as given
# up. Nothing is forced: CHAPPE_MIX_BENCH_FORCE is never set here.
# Needs a shell with `local' (dash, bash).
set -u

GROUP="${1:-}"
cd "$(dirname "$0")/../../.." || exit 1
OUT="${2:-_build/bench-pass}"
ROUNDS="${ROUNDS:-5}"
MAXWAIT="${MAXWAIT:-1800}"
BASE="${BASE:-}"
CUR=_build/default/lib/chappe_mix/ebin
ARMS=_build/bench
BASEDIR=_build/bench-base

mkdir -p "$OUT"
LOG="$OUT/$GROUP.log"

log() {
    echo "$@" | tee -a "$LOG"
}

cpus() {
    getconf _NPROCESSORS_ONLN
}

load1() {
    uptime | sed 's/.*load averages*: *//; s/,/ /g' | awk '{print $1}'
}

limit() {
    if [ -n "${CHAPPE_MIX_BENCH_MAX_LOAD:-}" ]; then
        echo "$CHAPPE_MIX_BENCH_MAX_LOAD"
    else
        awk -v c="$(cpus)" 'BEGIN { l = c / 4; if (l < 1) l = 1; print l }'
    fi
}

host_info() {
    log "== host $(uname -srm)"
    log "== nproc $(cpus)"
    if command -v lscpu >/dev/null 2>&1; then
        log "== cpu $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
    else
        log "== cpu $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    fi
    log "== limit $(limit)"
    log "== uptime $(uptime)"
    log "== commit $(git rev-parse --short HEAD 2>/dev/null)"
}

build_cur() {
    SKIP_ENGINE_BUILD="${SKIP_ENGINE_BUILD:-1}" rebar3 compile >/dev/null ||
        return 1
    mkdir -p "$ARMS"
    erlc -o "$ARMS" -pa "$CUR" \
        apps/chappe_mix/bench/*.erl \
        apps/chappe_mix/test/chappe_mix_test_tone.erl \
        apps/chappe_mix/test/chappe_mix_probe.erl \
        apps/chappe_mix/test/chappe_mix_sip_ua.erl \
        apps/chappe_mix/test/chappe_mix_ref.erl
}

# BASE's chappe_mix alone, compiled from its sources; the arms are this
# tree's, as bench/README.md "Compare two commits" asks.
build_base() {
    rm -rf "$BASEDIR"
    mkdir -p "$BASEDIR/ebin"
    git archive "$BASE" apps/chappe_mix/src | tar -x -C "$BASEDIR" || return 1
    erlc +debug_info -I "$BASEDIR/apps/chappe_mix/src" -o "$BASEDIR/ebin" \
        "$BASEDIR"/apps/chappe_mix/src/*.erl || return 1
    cp "$BASEDIR/apps/chappe_mix/src/chappe_mix.app.src" \
        "$BASEDIR/ebin/chappe_mix.app"
}

# run LABEL CMD...: one launch of CMD once the load allows, retried while
# the arm refuses.
run() {
    local label="$1" waited=0 refused=0 l tmp rc
    shift
    while :; do
        l="$(load1)"
        if awk -v l="$l" -v m="$(limit)" 'BEGIN { exit !(l <= m) }'; then
            log "== launch $label after ${waited}s waiting, $refused refused," \
                "$(date -u '+%H:%M:%S') $(uptime)"
            tmp="$OUT/.run.$$"
            "$@" >"$tmp" 2>&1
            rc=$?
            tee -a "$LOG" <"$tmp"
            rm -f "$tmp"
            if [ "$rc" -ne 2 ]; then
                log "== end $label rc=$rc"
                return 0
            fi
            refused=$((refused + 1))
            log "== refused $label (the arm saw the load above its limit)"
        fi
        if [ "$waited" -ge "$MAXWAIT" ]; then
            log "== gave up $label after ${waited}s, load $l, $refused refused"
            return 0
        fi
        sleep 15
        waited=$((waited + 15))
    done
}

# arm LABEL EBIN CONF ARM [ARGS...]
arm() {
    local label="$1" ebin="$2" conf="$3"
    shift 3
    run "$label" env CHAPPE_MIX_BENCH_CONF="$conf" \
        erl -noshell +S 1 -pa "$ebin" -pa "$ARMS" \
        -run chappe_mix_bench main "$@"
}

# ab ROUND LABEL OPTION ARM [ARGS...]: OPTION false and true, the side
# that goes first swapped every round.
ab() {
    local r="$1" label="$2" opt="$3" order v
    shift 3
    if [ $((r % 2)) -eq 1 ]; then
        order="false true"
    else
        order="true false"
    fi
    for v in $order; do
        arm "$label $opt=$v round $r" "$CUR" "$opt=$v" "$@"
    done
}

group_cost() {
    local r
    if [ -n "$BASE" ]; then
        build_base || { log "== base $BASE failed to build"; return 1; }
    fi
    r=1
    while [ "$r" -le "$ROUNDS" ]; do
        arm "null round $r" "$CUR" "" null
        arm "mix_cost head round $r" "$CUR" "" mix_cost 4 64
        [ -n "$BASE" ] &&
            arm "mix_cost base $BASE round $r" "$BASEDIR/ebin" "" mix_cost 4 64
        arm "mix_cost fit head round $r" "$CUR" "" mix_cost fit 4 64
        [ -n "$BASE" ] &&
            arm "mix_cost fit base $BASE round $r" "$BASEDIR/ebin" "" \
                mix_cost fit 4 64
        arm "mix_cost talk round $r" "$CUR" "" mix_cost talk 4 64
        arm "mix_cost nohear 1 round $r" "$CUR" "" mix_cost nohear 1 4 64
        arm "mix_cost nohear 4 round $r" "$CUR" "" mix_cost nohear 4 4 64
        r=$((r + 1))
    done
}

group_timer() {
    local r
    r=1
    while [ "$r" -le "$ROUNDS" ]; do
        ab "$r" "jitter idle" tick_ceiling jitter idle 30
        ab "$r" "jitter capacity" tick_ceiling jitter capacity 100 30
        r=$((r + 1))
    done
}

group_prefill() {
    local r
    r=1
    while [ "$r" -le "$ROUNDS" ]; do
        ab "$r" "latency" prefill_shrink latency 100
        ab "$r" "loss" prefill_shrink loss 100 2
        r=$((r + 1))
    done
}

group_events() {
    local r
    r=1
    while [ "$r" -le "$ROUNDS" ]; do
        arm "framing 10 round $r" "$CUR" "" framing 10 60
        arm "framing 30 round $r" "$CUR" "" framing 30 60
        arm "dtmf round $r" "$CUR" "" dtmf 20
        arm "talk round $r" "$CUR" "" talk 20
        r=$((r + 1))
    done
}

group_capacity() {
    local r
    r=1
    while [ "$r" -le "$ROUNDS" ]; do
        arm "capacity round $r" "$CUR" "" capacity 25 5 1000
        r=$((r + 1))
    done
}

# Against mod_conference in docker: one FreeSWITCH kept up for every
# launch (KEEP=1), torn down at the end.
group_ref() {
    local r
    export KEEP=1
    docker compose -f apps/chappe_mix/interop/freeswitch/docker-compose.yml \
        --profile bench pull -q
    run "ref_latency" apps/chappe_mix/test/ref.sh vm ref_latency 5 50
    r=1
    while [ "$r" -le "$ROUNDS" ]; do
        run "ref_capacity fs round $r" \
            apps/chappe_mix/test/ref.sh vm ref_capacity fs 25 20 1000
        run "ref_capacity chappe round $r" \
            apps/chappe_mix/test/ref.sh vm ref_capacity chappe 25 20 1000
        r=$((r + 1))
    done
    docker compose -f apps/chappe_mix/interop/freeswitch/docker-compose.yml \
        --profile bench down >/dev/null 2>&1
}

case "$GROUP" in
cost | timer | prefill | events | capacity | ref | all) ;;
*)
    echo "usage: $0 cost|timer|prefill|events|capacity|ref|all [OUT]" >&2
    exit 2
    ;;
esac

host_info
if [ "$GROUP" != ref ]; then
    build_cur || { log "== build failed"; exit 1; }
fi
if [ "$GROUP" = all ]; then
    for g in cost timer prefill events capacity; do
        log "### $g"
        "group_$g"
    done
else
    "group_$GROUP"
fi
log "== done $GROUP $(uptime)"
