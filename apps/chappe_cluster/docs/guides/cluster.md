# Run a cluster

This guide shows you how to run chappe_cluster on three nodes, add a fourth,
lose one, and use what the region gives you: leases with fences, the KV and
singletons. You need it when your app must have exactly one owner for
something (a room, a registration, a job) across several nodes. One node
works too, with `voters => [node()]`, the default.

## Start three nodes

Give each node the same `voters` list and its own name. In
`sys.config`:

```erlang
[{chappe_cluster, [
    {region, eu_west},
    {voters, ['a@host1', 'b@host2', 'c@host3']},
    {data_dir, "/var/lib/myapp/cluster"}
]}].
```

Start each node with the same cookie, then the app:

```sh
erl -name a@host1 -setcookie secret -config sys
```

```erlang
{ok, _} = application:ensure_all_started(chappe_cluster).
```

The region elects a leader once two of the three are up. Check a node's view:

```erlang
chappe_cluster:status().
%% #{region => eu_west, node => 'a@host1', live => true, epoch => 3,
%%   members => [...], leader => {chappe_cluster_eu_west, 'b@host2'}}
```

## Add a node

Start the new node with the same `voters` list (it is not in it), then add it
from any member:

```erlang
ok = chappe_cluster:join('d@host4').
```

Ra changes membership one node at a time. If another change is running, you
get an error back: retry. To remove a node:

```erlang
ok = chappe_cluster:leave('d@host4').
```

Then put the new list in `voters` for the next restart.

## Lose a node

Stop one of three. Nothing changes for the other two: they still have a
majority. The stopped node's leases stay valid until `lease_ms` after its
last renewal, then any node can claim its keys, with a greater fence.

Stop two of three. The last node cannot renew:

- its holders get `{chappe_cluster, Lease, lost}` within `lease_ms`;
- `claim/2`, `put/2`, `cas/3` and `delete/1` return `{error, no_quorum}`;
- `owner/1` and `get/1` still answer from the local replica, possibly stale.

Calls in progress are not touched. Restart one node and the region goes on.

## Claim and fence

```erlang
{ok, Lease} = chappe_cluster:claim({room, Name}, #{}),
{eu_west, _Epoch, Seq} = chappe_cluster:fence(Lease),
ok = storage:write(Key, Value, #{fence => Seq}).
```

- The caller is the holder; pass `#{pid => Pid}` to make another process
  hold it, and `#{timeout => Ms}` to bound the wait.
- Seq grows strictly per key. Have whatever you write to reject a fence
  lower than the last one it saw.
- The holder's death releases the lease. `release/1` gives it back.
- Handle the loss:

```erlang
receive
    {chappe_cluster, #{key := {room, Name}}, lost} -> stop_taking_members()
end.
```

- Find the owner: `chappe_cluster:owner(Key)` (local replica) or
  `chappe_cluster:owner(Key, consistent)` (through the leader). Both return
  `{ok, #{node, pid, fence}}` or `none`.
- `chappe_cluster:leases()` lists every lease in the region.

## Keep values

Keys are binaries. Each write returns the key's new version.

```erlang
{ok, V} = chappe_cluster:put(<<"peer/carrier1">>, #{status => up}),
case chappe_cluster:cas(<<"peer/carrier1">>, V, #{status => down}) of
    {ok, _V2} -> ok;
    {error, {version, Current}} -> reread(Current)
end,
{ok, _V3} = chappe_cluster:cas(<<"peer/new">>, 0, x).   %% create only
```

Watch a prefix from the process that wants the changes:

```erlang
ok = chappe_cluster:watch(<<"peer/">>),
receive
    {chappe_cluster, watch, {put, Key, Value}} -> update(Key, Value);
    {chappe_cluster, watch, {delete, Key, _Old}} -> drop(Key);
    {chappe_cluster, watch, overflow} -> resync()
end.
```

A watcher whose mailbox reaches `max_watch_mailbox` gets `overflow` once and
its watches end: read what you need with `get/1` and watch again. An event
can come twice after a member restarts; carry what you need in the value.

## Run a singleton

Call this on every node that may run the job:

```erlang
ok = chappe_cluster:singleton(trunk_pinger,
                              #{id => pinger, start => {my_pinger, start_link, []}}).
```

- One node holds the lease `{chappe_cluster_singleton, trunk_pinger}` and
  runs the child; when it loses the lease or the child stops, another node
  starts it.
- `chappe_cluster:whereis_singleton(trunk_pinger)` finds the running child
  from any node.
- Inside the child, `chappe_cluster:singleton_fence(trunk_pinger)` returns
  the fence to carry on its side effects.
- `chappe_cluster:stop_singleton(trunk_pinger)` stops contending from this
  node.

## Notes

- Keep a region on one low-latency network: every renewal waits for a
  majority round trip.
- `chappe_cluster:home(Key)` returns this node's region; the
  `chappe_cluster_directory` behaviour (`publish/3`, `resolve/1`) is where a
  cross-region backend will plug in.
- Set `lease_ms` at least twice `renew_ms`. A smaller `lease_ms` moves keys
  faster after a crash and loses them faster on a slow network.
