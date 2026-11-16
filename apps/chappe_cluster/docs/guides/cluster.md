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
  on the same node hold it (a pid on another node is `{error, badarg}`: the
  lease follows this node's liveness), and `#{timeout => Ms}` to bound the
  wait (an integer; `infinity` is refused).
- A claim waits for the quorum up to its timeout. On a call setup path,
  claim from another process or with a short timeout.
- Claiming a key you already hold returns `{error, {owned, Owner}}` with
  yourself as the owner. A claim that timed out may still be granted
  later; chappe_cluster gives it back, so retry after a short wait.
- Before each side effect, check `chappe_cluster:valid(Lease)` (true while
  this node still holds it) and carry the fence.
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

On a request path, bound the wait for the quorum, delete only the version
you read, and list what a prefix holds (from the local replica):

```erlang
{ok, V4} = chappe_cluster:cas(<<"peer/other">>, 0, y, #{timeout => 500}),
ok = chappe_cluster:delete(<<"peer/other">>, #{version => V4, timeout => 500}),
Keys = chappe_cluster:keys(<<"peer/">>).
```

A delete of a version that is no longer the key's returns
`{error, {version, Current}}` and leaves the key alone, so a delete never
removes a write it did not see.

Watch a prefix from the process that wants the changes:

```erlang
ok = chappe_cluster:watch(<<"peer/">>),
receive
    {chappe_cluster, watch, {put, Key, Value, _Hlc}} -> update(Key, Value);
    {chappe_cluster, watch, {delete, Key, _Old, _Hlc}} -> drop(Key);
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
- On `lost` the child is killed (`exit(Pid, kill)`), with no shutdown: it
  is dead before another node may start its own, and its `terminate/2`
  does not run. Keep what it writes fenced, and do not rely on a cleanup
  at stop. When you stop it yourself (`stop_singleton/1`) it gets a normal
  shutdown, bounded by what is left of the lease.
- Two copies never act at the same time, as long as each checks before it
  acts and clocks run at about the same rate (decision 0010). A paused copy can
  still be alive while another runs; the fence lets whatever it writes to
  refuse it.
- `chappe_cluster:whereis_singleton(trunk_pinger)` finds the running child
  from any node.
- Inside the child, check `chappe_cluster:singleton_valid(trunk_pinger)`
  before each side effect, and carry
  `chappe_cluster:singleton_fence(trunk_pinger)` on it. Both read a table,
  so they cost no message:

```erlang
handle_info(ping, S) ->
    case chappe_cluster:singleton_fence(trunk_pinger) of
        {ok, Fence} -> send_options(S, Fence);
        none -> ok                 %% the lease is gone: do nothing
    end,
    {noreply, S}.
```

  The kill on `lost` cannot reach a child that is paused (a suspended VM
  or container, a long GC): when it wakes up, the lease may already belong
  to another node, and only this check stops it before it acts.
- `chappe_cluster:stop_singleton(trunk_pinger)` stops contending from this
  node.

## Notes

- Keep a region on one low-latency network: every renewal waits for a
  majority round trip.
- `chappe_cluster:home(Key)` returns this node's region; the
  `chappe_cluster_directory` behaviour (`publish/3`, `resolve/1`) is where a
  cross-region backend will plug in.
- Set `lease_ms` at least three times `renew_ms`, or the app refuses to
  start. A smaller `lease_ms` moves keys faster after a crash and loses
  them faster on a slow network.
- Clocks: nothing needs the nodes' wall clocks to agree, and a wall clock
  that jumps changes no lease. Expiry runs on the leader's monotonic
  clock, and each holder gives up on its own; the only assumption is that
  clocks run at about the same rate, within `max_drift` percent (default
  1), during one lease. The app refuses to start when `lease_ms`,
  `renew_ms` and `max_drift` leave no margin.
- Timestamps: `chappe_cluster:now()` returns this node's hybrid logical
  clock. Leases, `leases()` rows and watch events carry the writer's
  stamp, merged by the region with the latest stamp it handed out, so
  anything applied after an event (a claim after a release) carries a
  later stamp, whichever wall clock runs ahead. Use it to order events in
  logs, not to decide ownership.
- Stopping the app tells every holder lost, and the next start takes a
  new epoch.
