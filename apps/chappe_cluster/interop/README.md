# The cluster lab

The cluster lab runs three to five chappe_cluster nodes in docker, cuts and
kills them on a random schedule, and checks that no key ever had two valid
leases at once. Run it when you change the Ra machine, the lease timings or
anything a lease depends on; CI runs it for five minutes on each pull request.

## Run it

```sh
make interop-cluster                       # 5 nodes, 5 minutes, a new seed
DURATION=30m make interop-cluster          # the long run, by hand
SEED=68350035 make interop-cluster         # replay a run
NODES=3 MODE=topology make interop-cluster # only check the faults apply
```

The seed is printed at the start and at the end. The same seed, duration,
node count and docker host give the same schedule.

## What it does

1. Builds one image from `apps/chappe_cluster` (OTP 29, chappe_cluster and
   Ra, the lab client from `test/lab`) and starts `n1`..`nN` on the network
   `clb_lab`. Each node runs as `lab@nN` with every started node as a voter.
   The cookie comes from `CLB_COOKIE` (random when unset) and is never
   printed.
2. Self-test: each fault is applied once and the controller checks, with
   `rpc` over distributed Erlang, that the cut node is unreachable and that
   the mesh comes back after the heal.
3. The schedule: one fault at a time, held 2 to 20 s, then healed:

   | Fault | How |
   |---|---|
   | isolate a minority, or a majority (no quorum) | `docker network disconnect` |
   | split a minority from the rest | `iptables` DROP on the minority |
   | kill a minority, sometimes a majority | `docker kill`, then `docker start` |
   | delay one node by 50 to 400 ms | `tc netem` |
   | pause a node past lease_ms, or for about renew_ms / 2 | `docker pause`, then `unpause` |
   | move a node's wall clock by 0.2 to 4 s, either way, for 72 to 95 s, and isolate a node 62 s in for lease_ms + 2 s | libfaketime, `docker network disconnect` |

   `split`, `delay` and `skew` are skipped when the docker host has no
   usable iptables or tc, or the image has no libfaketime, and the run
   says so. A skew holds over a minute because the runtime notices an OS
   clock change within 60 s; only then does `erlang:system_time`
   (`+C multi_time_warp`) follow it. An offset matters when a lease runs
   out across two clocks, hence the isolate inside it.
4. On each node three workers claim one of six keys at random, hold it for
   0.5 to 12 s (past lease_ms, `CLB_HOLD_MS`) while logging the fence
   every 200 ms, and release it. Before each side effect a worker reads its mailbox for `lost` (and calls
   `chappe_cluster:valid/1` when the app exports it). Every node also
   contends for one singleton whose child logs its fence every 200 ms and
   takes 1.5 s (`CLB_SINGLETON_STOP_MS`, more than renew_ms / 2) to stop.
   Every claim, renew, fence use, lost and release goes to `/logs` in the
   node, stamped with real time from the monotonic clock, so a skewed node
   still logs true times.
5. When it kills a node the controller logs the node's real time just
   before the kill. A lease that node held is the region's for renew_ms / 2
   more (`KILL_BOUND_MS`), or until the node is started again: its holder
   had not been told to stop, so a takeover sooner is an overlap. A
   holder silent for a second before the kill had already stopped.
6. After the last heal every node must claim again. The controller then
   stops the workers, copies the logs to `_build/clb/logs/<seed>/` and runs
   `chappe_cluster_lab_checker`.

## Prove each fault can fail

A fault the checker never fails on proves nothing. `MODE=proofs` runs each
fault against a fake cluster (`test/lab/chappe_cluster_lab_fake.erl`, test
code only, never part of the app) that has the matching bug, and expects the
checker to report a violation; two controls run the fake where it is right
and expect a pass. It takes about 20 minutes on 3 nodes, so it is a by-hand
step, not a CI job:

```sh
MODE=proofs make interop-cluster
```

| Proof | Fake mode | Faults | Expect |
|---|---|---|---|
| control | careful | none | pass |
| pause | lazylost: no check before a side effect, lost heard late | pause | violation |
| kill | naive: frees a key when its holder's node drops | kill | violation |
| skew | skewtrust: a takeover judged by the claimant's clock | skew | violation |
| skew_control | careful: judged by the server's clock | skew | pass |
| singleton | careful: the child stops slowly on lost | isolate, pause | violation |

Each run's output is in `_build/clb/proof-<name>.log`. Run when you change
a fault, the schedule or the checker.

## Read a failure

The checker prints the first violation and the events of its key around it:

```
violation: overlap at 1763200000123456
  key: {lab,3}
  first: #{holder => {n2,1763199990000,{1,7}},fence => {default,4,31},...}
  second: #{holder => {n4,1763199991000,{2,9}},fence => {default,6,32},...}
```

The holder is `{Node, Boot, {Worker, Incarnation}}`. Times are each node's
clock in microseconds; the controller prints the wall time of every fault in
the same unit, so you can find the fault that preceded the violation.
`MARGIN_MS` tolerates that much overlap (0 by default: the times are real
time, even on a skewed node).

## Notes

- `KEEP=1` leaves the containers up; attach with
  `docker exec -it clb-n1-1 erl -sname dbg -remsh lab@n1`.
- `CLB_PROJECT` moves the compose project, network and image name.
- `FAULTS=pause,skew` keeps those fault kinds only (`FAULTS=none` runs
  with no fault, a control run); `CHECK_KEYS=lab` or
  `singleton` checks the workers' keys or the singleton's only.
- `CLB_SINGLETON=0` leaves the singleton out; `CLB_FAKETIME=0` runs the
  beams without libfaketime; `CLB_TIME_WARP=default` runs them in the
  runtime's default time warp mode instead of `multi_time_warp`.
- `CLB_LEASE_MS`, `CLB_RENEW_MS`, `CLB_WORKERS`, `CLB_KEYS`,
  `CLB_HOLD_MS` and `CLB_TICKTIME` (net_ticktime, 10 s) tune the nodes.
