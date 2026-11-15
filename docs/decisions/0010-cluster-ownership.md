# 0010: One Ra group per region owns what needs one owner

This record explains why chappe gives a resource one owner across a cluster
through a Raft group per region (`apps/chappe_cluster`), why the future
cross-region directory is barrel_p2p and not the owner, and what a node or a
region does when it loses its quorum. Read it before you add something that
needs exactly one owner (a room, a registrar binding, a singleton job), or
before you stretch a cluster across regions.

## Status

Accepted (the maintainer's decision, 2026-11-15).

## Context

What the repository and the research show:

- Before chappe_cluster, ownership was per node. A conference room claims its
  name in a local ETS table (`chappe_mrf_registry`), the registrar keeps its
  bindings in a local table (`chappe_sip_registry`), and the trunk OPTIONS
  pings, the registry sweep and the recording retention sweep run on every
  node. Two nodes could each open a room with the same name.
- Lookups already work across nodes through `pg` (call refs, audio streams),
  and handles are pids. `pg` is eventually consistent: it finds things, it
  cannot make one of them the only one.
- Ra 3.2.0 (hex `ra`, pinned in `apps/chappe_cluster/rebar.config`) is
  RabbitMQ's Raft library. It runs many small groups per node, persists a
  log and snapshots, monitors processes and nodes for its state machine, and
  changes membership at runtime, one member at a time.
- RabbitMQ's guidance for its Raft-based queues is to keep a cluster within
  one region: every write, and so every lease renewal, waits on a majority
  round trip, and it advises against links past about 100 ms of RTT.
- barrel_p2p (0.1.0) is HyParView membership, Plumtree broadcast and CRDT
  maps. Its leader-election documentation says it is AP: during a partition
  both sides elect and own, and exclusive ownership needs consensus.
- CockroachDB and TiKV run small Raft groups inside a region, with an
  asynchronous directory between regions, and CockroachDB keeps range leases
  valid through a per-node liveness epoch.

## Decision

- **One Ra group per region** holds node liveness, leases and a small KV
  with versions (`chappe_cluster_machine`). The region's voters are three
  nodes, or two plus a small node that runs only chappe_cluster.
- **Epoch leases.** Each node renews one liveness record every `renew_ms`;
  a lease is valid while its node's record is. A node holding a thousand
  rooms writes one renewal per period, not a thousand. A renewal after the
  record expired starts a new epoch, and the old epoch's leases are dead.
- **Deterministic time.** The machine uses the timestamp the leader stamps
  on each command, never a replica's clock, so every replica applies the
  log to the same state.
- **Fences.** A lease carries `{Region, NodeEpoch, Seq}`. Seq grows strictly
  per key, so a side effect can carry it and the receiver can refuse an
  older owner; the region in it refuses a stale owner coming from another
  region.
- **The holder gives up first.** A node tells its holders their lease is
  lost `renew_ms / 2` before the region can expire it, so the old holder
  stops before a new one starts, with that margin for clock skew between
  leaders.
- **barrel_p2p later, as the directory.** Between regions, a later plan
  publishes `{home region, owner, fence}` through barrel_p2p behind the
  `chappe_cluster_directory` behaviour. It tells a region where a resource
  lives; it never decides who owns it, because an AP system cannot.

## What a lost quorum does

- A node that cannot renew for `lease_ms - renew_ms / 2` tells every holder
  `{chappe_cluster, Lease, lost}`. A singleton stops its child there.
- New claims and KV writes return `{error, no_quorum}` within their timeout
  (immediately once the node knows it is not live). Reads from the local
  replica still answer, possibly stale.
- Nothing on a call's setup path waits for the quorum: calls go on, and only
  the creation of new owned resources (a room, a binding) stops until the
  region is whole again. The majority side of a partition takes over the
  minority's keys once their leases run out.

## Consequences

- chappe_cluster is a leaf app: SIP-free, depending on `ra` only. chappe_sip
  and chappe_mrf use it behind one function per owned resource; with no
  cluster configured they behave as before.
- Each member keeps a Raft log under `data_dir`, and each region needs a
  majority of its voters up to take new leases.
- A region spans one low-latency network. Several regions are several
  groups, joined later by the directory, not one stretched group.
- Fences compare by Seq: the node epoch of a takeover can be lower than the
  previous holder's.

## Open questions

- Rehoming a resource between regions (an explicit, fenced operator action)
  is the cross-region plan's question.
- Whether the registrar's bindings stay in the region KV at large scale, or
  move to their own Ra group per shard.
