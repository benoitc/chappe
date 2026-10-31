# Design overview

This document describes the architecture of chappe_rtpengine. It is the reference you need when extending the library: it explains why the client is shaped the way it is, how the media session state machine works, and how failures are handled at each level.

## Scope

chappe_rtpengine controls rtpengine media proxies over the NG protocol: one `cookie SP bencoded-dictionary` message per request, over UDP (the default), TCP, or WebSocket (ws/wss). It serves a SIP B2BUA. The split is strict: SIP signalling and SDP interpretation live in the SIP server, and this library knows nothing about dialogs or transactions. The client and the session pass SDP bodies through as opaque binaries; the one opt-in exception is `chappe_rtpengine_sdp`, which reads and builds the media sections of a subscription answer (see below). Pure Erlang, no NIFs, no external services, one dependency (erlang_ws, see below).

## Supervision tree and modules

```
chappe_rtpengine_sup (rest_for_one)
|-- chappe_rtpengine_pool          (node registry, health, selection, pinning)
|-- chappe_rtpengine_dtmf          (DTMF event listener, idle until opened)
|-- chappe_rtpengine_client_sup    (simple_one_for_one)
|   `-- chappe_rtpengine_client    (gen_server, one per rtpengine node)
`-- chappe_rtpengine_session_sup   (simple_one_for_one)
    `-- chappe_rtpengine_session   (gen_statem, one per call)
