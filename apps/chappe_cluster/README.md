# chappe_cluster

chappe_cluster gives a key one owner across the nodes of a region. It runs one
Raft group per region on Ra and holds three things in it: each node's
liveness, fenced leases, and a small KV with versions and watches. On top of
the leases it runs singletons: a child that runs on one node of the region and
moves when that node goes. Use it when two nodes must never both own the same
room, binding or job. It does not need the nodes' clocks in sync. It is a
leaf app: it depends on `ra` and `hlc`, and nothing SIP.

## Claim a key

```erlang
{ok, _} = application:ensure_all_started(chappe_cluster),
case chappe_cluster:claim({room, <<"sales">>}, #{}) of
    {ok, Lease} ->
        Fence = chappe_cluster:fence(Lease),   %% {Region, NodeEpoch, Seq}
        run_room(Lease, Fence);
    {error, {owned, #{node := Node, pid := Pid}}} ->
        {use, Node, Pid};
    {error, no_quorum} ->
        retry_later
end.
```

The holder, a process on the claiming node, gets `{chappe_cluster, Lease,
lost}` when its node's liveness lapses or another node takes the key over;
it stops acting on it then. `chappe_cluster:valid(Lease)` checks it before
a side effect.

## Keep a value

```erlang
{ok, V1} = chappe_cluster:put(<<"trunk/carrier1">>, up),
{ok, up, V1} = chappe_cluster:get(<<"trunk/carrier1">>),
{ok, _V2} = chappe_cluster:cas(<<"trunk/carrier1">>, V1, down),
ok = chappe_cluster:watch(<<"trunk/">>).
%% {chappe_cluster, watch, {put, <<"trunk/carrier1">>, down, Hlc}}
```

## Run one of something

```erlang
ok = chappe_cluster:singleton(sweeper, #{id => sweeper,
                                         start => {my_sweeper, start_link, []}}).
```

Call it on every node that may run it; one node runs it at a time.

## Guides

- [Run a cluster](docs/guides/cluster.md): three nodes, add one, lose one,
  and the API.
- Why it works this way: [decision 0010](../../docs/decisions/0010-cluster-ownership.md).

## Configuration

Application env, validated at start (a bad value fails the start with
`{error, badarg}`):

| key | default | meaning |
|---|---|---|
| `region` | `default` | the region this node belongs to |
| `voters` | `[node()]` | the region's Ra members at boot |
| `data_dir` | `"cluster_data"` | Ra's log and snapshots, one folder per node |
| `lease_ms` | `6000` | how long one renewal keeps a node live |
| `renew_ms` | `2000` | how often a node renews; `lease_ms >= 3 * renew_ms` |
| `max_drift` | `1` | clock rate drift bound, in percent; checked against the two above |
| `wall_clock` | `{erlang, system_time, [millisecond]}` | the HLC's wall clock |
| `hlc_max_offset_ms` | `10000` | how far a received stamp may move the HLC past the wall clock (0: no limit) |
| `max_leases` | `100000` | leases one node may hold |
| `max_keys` | `100000` | keys in the region's KV |
| `max_value_bytes` | `65536` | one KV value, in external term size |
| `max_watch_mailbox` | `10000` | a watcher's queue before it gets `overflow` |
| `command_timeout` | `5000` | how long a write waits for the quorum |
| `directory` | `chappe_cluster_directory_local` | the directory backend |
