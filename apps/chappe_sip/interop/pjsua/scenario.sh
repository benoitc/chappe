#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# Runs one pjsua conformance scenario against the chappe node (which
# lab.sh up must have started) and exits 0 only if every step was seen.
#
# Usage: scenario.sh refer_blind | refer_attended | b2b_refer_blind |
#                    b2b_refer_attended | session_timer
#
#   refer_blind     agent a calls the node, then blind-transfers it to
#                   agent b (console `x'): the node must accept the REFER,
#                   INVITE b, and report the outcome so pjsua sees a final
#                   200 in the NOTIFY sipfrag (RFC 3515, RFC 7647)
#   refer_attended  agent a calls b, then calls the node, then transfers
#                   the node to b with Replaces (console `X'): the node
#                   must INVITE b with Replaces, b swaps its call with a
#                   for the node's, and a sees the final 200 (RFC 3891)
#   b2b_refer_blind agent a calls the node's b2b user, which bridges it to
#                   agent b as a B2BUA (transfer => auto); b blind-
#                   transfers a to agent c (console `x'): the node calls c
#                   on b's side, a gets no re-INVITE, b sees the final 200
#                   and is hung up (RFC 5589 6)
#   b2b_refer_attended
#                   a calls the node's b2b user (bridged to b), b calls its
#                   b2b-c user (bridged to c), and b transfers with Replaces
#                   (console `X'): the node joins a and c through the
#                   anchor, with no new INVITE to anyone; b sees the final
#                   200 and both its calls end (RFC 5589 7.3)
#   session_timer   agent a calls the node with session timers on
#                   (Session-Expires 90): the 2xx must carry
#                   Session-Expires with a refresher, and the call must
#                   survive past the first interval (RFC 4028)
#
# Agents: a 10.253.7.20, b 10.253.7.21, c 10.253.7.22, the node
# 10.253.7.10.
set -u

KIND="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
LAB="$HERE/../conformance/lab.sh"
NODE=10.253.7.10
A=10.253.7.20
B=10.253.7.21
C=10.253.7.22
# how long to wait for pjsua to report a step, in polls of 0.5 s
POLLS="${POLLS:-40}"
RC=0

log() { echo "[$KIND $(date -u +%T)] $*"; }

send() { "$LAB" cmd "$1" "$2"; }

logs() { "$LAB" logs "$1" | tr -d '\r'; }

# Wait until the agent's output has at least N lines matching RE.
wait_for() {
    agent="$1" re="$2" n="${3:-1}" i=0
    while [ "$i" -lt "$POLLS" ]; do
        if [ -n "$(logs "$agent" | grep -E "$re" | sed -n "${n}p")" ]; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.5
    done
    return 1
}

finish() {
    for a in a b c; do
        echo "===== pjsua $a"
        logs "$a" 2>/dev/null
        send "$a" 'q\n' 2>/dev/null
    done
    log "exit $RC"
    exit "$RC"
}

step() {
    if wait_for "$@"; then
        log "seen on $1: $2"
    else
        log "FAIL: timeout waiting on $1 for: $2"
        RC=1
        finish
    fi
}

up() {
    "$LAB" pjsua "$@"
    step "$1" 'PJSUA state changed: STARTING --> RUNNING'
}

case "$KIND" in
    refer_blind)
        up a "$A"
        up b "$B"
        send a "m\nsip:uas@$NODE:5060\n"
        step a 'Call 0 state changed to CONFIRMED'
        send a "x\nsip:b@$B:5060\n"
        step a 'Call 0: transfer status=200 .*final'
        step b 'Call [0-9]+ state changed to CONFIRMED'
        ;;
    refer_attended)
        up a "$A"
        up b "$B"
        send a "m\nsip:b@$B:5060\n"
        step a 'Call 0 state changed to CONFIRMED'
        send a "m\nsip:uas@$NODE:5060\n"
        step a 'Call 1 state changed to CONFIRMED'
        # the REFER goes on the current call (1, the node) and names call
        # 0 (b) in a Refer-To with Replaces
        send a "X\n0\n"
        step a 'Call 1: transfer status=200 .*final'
        step b 'Call 1 state changed to CONFIRMED'
        step b 'Call 0 is DISCONNECTED'
        ;;
    b2b_refer_blind)
        up a "$A"
        up b "$B"
        up c "$C"
        send a "m\nsip:b2b@$NODE:5060\n"
        step a 'Call 0 state changed to CONFIRMED'
        step b 'Call 0 state changed to CONFIRMED'
        send b "x\nsip:c@$C:5060\n"
        step b 'Call 0: transfer status=200 .*final'
        step c 'Call 0 state changed to CONFIRMED'
        step b 'Call 0 is DISCONNECTED'
        # a kept its call and its media: no INVITE ever reached it
        if logs a | grep -qE 'RX .*Request msg INVITE'; then
            log "FAIL: agent a got a re-INVITE"
            RC=1
        fi
        if logs a | grep -qE 'Call 0 is DISCONNECTED'; then
            log "FAIL: agent a lost its call"
            RC=1
        fi
        ;;
    b2b_refer_attended)
        up a "$A"
        up b "$B"
        up c "$C"
        send a "m\nsip:b2b@$NODE:5060\n"
        step a 'Call 0 state changed to CONFIRMED'
        step b 'Call 0 state changed to CONFIRMED'
        send b "m\nsip:b2b-c@$NODE:5060\n"
        step b 'Call 1 state changed to CONFIRMED'
        step c 'Call 0 state changed to CONFIRMED'
        # the REFER goes on b's current call (1, to c) and names call 0
        # (to a) in a Refer-To with Replaces
        send b "X\n0\n"
        step b 'Call 1: transfer status=200 .*final'
        step b 'Call 0 is DISCONNECTED'
        step b 'Call 1 is DISCONNECTED'
        # a and c stay up, and nobody got a new call
        for x in a c; do
            if logs "$x" | grep -qE 'Call 0 is DISCONNECTED|Call 1 state'; then
                log "FAIL: agent $x lost its call or got a new one"
                RC=1
            fi
        done
        ;;
    session_timer)
        up a "$A" --use-timer=1 --timer-se=90 --timer-min-se=90
        send a "m\nsip:uas@$NODE:5060\n"
        step a 'Call 0 state changed to CONFIRMED'
        # the 2xx to the INVITE, as pjsua logged it
        if logs a | sed -n '/Response msg 200\/INVITE/,/--end msg--/p' \
            | grep -qE '^(Session-Expires|x): *[0-9]+ *;.*refresher='; then
            log "the 2xx carries Session-Expires with a refresher"
        else
            log "FAIL: no Session-Expires with a refresher in the 2xx"
            RC=1
            finish
        fi
        # past 90 s the call must still be up: refreshed, not expired
        sleep 100
        if logs a | grep -qE 'Call 0 is DISCONNECTED'; then
            log "FAIL: the call ended before 100 s"
            RC=1
        else
            log "the call is up after 100 s"
        fi
        ;;
    *)
        echo "usage: $0 refer_blind | refer_attended | b2b_refer_blind |" \
            "b2b_refer_attended | session_timer" >&2
        exit 2
        ;;
esac
finish
