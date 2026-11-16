# Cluster demo

Three chappe nodes, `n1`, `n2` and `n3`, run chappe_cluster, chappe_sip and
chappe_mrf with `cluster => chappe_cluster`, in docker. Use it to see what
a region gives you before you build on it: a phone registered on one node
is called from another, callers of one conference number land in one
room whichever node they reach, the room moves when its node stops, and
one node pings the trunk for all of them.

Everything runs on one docker network, 172.29.18.0/24:

| Service | Address | What it is |
|---|---|---|
| n1, n2, n3 | .11, .12, .13, SIP on 5060/udp | the chappe nodes (`demo@n1` ...) |
| rtpengine | .20 | media in front of the room's mixer |
| trunk | .30, 5060/udp | answers OPTIONS and logs who sent them |
| ctl | | a node the smoke test asks the cluster from |

The node's code is `src/demo_cluster.erl`. Users: `alice` / `alice-demo`
and `bob` / `bob-demo`, domain `chappe.demo` (test-only passwords).

## Start it

```sh
make demo-cluster
```

The first start builds the tree, sofia-sip included, in a Linux
container: a few minutes. Then:

```sh
docker compose -f demo/cluster/docker-compose.yml logs -f n1 n2 n3 trunk
```

shows `demo demo@n1: up ...` on each node. `make demo-cluster-down` stops
it and drops the build volume. If 172.29.18.0/24 is taken on your machine,
set `DEMO_CLUSTER_PREFIX=10.77.18` (any free /24) for every command.

## Run the walkthrough by itself

```sh
make demo-cluster-smoke
```

It plays every step below with SIPp, checks each one, and prints
`smoke: PASSED`. CI-style: it starts the demo and removes it at the end
(`KEEP=1` leaves it up).

## Call a phone registered on another node

Register a softphone as `bob` on `172.29.18.11:5060` (n1) and another as
`alice` on `172.29.18.12:5060` (n2). On Linux and with OrbStack the
addresses are reachable from your machine; Docker Desktop on macOS does
not route to container addresses, so use the smoke test there.

From alice, call `bob`. n2 finds bob's binding in the region's KV and
sends the call to him; bob's phone rings. n2's log shows:

```
demo demo@n2: call to bob via ...
```

## Land in one room

Both phones dial `3000`. Each node's log shows the join, with the node
that runs the room:

```
demo demo@n1: <<"...">> joined room demo on demo@n1
demo demo@n2: <<"...">> joined room demo on demo@n1
```

In a shell (`make demo-cluster-shell N=n2`):

```erlang
demo_cluster:room().
%% #{node => 'demo@n1', pid => <...>, members => [#{...}, #{...}]}
```

## Kill the room's node

Kill the node the room runs on, here n1, as a crash would:

```sh
docker compose -f demo/cluster/docker-compose.yml kill n1
```

- The caller whose call runs on another node stays up: its node keeps the
  call. The audio of the room stops, since its mixer was on n1.
- `docker compose stop n1` is an orderly stop instead: the room's dialogs
  end with it, and both callers get a BYE.
- About `lease_ms` (6 s) later the room's lease is free. Dial `3000` again
  (from any phone, on n2 or n3): the room opens on a live node, and
  `demo_cluster:room()` names it.
- Without a majority (two of three nodes stopped) no new room opens: the
  caller gets 503.

Start n1 again with `docker compose ... start n1`; it rejoins the region.

## Watch the trunk pings

```sh
docker compose -f demo/cluster/docker-compose.yml logs -f trunk
```

```
trunk: OPTIONS from 172.29.18.12
```

The pings come from one address: the node running the pinger, a
chappe_cluster singleton (`demo_cluster:pinger()`). Stop that node: after
the lease runs out, the pings come from another node. Every node logs the
trunk's state and sees the same one (`demo_cluster:trunk()`).

## See the leases

```erlang
chappe_cluster:leases().
%% [#{key => {chappe_mrf_conf, <<"demo">>}, node => 'demo@n1', fence => {demo, 2, 7}, ...},
%%  #{key => {chappe_cluster_singleton, {chappe_sip_peer, trunk}}, ...}, ...]
```

Each lease names its node and its fence: the fence's last number grows
each time the key changes hands.

## Notes

- Ownership and its limits: [decision 0010](../../docs/decisions/0010-cluster-ownership.md)
  and the [cluster guide](../../apps/chappe_cluster/docs/guides/cluster.md).
- The rooms: the conference guide's
  [cluster section](../../apps/chappe_mrf/docs/guides/conference.md#run-rooms-on-a-cluster);
  the registrar: its [cluster section](../../apps/chappe_sip/docs/guides/registrar.md);
  the trunk pinger: [Run an SBC](../../apps/chappe_sip/docs/guides/sbc.md#ping-a-peer-from-one-node-of-a-cluster).
- Files: `docker-compose.yml`, `node/` (the image and its entry point),
  `src/` (the node, the trunk and the smoke test's ctl), `sipp/`,
  `smoke.sh`.
