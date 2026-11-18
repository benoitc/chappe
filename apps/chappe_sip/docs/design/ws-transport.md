# The WebSocket transport

SIP over WebSocket (RFC 7118) does not go through sofia-sip. It has its own
transport and transaction layer, written in Erlang, that speaks the same
event contract as the NIF so every dialog, UAC, proxy and registrar runs over
it unchanged. This page explains why that layer exists, how it mirrors nta,
and what must change in both places when one of them changes. Read it before
you touch `src/ws/` or the engine's handle dispatch. To use WebSocket, read
the [WebSocket guide](../guides/websocket.md).

## Why a second transaction layer

The WebSocket listener is a livery HTTP service in the VM: livery upgrades
`GET /ws` and hands frames to an Erlang process. The SIP messages on those
connections have to reach the same transaction users as UDP, TCP and TLS
traffic, so something must play nta's role for them: match retransmissions,
run the RFC 3261 timers, match responses to client transactions, and match
in-dialog requests to legs. Doing that in Erlang keeps the C surface small.
The reasoning and its cost are recorded in
[decision 0007](../../../../docs/decisions/0007-ws-transaction-layer.md).

## Shape

```
 browser --ws--> livery --> chappe_sip_ws_conn (one per connection)
                                 |  incoming/2, frames out
                                 v
                    chappe_sip_ws_transport (one gen_server)
                                 |  {chappe_sip_engine, ws, Event}
                                 v
                         chappe_sip_engine  <-- ops on WS handles
```

| Module | Role |
|---|---|
| `chappe_sip_ws_listener` | The livery service; started on demand when `ws` or `wss` is configured. |
| `chappe_sip_ws_conn` | The ws handler of one connection: frames in and out, keepalive pings, the size cap. |
| `chappe_sip_ws_transport` | The transaction layer's gen_server: its state, the message handling, inbound routing and the server transactions. |
| `chappe_sip_ws_txn` | The transaction, leg and ACK-wait tables, their indexes and timers, and the two outputs: a message on a flow, an event to the engine. |
| `chappe_sip_ws_ctxn` | The client transactions: originate, responses, Timer B/F and C, CANCEL and the ACK of a non-2xx final. |
| `chappe_sip_ws_msg` | The pure message code: Via and branch, the response, CANCEL and ACK builders, the Content-Length and RAck checks, the frame type. |
| `chappe_sip_ws` | The WS handle range (`base/0`). |
| `chappe_sip_ws_sup` | Supervises the transport and the listener. |
| `chappe_sip_hep` | HEP capture of WS traffic (sofia captures the native transports). |

## How it mirrors nta

- **Same events.** The transport delivers
  `{chappe_sip_engine, ws, Event}` with the event shapes of the NIF
  (`request`, `response`, `ack`, `ack_timeout`, `cancel`, `op_ok`,
  `op_failed`), so `chappe_sip_engine:handle_event` treats both alike. The
  contract is in the header of `src/engine/chappe_sip_nif.erl` and in
  [the engine design](engine.md#the-event-contract).
- **Same operations.** `chappe_sip_engine` sends an operation to the NIF or
  to the transport by handle: WS handles start at `16#4000000000000000`
  (`chappe_sip_ws:is_ws/1`, `chappe_sip_ws:base/0`). The transport exports
  `respond/6`, `reliable_respond/6`, `relay/3`, `leg_create/4`,
  `leg_destroy/1`, `finish_txn/1`, `send_request/3`, `send_stateless/2` and
  `cancel/1,2`, one for each NIF op the engine forwards.
- **Same matching.** Server transactions match by `{Flow, Branch, Method}`
  (RFC 3261 17.2.3), client transactions by our branch, and dialog legs by
  Call-ID and tags, for every method (nta needs a special lookup for
  SUBSCRIBE; the transport does not).
- **Reliable-transport timers.** WS is reliable (RFC 7118 5): no
  retransmissions, Timers I, J and K are zero, and only the timeouts remain:
  Timer B/F (`ws_client_txn_timeout_ms`), Timer C (`ws_timer_c_ms`), Timer H
  (`ws_ack_timeout_ms`), the unanswered-request reaper
  (`ws_server_txn_timeout_ms`), and the repeated provisional of a ringing
  INVITE (`ws_progress_ms`, RFC 3261 13.3.1.1, as nta's `sa_progress`).
- **nta behaviours copied.** A CANCEL of a proceeding INVITE answers it 487;
  a non-2xx final to an INVITE is ACKed with the INVITE's branch; a CANCEL
  waits for a provisional; a 2xx never ACKed is reported as `ack_timeout` so
  the dialog BYEs; reliable provisionals carry RSeq and match their PRACK.

## What must stay in step

When you change one of these on one side, change the other, and run both
`chappe_sip_websocket_SUITE`/`chappe_sip_ws_conf_SUITE` and the native
suites:

- the event shapes and their meta keys (`chappe_sip_nif` header,
  `chappe_sip_ws_txn:engine_event/1`);
- a new NIF op the engine forwards: add the WS function and the dispatch in
  `chappe_sip_engine` (`ws_call/1` wraps every call so a slow or restarting
  transport cannot crash the engine);
- an nta setting that changes behaviour (`NTATAG_CANCEL_487`, UA mode on
  proxy branches, the merge check): the transport must do the same;
- flow semantics: a closed connection ends the bindings and dialogs bound to
  it (`flow_lost`), as `flow_closed` does for TCP/TLS;
- the timers in `chappe_sip_config`.

## Lifetime

The transport survives an engine restart: it tolerates a briefly absent
engine. If the transport itself restarts, its connections close, their
bindings are dropped, and browsers reconnect and register again. Inbound
frames are dropped while its mailbox is deeper than
`ws_transport_max_mailbox`. It is one gen_server process; its code is
split across the four modules above, which share its `#state{}` through
`src/ws/chappe_sip_ws_transport.hrl` (finding M4 in the
[documentation plan](../../../../docs/plans/documentation-and-maintainability.md)).

## Tests

`chappe_sip_websocket_SUITE` (registration, calls, flows),
`chappe_sip_ws_conf_SUITE` (transaction rules), `chappe_sip_webrtc_gateway_SUITE`
(WS to UDP, proxy and B2BUA), and the JsSIP interop track
(`chappe_sip_interop_SUITE`, `make interop`).
