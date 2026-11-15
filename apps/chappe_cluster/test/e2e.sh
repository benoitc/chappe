#!/bin/sh
# Copyright 2026 Benoit Chesneau
# SPDX-License-Identifier: Apache-2.0
#
# The cluster lab (make interop-cluster): NODES chappe_cluster nodes in
# docker (apps/chappe_cluster/interop), a seeded schedule of partitions,
# kills, pauses, delays and clock skews, and the lease checker over every
# node's event log.
# The controller (test/lab/chappe_cluster_lab.erl) runs here, on the host,
# and reaches the nodes through docker; nothing is published on the host.
#
#   SEED=...        replay a run (logged at the start and the end)
#   DURATION=5m     run length (s or m suffix)
#   NODES=5         3 to 5
#   MODE=run        run: self-test then the schedule; topology: self-test
#                   only; proofs: each fault against the fake cluster with
#                   the matching bug, which must fail, and two controls,
#                   which must pass (about 20 minutes, 3 nodes);
#                   PROOFS="pause skew" runs those only
#   SELFTEST=1      0 skips the self-test before a run
#   MARGIN_MS=0     overlap allowed between two leases
#   KILL_BOUND_MS   how long a killed node's leases stay its (renew_ms / 2)
#   FAULTS=...      keep these fault kinds only (isolate,split,kill,delay,
#                   pause,skew)
#   CHECK_KEYS=all  lab or singleton checks only those keys
#   KEEP=1          leave the containers up afterwards
#   CLB_PROJECT=clb compose project, network and image prefix
#   CLB_COOKIE      the nodes' cookie; a random one when unset, never printed
#
# The event logs land in _build/clb/logs/<seed>/.
set -eu

cd "$(dirname "$0")/../../.."
OUT=_build/clb
mkdir -p "$OUT/ebin"
erlc -o "$OUT/ebin" apps/chappe_cluster/test/lab/chappe_cluster_lab.erl \
    apps/chappe_cluster/test/lab/chappe_cluster_lab_schedule.erl \
    apps/chappe_cluster/test/lab/chappe_cluster_lab_checker.erl

if [ -z "${CLB_COOKIE:-}" ]; then
    CLB_COOKIE=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
fi
export CLB_COOKIE

lab() {
    erl -noshell -pa "$OUT/ebin" -eval 'chappe_cluster_lab:main().'
}

if [ "${MODE:-run}" != "proofs" ]; then
    lab
    exit $?
fi

# The proofs: name, expected exit (0 pass, 2 violation), then the settings.
# The fake (test/lab/chappe_cluster_lab_fake.erl) runs instead of
# chappe_cluster on every node; FAKE_MODE picks its bug.
set +e
FAILED=""
proof() {
    name=$1 want=$2
    shift 2
    # PROOFS="pause skew" runs those only
    case " ${PROOFS:-$name} " in
        *" $name "*) ;;
        *) return 0 ;;
    esac
    echo "== proof $name: expect exit $want ($*)"
    env MODE=run NODES=3 SELFTEST=0 CLB_BACKEND=fake CLB_PROJECT=clbproof \
        "$@" erl -noshell -pa "$OUT/ebin" -eval 'chappe_cluster_lab:main().' \
        > "$OUT/proof-$name.log" 2>&1
    got=$?
    grep -aE "^violation|^  key|PASS:|FAIL:" "$OUT/proof-$name.log" | head -4
    if [ "$got" = "$want" ]; then
        echo "   ok"
    else
        echo "   UNEXPECTED exit $got, see $OUT/proof-$name.log"
        FAILED="$FAILED $name"
    fi
}
proof control 0 FAULTS=none FAKE_MODE=careful DURATION=90s SEED=100
# three keys for nine workers, held past a pause: a paused holder's key is
# taken over, and it acts again when it wakes
proof pause 2 FAULTS=pause CHECK_KEYS=lab FAKE_MODE=lazylost CLB_KEYS=3 \
    CLB_HOLD_MS=30000 DURATION=150s SEED=508
proof kill 2 FAULTS=kill CHECK_KEYS=lab FAKE_MODE=naive DURATION=120s SEED=102
proof skew 2 FAULTS=skew CHECK_KEYS=lab FAKE_MODE=skewtrust DURATION=200s SEED=420
proof skew_control 0 FAULTS=skew CHECK_KEYS=lab FAKE_MODE=careful DURATION=200s SEED=420
proof singleton 2 FAULTS=isolate,pause CHECK_KEYS=singleton FAKE_MODE=careful \
    DURATION=240s SEED=104
if [ -n "$FAILED" ]; then
    echo "proofs failed:$FAILED"
    exit 1
fi
echo "every fault failed its fake, and the controls passed"

