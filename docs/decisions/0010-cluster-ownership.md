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
  a lease is valid while its node's epoch is. A node holding a thousand
  rooms writes one renewal per period, not a thousand.
- **No clock in the machine.** The Ra machine never reads a time, neither
  its own nor the stamp Ra puts in a command. It applies results: a renew
  of the node's current epoch keeps it and counts the renew; an expire
  ends an epoch only if it names the current epoch and renew count; a
  claim succeeds only on a free key. Replay and snapshots are
  deterministic by construction.
- **Every command may arrive late.** A command whose caller timed out
  can still be applied, after later ones. So nothing stale ends what a
  later command made:
  - a renew of an epoch the region ended is refused, and changes nothing;
  - a new epoch is asked for by the node's incarnation (a number the
    region hands out at each app start) and names the epoch it replaces;
    a delayed request, or one from an earlier incarnation, is refused;
  - a second claim by the same holder is refused, so a delayed try never
    takes over the lease of its retry, and an abandoned try drops only
    its own lease.
- **The leader decides expiry, on its monotonic clock.** Each renew the
  leader applies cancels the node's timer and starts `{expire, Node,
  Epoch, Count}` of `lease_ms`, named after that renew. Ra runs these
  timers on the leader only, as erlang timers, which are monotonic, and
  appends a fired one as an ordinary command, which can land behind a
  renew whose commit stalled: that renew counted, so the stale timer names
  an old count and ends nothing. A new leader starts one timer for every
  live node at the moment it becomes leader (`state_enter`), so a node
  gets a full `lease_ms` from each new leader; a deposed leader's timer
  that still lands is dropped the same way.
- **The holder gives up first, on its own monotonic clock.** A renewal sent
  at T and answered keeps its holders until T + `lease_ms - renew_ms / 2`
  by the node's monotonic clock. The leader applied it after T, and
  expires the node `lease_ms` after that, or after it became leader, by
  its own. With every clock's rate within `max_drift` of real time
  (default 1 %), the worst case is a slow node and a fast leader:
  `(lease_ms - renew_ms / 2) * (1 + d) < lease_ms * (1 - d)`, checked at
  start (`chappe_cluster_config:timing_ok/3`). With the defaults the
  margin covers up to about 9 %. The lost comes from a process that does
  nothing else (`chappe_cluster_lapse`), the holders and the deadline live
  in a table the app's supervisor owns, and a grant that comes back after
  the deadline is given back. `chappe_cluster:valid/1` tells a holder,
  before each side effect, whether its lease still holds.
- **What remains assumed:** clocks run at about the same rate (within
  `max_drift`) during one lease. Nothing assumes the nodes' wall clocks
  agree, or that a wall clock does not jump: no lease, expiry or claim
  reads one.
- **HLC where a timestamp is needed.** Each node keeps one hybrid logical
  clock (hlc 3.0.4, the one barrel_p2p uses). Claims and KV writes carry
  the writer's stamp; leases, `leases()` rows and watch events carry it,
  and a node's clock moves forward with the stamps it receives, but by no
  more than `hlc_max_offset_ms` (10 s) past its own wall clock, so one node
  with a far-future clock cannot drag the others along.
  `chappe_cluster:now/0` returns it. It orders events for logs and for the
  cross-region directory; no ownership decision depends on it.
- **No message closes a window.** When an epoch ends, the region tells the
  node's agent which keys went (`chappe_cluster_taken`); that message may
  be lost and nothing depends on it. The holders gave up already, by
  their own deadline, before the leader's timer could end the epoch.
- **Fences.** A lease carries `{Region, NodeEpoch, Seq}`. Seq grows strictly
  per key, so a side effect can carry it and the receiver can refuse an
  older owner; the region in it refuses a stale owner coming from another
  region.
- **Singletons are killed on lost.** A singleton's child gets an `exit(Pid,
  kill)` the moment its node gives the lease up: there is no time for a
  graceful stop inside the `renew_ms / 2` margin. A stop while the lease
  holds is a shutdown, bounded by what is left of the lease. A kill cannot
  reach a paused process (a suspended VM or container, a long GC): when it
  wakes up the lease may be another node's. So a child checks
  `chappe_cluster:singleton_valid/1` before each side effect and carries
  `chappe_cluster:singleton_fence/1` on it, as a plain holder checks
  `valid/1`; both read the node's table, not a process. The cluster lab
  found this: a paused child wrote with its old fence after another node
  had started the singleton.
- **barrel_p2p later, as the directory.** Between regions, a later plan
  publishes `{home region, owner, fence}` through barrel_p2p behind the
  `chappe_cluster_directory` behaviour. It tells a region where a resource
  lives; it never decides who owns it, because an AP system cannot.

## What a lost quorum does

- A node that cannot renew for `lease_ms - renew_ms / 2` tells every holder
  `{chappe_cluster, Lease, lost}`. A singleton's child is killed there.
- A claim or a KV write waits for the quorum up to its timeout
  (`command_timeout`, 5 s by default), then returns `{error, no_quorum}`;
  once the node knows it is not live, a claim returns at once. Reads from
  the local replica still answer, possibly stale.
- So a call setup path that claims a resource can wait. The users in PR 2
  (rooms, the registrar) must claim asynchronously, or with a short
  `timeout`, and fall back to what they do without a cluster: a lost quorum
  stops the creation of new owned resources, never the calls already up.
  The majority side of a partition takes over the minority's keys once
  their leases run out.

## Consequences

- chappe_cluster is a leaf app: SIP-free, depending on `ra` and `hlc` only. chappe_sip
  and chappe_mrf use it behind one function per owned resource; with no
  cluster configured they behave as before.
- Each member keeps a Raft log under `data_dir`, and each region needs a
  majority of its voters up to take new leases.
- A region spans one low-latency network. Several regions are several
  groups, joined later by the directory, not one stretched group.
- Fences compare by Seq: the node epoch of a takeover can be lower than the
  previous holder's.
- A lease is held on the node that claimed it: its holder must be a local
  process, since `lost` is a local message from that node.
- `lease_ms` must be at least three times `renew_ms`: a renewal may take up
  to `renew_ms`, and the holder gives up `renew_ms / 2` early.
- Every Ra call (claims, releases, KV writes, renewals) keeps one deadline:
  the last known leader first, each member only what is left of it.
- Stopping the app tells every holder lost; the next start takes a new
  epoch, which ends the old one's leases in the region.

## Open questions

- Rehoming a resource between regions (an explicit, fenced operator action)
  is the cross-region plan's question.
- Whether the registrar's bindings stay in the region KV at large scale, or
  move to their own Ra group per shard.
