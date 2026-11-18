# Features

What chappe_cluster does today, and what is planned. Use this to see
whether a capability exists before you reach for it. Each line links to the
page that shows you how to use it.

## Working

- **One Ra group per region** on Ra 3.2.0: node liveness, leases and a KV
  in one machine, with voters from `voters` and runtime membership changes
  (`join/1`, `leave/1`). [Run a cluster](guides/cluster.md#start-three-nodes)
- **Fenced epoch leases**: `claim/2`, `release/1`, `fence/1`, `valid/1`;
  one renewal per node keeps every lease it holds; a holder hears `lost`
  before the region frees its key, within the `max_drift` bound. [Run a cluster](guides/cluster.md#claim-and-fence)
- **Owner lookups**: `owner/1` from the local replica, `owner/2` through
  the leader, `leases/0` for the region.
- **Bounded calls**: every write waits at most its timeout and returns
  `{error, no_quorum}`; a node that knows it is not live answers a claim
  at once. [Run a cluster](guides/cluster.md#lose-a-node)
- **No wall clock in ownership**: expiry runs on the leader's monotonic
  clock, a holder gives up on its own, and the start refuses timings that
  leave no margin under `max_drift`.
  [Configuration](configuration.md#the-timing-check)
- **A KV with versions**: `put/2`, `get/1,2`, `cas/3,4`, `delete/1,2`
  (only the version you read), `keys/1,2` paginated, bounded by `max_keys`
  and `max_value_bytes`. [Run a cluster](guides/cluster.md#keep-values)
- **Watches** on a key prefix, at least once, with an `overflow` bound.
  [Run a cluster](guides/cluster.md#keep-values)
- **Singletons**: one child per name in the region, killed on `lost`, with
  `singleton_valid/1` and `singleton_fence/1` for its side effects.
  [Run a cluster](guides/cluster.md#run-a-singleton)
- **HLC timestamps** on leases, KV writes and watch events (`now/0`).
- **The directory seam**: the `chappe_cluster_directory` behaviour with its
  `local` backend, picked by the `directory` key.
- **The cluster lab**: seeded partitions, kills, pauses, delays and clock
  skews in docker, checked for overlapping leases
  (`make interop-cluster`). [The lab](../interop/README.md)

## Planned

- A cross-region directory backend on barrel_p2p, behind
  `chappe_cluster_directory`: it publishes where a resource lives between
  regions and never decides its owner
  ([decision 0010](../../../docs/decisions/0010-cluster-ownership.md)).
  `home/1` returns this node's region until then.
- Rehoming a resource between regions, as an explicit fenced operator
  action, is an open question of the same plan.
