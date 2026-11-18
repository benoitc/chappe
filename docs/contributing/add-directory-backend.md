# Add a directory backend

The [directory](../glossary.md#directory) says where a key lives, as its
home [region](../glossary.md#region) and some info. It is the seam between
regions: a module that implements `chappe_cluster_directory`. This release
ships `chappe_cluster_directory_local`, which only this region sees. Use this
page when you write a cross-region backend (barrel_p2p is the planned one)
or change the local one.

## Before you start

- [Decision 0010](../decisions/0010-cluster-ownership.md), the "barrel_p2p
  later, as the directory" and "Fences" points.
- [apps/chappe_cluster/docs/design/overview.md: The directory seam](../../apps/chappe_cluster/docs/design/overview.md#the-directory-seam).
- [use-the-cluster.md](use-the-cluster.md).

## Where to look

| Module (under `apps/chappe_cluster/src/`) | Role |
|---|---|
| `chappe_cluster_directory` | the behaviour, and `publish/3`, `resolve/1`, which call the configured backend |
| `chappe_cluster_directory_local` | the local backend: entries in the region's KV under `chappe_cluster/directory/` |
| `chappe_cluster_config` | the `directory` key (default `chappe_cluster_directory_local`) |
| `chappe_cluster` | `home/1` (this node's region in this release), `fence/1`, `get/1`, `put/2` |

## Steps

1. Write a module with `-behaviour(chappe_cluster_directory)` and its two
   callbacks:
   - `publish(Key, Region, Info)`: record that `Key` is homed in `Region`,
     `ok` or `{error, Reason}`;
   - `resolve(Key)`: `{ok, #{region := Region, info := Info}}`,
     `not_found`, or `{error, Reason}`.
2. Start from `chappe_cluster_directory_local`:

   ```erlang
   publish(Key, Region, Info) ->
       case chappe_cluster:put(kv_key(Key), #{region => Region, info => Info}) of
           {ok, _} -> ok;
           {error, _} = E -> E
       end.
   ```

   A cross-region backend publishes the same entry to the other regions
   instead of to this region's KV.
3. Keep the directory out of ownership. A resolve tells a region where a
   resource lives; it never decides who owns it. The region's leases do
   that, because the planned cross-region backend is AP: during a
   partition both sides of it would elect and own. Do not claim or
   release a lease because of a directory answer.
4. Carry the fence in `Info` when you publish an owner. A fence is
   `{Region, NodeEpoch, Seq}` (`chappe_cluster:fence/1`): the Seq lets a
   receiver refuse an older owner of the key, and the region in it refuses
   a stale owner coming from another region.
5. Pick it with the `directory` env of chappe_cluster:

   ```erlang
   {chappe_cluster, [{region, eu_west}, {directory, my_directory}]}
   ```

   It is read once at start. Callers of `chappe_cluster_directory` do not
   change.

## Tests to add or run

- `directory_local` in `chappe_cluster_SUITE` publishes and resolves a key
  and checks the `badarg` case: copy it for your backend.
- A cross-region backend needs a case with two regions, each its own set
  of `peer` nodes ([add-tests.md](add-tests.md#several-nodes)): publish in
  one, resolve in the other, and a partition that leaves each region's
  leases as they were.

```sh
rebar3 ct --suite apps/chappe_cluster/test/chappe_cluster_SUITE --case directory_local
```

## How to know it works

- `make check` passes.
- With your backend set, `chappe_cluster_directory:resolve/1` on another
  region returns what `publish/3` wrote.
- `make interop-cluster` still passes: the directory changes no lease.

## Notes

- `publish/3` refuses a region that is not an atom or info that is not a
  map with `{error, badarg}` before it reaches the backend.
- In this release nothing in the umbrella calls `publish/3`, and
  `chappe_cluster:home/1` returns this node's region for every key.
  Rehoming a resource between regions is an open question of decision
  0010.

## Related

- [use-the-cluster.md](use-the-cluster.md)
- [add-location-backend.md](add-location-backend.md)
