#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# One wideband call from the lab pjsua (the Dockerfile here), for the HD
# labs: pjsua offers one codec only, plays a wav into the call and
# records what it hears, with its conference bridge at 16 or 48 kHz.
# With a TARGET it calls it; without one it answers the first call.
#
# Usage: hd.sh [-c CODEC] [-r RATE] [-p PLAY.wav] [-o REC.wav]
#              [-d SECONDS] [-n NETWORK] [-l SIP_PORT] [-m RTP_PORT]
#              [-N NAME] [-i IMAGE] [TARGET]
#
#   -c  the one codec offered: opus, G722, PCMU, ... (default G722)
#   -r  pjsua's clock rate, of the bridge and the recording: 8000, 16000
#       or 48000 (default 16000)
#   -p  a 16-bit mono wav to play, from the call's start, looped
#   -o  where to write what pjsua hears (a wav at the clock rate)
#   -d  seconds the call lasts before pjsua hangs up (default 10)
#   -n  docker network (default host)
#   -l  local SIP port (default 25060), -m first RTP port (default 25100)
#   -N  container name (default hd-<pid>), also the SIP user
#   -i  image (default chappe-conf-pjsua; built here if missing)
#
# The pjsua log (SIP at level 5) lands next to the recording as
# NAME.log. Exits with pjsua's status.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CODEC=G722
RATE=16000
PLAY=""
REC=""
DUR=10
NET=host
SIP=25060
RTP=25100
NAME="hd-$$"
IMAGE=chappe-conf-pjsua

while getopts c:r:p:o:d:n:l:m:N:i: opt; do
    case $opt in
        c) CODEC=$OPTARG ;;
        r) RATE=$OPTARG ;;
        p) PLAY=$OPTARG ;;
        o) REC=$OPTARG ;;
        d) DUR=$OPTARG ;;
        n) NET=$OPTARG ;;
        l) SIP=$OPTARG ;;
        m) RTP=$OPTARG ;;
        N) NAME=$OPTARG ;;
        i) IMAGE=$OPTARG ;;
        *) sed -n '10,24p' "$0" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
TARGET=${1:-}

case $RATE in
    8000|16000|48000) ;;
    *) echo "hd.sh: clock rate $RATE: 8000, 16000 or 48000" >&2; exit 2 ;;
esac

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -q -t "$IMAGE" "$HERE" >/dev/null
fi

abs() { (cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"); }

set -- --null-audio --clock-rate "$RATE" --snd-clock-rate "$RATE" \
    --no-vad --ec-tail 0 --quality 10 --ptime 20 \
    --dis-codec "" --add-codec "$CODEC" \
    --local-port "$SIP" --rtp-port "$RTP" --no-tcp --max-calls 1 \
    --id "sip:$NAME@lab.invalid" --duration "$DUR" \
    --log-level 5 --app-log-level 3
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

# pjsua quits on end of input: keep stdin open for the call, then hang
# up and quit (a callee waits twice as long for its call to come)
WAIT=$((DUR + 3))
[ -n "$TARGET" ] || WAIT=$((2 * DUR + 3))
# shellcheck disable=SC2086
(sleep "$WAIT"; printf 'h\nq\n') | docker run --rm -i --name "$NAME" \
    --network "$NET" $VOLS "$IMAGE" "$@"
