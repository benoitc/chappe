# Add a location backend

The registrar keeps its rules in `chappe_sip_registry` and the bindings of
each AOR in a [location backend](../glossary.md#location-backend), a module
that implements `chappe_sip_location`. Two ship: `chappe_sip_location_ets`
(one node) and `chappe_sip_location_cluster` (the region's KV). Use this
page when you add a third one (a database, another shared store) or change
one of the two.

## Before you start

- [Decision 0015](../decisions/0015-location-behaviour.md): why the
  bindings sit behind a behaviour, and how far one region goes.
- [apps/chappe_sip/docs/design/registrar.md](../../apps/chappe_sip/docs/design/registrar.md),
  sections [The location behaviour](../../apps/chappe_sip/docs/design/registrar.md#the-location-behaviour)
  and [CAS writes and the read-retry](../../apps/chappe_sip/docs/design/registrar.md#cas-writes-and-the-read-retry).
- The contract: the callbacks and moduledoc of
  `apps/chappe_sip/src/conn/chappe_sip_location.erl`.

## Where to look

| Module (under `apps/chappe_sip/`) | Role |
|---|---|
| `src/conn/chappe_sip_location.erl` | the behaviour, and `backend/0`, which picks the module |
| `src/conn/chappe_sip_location_ets.erl` | the one-node backend, `serialized` |
| `src/conn/chappe_sip_location_cluster.erl` | the cluster backend, `cas` |
| `src/conn/chappe_sip_registry.erl` | the registrar: `register_request/2` and its read-retry |
| `src/conn/chappe_sip_registry_store.erl` | `modify/3`, the index of held AORs and flows |
| `test/chappe_sip_location_lagging.erl` | a test backend whose local reads lag the region |

## Steps

1. Write a module with `-behaviour(chappe_sip_location)` and the
   callbacks: `read/2`, `write/3`, `aors/0`, `clear/0`, `write_mode/0`,
   `start/0`, `stop/0`, `periodic/2`, `held/4`, `mine/0`, `view/2`,
   `edge/1`. Bindings are `#binding{}` records
   (`src/conn/chappe_sip_location.hrl`).
2. Choose `write_mode/0`:
   - `serialized`: every write goes through the registry process, one at a
     time. Return version 0 from `read/2` and ignore it in `write/3`, as
     the ETS backend does. Only right when one node writes the store.
   - `cas`: the request worker writes. `read/2` returns the version it
     read; `write/3` replaces the bindings only if the AOR is still at that
     version, and returns `{error, conflict}` otherwise. Version 0 means no
     AOR; writing `[]` removes it.
3. Honour the read modes. `read(Aor, local)` may be stale and must answer
   without a quorum; `read(Aor, consistent)` returns the latest value the
   store holds. The registrar reads `local` first, and after a `conflict`
   backs off and reads `consistent` (`cas_register/5` in
   `chappe_sip_registry`), at most `chappe_sip_registry_store:tries/0`
   times. A backend whose `consistent` read is no fresher than its `local`
   one turns every race into a 500.
4. Map your store's errors to the four the registrar knows:
   `no_quorum` (503 with Retry-After), `too_large`, `full`, `conflict`.
5. Fill in the rest:
   - `periodic/2` runs every `registrar_sweep_ms` in the registry process:
     sweep there (ETS), or start a helper and return its monitor reference
     (cluster).
   - `start/0`, `stop/0`: what lives with the registry, such as the
     cluster backend's sweep singleton.
   - `held/4`, `mine/0`: the index of the AORs this node holds bindings
     of. A one-node store can keep none.
   - `view/2`, `edge/1`: how a binding looks from this node, and what is
     stored with a new one. On a shared store, a binding another node took
     needs the edge route to that node (`chappe_sip_location_cluster`).
6. Pick the module in `chappe_sip_location:backend/0`. No setting names a
   backend module today: `backend/0` reads the `cluster` setting, which
   `chappe_sip_config:check_cluster/0` accepts as `none` or
   `chappe_cluster` only, and which also drives `probe => singleton` peers.
   A new backend needs its own clause there, the setting that selects it,
   and a row in `apps/chappe_sip/docs/configuration.md`.

## Tests to add or run

| Test | Covers |
|---|---|
| `chappe_sip_registry_lag_tests` | a `conflict` on a stale replica is retried with a `consistent` read, on `chappe_sip_location_lagging` |
| `chappe_sip_registrar_SUITE` | the registrar's rules, on the ETS backend |
| `chappe_sip_registrar_cluster_SUITE` | three nodes: calls through the edge, 430 on a dead flow, the sweep and the index |

Copy `chappe_sip_location_lagging` to drive your backend's version and
conflict paths without a live store, and run the registrar suites on it.

```sh
rebar3 eunit --module chappe_sip_registry_lag_tests
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_registrar_SUITE
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_registrar_cluster_SUITE
```

## How to know it works

- `make check` passes.
- Two REGISTERs for one AOR on two nodes at once keep both bindings.
- With the store unreachable, a REGISTER gets 503 and calls to devices
  already registered still route.
- `make demo-cluster-smoke` passes for a cluster backend.

## Notes

- `read/2` returns expired bindings too; the registry filters them.
- A value on a shared store may be read by a node of a later release:
  the cluster backend stores bindings as maps for that reason.
- `chappe_sip_location` also exports wrappers the registry calls,
  `periodic/3` and `held/5`, which take the backend module first; the
  callbacks you implement are `periodic/2` and `held/4`.

## Related

- [use-the-cluster.md](use-the-cluster.md)
- [add-sip-feature.md](add-sip-feature.md)
- [debug-a-call.md: Across nodes](debug-a-call.md#across-nodes)
