#!/usr/bin/env bash
# One block of the A/B: start the demo of a build from its clean worktree,
# start the packet traces and the mixer probe, run block.sh, then stop the
# traces, the probe and the demo. When the demo loses rtpengine (block.sh
# exit 4), it is restarted (a new session, with its own logs and traces)
# and the block resumes, up to MAXSESS (4) sessions.
# OUT_DIR (this directory) holds the builds' run directories, the logs and
# the traces.
# Usage: WT=... [OUT_DIR=...] ab.sh N BUILD REP   (N 1 to 4; BUILD old or new)
set -euo pipefail
N=$1; B=$2; REP=$3
TAQ_DIR=${TAQ_DIR:-$HOME/Projects/telephony-audio-quality}
R=$(cd "$(dirname "$0")" && pwd)
O=${OUT_DIR:-$R}
WT=${WT:?WT, the directory holding the ab-<sha> worktrees}
MAXSESS=${MAXSESS:-4}
case $B in old) SHA=821870c ;; new) SHA=840bb74 ;; *) exit 2 ;; esac
W=$WT/ab-$SHA
P=$O/pcap; mkdir -p "$P"
[ "$(git -C "$W" rev-parse --short HEAD)" = "$SHA" ]
[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]
descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
RC=0
for S in $(seq "${SESS0:-1}" "$MAXSESS"); do
    L=$O/block$N-$B-s$S
    echo "$(date -u +%FT%TZ) block $N $B ($SHA) rep $REP session $S: demo starting" | tee -a "$O/blocks.log"
    (cd "$W" && DEMO_SIP_PORT=5080 exec make demo) > "$L.demo.log" 2>&1 &
    MPID=$!
    stop_demo() {
        local p
        for p in $(descendants "$MPID"); do
            case $(ps -o comm= -p "$p" 2>/dev/null) in *beam*) kill -TERM "$p" 2>/dev/null || true ;; esac
        done
        wait "$MPID" 2>/dev/null || true
        (cd "$W" && make demo-down) >> "$L.demo.log" 2>&1 || true
    }
    for _ in $(seq 1 300); do
        grep -q 'demo up' "$L.demo.log" && break
        kill -0 "$MPID" 2>/dev/null || break
        sleep 2
    done
    if ! grep -q 'demo up' "$L.demo.log"; then echo "demo not up" >&2; stop_demo; exit 1; fi
    {
        echo "chappe $(git -C "$W" rev-parse HEAD)"
        echo "rtpengine image $(docker image inspect chappe-rtpengine-interop --format '{{.Id}}')"
        docker compose -p chappe-demo ps --format '{{.Service}} {{.Image}} {{.Status}}'
        docker exec chappe-demo-rtpengine-1 rtpengine --version 2>&1 | head -1 || true
        erl -noshell -eval 'io:format("otp ~s erts ~s~n", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().'
    } > "$L.versions" 2>&1
    erl -sname mixprobe -hidden -setcookie chappe-demo -noshell -pa "$R" \
        -run mixprobe main demo@localhost "$L.mix.log" > /dev/null 2>&1 &
    PROBE=$!
    docker run -d --rm --name hd-ab-sip --net host -v "$P:/out" nicolaka/netshoot:v0.13 \
        tcpdump -i any -n -s 0 -w "/out/block$N-$B-s$S-sip.pcap" \
        'udp and (port 5080 or port 15081 or port 15082 or port 22223 or portrange 5170-5175)' > /dev/null
    docker run -d --rm --name hd-ab-rtp --net host -v "$P:/out" nicolaka/netshoot:v0.13 \
        tcpdump -i any -n -s 128 -w "/out/block$N-$B-s$S-rtp.pcap" \
        'udp and (portrange 31000-31100 or portrange 40000-40201)' > /dev/null
    sleep 2
    echo "$(date -u +%FT%TZ) block $N $B session $S: demo up, traces on, trials starting" | tee -a "$O/blocks.log"
    RC=0
    RUN_DIR=$O/$B META_DIR=$O/$B CHAPPE_DIR=$W DEMO_SIP_PORT=5080 TAQ_DIR=$TAQ_DIR \
        DEMO_LOG=$L.demo.log bash "$R/block.sh" "$REP" > "$L.block.log" 2>&1 || RC=$?
    docker stop hd-ab-sip hd-ab-rtp > /dev/null || true
    kill "$PROBE" 2>/dev/null || true
    stop_demo
    echo "$(date -u +%FT%TZ) block $N $B session $S: done rc=$RC" | tee -a "$O/blocks.log"
    [ "$RC" -eq 4 ] || break
done
exit $RC
