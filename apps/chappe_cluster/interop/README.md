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

   `split` and `delay` are skipped when the docker host has no usable
   iptables or tc, and the run says so.
4. On each node three workers claim one of six keys at random, hold it for
   0.5 to 8 s while logging the fence every 200 ms, and release it. Every
   claim, renew, fence use, lost and release goes to `/logs` in the node.
5. After the last heal every node must claim again. The controller then
   stops the workers, copies the logs to `_build/clb/logs/<seed>/` and runs
   `chappe_cluster_lab_checker`.

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
`MARGIN_MS` tolerates that much overlap for clock skew (0 by default: all
containers share the docker host's clock).

## Notes

- `KEEP=1` leaves the containers up; attach with
  `docker exec -it clb-n1-1 erl -sname dbg -remsh lab@n1`.
- `CLB_PROJECT` moves the compose project, network and image name.
- `CLB_LEASE_MS`, `CLB_RENEW_MS`, `CLB_WORKERS`, `CLB_KEYS` and
  `CLB_TICKTIME` (net_ticktime, 10 s) tune the nodes.