```

`rest_for_one`: when the pool restarts, the clients and sessions started
after it restart too, so no client runs unknown to the registry.

| Module | Role |
|---|---|
| `chappe_rtpengine` | Public API; required-key checks; translates client exits into `{error, client_down}` |
| `chappe_rtpengine_bencode` | Pure codec; canonical encoding (dict keys in ascending byte order, duplicate keys refused), decoding that tolerates unsorted dicts but rejects non-canonical numbers and nesting deeper than 64, wire types preserved |
| `chappe_rtpengine_stream` | Pure incremental framer for NG over TCP: cookie, then one bencode value, linear in the stream size, 4 MiB and 256-byte cookie caps |
| `chappe_rtpengine_ng` | Command dictionary building, key/value wire mapping, reply classification |
| `chappe_rtpengine_client` | Transport gen_server, one per node: socket, cookies, pending map, retransmits |
| `chappe_rtpengine_client_sup` | Runtime-added clients, transient restarts |
| `chappe_rtpengine_pool` | ETS registry read directly by callers, gen_server serializes writes and health transitions |
| `chappe_rtpengine_session` | Per-call FSM owning call-id, tags, and the pinned node |
| `chappe_rtpengine_sdp` | Opt-in SDP helpers for subscriptions: the offer's m-lines and labels (`streams/1`), and an answer that routes chosen streams to a receiver (`fork_answer/2,3`) |
| `chappe_rtpengine_dtmf` | Listener for rtpengine's `--dtmf-log-dest` JSON datagrams; dispatches digits to subscribers by call-id |
| `chappe_rtpengine_resolve` | Host resolution for the client (IPv4 first, then IPv6), through inet or a resolver fun, in a monitored helper process so the client never blocks on DNS |
| `chappe_rtpengine_ws_handler` | `ws_handler` bridging a WebSocket session to its client; refuses a session that did not grant `ng.rtpengine.com` |

## The client

One process per rtpengine node, one UDP socket per process.

- Socket options: `{active, N}` with re-arm on `udp_passive` for flow control, `sndbuf` and `recbuf` of 256 KiB, and a 64 KiB user `buffer`. Large SDP bodies (ICE candidate lists, several m-lines) exceed default buffers: the kernel refuses datagrams beyond sndbuf (9216 bytes by default on macOS), and gen_udp silently truncates datagrams beyond its buffer.
- Outgoing datagrams are checked against `max_datagram` (default 65507, the IPv4 payload limit) before the send; an oversized request, or one the kernel rejects with `emsgsize`, returns `{error, too_large}` and is not retried.
- NG over TCP is parsed by `chappe_rtpengine_stream`, whose work is linear in the stream size however the bytes are fragmented. A resumable scanner walks each byte once to find where the value ends, keeping across feeds the cookie phase, the open containers, and the token in progress (an integer, a string length, or the string bytes left to skip; string bodies are skipped, not read). The message's bytes stay in the chunks they arrived in, are joined once its end is found, and are decoded once. The scanner also rejects what can never parse as it arrives: a bad type byte, a non-canonical integer or length, a non-string dictionary key, nesting deeper than 64, or a string announcing more than the 4 MiB cap. A list of 4000 small dictionaries fed 4 bytes at a time costs about 0.4M reductions (the earlier framer, which re-parsed the partial value per fragment, cost 736M). A stream that is corrupt or exceeds the caps drops the connection.
- The TCP transport resolves the host on every connect attempt (the WebSocket client resolves the URL host itself); UDP resolves once at start. A name that does not resolve is retried like a refused connection.
- The calling process builds and bencodes the command through `chappe_rtpengine_ng:encode_command/2`; the client only prepends the cookie and sends. This keeps SDP-sized encoding work out of the serialized gen_server. If per-node throughput ever becomes a limit, the next step is a small socket pool per node picked by `erlang:phash2(CallId, N)`, which keeps one call's commands ordered on one socket.
- Cookies are `RandomHex-UniqueInteger`. The random component is a correctness requirement, not a nicety: rtpengine caches replies by cookie for about 30 seconds, and a restarted client reusing cookies would be served stale replies for different commands.
- Pending requests live in a map keyed by cookie, holding the caller, the exact datagram, remaining attempts, and the timer reference. On a timer fire the entry must exist and the timer reference must match, otherwise the message is stale and ignored (a reply can arrive after the timeout message is already queued). Unknown-cookie replies are dropped and counted, never crash.
- Retransmission resends the byte-identical datagram. rtpengine's cookie cache makes duplicates idempotent: a retransmitted request that already succeeded is served the cached reply. Defaults are 1000 ms per attempt and 3 attempts, well under the 30 second cache window.
- Callers use `gen_server:call` with timeout infinity. That is safe because the server always answers within `attempts * timeout`, `terminate/2` answers everything still pending, and a crash reaches the caller as an exit that the facade turns into `{error, client_down}`. A client restart drops in-flight requests by design.
- The ws/wss transports carry NG over rtpengine's HTTP interface (`--listen-http` / `--listen-https`) negotiating the `ng.rtpengine.com` subprotocol. WebSocket preserves message boundaries, so one binary (or text) frame is one complete `cookie SP bencode` message and the TCP stream parser is not involved. Reliability semantics match TCP: deadline timers only, no retransmit, background reconnect. The connection is a `ws_session` process the client monitors; a server that does not grant the subprotocol fails the connect (the check runs in the handler's `init`, inside the session start).
- WebSocket dependency decision: the library takes erlang_ws from hex (`{ws, "~> 0.3.0", {pkg, erlang_ws}}`), the only runtime dependency. It is pure Erlang with nothing beyond OTP's ssl/crypto/public_key, same author and license, and provides the client (`ws:connect/2` with subprotocols and TLS options), the handler behaviour, and a reference server the test fake reuses. gun was rejected because it drags cowlib in and duplicates what erlang_ws already does; livery was rejected because it has no WebSocket client (its WebSocket support is server-side and itself built on erlang_ws) and would pull a full web framework into a leaf library; hand-rolling the handshake and frame codec was rejected as code this library would then own for no gain.

## Data model

Commands are Erlang maps with atom keys; replies are maps with binary keys.

- Key mapping: underscores become hyphens (`call_id` to `call-id`, `via_branch` to `via-branch`), with the irregular NG names explicit: `ice` to `ICE`, `ice_lite` to `ICE-lite`, `dtls` to `DTLS`, `dtls_fingerprint` to `DTLS-fingerprint`, `dtls_reverse` to `DTLS-reverse`, `sdes` to `SDES`, `osrtp` to `OSRTP`, `tos` to `TOS`, `t38` to `T.38`, `record_call` to `record call`, `media_address` to `media address`, `address_family` to `address family`, `received_from` to `received from`. Binary keys pass through, which is the escape hatch for anything unmapped.
- Command names: atoms with underscores where NG uses spaces (`start_recording` to `start recording`, `block_dtmf` to `block DTMF`, `subscribe_request` to `subscribe request`).
- Values: binaries and integers pass through, lists and maps recurse. Atoms under the option-word keys (`flags`, `replace`, `rtcp-mux`, `ICE`, `ICE-lite`, `DTLS`, `DTLS-reverse`, `OSRTP`, `T.38`, `record call`) are NG option words, which the NG documentation writes with hyphens, so they hyphenate (`trust_address` to `trust-address`). Every other atom is sent verbatim, which keeps SDES suite names (`AES_CM_128_HMAC_SHA1_80`), codec names and interface names intact. Floats and tuples raise `{bad_param, Key, Value}` in `chappe_rtpengine_ng:command/2`; the client returns that as `{error, {bad_param, Key, Value}}`. Bencode has no booleans; NG flags are list membership, `flags => [trust_address]`.
- Replies keep their wire types. Some fields flip between integer and string across rtpengine versions, so no coercion happens. Classification looks only at `result`: `ok` and `pong` give `{ok, Reply}`; `error` gives `{error, Reason, Reply}` with a missing `error-reason` tolerated; `load limit` gives `{error, load_limit, Reply}`; anything else gives `{error, {unexpected_result, R}, Reply}`. A `warning` key is logged and stays in the reply map.

## Media session state machine

One rtpengine session spans both B2BUA legs, driven by one `chappe_rtpengine_session` gen_statem:

```
idle -> offering -> offered -> answering -> established
established -> reoffering -> offered' (re-INVITE, hold/resume)
offered' -> established (re-INVITE rejected, reoffer_rejected/1)
any -> deleting -> terminated
```

Design points:

- The FSM never blocks in a state callback. The external API is `gen_statem:call`; the FSM stores the caller, issues the client request asynchronously, and replies when the client's message arrives. The intermediate states exist precisely to await that message, which keeps delete, owner-down, and node-down events live during the retry window.
- The FSM data records which SIP leg owns which tag and who initiated each offer. rtpengine's `from-tag` is always the tag of the party sending the offer, so a callee-initiated re-INVITE swaps the tags. Making this explicit in the data avoids the classic re-INVITE direction bug.
- Repeated answers are allowed: a 183 with SDP produces an answer before the 200 does, and forked branches answer with distinct to-tags. Branches are tracked in the FSM data; when the final answer settles, losing branches get a best-effort delete with their to-tag.
- Glare: an offer while an offer/answer exchange is open (`offering`, `offered`, `answering`, `reoffering`, `publishing`) returns `{error, glare}` immediately. SIP owns glare resolution (491 and offset retry timers); the FSM must not queue competing offers.
- A rejected re-INVITE rolls back with `reoffer_rejected/1` (from `offered` after a re-offer only). A failed answer restores the to-tag the session had before it, so a failed re-answer never loses an established call's tag.
- Cleanup: the FSM monitors its owner. Owner death or an explicit stop moves to `deleting`, sends delete with retries, and terminates whatever the outcome. A reply for a request still in flight that lands in `deleting` answers its caller with `{error, stopped}` and leaves the FSM in `deleting`; callers still pending when the delete completes get the same answer.
- Callback mode is `handle_event_function`: most events are handled alike across states, and a reply's meaning depends on the state it arrives in.

### State x reply

`handle_event/4` is long (plan finding M10) because what a client reply
means depends on the request it answers and the state it lands in. Each
request in flight is kept in `pending` by reference with its kind; the
reply goes through `handle_reply/5` and then `reply/5`. Read it as a table:

| Request, state | `{ok, Reply}` | error |
|---|---|---|
| offer, `offering` | `offered` | `idle` |
| re-offer, `reoffering` | `offered` (re-offer flagged) | `established` |
| publish, `publishing` | `established` | `idle` |
| answer, `answering` | settle the branch, `established` | `offered`, previous to-tag restored |
| answer, `established` (a later branch) | settle the branch | no change |
| query or auxiliary command | answer the caller, no change | the same |
| any, `deleting` | the caller gets `{error, stopped}` | the same |

Before that, any reply in an active state that says "unknown call-id" tells
the owner `{node_restarted, Node}`, once (`note_media_lost/4`).

The auxiliary commands (`play_media/2`, `silence_media/2`,
`subscribe_request/2`, ...) are thin wrappers that inject the call-id, the
tags and the pinned node, then go through the same reply path.

### SDP helpers

`chappe_rtpengine_sdp` exists because rtpengine has no request-side selector
for one media stream of a subscription. The offer describes every stream of
the tapped participants in m-line order, with each stream's `a=label`; the
consumer's answer decides which ones it receives (a port routes the stream,
port 0 rejects it). `fork_answer/2,3` builds that aligned answer. Callers
that write their own SDP can ignore the module.

## Node pool

### Concurrency model

The pool is read far more often than it is written: every command looks up
its node, every session start selects one. So reads never go through the
pool process.

- `chappe_rtpengine_pool_nodes` (protected, `read_concurrency`) holds one
  `{Name, Status, Generation}` row per node. Only the pool gen_server
  writes it. `select/0`, `list_nodes/0`, `node_info/1` and `is_managed/1`
  read it in the calling process.
- `chappe_rtpengine_pool_counters` (public, `write_concurrency`) holds
  `{Name, InFlight, Pinned}`. The calling process bumps it with
  `ets:update_counter/3`: the facade around each command
  (`track_start/1`, `track_end/1`), and `pin/1`, `pin_to/2`, `unpin/1`.
- `chappe_rtpengine_pool_pins` (public) maps a call-id to
  `{Node, Generation}`, written by the session that pins.
- The gen_server serializes the rest: `add_node/2`, `remove_node/1`, health
  pings, the `report/2` casts the facade sends after each command (`ok` or
  `timeout`), up and down transitions, and notices to subscribers.

A reader can see a node a moment before or after a transition. That is
accepted: a command sent to a node just marked down times out like any
other and feeds the same health count.

### Selection and pinning

`select/0` takes the up node with the least in-flight requests plus pinned
calls. The NG `statistics` command reports session totals but is
seconds-stale, so it serves periodic sanity checks, not per-call selection.
A session pins its call to the node at start (`pin/1`, or `pin_to/2` when
you name the node) and every later command of that call goes there, because
rtpengine keeps the call's state on one node.

### Health

A periodic ping per node (`health_interval`, 5000 ms) plus the facade's
reports. `down_after` (2) consecutive failures mark a node down: it is left
out of selection and subscribers get `{node_down, Name}`. A successful ping
or command brings it back up.

Each `add_node/2` gives the node a fresh incarnation, separate from the
generation below. The health timer message and every ping result carry it,
and `remove_node/1` cancels the timer. A timer or ping result whose
incarnation is not the current node's is dropped, so when you remove a name
and add it again, one timer chain runs and a ping started for the old node
never counts against the new one.

### Generation counter

rtpengine loses all sessions on restart, and a health ping cannot tell.
Each node carries a generation counter bumped on every down-to-up
transition; sessions record the generation they were pinned under. On
recovery, subscribers get `{node_up, Name, Generation}` and sessions holding
an older generation tell their owner `{node_restarted, Node}`. An "Unknown
call-ID" error on an established session triggers the same notice. The
owner decides between re-offer elsewhere and teardown; the library never
re-offers on its own, because a new offer needs SDP that only signalling
can produce.

## DTMF listener

rtpengine reports detected digits as one JSON datagram per event to
`--dtmf-log-dest`. `chappe_rtpengine_dtmf` owns that socket (opened by the
`dtmf_listen` app env or `open/1,2`), drops datagrams from sources not in
`allowed_sources`, and sends `{chappe_rtpengine_dtmf, CallId, Event}` to the
processes subscribed to that call-id. A session started with `dtmf => true`
subscribes itself and forwards the digits to its owner. See
[Configuration](../configuration.md).

## Failure summary

| Level | Failure | Behavior |
|---|---|---|
| Request | No reply within an attempt | Retransmit identical datagram, same cookie |
| Request | All attempts exhausted | `{error, timeout}` to the caller |
| Request | Malformed reply | `{error, {bad_reply, Bin}}` to the caller |
| Request | UDP datagram over `max_datagram` or refused as too big | `{error, too_large}`, not sent |
| Request | Float or tuple parameter | `{error, {bad_param, Key, Value}}`, not sent |
| Request | Node shedding load | `{error, load_limit, Reply}` |
| Client | Corrupt or oversized TCP stream | Connection dropped, pending requests get `{error, closed}`, reconnect |
| Request | rtpengine error | `{error, Reason, Reply}` |
| Client | Process not running | `{error, client_down}` from the facade |
| Client | Crash | Supervisor restarts it; in-flight requests are lost |
| Node | Consecutive timeouts | Marked down, excluded from selection, ping recovery |
| Node | Restart while pinned | Generation mismatch notifies affected sessions |
| Session | Owner death | Best-effort delete, then terminate |
| Session | Stop or owner death with a request in flight | That caller gets `{error, stopped}`; delete proceeds |

## Why it takes no SIP dependency

chappe_rtpengine is a leaf app: it depends on nothing else in the umbrella
and is published on its own. The rule and its reasons are recorded in
[decision 0003](../../../../docs/decisions/0003-leaf-apps.md).

## Where it lives

- Code: `apps/chappe_rtpengine/src/`
- Tests: eunit for `bencode`, `ng`, `stream`, `sdp`; suites
  `chappe_rtpengine_client_SUITE`, `_pool_SUITE`, `_session_SUITE`,
  `_dtmf_SUITE` against an in-process fake
  (`chappe_rtpengine_fake_server`)
- Lab: `make interop` (`chappe_rtpengine_e2e_SUITE`, `_live_SUITE` and
  `_siprec_SUITE` against rtpengine in docker,
  `apps/chappe_rtpengine/interop/`)
