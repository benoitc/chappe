# Configuration

This page lists every application environment key of chappe_cluster, with
its default and what it does. Read it when you set up a region, size its
limits or tune the lease timings.

## Set it

The keys go in the `chappe_cluster` application environment, usually
`sys.config`:

```erlang
[{chappe_cluster, [
    {region, eu_west},
    {voters, ['a@host1', 'b@host2', 'c@host3']},
    {data_dir, "/var/lib/myapp/cluster"}
]}].
```

The app reads them once, at start, and keeps them until it restarts. A bad
value fails the start with `{error, badarg}` and a log line that names the
key.

## Keys

| Key | Default | What it does |
|---|---|---|
| `region` | `default` | The region this node belongs to: an atom other than `undefined`. It names the region's Ra server (`chappe_cluster_<region>`) and is the first element of every fence. |
| `voters` | `[node()]` | The region's Ra members at boot: a non-empty list of node names. A node in the list starts a member; on a fresh region the lowest node name triggers the first election. A node outside the list joins with `chappe_cluster:join/1`. |
| `data_dir` | `"cluster_data"` | Where Ra keeps its log and snapshots: a string or a binary. Each node writes under its own folder, `data_dir/<node name>`. |
| `lease_ms` | `6000` | How long one renewal keeps a node live, in ms. The leader expires a node `lease_ms` after the last renewal it applied. |
| `renew_ms` | `2000` | How often a node renews, in ms. It is also the budget of one renewal and the pause between a singleton's tries. |
| `max_drift` | `1` | The bound on any clock's rate drift, in percent (at least 0, below 50). It is checked against `lease_ms` and `renew_ms` (below). |
| `wall_clock` | `{erlang, system_time, [millisecond]}` | The HLC's wall clock, as `{M, F, A}`. |
| `hlc_max_offset_ms` | `10000` | How far a received stamp may move this node's HLC past its wall clock, in ms (0: no limit). |
| `max_leases` | `100000` | Leases one node may hold; a claim past it returns `{error, max_leases}`. It also bounds the releases a node queues for its next renewal, at three times its value. |
| `max_keys` | `100000` | Keys in the region's KV; a write of a new key past it returns `{error, max_keys}`. |
| `max_value_bytes` | `65536` | One KV value, in external term size; a larger one returns `{error, too_large}` before anything is sent. |
| `max_watch_mailbox` | `10000` | A watcher's message queue before it gets `{chappe_cluster, watch, overflow}` and its watches end. |
| `command_timeout` | `5000` | How long a write waits for the quorum, in ms, and the default `timeout` of `claim/2`, `cas/4` and `delete/2`. Past it, `{error, no_quorum}`. |
| `directory` | `chappe_cluster_directory_local` | The module behind `chappe_cluster_directory` (`publish/3`, `resolve/1`). |

Every other integer key must be a positive integer.

## The timing check

The app refuses to start unless `lease_ms`, `renew_ms` and `max_drift`
leave a holder time to give up before the leader expires its node
(`chappe_cluster_config:timing_ok/3`):

- `lease_ms >= 3 * renew_ms`: a renewal may take up to `renew_ms`, and the
  holder gives up `renew_ms / 2` early;
- `(lease_ms - renew_ms / 2) * (1 + d) < lease_ms * (1 - d)`, with `d` the
  drift as a fraction: a slow node and a fast leader still agree.

With the defaults the margin covers a drift of about 9 %
([decision 0010](../../../docs/decisions/0010-cluster-ownership.md)).

## Notes

- A smaller `lease_ms` moves keys sooner after a node crash, and loses
  them sooner on a slow network.
- `keys/2` pages are not configured: 1000 keys by default, 10000 at most
  per page.
- The [design overview](design/overview.md) says where each key is read.
