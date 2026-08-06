# Design overview

This document describes the architecture of chappe_rtpengine. It is the reference you need when extending the library: it explains why the client is shaped the way it is, how the media session state machine works, and how failures are handled at each level.

## Scope

chappe_rtpengine controls rtpengine media proxies over the NG protocol (UDP datagram: `cookie SP bencoded-dictionary`). It serves a SIP B2BUA. The split is strict: SIP signalling and SDP interpretation live in the SIP server; this library treats SDP bodies as opaque binaries and knows nothing about dialogs or transactions. Pure Erlang, no NIFs, no external services, one dependency (erlang_ws, see below).

## Supervision tree and modules

```
chappe_rtpengine_sup (rest_for_one)
|-- chappe_rtpengine_pool          (node registry, health, selection, pinning)
|-- chappe_rtpengine_client_sup    (simple_one_for_one)
|   `-- chappe_rtpengine_client    (gen_server, one per rtpengine node)
`-- chappe_rtpengine_session_sup   (simple_one_for_one)
    `-- chappe_rtpengine_session   (gen_statem, one per call)
```

| Module | Role |
|---|---|
| `chappe_rtpengine` | Public API; required-key checks; translates client exits into `{error, client_down}` |
| `chappe_rtpengine_bencode` | Pure codec; canonical encoding (dict keys in ascending byte order), tolerant decoding, wire types preserved |
| `chappe_rtpengine_ng` | Command dictionary building, key/value wire mapping, reply classification |
| `chappe_rtpengine_client` | Transport gen_server, one per node: socket, cookies, pending map, retransmits |
| `chappe_rtpengine_client_sup` | Runtime-added clients, transient restarts |
| `chappe_rtpengine_pool` | ETS registry read directly by callers, gen_server serializes writes and health transitions |
| `chappe_rtpengine_session` | Per-call FSM owning call-id, tags, and the pinned node |

## The client

One process per rtpengine node, one UDP socket per process.

- Socket options: `{active, N}` with re-arm on `udp_passive` for flow control, and explicit `recbuf`/`buffer` of 64 KiB. Large SDP bodies (ICE candidate lists, several m-lines) exceed default buffers, and gen_udp silently truncates datagrams beyond recbuf.
- The calling process builds and bencodes the command through `chappe_rtpengine_ng:encode_command/2`; the client only prepends the cookie and sends. This keeps SDP-sized encoding work out of the serialized gen_server. If per-node throughput ever becomes a limit, the next step is a small socket pool per node picked by `erlang:phash2(CallId, N)`, which keeps one call's commands ordered on one socket.
- Cookies are `RandomHex-UniqueInteger`. The random component is a correctness requirement, not a nicety: rtpengine caches replies by cookie for about 30 seconds, and a restarted client reusing cookies would be served stale replies for different commands.
- Pending requests live in a map keyed by cookie, holding the caller, the exact datagram, remaining attempts, and the timer reference. On a timer fire the entry must exist and the timer reference must match, otherwise the message is stale and ignored (a reply can arrive after the timeout message is already queued). Unknown-cookie replies are dropped and counted, never crash.
- Retransmission resends the byte-identical datagram. rtpengine's cookie cache makes duplicates idempotent: a retransmitted request that already succeeded is served the cached reply. Defaults are 1000 ms per attempt and 3 attempts, well under the 30 second cache window.
- Callers use `gen_server:call` with timeout infinity. That is safe because the server always answers within `attempts * timeout`, `terminate/2` answers everything still pending, and a crash reaches the caller as an exit that the facade turns into `{error, client_down}`. A client restart drops in-flight requests by design.
- The ws/wss transports carry NG over rtpengine's HTTP interface (`--listen-http` / `--listen-https`) negotiating the `ng.rtpengine.com` subprotocol. WebSocket preserves message boundaries, so one binary frame is one complete `cookie SP bencode` message and the TCP stream parser is not involved. Reliability semantics match TCP: deadline timers only, no retransmit, background reconnect. The connection is a `ws_session` process the client monitors; a server that does not grant the subprotocol fails the connect (the check runs in the handler's `init`, inside the session start).
- WebSocket dependency decision: the library takes erlang_ws from hex (`{ws, "~> 0.3.0", {pkg, erlang_ws}}`), the only runtime dependency. It is pure Erlang with nothing beyond OTP's ssl/crypto/public_key, same author and license, and provides the client (`ws:connect/2` with subprotocols and TLS options), the handler behaviour, and a reference server the test fake reuses. gun was rejected because it drags cowlib in and duplicates what erlang_ws already does; livery was rejected because it has no WebSocket client (its WebSocket support is server-side and itself built on erlang_ws) and would pull a full web framework into a leaf library; hand-rolling the handshake and frame codec was rejected as code this library would then own for no gain.

## Data model

Commands are Erlang maps with atom keys; replies are maps with binary keys.

- Key mapping: underscores become hyphens (`call_id` to `call-id`, `via_branch` to `via-branch`), with irregular NG casings explicit: `ice` to `ICE`, `dtls` to `DTLS`, `sdes` to `SDES`, `osrtp` to `OSRTP`, `record_call` to `record call`. Binary keys pass through, which is the escape hatch for anything unmapped.
- Command names: atoms with underscores where NG uses spaces (`start_recording` to `start recording`, `block_dtmf` to `block DTMF`, `subscribe_request` to `subscribe request`).
- Values: binaries and integers pass through, atoms hyphenate (`trust_address` to `trust-address`), lists and maps recurse. Bencode has no booleans; NG flags are list membership, `flags => [trust_address]`.
- Replies keep their wire types. Some fields flip between integer and string across rtpengine versions, so no coercion happens. Classification looks only at `result`: `ok` and `pong` give `{ok, Reply}`; `error` gives `{error, Reason, Reply}` with a missing `error-reason` tolerated; a `warning` key is logged.

## Media session state machine

One rtpengine session spans both B2BUA legs, driven by one `chappe_rtpengine_session` gen_statem:

```
idle -> offering -> offered -> answering -> established
established -> reoffering -> offered' (re-INVITE, hold/resume)
any -> deleting -> terminated
```

Design points:

- The FSM never blocks in a state callback. The external API is `gen_statem:call`; the FSM stores the caller, issues the client request asynchronously, and replies when the client's message arrives. The intermediate states exist precisely to await that message, which keeps delete, owner-down, and node-down events live during the retry window.
- The FSM data records which SIP leg owns which tag and who initiated each offer. rtpengine's `from-tag` is always the tag of the party sending the offer, so a callee-initiated re-INVITE swaps the tags. Making this explicit in the data avoids the classic re-INVITE direction bug.
- Repeated answers are allowed: a 183 with SDP produces an answer before the 200 does, and forked branches answer with distinct to-tags. Branches are tracked in the FSM data; when the final answer settles, losing branches get a best-effort delete with their to-tag.
- Glare: a modify request while a reoffer is in flight returns `{error, glare}` immediately. SIP owns glare resolution (491 and offset retry timers); the FSM must not queue competing offers.
- Cleanup: the FSM monitors its owner. Owner death or an explicit stop moves to `deleting`, sends delete with retries, and terminates whatever the outcome.

## Node pool

- ETS registry with `read_concurrency`, read directly by callers; the pool gen_server only serializes writes and health transitions. In-flight and pinned-session counters via `ets:update_counter` are the primary load metric. The NG `statistics` command reports session totals but is seconds-stale, so it serves periodic sanity checks, not per-call selection.
- Health: K consecutive timeouts mark a node down; a periodic ping recovers it.
- Node restart detection: rtpengine loses all sessions on restart, and a health ping cannot tell. Each node carries a generation counter bumped on every down-to-up transition; sessions record the generation they were pinned under. On recovery, sessions holding an older generation are told the node restarted, and an "Unknown call-ID" error on an established session triggers the same notification. The owner decides between re-offer elsewhere and teardown; the library never re-offers on its own, because a new offer needs SDP that only signalling can produce.

## Failure summary

| Level | Failure | Behavior |
|---|---|---|
| Request | No reply within an attempt | Retransmit identical datagram, same cookie |
| Request | All attempts exhausted | `{error, timeout}` to the caller |
| Request | Malformed reply | `{error, {bad_reply, Bin}}` to the caller |
| Request | rtpengine error | `{error, Reason, Reply}` |
| Client | Process not running | `{error, client_down}` from the facade |
| Client | Crash | Supervisor restarts it; in-flight requests are lost |
| Node | Consecutive timeouts | Marked down, excluded from selection, ping recovery |
| Node | Restart while pinned | Generation mismatch notifies affected sessions |
| Session | Owner death | Best-effort delete, then terminate |
