#!/usr/bin/env bash
# One HD room trial against the running demo (make demo, DEMO_SIP_PORT),
# without taq: the drop-in for taq's scripts/campaign/run1.sh that
# block.sh runs as RUN1 on a runner. taq live-import finishes the trial on
# the machine that scores it.
# Usage: trial.sh ARM REP DIR CLIP
#   ARM baseline (room 1004, FreeSWITCH) | candidate (room 1003, chappe_mix)
#   DIR g722-to-opus | opus-to-g722
#   CLIP a clip id of clips/SHA256SUMS
# Environment:
#   RUN_DIR     the build's run directory: the trial goes to RUN_DIR/ID, its
#               log to RUN_DIR/ID.live.log, the gate's lines to
#               RUN_DIR/load.log
#   PADDED_DIR  where pad.py wrote the played files and padded.json
#   CHAPPE_DIR  the build under test, for its SHA (default: this checkout)
#   DEMO_SIP_PORT (5080), HD_SH (this branch's hd.sh), HD_IMAGE
#   (chappe-conf-pjsua), HD_SKIP_BUILD (passed to hd.sh)
# The load gate is run1.sh's: before the trial it waits until the 1 min
# load average has stayed at most MAX_LOAD (4.0) for LOAD_QUIET (30) s in
# a row, polling every LOAD_POLL (5) s; if that does not happen within
# MAXWAIT (1800) s, it runs nothing and exits 1. load.log gets the wait
# and the load at the start and the end, in run1.sh's words (block.sh
# reads them).
# The calls are taq live's: the listener (bob) calls for D+6 s, then after
# 3 s the talker (alice) calls for D s and plays the padded clip, where D
# is the played length rounded up. A call still running 30 s after its
# expected end has its container killed.
# RUN_DIR/ID gets alice.rx.wav, bob.rx.wav, alice.pjsua.log,
# bob.pjsua.log, what each hd.sh printed (NAME.out) and trial.json.
# Exits non-zero when a call exits non-zero or times out, a recording is
# missing or empty, or a pjsua log holds no 200 OK with SDP.
set -euo pipefail
ARM=${1:-}; REP=${2:-}; DIR=${3:-}; CLIP=${4:-}
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { sed -n '6,9p' "$0" >&2; exit 2; }
[ $# -eq 4 ] || usage
case $REP in '' | *[!0-9]*) echo "trial.sh: REP $REP is not a number" >&2; exit 2 ;; esac
R=${RUN_DIR:?RUN_DIR, the run directory of the build}
PADDED=${PADDED_DIR:?PADDED_DIR, the directory pad.py wrote}
HD=${HD_SH:-$HERE/../../../../../chappe_sip/interop/pjsua/hd.sh}
IMAGE=${HD_IMAGE:-chappe-conf-pjsua}
CHAPPE=${CHAPPE_DIR:-$(git -C "$HERE" rev-parse --show-toplevel)}
PORT=${DEMO_SIP_PORT:-5080}
case $ARM in
    baseline) ROOM=1004; ARMS=b
        PATHD="pjsua > rtpengine > FreeSWITCH mod_conference demo-hd-fs@wideband (16 kHz) > rtpengine > pjsua" ;;
    candidate) ROOM=1003; ARMS=c
        PATHD="pjsua > rtpengine > chappe_mix demo-hd (L16, 16 kHz) > rtpengine > pjsua" ;;
    *) echo "trial.sh: unknown arm $ARM" >&2; exit 2 ;;
esac
case $DIR in
    g722-to-opus) TC=G722; TR=16000; LC=opus; LR=48000 ;;
    opus-to-g722) TC=opus; TR=48000; LC=G722; LR=16000 ;;
    *) echo "trial.sh: unknown direction $DIR" >&2; exit 2 ;;
esac
ID=$ARMS$REP-$DIR-$CLIP
OUT=$R/$ID
LOG=$R/$ID.live.log
TARGET=sip:$ROOM@127.0.0.1:$PORT
# before the wait, so that a trial that cannot run fails at once: the
# played file (checked against padded.json), hd.sh, a free run directory
[ -f "$HD" ] || { echo "trial.sh: $HD missing" >&2; exit 2; }
if [ -e "$OUT" ]; then echo "trial.sh: $OUT exists" >&2; exit 2; fi
INFO=$(python3 -c '
import hashlib, json, math, sys
from pathlib import Path
d = Path(sys.argv[1]); p = json.loads((d / "padded.json").read_text())
c = p["clips"][sys.argv[2]]; f = d / c["file"]
assert hashlib.sha256(f.read_bytes()).hexdigest() == c["tx_sha256"], f"{f} changed"
print(c["play_s"], math.ceil(c["frames"] / c["sample_rate"] + p["pad_s"]), f)
' "$PADDED" "$CLIP") || {
    echo "trial.sh: no played file for $CLIP in $PADDED (run pad.py)" >&2; exit 2; }
