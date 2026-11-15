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
#   MODE=run        run: self-test then the schedule; topology: self-test only
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

exec erl -noshell -pa "$OUT/ebin" -eval 'chappe_cluster_lab:main().'
