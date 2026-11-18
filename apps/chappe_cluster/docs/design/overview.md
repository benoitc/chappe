# Design overview

This page describes how chappe_cluster is built: its processes, what each
one owns, and why the tree is ordered the way it is. Read it before you
change the node agent, the lapse timer or the singletons, or review a
change to them. Why the cluster works this way is in
[decision 0010](../../../../docs/decisions/0010-cluster-ownership.md); how
you use it is in the [guide](../guides/cluster.md).

## Processes

```
chappe_cluster_sup (rest_for_one)     owns the chappe_cluster_tab table
|-- pg scope chappe_cluster           watchers by prefix, running singletons
|-- chappe_cluster_hlc                the node's hybrid logical clock (hlc)
|-- chappe_cluster_watch              hands KV changes to local watchers
|-- chappe_cluster_lapse              gives every lease up at the deadline
|-- chappe_cluster_node               the Ra system and member, renewals
`-- chappe_cluster_singleton_sup      one chappe_cluster_singleton per name
    `-- chappe_cluster_singleton_sup  (per running singleton) its child
```

`chappe_cluster_sup` is `rest_for_one`: what depends on a process restarts
with it. The watch hub starts before the member that feeds it, and the
lapse timer before the agent, so an agent crash leaves the timer armed.

`chappe_cluster_sup` creates `chappe_cluster_tab` before its children and
owns it. The table holds the node's holders, its liveness and the pending
releases, so a crash of the agent or of the lapse timer loses no holder.

`chappe_cluster_singleton_sup` has two roles. Started with `top`, it is the
`one_for_one` supervisor of the contenders, one per singleton name. Started
with `{child, Spec}`, it is the supervisor of one running singleton, linked
to the contender that holds the name's lease, with intensity 0: the child
never restarts there and never outlives its contender. The contender sees
the child go, gives the lease back and contends again, so another node may
run it.

| Module | Role |
|---|---|
| `chappe_cluster` | Public API: `claim/2` and leases, the KV and `watch/1`, `singleton/2`. Checks arguments in the caller. |
| `chappe_cluster_directory`, `chappe_cluster_directory_local` | The directory behaviour (where a key lives) and its region-local backend. |
| `chappe_cluster_node` | The node's agent: starts Ra, renews the node's liveness every `renew_ms`, refreshes the members, hands takeovers to the holders. |
| `chappe_cluster_lapse` | The lapse timer: when the local deadline passes without a renewal, marks the node not live and tells every holder `lost`. |
| `chappe_cluster_watch` | The KV watch hub: matches each change to the pg groups of the watchers' prefixes. Keeps no state. |
| `chappe_cluster_tab` | The node's table: liveness, members, holders, leader, pending releases. |
| `chappe_cluster_machine` | The region's Ra machine: liveness by epoch, leases, the KV. Reads no clock. |
| `chappe_cluster_ra` | A Ra command bounded by one deadline across every member it tries. |
| `chappe_cluster_singleton`, `chappe_cluster_singleton_sup` | One node's contender for one singleton name, and the supervisors above. |
| `chappe_cluster_config` | The app env, validated once at start. |
| `chappe_cluster_app`, `chappe_cluster_sup` | Boot and the root supervisor. |

## The lapse

A renewal sent at time T keeps the node live until a local deadline the
agent computes from T, not from the time the reply came back. The agent
hands each deadline to `chappe_cluster_lapse`. The lapse timer is its own
process so nothing in another mailbox can delay a `lost`: it only receives
deadlines and its own tick. When it starts, it cannot know the deadline, so
it tells every holder its lease is lost before anything else.

The machine never reads a clock. A renewal carries the node's epoch; a
renewal with an old epoch (a delayed command from before a lapse) is
refused with `{error, stale_epoch}`. A node whose liveness lapsed asks for a
new epoch before it claims again.

## Singletons

A contender claims the lease `{chappe_cluster_singleton, Name}` every
`renew_ms` until it wins. Once it holds it, it starts the child under a
`{child, Spec}` supervisor and joins it to the pg group
`{chappe_cluster_singleton, Name}`. On `lost` it kills the child: the node
gives its leases up `renew_ms / 2` before the region may let another node
run it, and a graceful shutdown could outlast that. A child fences its side
effects with `chappe_cluster:singleton_valid/1` and
`chappe_cluster:singleton_fence/1`.

## Where it lives

- Configuration keys and defaults: `chappe_cluster_config` and the
  [README](../../README.md#configuration).
- The fault lab: [interop/README.md](../../interop/README.md) and
  `make interop-cluster`.
