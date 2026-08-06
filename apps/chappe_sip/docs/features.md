# Features

What chappe_sip does today, and what is planned. This is the feature
tracker; the milestone history is in `docs/plan.md`.

## Working

### Transport and engine
- Embedded SIP engine (sofia-sip nta) started and supervised by the
  Erlang application, over a plain-C NIF. No external signaling daemon.
- UDP and TCP contacts, plus an optional TLS listener on its own port
  (`tls => #{contact, cert_dir, verify}` in `chappe_sip:start/1`; see
  `docs/design/engine.md`).
- SIP-over-WebSocket (RFC 7118) via livery (`ws => #{port}` in
  `chappe_sip:start/1`): an Erlang WS transport bridges frames to the shared
  transaction-user logic, so UAS/registrar/etc. work over WS. The engine
  multiplexes each operation to the sofia NIF or the WS transport by
  handle. The `sip` subprotocol is negotiated, the idle timeout is
  disabled (long-lived registrations), and the client peer is stamped into
  Via `received`/`rport`. livery starts lazily, only when a WS listener is
  configured.
- WebRTC gateway: bridge a browser (WS) and a UDP/TCP peer in both
  directions, as a proxy (`chappe_sip:proxy_request` to a `{ws, Flow}` target,
  Record-Route with a flow token so in-dialog ACK/BYE/re-INVITE traverse) or
  a B2BUA (`chappe_sip:create_b2bua` with a `flow` opt). Resolve a registered
  browser with `chappe_sip:location_flow/1`. A real JsSIP-to-JsSIP WebRTC call
  completes through the b2bua over WS (verified in the interop track). Limits:
  a WS-to-WS proxied dialog (two WS legs) needs two flow tokens; the token is
  trusted-gateway scoped.
- Dialog-forming 2xx responses carry a Contact (RFC 3261 12.1.1), and a
  UAC-built request over WS (e.g. a 2xx ACK) gets a Via from the transport, so
  strict clients (JsSIP) build the dialog and accept in-dialog requests.
- Controlled engine restart (`chappe_sip_engine:restart_engine/0`): tears live
  dialogs down with `engine_restart`, keeps routes, restarts the NIF.
- Health check that round-trips through the sofia event loop, with a
  halt-the-node hang policy.

### Application API (srf-style)
- Request handlers by method: `chappe_sip:invite/1`, `chappe_sip:register/1`,
  `chappe_sip:options/1`, and so on; connect-style middleware with `chappe_sip:use/1,2`.
- `chappe_sip:create_uas/3`: answer an incoming dialog-forming request.
- `chappe_sip:create_uac/2` and `chappe_sip:request/2`: originate INVITE and
  out-of-dialog requests, with provisional delivery, digest 401/407
  retry, 3xx redirects, and 3PCC (`no_ack`).
- `chappe_sip:create_b2bua/4`: bridge an incoming INVITE to a new one, with
  header proxy rules, CANCEL relay, and failure/provisional passthrough.
- `chappe_sip:proxy_request/3`: sequential and parallel forking, CANCEL of
  losing branches, best-final selection, Record-Route insertion, and
  in-dialog forwarding through the record route (2xx ACK, BYE, re-INVITE
  loose-routed back to the proxy are forwarded to the far end in both
  directions). A forked second 2xx (a different To-tag arriving after the
  first) is forwarded statelessly upstream. One Record-Route (single
  interface); a pre-existing multi-hop Route set is forwarded by its next
  Route or the Request-URI, and strict-router (non-`;lr`) recovery is not
  implemented.
- Dialogs as processes: `chappe_sip_dialog:destroy/1`, `modify/2` (re-INVITE,
  including `hold`/`unhold`), `request/2` (INFO/REFER/UPDATE), with an
  auto-answer rule for unclaimed in-dialog requests.
- `chappe_sip_handler`: an optional behaviour for structured UAS apps.
- Reliable provisionals (PRACK / 100rel, RFC 3262): a UAS sends a reliable
  1xx with `chappe_sip_res:send_reliable/2` and blocks for the PRACK with
  `chappe_sip_res:await_prack/2`; a UAC opts in with `rel100 => supported` and
  auto-PRACKs reliable provisionals it receives.
- Registrar location store: `chappe_sip:registrar/0` is a ready REGISTER handler
  backed by a persistent AOR to contact store (per-contact and header
  `Expires`, `expires=0` removal, `Contact: *` clear, CSeq reorder
  rejection, expiry sweep); `chappe_sip:location/1` resolves an AOR. A WS binding is
  purged when its connection drops (RFC 5626: the flow is the only path to the
  UA), so a browser that disconnects is deregistered.

### Limits and overload
- Bounded request workers (503 shed past the cap), per-request handler
  deadline (500 on expiry), and a message-size cap on both directions of
  the NIF boundary. All tunable in `chappe_sip_config`.

### Reliability
- A call is not bounded by the handler deadline: once a worker owns a dialog
  (or forks as a proxy) its deadline is disarmed, so long calls are not torn
  down. The deadline still catches a handler that never responds.
- WS state survives an engine restart: the transport tolerates a briefly-absent
  engine, and a WS connection re-registers if the transport itself restarts.
- Registrations survive a registry-process crash (the ETS is held by a separate
  keeper), and a WS binding is dropped when its connection closes (RFC 5626).
- Handle and C-object cleanup on crash paths (UAC/dialog/proxy), WS transaction
  timers (no sofia Timer B/F over WS), and absolute proxy/b2bua timeouts bound
  resource use. The C engine start/stop/restart lifecycle is use-after-free-free
  (an RWLock guards the sofia root, CAS transitions guard start/abandon, and the
  stack thread holds its own resource ref so the destructor never frees under
  it) validated under AddressSanitizer via the `chappe_sip_engine_lifecycle` stress
  suite in `test/asan/`.
