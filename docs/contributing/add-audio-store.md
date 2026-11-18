# Add an audio store backend

chappe_audio keeps recordings in a [store](../glossary.md#store-and-sweep):
a module that implements `chappe_audio_store`. The app configures it; chappe
ships the file backend, `chappe_audio_store_file`. Use this page when you
keep recordings somewhere else (an object store, a database) or change the
file backend.

## Before you start

- [Decision 0011](../decisions/0011-chappe-audio-leaf.md): why the store is
  a behaviour in a leaf app.
- [apps/chappe_audio/docs/design/overview.md](../../apps/chappe_audio/docs/design/overview.md#the-store).
- The user guide [record.md](../../apps/chappe_audio/docs/guides/record.md)
  and the `storage` keys in
  [configuration.md](../../apps/chappe_audio/docs/configuration.md).
- The contract: the callbacks and moduledoc of
  `apps/chappe_audio/src/chappe_audio_store.erl`.

## Where to look

| Module (under `apps/chappe_audio/src/`) | Role |
|---|---|
| `chappe_audio_store` | the API (`open/2`, `find/1`, `adopt/3`, ...) and the behaviour |
| `chappe_audio_store_file` | the file backend: layout, the two-step rename, the sweep |
| `chappe_audio_store_srv` | the node's store: config, lookups from other nodes, the timed sweep and its `sweep_guard` |
| `chappe_audio_writer` | one writer process per recording, which calls your `open/2`, `write/2`, `close/2`, `abort/1` |

## Steps

1. Write a module with `-behaviour(chappe_audio_store)` and the callbacks:
   `open/2`, `write/2`, `close/2`, `abort/1`, `adopt/3`, `find/2`,
   `get/2`, `read/3`, `delete/2`, `sweep/1`, and the optional `part/1`.
   Each gets the store's config map as its last argument (`open/2`,
   `adopt/3`, `find/2`, ...) or works on the handle `open/2` returned.
2. Never list a recording in progress. The file backend writes the audio
   and its JSON sidecar under `.part` names, then on `close/2` renames the
   audio first and the sidecar last; `find/2` lists sidecars only. Do the
   same in two steps on your store: write the data, then publish the entry
   that makes it findable.
3. Return a `recording()` map from `find/2` and `get/2`, with `id`,
   `call_ref` and `node` (the node whose store answers), and what the
   sidecar holds (parties, source, start, duration_ms, format, bytes).
4. Implement `sweep/1`. It removes what `retention_days` says is old, and
   partial data left by writers that died. The config it gets holds `live`,
   the parts of the writers still running: skip those. Export `part/1`,
   which names a handle's partial data, so the writer can register it as
   live; without it, `live` stays empty for your backend.
5. Configure it on each node by module name:

   ```erlang
   ok = chappe_audio_store:configure(#{backend => my_store, retention_days => 30}).
   ```

   or as the `storage` env of chappe_audio. The store checks that the
   module loads.
6. For a store the nodes share, let one node sweep it: pass a
   `sweep_guard`, a fun or `{M, F, A}` that returns `true` on one node
   only, backed by a chappe_cluster singleton
   ([record.md](../../apps/chappe_audio/docs/guides/record.md#sweep-a-shared-store-from-one-node)).
   chappe_audio does not depend on chappe_cluster; the guard is the app's.

## Tests to add or run

`chappe_audio_store_SUITE` is the contract the file backend passes: copy it
for yours, pointing `configure/1` at your module in `init_per_testcase/2`.

| Case | Covers |
|---|---|
| `layout_and_atomic_write` | not listed until `close/2` |
| `read_ranges_and_delete` | `read/2` byte ranges, `delete/1` |
| `adopt_wav`, `adopt_in_job`, `adopt_other_and_keep` | adoption |
| `retention_and_stale_parts`, `sweep_spares_live_writers` | the sweep |
| `sweep_guard_skips` | the guard says no, yes, or crashes |
| `writer_owner_death`, `writer_crash`, `writer_bound` | the writer process |

```sh
rebar3 ct --suite apps/chappe_audio/test/chappe_audio_store_SUITE
```

## How to know it works

- `make check` passes.
- `chappe_audio_store:find/1` from another node returns the recordings
  your store holds.
- A writer killed mid-recording leaves nothing listed, and a later sweep
  removes its part (the file backend waits until it is an hour old).

## Notes

- `find/1` asks the store of every node through pg; `get/1`, `read/2` and
  `delete/1` ask this node first, then the others. A shared store answers
  the same on every node: `find/1` may then return a recording once per
  node.
- A writer that crashes never touches the call; its owner hears it through
  its monitor.
- Recordings hold personal data: set a retention.

## Related

- [use-the-cluster.md](use-the-cluster.md)
- [add-app.md](add-app.md)
- [add-tests.md](add-tests.md)
