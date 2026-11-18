# Use the cluster

chappe_cluster gives a key one owner across a [region](../glossary.md#region):
a [lease](../glossary.md#lease) for a process, or a
[singleton](../glossary.md#singleton) child that runs on one node at a time.
`pg` finds things across nodes but never makes one of them the only one. Use
this page when you add something to chappe_sip, chappe_mrf or your own app
that must have exactly one owner in the region, or that other nodes must find.

## Before you start

- [Decision 0010](../decisions/0010-cluster-ownership.md): leases, epochs,
  fences and what a lost quorum does.
- [apps/chappe_cluster/docs/design/overview.md](../../apps/chappe_cluster/docs/design/overview.md):
  leases, singletons, watchers.
- The user guide [cluster.md](../../apps/chappe_cluster/docs/guides/cluster.md),
  sections [Claim and fence](../../apps/chappe_cluster/docs/guides/cluster.md#claim-and-fence)
  and [Run a singleton](../../apps/chappe_cluster/docs/guides/cluster.md#run-a-singleton).
- [add-tests.md: Several nodes](add-tests.md#several-nodes).

## Where to look

| You need | Use | Example in the tree |
|---|---|---|
| A named resource a caller creates, held by one process (a room) | a lease: `chappe_cluster:claim/2` | `chappe_mrf_conf_cluster` |
| A job one node runs (a sweep, a pinger) | a singleton: `chappe_cluster:singleton/2` | `chappe_sip_peers` with `probe => singleton`, `chappe_sip_registry_sweep` |
| Find every process that serves a key, on any node | a `pg` group in your app's [scope](../glossary.md#pg-scope) | `chappe_sip_call`, `chappe_sip_mwi` |
| A small shared value with a version | the region KV: `chappe_cluster:get/1`, `chappe_cluster:cas/4` | `chappe_sip_location_cluster` |

## Steps

1. Pick the shape from the table. A `pg` lookup needs no chappe_cluster;
   take a lease only when two owners would be a bug.
2. For a lease, claim in the caller, not in the process's `init/1`, and
   name the process as holder, as `chappe_mrf_conf_cluster:start/2` does.
   A claim waits for the quorum, so keep its timeout short on a call
   setup path:

   ```erlang
   {ok, Pid} = my_sup:start_waiting(Name),
   case chappe_cluster:claim({my_thing, Name}, #{pid => Pid, timeout => 1000}) of
       {ok, Lease} -> my_thing:activate(Pid, Lease);
       {error, {owned, #{pid := Other}}} -> my_thing:stop(Pid), {ok, Other};
       {error, no_quorum} -> my_thing:stop(Pid), {error, no_quorum};
       {error, _} = Error -> my_thing:stop(Pid), Error
   end.
   ```

   Without a quorum, fall back to what you do with no cluster, or to the
   owner the local replica names (`chappe_cluster:owner/1`), never to a
   second owner.
3. Handle `lost` in the holder. Match on the lease you hold, since an
   older lease's `lost` may still arrive:

   ```erlang
   handle_info({chappe_cluster, #{seq := Seq}, lost}, #{lease := #{seq := Seq}} = S) ->
       {noreply, stop_taking_work(S)};
   handle_info({chappe_cluster, _Old, lost}, S) ->
       {noreply, S}.
   ```

   Take no new work from then on. Work already under way (calls up, members
   in a room) may finish.
4. Before each side effect, check the lease and carry its fence:

   ```erlang
   case chappe_cluster:valid(Lease) of
       true ->
           {_Region, _Epoch, Seq} = chappe_cluster:fence(Lease),
           my_store:write(Key, Value, #{fence => Seq});
       false ->
           {error, lost}
   end.
   ```

   The receiver keeps the highest Seq it saw for the key and refuses a
   lower one. Compare by Seq only.
5. For a singleton, call `chappe_cluster:singleton/2` on every node that
   may run it, with the same child spec. The child is killed on `lost`,
   so it checks `chappe_cluster:singleton_valid/1` before each side effect
   and carries `chappe_cluster:singleton_fence/1`, as `chappe_sip_peer`
   does before it writes a peer's state to the KV.
6. On a clean stop, give the lease back with `chappe_cluster:release/1`,
   or hand the work to another node first, as `chappe_mrf_conf_move` does
   for rooms.

## Tests to add or run

Write the four tests of the distributable rule
([add-tests.md](add-tests.md#several-nodes)): owner death, its own crash,
from another node, the bound. Then the cluster cases on three `peer`
nodes: the owner node dies, the owner node shuts down, a node loses its
quorum and its holder hears `lost`, and two nodes start the same key at
once and get one owner. Copy a real suite:

| Suite | Covers |
|---|---|
| `chappe_mrf_cluster_SUITE` | a lease per room: one room from two nodes, owner death, lost lease |
| `chappe_sip_peers_cluster_SUITE` | a singleton pinger and its fenced KV writes |
| `chappe_sip_registrar_cluster_SUITE` | KV values with compare-and-swap |
| `chappe_cluster_SUITE`, `chappe_cluster_peer_SUITE` | chappe_cluster itself |

```sh
rebar3 ct --suite apps/chappe_mrf/test/chappe_mrf_cluster_SUITE
make interop-cluster
make demo-cluster-smoke
```

`make interop-cluster` runs chappe_cluster nodes under partitions, kills,
pauses and clock skews, then `chappe_cluster_lab_checker` over every node's
log: no key ever had two valid leases at once, and fences only grow. It
checks chappe_cluster itself; run it when you change chappe_cluster, and
your own peer suite for your feature. `make demo-cluster-smoke` checks the
registrar, a room and a trunk pinger across three nodes.

## How to know it works

- `make check` passes.
- Your cluster suite passes several times in a row (`rebar3 ct --suite ...
  --repeat 5`): a race shows up as a flaky case.
- `make interop-cluster` passes when you touched chappe_cluster
  ([lab README](../../apps/chappe_cluster/interop/README.md)).

## Notes

- A lease's holder must be a process on the claiming node: `lost` is a
  local message.
- Claiming a key you already hold returns `{error, {owned, Owner}}` with
  yourself as owner.
- A kill on `lost` cannot reach a paused process; only `valid/1` and the
  fence stop a holder that wakes up after its lease went.
- chappe_sip and chappe_mrf turn the cluster on with their `cluster`
  setting (`none` by default); chappe_audio takes a `sweep_guard` instead
  ([add-audio-store.md](add-audio-store.md)).

## Related

- [add-location-backend.md](add-location-backend.md)
- [add-directory-backend.md](add-directory-backend.md)
- [debug-a-call.md: Across nodes](debug-a-call.md#across-nodes)
