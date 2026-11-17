# 0015: Registrar bindings sit behind a location behaviour; cross-node calls go through the edge node

This record explains where the registrar keeps its bindings, why a call to
a device registered on another node goes through that node, and how far one
region's store goes. Read it before you add a location backend, change how a
binding is routed from another node, or size a registrar cluster.

## Status

Accepted (the maintainer's decision, 2026-11-17).

## Context

What the repository shows:

- `chappe_sip_registry` holds the registrar's rules; a backend that
  implements `chappe_sip_location` holds the bindings of each AOR
  (`apps/chappe_sip/src/conn/chappe_sip_location.erl`). Its callbacks:
  `read/2`, `write/3`, `aors/0`, `clear/0`, `write_mode/0`, `start/0`,
  `stop/0`, `periodic/2`, `held/4`, `mine/0`, `view/2`, `edge/1`.
- `chappe_sip_location:backend/0` picks it from the `cluster` setting:
  `chappe_sip_location_ets` by default, a node-local table bounded by
  `registrar_max_aors` (100,000, `chappe_sip_config`), written by the
  registry process only; `chappe_sip_location_cluster` with
  `cluster => chappe_cluster`, one KV value per AOR under
  `chappe_sip/aor/<AOR>`, written with compare-and-swap, read from the local
  replica.
- On a cluster, each binding records the node that took it and, when the
  contact is reached over that node's flow (an RFC 5626 flow, a WS
  connection, a UDP source behind a NAT), an edge route to it
  (`chappe_sip_location_cluster:edge/1`, `chappe_sip_flow:edge_route/4`).
  The route carries a MAC under the node's secret and expires with the
  binding (`chappe_sip_flow` moduledoc).
- Seen from another node, such a binding has no flow and its edge route
  ahead of its path. When the holding node is gone, a UDP binding is
  reached at its address, and a TCP, TLS or WS one is left out until the UA
  registers again (`view/2` in `chappe_sip_location_cluster`, moduledoc of
  `chappe_sip_registry`).
- When the flow an edge route names no longer exists, the proxy answers
  430 Flow Failed and removes the bindings on that flow
  (`chappe_sip_proxy_dialog`, `forward_failed/3` and `relay_indialog/1`,
  RFC 5626 5.3).
- Without a quorum within `registrar_cluster_timeout_ms` (1000) a REGISTER
  fails with 503 and Retry-After (`chappe_sip_registry` moduledoc). A new
  AOR past the KV's `max_keys` is refused `full`, a value past
  `max_value_bytes` (65536) `too_large`
  (`apps/chappe_cluster/src/chappe_cluster_config.erl`,
  `chappe_sip_location_cluster`).

## Decision

- The registrar never names a backend: it calls `chappe_sip_location`, and
  the backend says how it is written (`serialized` or `cas`), swept and
  shown.
- A device's connection lives on one node. A call to it from another node
  goes through that node, by the edge route stored with the binding; no
  node uses another node's connection directly.
- On a cluster, bindings stay in the region's KV
  ([0010](0010-cluster-ownership.md), the answered question). The limit is
  `max_keys` AORs (100,000 by default) and the write rate of one Ra group.
  A deployment above that splits into regions.

## Consequences

- A device that registers to one node can be called from any node of the
  region.
- When the node a TCP, TLS or WS device is connected to stops, the device
  cannot be reached until it registers again.
- When the region has no quorum, new registrations fail with 503; calls to
  devices already registered keep working from the local replica.
- To size a region, count AORs against `max_keys` and REGISTER writes
  against one Ra group. A larger deployment runs several regions.

## Open questions

- The write rate one Ra group sustains for REGISTER traffic is not
  measured in the repository.
