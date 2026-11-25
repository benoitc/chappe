#!/usr/bin/env bash
# One taq live trial against the running demo (make demo, DEMO_SIP_PORT).
# Usage: run1.sh ARM REP DIR CLIP [pcmu] [--no-into]
#   ARM baseline (room 1004, FreeSWITCH) | candidate (room 1003, chappe_mix)
#   DIR g722-to-opus | opus-to-g722
#   pcmu: a silent PCMU caller joins about 2 s into the clip and leaves 5 s later
# TAQ_DIR is the taq checkout (cf11b89); $R/manifest.json there is a copy
# of manifest-margins.json, made before the first trial.
# Exits non-zero when taq live fails or warns, or when the PCMU caller fails.
set -euo pipefail
ARM=$1; REP=$2; DIR=$3; CLIP=$4; MODE=${5:-idle}; INTO=${6:-into}
T=${TAQ_DIR:-$HOME/Projects/telephony-audio-quality}
HERE=$(cd "$(dirname "$0")" && pwd)
R=${RUN_DIR:-$T/runs/hd-room-2026-11-25}
META=${META_DIR:-$HERE}
HD=${HD_SH:-$HERE/../../../../chappe_sip/interop/pjsua/hd.sh}
PORT=${DEMO_SIP_PORT:-5080}
case $ARM in
    baseline) ROOM=1004; ARMS=b
        PATHD="pjsua > rtpengine > FreeSWITCH mod_conference demo-hd-fs@wideband (16 kHz) > rtpengine > pjsua" ;;
    candidate) ROOM=1003; ARMS=c
        PATHD="pjsua > rtpengine > chappe_mix demo-hd (L16, 16 kHz) > rtpengine > pjsua" ;;
    *) echo "run1.sh: unknown arm $ARM" >&2; exit 2 ;;
esac
case $DIR in
    g722-to-opus) TC=G722; TR=16000; LC=opus; LR=48000 ;;
    opus-to-g722) TC=opus; TR=48000; LC=G722; LR=16000 ;;
    *) echo "run1.sh: unknown direction $DIR" >&2; exit 2 ;;
esac
case $MODE in
    pcmu) LOAD=pcmu-join; SUF=-pcmu ;;
    *) LOAD=idle; SUF="" ;;
esac
ID=$ARMS$REP-$DIR-$CLIP$SUF
OUT=$R/$ID
COND=hd-room/$DIR/$LOAD/clean
echo "$(date -u +%H:%M:%S) $ID $(uptime | sed 's/.*load averages*: //')" >> "$R/load.log"
PCMU_PID=""
if [ "$MODE" = pcmu ]; then
    (sleep "${PCMU_DELAY:-5}"; mkdir -p "$OUT-pcmu-caller"
     sh "$HD" -c PCMU -r 8000 -d 5 -l 25080 -m 25500 -N "hd-pcmu-$ID" \
        -i chappe-hd-pjsua -o "$OUT-pcmu-caller/pcmu.wav" \
        "sip:$ROOM@127.0.0.1:$PORT" > "$OUT-pcmu-caller.out" 2>&1) &
    PCMU_PID=$!
fi
set -- live "sip:$ROOM@127.0.0.1:$PORT" --out "$OUT" --clip "$CLIP" \
    --codec "$TC" --clock-rate "$TR" --listeners 1 --sip-port 5170 \
    --rtp-port 40000 --arm "$ARM" --rep "$REP" --condition-id "$COND" \
    --path "$PATHD" --meta "$META/meta-$ARM.json" --load "$LOAD" \
    --impairment clean --seed 0
if [ "$INTO" = into ]; then set -- "$@" --into "$R/manifest.json"; fi
RC=0
(cd "$T" && TAQ_TALKER_CODEC=$TC TAQ_TALKER_RATE=$TR TAQ_LISTENER_CODEC=$LC \
    TAQ_LISTENER_RATE=$LR uv run python "$HERE/live2.py" "$@") > "$OUT.live.log" 2>&1 \
    || RC=$?
PRC=0
if [ -n "$PCMU_PID" ]; then wait "$PCMU_PID" || PRC=$?; fi
WARN=$(grep -c warning "$OUT.live.log" || true)
# no count at all (the log could not be read) is a failure too
case $WARN in '' | *[!0-9]*) WARN=1 ;; esac
# the PCMU caller's exit status is pjsua's, often 0 for a refused call:
# it must also have recorded something
if [ -n "$PCMU_PID" ] && [ "$PRC" -eq 0 ] && [ ! -s "$OUT-pcmu-caller/pcmu.wav" ]; then
    PRC=1
fi
echo "$ID rc=$RC pcmu_rc=$PRC $WARN warnings"
if [ "$RC" -ne 0 ] || [ "$PRC" -ne 0 ] || [ "$WARN" -ne 0 ]; then
    echo "$ID failed: see $OUT.live.log${PCMU_PID:+ and $OUT-pcmu-caller.out}" >&2
    exit 1
fi
