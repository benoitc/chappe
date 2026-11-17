# 0007: WebSocket has its own Erlang transaction layer

This record explains why SIP over WebSocket does not go through sofia-sip,
and runs a second transaction layer written in Erlang. Read it before you
change transaction behaviour (timers, CANCEL, PRACK, ACK matching), because
the change usually has to be made in both layers.

## Status

Accepted (the maintainer's decision, 2026-11-17).

## Context

What the repository shows:

- `chappe_sip_ws_transport` terminates RFC 7118 connections and "gives them
  the same engine event contract the sofia NIF uses, so all TU logic runs
  over WS unchanged" (moduledoc of
  `apps/chappe_sip/src/ws/chappe_sip_ws_transport.erl`). It matches server
  transactions by flow, branch and method, client transactions by branch,
  and dialog legs by Call-ID and tags.
- WS handles are allocated in their own range, and `chappe_sip_engine`
  sends each operation to the NIF or to the WS transport by handle
  (`chappe_sip_ws:base/0`, the `?IS_WS` guard).
- The WS listener is served by livery, started only when a WS listener is
  configured (`apps/chappe_sip/src/chappe_sip.app.src`,
  `chappe_sip_ws_sup`).
- `apps/chappe_sip/docs/history/plan.md`, M14 and M15, records the layer
  being built; it states no reason for not using sofia's own WS transport.
- sofia is now built without `nth`, the only switch for its `ws`, `wss`
  and HTTP CONNECT transports, so none of them is linked
  (`apps/chappe_sip/c_src/build.sh`, the `--disable-nth` comment), and a
  contact naming `ws`, `wss` or `*` is refused with `badarg`
  (`apps/chappe_sip/src/engine/chappe_sip_bind_uri.erl`). See
  [0016](0016-security-defaults.md).
- WS has its own timer settings, "no sofia timers over WS"
  ([configuration guide](../../apps/chappe_sip/docs/guides/configuration.md),
  `ws_client_txn_timeout_ms`, `ws_timer_c_ms`).

## Decision

WebSocket connections are terminated in Erlang (livery), and their
transactions are run by `chappe_sip_ws_transport`, which mirrors nta's
behaviour for a reliable transport and emits the same events.

## Consequences

- Everything above the transaction layer (dialogs, B2BUA, proxy, registrar)
  works over WS without knowing it.
- Two transaction layers must stay in step: a fix to CANCEL, PRACK, Timer C
  or ACK handling in one usually needs the same fix in the other. The
  conformance lab covers nta; `chappe_sip_websocket_SUITE`,
  `chappe_sip_ws_conf_SUITE` and the JsSIP lab cover WS.
- The guard's `drop` blocks a source before it costs a transaction over UDP,
  TCP and TLS, but over WS each request reaches the guard
  (`chappe_sip_guard` moduledoc).
- `chappe_sip_ws_transport` is a large single gen_server (finding M4 in
  `docs/plans/documentation-and-maintainability.md`).

## Open questions

- Why the layer was first written in Erlang rather than on sofia's WS
  transport: neither `history/plan.md` nor the code says. Today's build no
  longer links that transport, which settles where WS runs, not why.
