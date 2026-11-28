#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# One wideband call from the lab pjsua (the Dockerfile here), for the HD
# labs: pjsua offers the codecs of -c only (one by default), plays a wav
# into the call and records what it hears, with its conference bridge at
# 16 or 48 kHz.
# With a TARGET it calls it; without one it answers the first call.
#
# Usage: hd.sh [-c CODECS] [-r RATE] [-p PLAY.wav] [-o REC.wav]
#              [-d SECONDS] [-D DELAY:DIGITS] [-n NETWORK] [-l SIP_PORT]
#              [-m RTP_PORT] [-N NAME] [-i IMAGE] [TARGET]
#
#   -c  the codecs offered, in this order, comma-separated: opus, G722,
#       PCMU, speex/16000, ... (default G722)
#   -r  pjsua's clock rate, of the bridge and the recording: 8000, 16000
#       or 48000 (default 16000)
#   -p  a 16-bit mono wav to play, from the call's start, looped
#   -o  where to write what pjsua hears (a wav at the clock rate)
#   -d  seconds the call lasts before pjsua hangs up (default 10)
#   -D  DELAY seconds after pjsua starts, send DIGITS (0-9, *, #, A-D) on
#       the call as RFC 4733 events (pjsua's # command); DELAY is a whole
#       number of seconds, less than the time pjsua runs. Give -D again
#       for more entries, each DELAY past the one before (-D 8:1111
#       -D 14:2222)
#   -n  docker network (default host)
#   -l  local SIP port (default 25060), -m first RTP port (default 25100)
#   -N  container name (default hd-<pid>), also the SIP user
#   -i  image (default chappe-conf-pjsua; built here unless up to date)
#
# The pjsua log (SIP at level 5) lands next to the recording as
# NAME.log: the SDP pjsua offers or answers (its telephone-event), and
# each digit it receives (`Incoming DTMF on call 0: 4'). Exits with
# pjsua's status.
#
# Before each call, scripts/lab_image.sh builds the image when its label
# does not match this directory (an image another checkout made, one
# without Opus say, is rebuilt); an up-to-date image costs a hash. With
# HD_SKIP_BUILD=1 the image is used as it is, so that no build runs while
# a measured call is up: the job builds it once before its first call.
# hd.sh then fails when the image does not exist.
set -euf

HERE=$(cd "$(dirname "$0")" && pwd)
CODEC=G722
RATE=16000
PLAY=""
REC=""
DUR=10
DTMF=""
NET=host
SIP=25060
RTP=25100
NAME="hd-$$"
IMAGE=chappe-conf-pjsua

while getopts c:r:p:o:d:D:n:l:m:N:i: opt; do
    case $opt in
        c) CODEC=$OPTARG ;;
        r) RATE=$OPTARG ;;
        p) PLAY=$OPTARG ;;
        o) REC=$OPTARG ;;
        d) DUR=$OPTARG ;;
        D) DTMF="$DTMF $OPTARG" ;;
        n) NET=$OPTARG ;;
        l) SIP=$OPTARG ;;
        m) RTP=$OPTARG ;;
        N) NAME=$OPTARG ;;
        i) IMAGE=$OPTARG ;;
        *) sed -n '11,31p' "$0" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
TARGET=${1:-}

case $RATE in
    8000|16000|48000) ;;
    *) echo "hd.sh: clock rate $RATE: 8000, 16000 or 48000" >&2; exit 2 ;;
esac

# pjsua quits on end of input: keep stdin open for the call, then hang
# up and quit (a callee waits twice as long for its call to come)
WAIT=$((DUR + 3))
[ -n "$TARGET" ] || WAIT=$((2 * DUR + 3))

# -D DELAY:DIGITS, once or more: the console's # command, then the
# digits, DELAY seconds in, each entry after the one before; the rest of
# WAIT after the last
LAST=-1
for ENTRY in $DTMF; do
    DELAY=${ENTRY%%:*}
    DIGITS=${ENTRY#*:}
    case $DELAY in
        ''|*[!0-9]*) DELAY=x ;;
    esac
    case $DIGITS in
        ''|*[!0-9*#A-D]*) DIGITS=x ;;
    esac
    if [ "$ENTRY" = "$DELAY" ] || [ "$DELAY" = x ] || [ "$DIGITS" = x ] ||
        [ "$DELAY" -ge "$WAIT" ] || [ "$DELAY" -le "$LAST" ]; then
        echo "hd.sh: -D $ENTRY: DELAY:DIGITS, DELAY seconds under $WAIT" \
            "and past the entry before, DIGITS of 0-9 * # A-D" >&2
        exit 2
    fi
    LAST=$DELAY
done

LAB_IMAGE=$(cd "$HERE/../../../.." && pwd)/scripts/lab_image.sh
if [ "${HD_SKIP_BUILD:-}" = 1 ]; then
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "hd.sh: HD_SKIP_BUILD=1 and no image $IMAGE:" \
            "$LAB_IMAGE pjsua $IMAGE" >&2
        exit 2
    fi
else
    "$LAB_IMAGE" pjsua "$IMAGE" >/dev/null
fi

abs() { (cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"); }

set -- --null-audio --clock-rate "$RATE" --snd-clock-rate "$RATE" \
    --no-vad --ec-tail 0 --quality 10 --ptime 20 \
    --dis-codec "" \
    --local-port "$SIP" --rtp-port "$RTP" --no-tcp --max-calls 1 \
    --id "sip:$NAME@lab.invalid" --duration "$DUR" \
    --log-level 5 --app-log-level 3
# one --add-codec per codec of -c, the last first: pjsua ranks a codec
# it is given later above the ones before, so the SDP keeps -c's order
OIFS=$IFS
IFS=,
REV=""
for C in $CODEC; do
    REV="$C,$REV"
done
for C in $REV; do
    set -- "$@" --add-codec "$C"
done
IFS=$OIFS
VOLS=""
if [ -n "$PLAY" ]; then
    PLAY=$(abs "$PLAY")
    VOLS="$VOLS -v $PLAY:/in/play.wav:ro"
    set -- "$@" --play-file /in/play.wav --auto-play
fi
if [ -n "$REC" ]; then
    mkdir -p "$(dirname "$REC")"
    REC=$(abs "$REC")
    OUT=$(dirname "$REC")
    VOLS="$VOLS -v $OUT:/out"
    set -- "$@" --rec-file "/out/$(basename "$REC")" --auto-rec \
        --log-file "/out/$NAME.log"
fi
if [ -n "$TARGET" ]; then
    set -- "$@" "$TARGET"
else
    set -- "$@" --auto-answer 200
fi

console() {
    AT=0
    for ENTRY in $DTMF; do
        sleep $((${ENTRY%%:*} - AT))
        AT=${ENTRY%%:*}
        printf '#\n%s\n' "${ENTRY#*:}"
    done
    sleep $((WAIT - AT))
    printf 'h\nq\n'
}

# shellcheck disable=SC2086
console | docker run --rm -i --name "$NAME" \
    --network "$NET" $VOLS "$IMAGE" "$@"