- A crash of the engine process re-establishes the native stack and its
  handlers from a config snapshot (held in the keeper's ETS), so SIP recovers
  without a manual restart; a controlled restart also fails in-flight UAC/dialog
  work cleanly.

### Security
- The Record-Route marker and WS flow token are HMAC-authenticated (per-node
  secret), so a crafted Route cannot turn the proxy into an open relay or target
  another WS leg. The registrar takes a mandatory digest/callback auth hook.
- Resource ceilings: dialogs, UAC transactions, WS connections, the WS transport
  mailbox, and registrar AORs/bindings are all bounded.
- Refuses the default distribution cookie at boot; distribution binds to
  loopback. TLS floors at 1.2 and rejects an invalid verify value. The WS
  upgrade honours an optional Origin allowlist.
- Digest does not replay credentials across a cross-authority redirect and
  refuses an unsupported qop instead of downgrading.

### Protocol compliance (RFC 3261)
- The RFC 4475 torture-test corpus is embedded (`test/chappe_sip_rfc4475_SUITE`,
  50 messages, IETF Trust license). Each vector is classified against our
  lenient layer: well-formed messages parse, malformed start lines are
  rejected, and the rest survive without crashing.
- The message parser is total: `chappe_sip_msg:parse/1` never throws on any input
  (a non-token or non-UTF-8 header name yields `{error, malformed}`, not a
  worker crash). `chappe_sip_msg:validate/1` checks the mandatory headers
  (Via/From/To/Call-ID/CSeq); a missing one is a 400 on both the UDP and WS
  ingress.
- Handling MUSTs: 405 carries an `Allow` header (21.4.5), a non-100 response
  carries a To-tag (8.2.6.2), an unsupported `Require`/`Proxy-Require` gets a
  420 with `Unsupported` (8.2.2), a too-brief REGISTER gets a 423 with
  `Min-Expires` (10.3), INVITE gets a 100 Trying, and merged requests get a
  482 (8.2.2.2).
- Dialogs build a route set from Record-Route and loose-route in-dialog
  requests through it (12.1.1/12.2.1.1); an out-of-order in-dialog request is
  rejected (12.2.2).

### Media control plane
- `chappe_sip_media`: a capability-based facade that maps a SIP call to a media
  session on an external engine. You ask for a capability (anchor, relay,
  conference, ...) and it routes to a backend; the media plane (RTP) stays in
  the external daemon, only the control plane runs in the BEAM. See
  `docs/design/media.md`.
- rtpengine backend (via the `chappe_rtpengine` library): anchor/relay a call's
  media with `chappe_sip_media:offer/2` and `answer/2` (SDP in, rewritten SDP out),
  plus `play`/`record`/`dtmf`, `subscribe` (tap a party's media to an external
  consumer such as an STT receiver), and `duck` (block or silence a party while
  a prompt plays). A session is correlated by SIP dialog identity (Call-ID +
  from/to tags) and bound to the call-owner process, so it is torn down when the
  call ends.
- FreeSWITCH backend (via the `chappe_esl` library): drive a channel over ESL for
  `conference`, `play`, `record`, and `dtmf`. Media rides the real SIP leg you
  originate to FreeSWITCH, so offer/answer do not apply on this backend.
- Optional and dormant: the media libraries are load-only and nothing in them
  starts unless you pass a `media` config to `chappe_sip:start/1`.

### Interop
- Opt-in interop track (`INTEROP=1`, out of the fast run) against real stacks:
  a real JsSIP UA registers over WS, two JsSIP UAs place a WebRTC media call
  through the b2bua, and a Kamailio container OPTIONS-pings chappe_sip both
  directions. Drivers and setup live in `interop/`.

## Planned

Gaps relative to drachtio, in rough order of impact.

- **Multi-app / outbound connection model**: drachtio decouples the SIP stack
  from the app over a control socket (`connect` inbound, `listen` outbound),
  so one server fronts many apps, one app fronts many servers, and an app
  restarts without dropping the stack. We embed the stack in the node, so a
  remote-app split and outbound cloud-scaling are not available yet.
- **CDR events**: no call-accounting event stream. drachtio emits
  `cdr:attempt` / `cdr:start` / `cdr:stop`; we would surface the equivalent as
  process events or telemetry for billing and observability.
- **SUBSCRIBE/NOTIFY subscriptions**: SUBSCRIBE/NOTIFY/PUBLISH route as
  methods, but there is no subscription dialog (event package,
  Subscription-State, refresh/expiry). No presence or MWI on top of it.
- **RFC 4028 session timers**: Session-Expires/Min-SE are parsed but not
  enforced, so a stalled dialog is not refreshed or torn down on timeout.
- **RFC 3327 Path in the registrar**: no Path support, so an edge/outbound
  registrar in front of the location store is not covered.
- **Multi-homed contacts**: one contact per transport today; binding several
  listen addresses on the same transport is not supported.
- **SIP capture (HEP/Homer)**: no native trace export to a capture agent.
- **WS-to-WS proxied dialogs**: two WS legs need two record-route flow
  tokens (a single token routes one direction today).

## Non-goals

- Media plane. chappe_sip moves SIP signaling and controls media
  engines through `chappe_sip_media`, but RTP never flows through it: the media
  plane stays in rtpengine / FreeSWITCH. It is not a media relay or a media
  server itself.