read -r PLAY_S D TX <<< "$INFO"
mkdir -p "$R"
MAX_LOAD=${MAX_LOAD:-4.0}; MAXWAIT=${MAXWAIT:-1800}
QUIET=${LOAD_QUIET:-30}; POLL=${LOAD_POLL:-5}
# the 1, 5 and 15 min load averages: /proc/loadavg on Linux, else uptime
loadavg() {
    local l
    if ! l=$(cat /proc/loadavg 2>/dev/null) || [ -z "$l" ]; then
        l=$(uptime 2>/dev/null | sed 's/.*load averages*: //') || l=""
    fi
    echo "$l" | tr -d '{},' | awk '{print $1, $2, $3}'
}
# a load that cannot be read is not quiet
quiet() {
    awk -v l="$1" -v m="$MAX_LOAD" 'BEGIN { exit !(l ~ /^[0-9]+([.][0-9]+)?$/ && l + 0 <= m + 0) }'
}
stamp() { date -u +%H:%M:%S; }
T0=$(date +%s); SINCE=""
while :; do
    LA=$(loadavg); NOW=$(date +%s)
    if quiet "${LA%% *}"; then
        SINCE=${SINCE:-$NOW}
        if [ $((NOW - SINCE)) -ge "$QUIET" ]; then break; fi
    else
        SINCE=""
    fi
    if [ $((NOW - T0)) -ge "$MAXWAIT" ]; then
        echo "$(stamp) $ID not run: waited $((NOW - T0)) s," \
            "1 min load not at most $MAX_LOAD for $QUIET s; load $LA" >> "$R/load.log"
        echo "$ID failed: the 1 min load did not stay at most $MAX_LOAD" \
            "for $QUIET s within $MAXWAIT s (load $LA)" >&2
        exit 1
    fi
    sleep "$POLL"
done
echo "$(stamp) $ID start waited $((NOW - T0)) s load $LA" >> "$R/load.log"

# epochs with sub-second precision: GNU date, else python3
case $(date +%N 2>/dev/null) in
    '' | *[!0-9]*) now() { python3 -c 'import time; print(f"{time.time():.6f}")'; } ;;
    *) now() { date +%s.%N; } ;;
esac
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
ST=$(mktemp -d)
trap 'rm -rf "$ST"' EXIT
mkdir -p "$OUT"
# call NAME hd.sh-args...: hd.sh in the background, its start and end
# epochs and its exit status in ST; the caller reads the PID from $!
call() {
    local name=$1; shift
    printf '%q ' sh "$HD" "$@" | sed 's/ $//' > "$ST/$name.cmd"
    (
        now > "$ST/$name.start"
        rc=0
        sh "$HD" "$@" > "$OUT/$name.out" 2>&1 || rc=$?
        now > "$ST/$name.end"
        echo "$rc" > "$ST/$name.rc"
    ) &
}
alive() { kill -0 "$1" 2>/dev/null; }
descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
# guard NAME PID LIMIT: past LIMIT (epoch s), kill the call's container,
# and 10 s later hd.sh itself
guard() {
    local name=$1 pid=$2 limit=$3 t p
    alive "$pid" || return 0
    t=$(date +%s)
    [ "$t" -ge "$limit" ] || return 0
    if [ ! -e "$ST/$name.timeout" ]; then
        echo "$t" > "$ST/$name.timeout"
        log "$name: still running 30 s after its expected end, killing container $name"
        docker kill "$name" > /dev/null 2>&1 || true
    elif [ "$t" -ge $(($(cat "$ST/$name.timeout") + 10)) ]; then
        log "$name: still running after docker kill, killing hd.sh"
        for p in $(descendants "$pid") "$pid"; do kill -TERM "$p" 2>/dev/null || true; done
    fi
}
# collect NAME PID: wait for the call; a killed one gets its status here
collect() {
    local st=0
    wait "$2" || st=$?
    [ -s "$ST/$1.rc" ] || echo "$st" > "$ST/$1.rc"
    [ -s "$ST/$1.end" ] || now > "$ST/$1.end"
}
# hd.sh hangs a caller up after -d s and quits it 3 s later
log "bob: calling $TARGET ($LC, $LR Hz, $((D + 6)) s)"
call bob -c "$LC" -r "$LR" -d $((D + 6)) -l 5172 -m 40100 -N bob -i "$IMAGE" \
    -o "$OUT/bob.rx.wav" "$TARGET"
BOB=$!; BOB_LIMIT=$(($(date +%s) + D + 6 + 3 + 30))
sleep 3
log "alice: calling $TARGET, playing $CLIP ($PLAY_S s, $TC, $TR Hz, $D s)"
call alice -c "$TC" -r "$TR" -d "$D" -l 5170 -m 40000 -N alice -i "$IMAGE" \
    -p "$TX" -o "$OUT/alice.rx.wav" "$TARGET"
ALICE=$!; ALICE_LIMIT=$(($(date +%s) + D + 3 + 30))
while alive "$BOB" || alive "$ALICE"; do
    guard bob "$BOB" "$BOB_LIMIT"
    guard alice "$ALICE" "$ALICE_LIMIT"
    sleep 1
done
collect alice "$ALICE"
collect bob "$BOB"
echo "$(stamp) $ID end load $(loadavg)" >> "$R/load.log"
for n in bob alice; do
    if [ -f "$OUT/$n.log" ]; then mv "$OUT/$n.log" "$OUT/$n.pjsua.log"; fi
    log "$n: hd.sh exited $(cat "$ST/$n.rc")"
done
DIGEST=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
SHA=$(git -C "$CHAPPE" rev-parse HEAD 2>/dev/null || echo unknown)
RC=0
T_ID=$ID T_ARM=$ARM T_REP=$REP T_DIR=$DIR T_CLIP=$CLIP T_PATH=$PATHD \
    T_TARGET=$TARGET T_PADDED=$PADDED/padded.json T_UA_IMAGE=$IMAGE \
    T_UA_DIGEST=$DIGEST T_CHAPPE=$SHA \
    T_DOCKERFILE=$(dirname "$HD")/Dockerfile \
    T_PARTS="bob listener $LC $LR 5172 40100 $((D + 6)),alice talker $TC $TR 5170 40000 $D" \
    python3 "$HERE/trial.py" "$OUT" "$ST" >> "$LOG" 2>&1 || RC=$?
log "trial.json written, rc=$RC"
echo "$ID rc=$RC"
if [ "$RC" -ne 0 ]; then
    echo "$ID failed: see $LOG" >&2
    exit 1
fi
