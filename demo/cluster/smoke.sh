#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The cluster demo's walkthrough (README.md), driven by SIPp and checked
# through demo_cluster_ctl, so the demo cannot rot:
#   1. bob registers on n1, alice calls him through n2;
#   2. the trunk's OPTIONS leave from one node, and move when it stops;
#   3. two callers dial 3000 on n1 and n2 and land in one room; the room's
#      node stops cleanly (docker stop): the room hands off, and the other
#      caller is in the room on a live node;
#   4. the same room's node is killed (docker kill): the other caller's
#      call stays up, and a new caller opens the room on a live node;
#   5. chappe_cluster:leases().
# DEMO_CLUSTER_PROJECT names the compose project (chappe-demo-cluster);
# KEEP=1 leaves the demo up. On a failure every container's log goes to
# DEMO_CLUSTER_LOGS (_build/demo-cluster-logs), for CI to upload.
#
# Usage: demo/cluster/smoke.sh   (or: make demo-cluster-smoke)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
LOGS=${DEMO_CLUSTER_LOGS:-$HERE/../../_build/demo-cluster-logs}
P=${DEMO_CLUSTER_PROJECT:-chappe-demo-cluster}
DC="docker compose -p $P -f $HERE/docker-compose.yml"
SIPP="-m 1 -l 1 -nostdin -trace_err"
NET=${DEMO_CLUSTER_PREFIX:-172.29.18}
N1=$NET.11:5060 N2=$NET.12:5060 N3=$NET.13:5060

say() { printf 'smoke: %s\n' "$*"; }
fail() { say "FAILED: $*"; exit 1; }
ctl() { $DC exec -T ctl demo-node ctl-run "$@"; }
# sipp NAME ARGS...: SIPp in the background, in a container named NAME
sipp() {
    name=$1
    shift
    docker rm -f "$P-$name" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    $DC --profile tools run -d --name "$P-$name" sipp $SIPP "$@" >/dev/null
}
# wait_ok NAME: the SIPp run NAME ended well
wait_ok() {
    rc=$(docker wait "$P-$1")
    [ "$rc" = 0 ] || { docker logs "$P-$1" 2>&1 | tail -20; fail "$1 exited $rc"; }
    docker rm "$P-$1" >/dev/null
}
service() { echo "${1#demo@}"; }

cleanup() {
    rc=$?
    if [ "$rc" != 0 ]; then
        mkdir -p "$LOGS"
        $DC --profile tools logs --no-color > "$LOGS/compose.log" 2>&1 || true
        for c in bob alice confa confb confc confd confe; do
            docker logs "$P-$c" > "$LOGS/sipp-$c.log" 2>&1 || true
        done
        say "logs in $LOGS"
    fi
    for c in bob alice confa confb confc confd confe; do docker rm -f "$P-$c" >/dev/null 2>&1 || true; done
    [ "${KEEP:-0}" = 1 ] || $DC --profile tools down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

say "building and starting (the first build compiles sofia-sip: a few minutes)"
$DC --profile tools build sipp >/dev/null
$DC up -d --build
ctl ready

say "1. bob registers on n1, alice calls him through n2"
docker rm -f "$P-bob" >/dev/null 2>&1 || true
$DC --profile tools run -d --name "$P-bob" --entrypoint /bin/sh sipp \
    /demo/bob.sh "$N1" >/dev/null
i=0
until docker logs "$P-bob" 2>&1 | grep -q "bob registered"; do
    i=$((i + 1))
    [ $i -lt 30 ] || fail "bob did not register"
    sleep 1
done
sipp alice -sf /scen/call.xml -s bob -d 2000 "$N2"
wait_ok alice
wait_ok bob
say "alice reached bob, registered on n1, from n2"

say "2. the trunk is pinged from one node"
ctl trunk up
PINGER=$(ctl pinger)
ctl sources "$PINGER"
say "pinged from $PINGER; stopping it"
$DC stop "$(service "$PINGER")" >/dev/null
NEXT=$(ctl pinger "$PINGER")
ctl sources "$NEXT"
ctl trunk up
say "the pings moved to $NEXT"
$DC start "$(service "$PINGER")" >/dev/null
ctl live "$PINGER"

say "3. two callers dial 3000 on n1 and n2; a clean stop hands the room off"
sipp confa -sf /scen/call.xml -s 3000 -d 40000 "$N1"
ctl room 1 >/dev/null
sipp confb -sf /scen/call.xml -s 3000 -d 40000 "$N2"
OWNER=$(ctl room 2)
say "both in one room, on $OWNER; stopping it"
$DC stop "$(service "$OWNER")" >/dev/null
case "$OWNER" in
    demo@n1) STAYS=confb ;;
    demo@n2) STAYS=confa ;;
    *) STAYS="confa confb" ;;
esac
MOVED=$(ctl room 1 "$OWNER")
say "the room moved to $MOVED with its caller ($STAYS)"
for c in $STAYS; do wait_ok "$c"; done
say "the moved caller stayed up and hung up normally"
docker rm -f "$P-confa" "$P-confb" >/dev/null 2>&1 || true
$DC start "$(service "$OWNER")" >/dev/null
ctl live "$OWNER"

say "4. a kill: the caller stays up, the next caller reopens the room"
sipp confd -sf /scen/call.xml -s 3000 -d 40000 "$N3"
ROOM=$(ctl room 1)
case "$ROOM" in
    demo@n3) FAR=$N1 ;;
    *) FAR=$N3 ;;
esac
# the second caller on another node than the room's
sipp confe -sf /scen/call.xml -s 3000 -d 40000 "$FAR"
ROOM=$(ctl room 2)
say "both in one room, on $ROOM; killing it"
$DC kill "$(service "$ROOM")" >/dev/null
case "$ROOM" in
    demo@n3) STAYS=confe ;;
    *) STAYS=confd ;;
esac
# the lease of the killed node runs out (lease_ms, 6 s), then the next
# caller opens the room on a live node
sleep 10
case "$ROOM" in
    demo@n2) NEXT=$N1 ;;
    *) NEXT=$N2 ;;
esac
sipp confc -sf /scen/call.xml -s 3000 -d 4000 "$NEXT"
REOPENED=$(ctl room 1 "$ROOM")
say "the room reopened on $REOPENED"
wait_ok confc
for c in $STAYS; do wait_ok "$c"; done
say "the caller on a live node stayed up ($STAYS)"
docker rm -f "$P-confd" "$P-confe" >/dev/null 2>&1 || true
OWNER=$ROOM

say "5. the leases"
ctl leases
$DC start "$(service "$OWNER")" >/dev/null
ctl live "$OWNER"
say "PASSED"
