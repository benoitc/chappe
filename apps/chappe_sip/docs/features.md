# Features

What chappe_sip does today, and what is planned. This is the feature
tracker; the milestone history is in `docs/plan.md`.

## Working

### Transport and engine
- Embedded SIP engine (sofia-sip nta) started and supervised by the
  Erlang application, over a plain-C NIF. No external signaling daemon.
- UDP and TCP contacts, plus an optional TLS listener on its own port
  (`tls => #{contact, cert_dir, verify, verify_clients}` in
  `chappe_sip:start/1`; see `docs/guides/tls.md`). Outbound TLS checks the
  server certificate and host (RFC 5922) by default; client certificates are
  opt-in.
- SIP-over-WebSocket (RFC 7118) via livery (`ws => #{port}` in
  `chappe_sip:start/1`, and `wss => #{port, cert_dir}` for secure WebSocket
  with the `agent.pem` of the SIP TLS cert dir): an Erlang WS transport
  bridges frames to the shared transaction-user logic, so UAS/registrar/etc.
  work over WS. The engine multiplexes each operation to the sofia NIF or the
  WS transport by handle. The `sip` subprotocol is required (a client that
  does not offer it is refused); text and binary frames are accepted, and a
  message that is not valid UTF-8 goes out in a binary frame. Requests over
  WSS carry a `WSS` Via. livery starts lazily, only when a WS listener is
  configured. To terminate TLS at a load balancer instead, point it at the
  plain `ws` port.
- WS transactions follow the RFC 3261 rules for a reliable transport: no
  retransmissions, a retransmitted request gets the last response again, a
  non-2xx INVITE final waits for its ACK (Timer H), Timer B/F bound a client
  transaction, Timer C (180 s) CANCELs an INVITE stuck after a provisional,
  a CANCEL waits for a provisional, and a non-2xx final is ACKed with the
  INVITE's branch. A CANCEL of an unanswered INVITE gets the 487, a 2xx
  never ACKed within 64*T1 is BYEd, reliable provisionals (100rel) carry
  RSeq and are matched to their PRACK, and dialog-forming responses carry
  the request's Record-Route. An INVITE left ringing sends its last non-100
  provisional again every `ws_progress_ms` (60 s) until the final, as nta
  does on UDP, TCP and TLS (RFC 3261 13.3.1.1).
- Via `received` is stamped when the sent-by is not the client address (a
  WS client's `.invalid` host always is); `rport` is filled in only when the
  client asked with a bare `rport` (RFC 3581).
- Keepalive: a CRLFCRLF ping gets a CRLF pong on WS and, through sofia, on
  TCP/TLS (RFC 5626 4.4.1). The server pings each WS connection every
  `ws_ping_interval_ms` (30 s); a connection with no inbound traffic for
  `ws_idle_timeout_ms` (600 s) is closed, so only a client that stopped
  answering is reaped.
- WebRTC gateway: bridge a browser (WS) and a UDP/TCP peer in both
  directions, as a proxy (`chappe_sip:proxy_request` to a `{ws, Flow}` target,
  Record-Route with a flow token so in-dialog ACK/BYE/re-INVITE traverse) or
  a B2BUA (`chappe_sip:create_b2bua` with a `flow` opt). Resolve a registered
  browser with `chappe_sip:location_flow/1`. A real JsSIP-to-JsSIP WebRTC call
  completes through the b2bua over WS (verified in the interop track). A
  WS-to-WS proxied dialog carries a flow token per leg, so both directions
  route; the tokens are trusted-gateway scoped.
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
  out-of-dialog requests, with provisional delivery, digest 401/407 retry
  (one credential per realm, so a 407 then a 401 works; `stale=true` retried
  with the new nonce; SHA-256 preferred over MD5; nonce counts per nonce),
  3xx redirects (Contacts best `q` first, the next one on a 4xx/5xx, sip/sips
  only, `?headers` and `method` dropped; a 305 keeps the Request-URI and
  goes through the Contact as proxy), a preloaded `route_set` (loose or
  strict first route, RFC 3261 8.1.1.1), a URI `method` parameter used as
  the method when none is given and left out of the Request-URI, a sips
  Contact when the Request-URI, `proxy` or first route is SIPS (also on the
  dialog's target refreshes), a sip: next hop reached as sips: for a SIPS
  Request-URI, a `sips:...;transport=udp` target refused, and 3PCC (`no_ack`, then
  `chappe_sip_dialog:ack/2` sends the ACK with the answer). A
  `create_uac/2` timeout CANCELs the INVITE and BYEs a 2xx that crosses it.
  The 2xx ACK carries the INVITE's credentials. The body is `local_sdp`
  (application/sdp) or `body` plus `content_type` for anything else, such as a
  SIPREC `multipart/mixed` of SDP and rs-metadata.
- `chappe_sip:create_b2bua/4`: bridge an incoming INVITE to a new one, with
  header proxy rules both ways, CANCEL relay, failure passthrough, and
  provisionals relayed with their body (early media) and 100rel on each leg,
  and Timer C on the B leg (restarted by each provisional, 408 on expiry).
  `chappe_sip_b2b:relay/1,2` carries re-INVITE and UPDATE offers across the
  legs (answer, failure and 491 back to the offerer, an optional SDP rewrite),
  lets each leg answer its own session refreshes, and repeats the `Reason` of
  a BYE or CANCEL (RFC 3326) on the other leg. With `privacy => true` it acts
  as an RFC 3323 privacy service: a `critical` Privacy naming a level it
  cannot apply (`session`, unless you anonymize the media and say so with
  `privacy => #{session => true}`, or an unknown token) gets 500 with the
  levels in the reason phrase before B is called; `user` and `header` keep
  Subject, Call-Info, Organization, User-Agent, Reply-To and In-Reply-To
  from B, and `id` keeps P-Asserted-Identity, even with
  `proxy_request_headers => all`.
- `chappe_sip:proxy_request/3`: a stateful proxy after RFC 3261 section 16.
  Sequential and parallel forking with the Request-URI rewritten to each
  target, a pre-existing Route set honoured (loose and strict next hops,
  strict-router recovery), Timer C per INVITE branch, CANCEL relayed to the
  branches (the downstream 487 or a crossing 2xx goes upstream), loop
  detection (482) that lets spirals through, and the 16.7 best response (6xx
  first, lowest class, retry-able 4xx preferred, challenges and 3xx Contacts
  merged, 503 sent as 500). Every 2xx is forwarded for 64*T1 after the first
  (RFC 6026), also over TCP/TLS, where nta ends the client transaction at
  the first 2xx: the shim's agent callback catches the later ones. Record-Route insertion (sips when the forwarded request is
  SIPS, rewritten in responses across TLS/non-TLS) and in-dialog forwarding
  through it, CANCEL of a transit re-INVITE included.
- Dialogs as processes: `chappe_sip_dialog:destroy/1,2` (headers such as a
  Reason on the BYE), `modify/2,3` (re-INVITE, including `hold`/`unhold`, with
  an optional RFC 3261 14.1 retry after 491), `request/2` (INFO/REFER/UPDATE).
  `hold` marks each live stream sendonly (inactive when it was recvonly) and
  `unhold` reverses it, stream by stream, with the next o= version. A
  provisional to our re-INVITE keeps its transaction open until the final.
  An early dialog our 18x formed (`create_uas/3` with a 1xx `status`) takes
  UPDATE both ways, and the caller's BYE in it gets 200 and its INVITE 487.
  Each early dialog of an INVITE we send (a 101..199 with a new To tag) is a
  dialog handle too, reported as `{early_dialog, Dialog}` just before its
  provisional: the callee's UPDATE and INFO in it are delivered or answered
  as in a confirmed dialog, its BYE gets 200 and ends that dialog (the
  INVITE still completes with its final), and `request/2` sends UPDATE or
  INFO in it, sharing the INVITE's CSeq counter with the PRACKs. `destroy/1`
  on it CANCELs the INVITE, `modify/2` returns `{error, early}`. The 2xx
  with its To tag confirms the same handle (route set and remote target
  taken again from the 2xx, RFC 3261 13.2.2.4); the other early dialogs end
  on the INVITE's final, their owner getting `destroy` with reason
  `{early_ended, Status}`.
  Unclaimed in-dialog requests are answered by the dialog: offers in re-INVITE
  and UPDATE with the current local SDP (488 without one), an offerless
  re-INVITE with our SDP as the offer (answer taken from the ACK), REFER 603,
  unknown methods 501 and REGISTER/PUBLISH 405 (both with Allow), OPTIONS 200
  with Allow/Accept/Supported. `remote_sdp/1` and `local_sdp/1` track re-INVITE, UPDATE and ACK.
  Glare gets 491 and overlapping INVITE/UPDATE 500 with Retry-After (RFC 3261
  14.2, RFC 3311 5.2).
- Reason (RFC 3326): on the BYE via `chappe_sip_dialog:destroy/2`, on a
  CANCEL via `chappe_sip_uac:cancel/2`; a received CANCEL reaches the INVITE
  handler as `{chappe_sip_cancel, TxnH, CancelReq}` and a received BYE as the
  `destroy` event's request.
- SUBSCRIBE/NOTIFY subscription dialogs (RFC 6665, notifier side):
  `chappe_sip:create_uas/3` on a SUBSCRIBE answers 200 with the granted
  `Expires` (capped by `expires`, 423 below `min_expires`) and confirms the
  dialog at once. `chappe_sip_dialog:notify/2` sends NOTIFY with Event and
  `Subscription-State` (`active`/`pending` carry the seconds left). In-dialog
  refreshes and `Expires: 0` unsubscribes are answered by the dialog and
  reported to the owner; expiry, `destroy/1` and owner death send a final
  `terminated` NOTIFY instead of a BYE; a NOTIFY failure of RFC 6665 4.2.2 ends
  the subscription; `chappe_sip:subscribe/2` answers 489 with Allow-Events
  for packages you do not serve. `notify/2` also sends the implicit REFER subscription's NOTIFYs
  inside an INVITE dialog. Works over UDP/TCP and WS. See the subscriptions
  guide.
- Event package routing: `chappe_sip:event_package/2` gives each package
  its own SUBSCRIBE handler, `subscribe/1,2` staying the catch-all;
  Allow-Events (OPTIONS 200, the 489) lists the registered packages.
- Subscriber side (RFC 6665): `chappe_sip:subscribe_to/3` starts a process
  that sends the SUBSCRIBE through the UAC (digest, proxy, flow), forms the
  dialog from the 2xx or the first NOTIFY, starts a subscription of its own
  for each forked NOTIFY, refreshes before expiry (a NOTIFY's `expires`
  wins), runs Timer N, ends on the refresh failures of 4.1.2.2, and acts on
  the terminated reasons (re-subscribe at once, after `retry-after`, or
  stop). `chappe_sip:unsubscribe/1` sends `Expires: 0`. NOTIFYs outside a
  dialog go through one router: our subscriptions, then REFERs we sent,
  then your `notify/1` handler, else 481. `chappe_sip_hdr:subscription_state/1`
  parses the header.
- Publication (RFC 3903): `chappe_sip:publish/1` with a map is an event
  state compositor (SIP-ETag per 2xx, SIP-If-Match refresh, modify and
  remove, 412, 423 with Min-Expires, 489, 415, 404 by a `resources` fun,
  digest `auth`, expiry); `chappe_sip:publish_state/4` is the client side
  (refresh before expiry, modify, remove, a full republish after 412, the
  423 retry, one PUBLISH at a time).
- Presence (RFC 3856, PIDF of RFC 3863): `chappe_sip_presence:serve/1` (or
  the `presence` start option) serves the presence package from the
  published state: authentication, an `authorize` hook (allow, polite
  blocking, pending with a note, deny), 406 for an Accept without PIDF, the
  full composed state on subscribe, refresh and every change, at most one
  NOTIFY per `min_interval` (5 s). `chappe_sip_pidf` renders, parses (xmerl,
  no DOCTYPE) and composes PIDF; a presence subscription parses each NOTIFY
  into `doc` and keeps one dialog per SUBSCRIBE.
- Message waiting (RFC 3842): `chappe_sip_mwi:serve/1` and `update/2` notify
  every `message-summary` subscriber of an account (at most once a second
  each); `chappe_sip_mwi` renders and parses simple-message-summary. See the
  presence guide.
- REFER (RFC 3515 as updated by RFC 7647), both sides, in `chappe_sip_refer`
  (facade: `chappe_sip:accept_refer/3,4`, `send_refer/3`). Recipient: 400 for
  zero or several Refer-To, 416 for a non sip/sips/tel target, an `authorize`
  hook (required for `method=BYE`, RFC 4579 5.11), 200 never 202, the implicit
  subscription with message/sipfrag NOTIFYs, `Event: refer;id=<CSeq>` from
  the second REFER in a dialog, refresh/unsubscribe by SUBSCRIBE (403 for an
  unknown id), expiry, at most one NOTIFY a second with the final one never
  dropped, `Refer-Sub: false` with `norefersub` (RFC 4488), Target-Dialog
  lookups (RFC 4538) for out-of-dialog REFERs, Replaces and nested Refer-To
  in the target. Sender: in or out of dialog, Referred-By (RFC 3892), Replaces,
  Refer-Sub, Target-Dialog; NOTIFYs become `{refer_progress, Id, Code}` and
  `{refer_done, Id, Code}`, unknown ones get 481. `chappe_sip_sipfrag` builds
  and parses message/sipfrag (RFC 3420). See the REFER guide.
- Conference focus (RFC 4579) and conference state (RFC 4575):
  `chappe_sip_focus` gives your conference process the `isfocus` Contact, the
  Allow/Accept/Allow-Events/Supported set for its 2xx and OPTIONS 200, and a
  per-conference notifier: 489/406 checks, full state on subscribe and
  refresh, per-subscription versions, NOTIFYs coalesced to one per 5 s per
  watcher, and one `noresource` NOTIFY each when the conference ends.
  `chappe_sip_confinfo` renders full and partial conference-info+xml and
  anonymous participants (`Privacy`), with conf-uris, available-media and
  referred, keys kept unique and call-info shown only when the focus's
  `call_info` policy allows. A subscriber can have its own `view` (a
  moderator sees call-info, a denied watcher gets 200 and an empty roster).
  `departure/1`, `referred/1`, `media/2` and `leg_status/1` derive an
  endpoint's disconnection-method, referred-by, media (with the `a=ssrc` as
  src-id) and on-hold state from SIP. See the conference focus guide.
- `chappe_sip_handler`: an optional behaviour for structured UAS apps.
- Call records: `chappe_sip_cdr:subscribe/1` sends `attempt`, `start` and
  `stop` for each INVITE call attempt and role (`uas`, `uac`, `b2b_a` and
  `b2b_b` linked to each other, `proxy`), with the tags, the transport and
  source, the ring, answer and end times, the final status and a
  normalized reason (`{bye, local | remote}`, `cancel`, `{final, Status}`,
  `owner_down`, `flow_lost`, ...). Exactly one stop per attempt: one
  process owns the open records and monitors what drives each call, so a
  killed or shut down fsm still ends its record (`{process_down, Why}`).
  No subscriber, no record. See the call records guide.
- Replaces (RFC 3891): `chappe_sip:find_replaced/1` matches an INVITE's
  `Replaces` to a live dialog and returns its state (`early | confirmed |
  terminated`), role, and `early-only` flag so you can answer 400/481/486/603;
  `chappe_sip:find_dialog/3` looks a dialog up by call-id and tags. Backed by an
  ETS index the dialog fsm maintains (cleared on BYE, owner death, fsm crash,
  and engine restart; bounded by `max_dialogs`). `chappe_sip_hdr:replaces/1`,
  `replaces_value/1`, `escape/1` and `refer_to_replaces/1` parse and build the
  value, including inside a Refer-To URI. `chappe_sip:replaces_response/1,2`
  gives the section 3 answer (accept, or reject 400/481/486/603) and refuses
  a match with 403 unless your `authorize` fun accepts it or the sender
  passes digest (`auth`, a 401 challenge first): RFC 3891 section 8. The early
  dialogs of a ringing UAC call are indexed, so it can be replaced (destroy
  sends the CANCEL). `replaces` is in Supported on our INVITE and its 2xx and accepted in
  Require. See the answer-calls guide.
- Reliable provisionals (PRACK / 100rel, RFC 3262): a UAS sends a reliable
  1xx with `chappe_sip_res:send_reliable/2` and blocks for the PRACK with
  `chappe_sip_res:await_prack/2`, which hands back a PRACK carrying an offer
  for the app to answer; a UAC opts in with `rel100 => supported` and
  auto-PRACKs reliable provisionals it receives (those with
  `Require: 100rel` and an RSeq), in RSeq order, through the early dialog's
  route set to its Contact, answering an offer they carry in the PRACK.
- Session timers (RFC 4028): `Supported: timer` on every request,
  `Require: timer` accepted, `Session-Expires`/`Min-SE` negotiated on the
  INVITE and its 2xx (422 below `min_se`, a UAC retry after 422), refresher
  selection, refreshes at half the interval by UPDATE (or re-INVITE with the
  unchanged SDP), and a BYE with destroy reason `session_expired` when no
  refresh arrives. Asking for a timer is opt-in (`session_expires`); a peer's
  request is always honored. See the session timers guide.
- Registrar (RFC 3261 10.3): `chappe_sip:registrar/1` is a ready REGISTER
  handler backed by a persistent AOR to contact store. The AOR is the
  canonical To URI (host case-insensitive, parameters dropped, escapes
  undone); comma-joined Contacts each take their own `expires`; a Contact
  matches its binding by the 19.1.4 URI rules; the CSeq check is per binding
  and a failing REGISTER writes nothing (one the store could not apply in
  time gets 500 and is never applied); `expires=0` removal, `Contact: *`
  clear, 423 with `Min-Expires` below `registrar_min_expires` (60), 404
  outside `registrar_domains`, never a 6xx (an auth policy's 6xx goes out
  as 403); the 200 lists every binding with `expires` and `q`, and a
  `Date`. A UA registering directly gets its keep-alives answered: STUN
  Binding on UDP, CRLF pong on TCP, TLS and WS (RFC 5626 5.4). `chappe_sip:location/1` resolves an AOR the highest q
  first and `chappe_sip:bindings/1` gives each binding with its Path. Path
  (RFC 3327) is stored and echoed (420 without `Supported: path`). Outbound
  (RFC 5626): one binding per (instance, reg-id) flow, `Require: outbound` and
  `Flow-Timer` in the 200, 439 past a first hop without an `ob` Path. A WS
  binding is purged when its connection drops (the flow is the only path to
  the UA), so a browser that disconnects is deregistered; only that flow's
  binding goes. An outbound binding registered directly over TCP/TLS is tied
  to its connection (`{conn, Id}`, from the request meta `conn`) and purged
  when it closes; over UDP to its source address and port. A request reaches
  it over that flow (`proxy_request/3` with `{flow, Uri, Flow}`, or the
  `flow` option of a UAC or b2bua).

### Limits and overload
- Bounded request workers (503 shed past the cap), per-request handler
  deadline (500 on expiry), and a message-size cap on both directions of
  the NIF boundary, all on WS too (a WS-only node answers them without a
  native engine). Over WS a message past `max_message_size` closes the
  connection with 1009 inbound, checked by the ws parser on each frame and
  reassembled message before it is buffered, and is refused
  (`{error, too_large}`) outbound. All tunable in `chappe_sip_config`.

### Reliability
- A call is not bounded by the handler deadline: once a worker owns a dialog
  (or forks as a proxy) its deadline is disarmed, so long calls are not torn
  down. The deadline still catches a handler that never responds.
- WS state survives an engine restart: the transport tolerates a briefly-absent
  engine. If the WS transport process itself restarts, its connections close
  and their bindings are dropped; the UAs reconnect and register again.
- Registrations survive a registry-process crash (the ETS is held by a separate
  keeper), and a WS binding is dropped when its connection closes (RFC 5626).
- Handle and C-object cleanup on crash paths (UAC/dialog/proxy), WS transaction
  timers (no sofia timers over WS; a server transaction the app never answers
  gets 408 or 500), and Timer C on proxy and b2bua INVITE branches bound
  resource use. A worker that sends an INVITE (a b2bua B leg) owns the call, so
  a callee ringing past the handler deadline is not cut. The C engine
  start/stop/restart lifecycle is use-after-free-free
  (an RWLock guards the sofia root, CAS transitions guard start/abandon, and the
  stack thread holds its own resource ref so the destructor never frees under
  it) validated under AddressSanitizer via the `chappe_sip_engine_lifecycle` stress
  suite in `test/asan/`, with LeakSanitizer reporting any leak on a NIF call
  path (`test/asan/lsan.supp` covers only stacks without a NIF frame).
- A crash of the engine process re-establishes the native stack and its
  handlers from a config snapshot (held in the keeper's ETS), so SIP recovers
  without a manual restart; a controlled restart also fails in-flight UAC/dialog
  work cleanly.

### Security
- The Record-Route marker and WS flow tokens are HMAC-authenticated (per-node
  secret, at least 16 bytes when configured) and carry a signed expiry, so a
  crafted or replayed Route cannot turn the proxy into an open relay or target
  another WS leg. The registrar requires a digest/callback auth hook; running
  without one takes an explicit `allow_unauthenticated => true`.
- Resource ceilings: dialogs, UAC transactions, WS connections, the WS transport
  mailbox, and registrar AORs/bindings are all bounded.
- Refuses the default distribution cookie at boot; distribution and epmd bind
  to loopback. TLS floors at 1.2, verifies outbound peers by default, and
  rejects an invalid verify value; `verify => none` needs `allow_insecure`. The WS
  upgrade honours an optional Origin allowlist.
- Digest (RFC 2617, RFC 7616, RFC 8760: MD5, MD5-sess, SHA-256,
  SHA-256-sess) does not replay credentials across a redirect to another
  scheme, host or port, and refuses an unsupported qop instead of
  downgrading. The server side refuses a replayed nonce count (stale), an
  answer without the qop it offered, and a digest uri that is not the
  Request-URI; `chappe_sip_digest:challenges/2` offers SHA-256 and MD5. The
  registrar checks the AOR's user and domain against the credentials.

### Protocol compliance (RFC 3261)
- The RFC 4475 torture-test corpus is embedded (`test/chappe_sip_rfc4475_SUITE`,
  50 messages, IETF Trust license). Each vector is classified against our
  lenient layer: well-formed messages parse, malformed start lines are
  rejected, and the rest survive without crashing.
- The message parser is total: `chappe_sip_msg:parse/1` never throws on any input
  (a non-token or non-UTF-8 header name yields `{error, malformed}`, not a
  worker crash), and header values are trimmed byte-wise, so `get/2`,
  `get_all/2` and `validate/1` never throw either. The SIP-Version is
  case-insensitive, the method a token, and every IANA compact header form is
  read. `chappe_sip_msg:validate/1` checks the mandatory headers
  (Via/From/To/Call-ID/CSeq) and that a request's CSeq is `1*DIGIT LWS Method`
  naming its own method; a failure is a 400 on both the UDP and WS ingress.
  Over WS a Content-Length that is repeated, negative or not the body size is
  a 400 too; a response with either problem is dropped.
  Max-Forwards is not required of a received request (a proxy adds 70).
- URIs: a user part may carry `;` (`sip:alice;day=tuesday@example.com`), the
  scheme is case-insensitive, and `chappe_sip_uri:equal/2` compares by RFC
  3261 19.1.4. `chappe_sip_uri:format/1` percent-escapes what each component
  (user, tel subscriber, password, parameters, headers) may not carry raw,
  keeps existing escapes, and writes a repeated parameter once.
- Handling MUSTs: an out-of-dialog method with no handler gets 405 with
  `Allow` (21.4.5), or 501 when unknown (21.5.2), and OPTIONS 200 with our
  capabilities (11); a non-100 response
  carries a To-tag (8.2.6.2), an unsupported `Require` gets a 420 with
  `Unsupported` (8.2.2.3), in a dialog too, never for ACK or CANCEL, while a
  UAS ignores `Proxy-Require`. The accepted tags are `supported_option_tags`
  plus a route's own (`chappe_sip:handle/3` `option_tags`, e.g. `siprec` for a
  recording server, RFC 7866 6.1.1); a route with `proxy => true` and the
  in-dialog forwarding of a record-routed dialog leave `Require` to the far
  UAS and check `Proxy-Require` (16.3). A too-brief REGISTER gets a 423 with
  `Min-Expires` (10.3), INVITE gets a 100 Trying, and merged requests get a
  482 (8.2.2.2).
- No content coding: sofia's zlib support is turned off at build time
  (`c_src/build.sh`), so nta neither inflates a request body nor deflates a
  response. An INVITE whose body has a Content-Encoding other than identity
  gets 415 with `Accept-Encoding: identity`; any other request reaches the
  app with its body and Content-Encoding as sent (RFC 3261 20.12).
- Requests to a domain are resolved per RFC 3263 by nta (NAPTR, SRV, A,
  with failover to the next SRV target, over TLS for a `sips:` URI); the
  conformance lab checks both against a dnsmasq server.
- Dialogs build a route set from Record-Route and route in-dialog
  requests through it (12.1.1/12.2.1.1): loose routing, or behind a strict
  router the first route as the Request-URI and the remote target last in
  Route; an out-of-order in-dialog request is rejected (12.2.2).

### Media control plane
- `chappe_sip_media`: a capability-based facade that maps a SIP call to a media
  session. You ask for a capability (anchor, relay, conference, ...) and it
  routes to a backend: rtpengine for anchoring, chappe_mix for conferences. The
  SIP processes never touch RTP. See `docs/design/media.md`.
- rtpengine backend (via the `chappe_rtpengine` library): anchor/relay a call's
  media with `chappe_sip_media:offer/2` and `answer/2` (SDP in, rewritten SDP out),
  plus `play`/`record`/`dtmf`, `subscribe` (tap a party's media to an external
  consumer such as an STT receiver), and `duck` (block or silence a party while
  a prompt plays). `publish/2` anchors a call with no second leg (a recording
  server taking N sendonly streams): rtpengine answers the offer itself, and
  `subscribe/2` reports the tapped streams in m-line order with their labels so
  each one can be forked to its own receiver. A session is correlated by SIP
  dialog identity (Call-ID +
  from/to tags) and bound to the call-owner process, so it is torn down when the
  call ends.
- chappe_mix backend (the `conference` capability): `conference/3` starts or
  joins a named room, opens a mixer leg for the call and returns its G.711 SDP
  (an answer to the call's offer, or an offer you complete with `set_remote/2`).
  `leave/1`, `mute/1` and `unmute/1` act on the leg. A room stops with its last
  leg or when its owner exits; a leg leaves when its call process exits. G.711
  (PCMU/PCMA) over RTP/AVP in 20 ms frames only: anchor other calls on
  rtpengine and give the mixer rtpengine's offer, so rtpengine transcodes and
  terminates SRTP/DTLS.
- `play`, `record` and `dtmf` run on rtpengine only.
- A dialog handle passed to `session/2` maps its tags by role: the From tag is
  the peer's on a UAS dialog and ours on a UAC dialog.
- Optional and dormant: the media libraries are load-only and nothing in them
  starts unless a `media` config is given, as the `chappe_sip:start/1` option
  or the `media` application env (the option wins).

### Interop
- Opt-in interop track (`INTEROP=1`, out of the fast run) against real stacks:
  a real JsSIP UA registers over WS, two JsSIP UAs place a WebRTC media call
  through the b2bua, and a Kamailio container OPTIONS-pings chappe_sip both
  directions. Drivers and setup live in `interop/`.
- Conformance lab (`make interop-conformance`, also in CI): SIPp, pjsua and
  a dnsmasq server against a chappe node in docker, one RFC flow per case
  (`interop/conformance`, `docs/guides/interop-testing.md`).

## Breaking changes

- `chappe_sip:replaces_response/1,2` no longer accepts a Replaces by
  default: a match that would be accepted is `{reject, 403}` unless you
  pass `authorize => fun((Dialog, Req) -> boolean())` or
  `auth => #{realm, secret}` (RFC 3891 section 8). With `auth`, it can also
  return `{reject, 401, Headers}`; send those headers with the 401. To keep
  the old behaviour on a closed network, pass
  `#{authorize => fun(_, _) -> true end}`.
- A CANCEL of an INVITE you answered 1xx with `create_uas/3` now ends that
  early dialog: its owner gets `{chappe_sip_dialog, D, destroy, cancel}`.
- `chappe_sip:stop/0` and an engine degrade now tear the dialogs down as
  `restart_engine/0` does: owners get `destroy` with reason
  `engine_restart`, and a UAC still ringing gets `{error, engine_restart}`.
- A closed WebSocket connection now ends the dialogs bound to it: owners get
  `destroy` with reason `flow_lost`.
- Every NOTIFY outside a dialog now goes through the built-in router: your
  `chappe_sip:notify/1` handler sees only the NOTIFYs no subscription of
  ours and no REFER we sent claims, and without a handler a NOTIFY gets 481
  instead of 405. NOTIFY is always in Allow.
- A UAC INVITE now watches its owner (`owner`, else `notify`, else the
  caller of `chappe_sip_uac:start/2`): when that process exits while the
  INVITE rings, the INVITE is CANCELled and a 2xx that still comes is ACKed
  and BYEd. Start the call from the process that keeps it, or pass `owner`.
- `chappe_sip_focus:subscribe/4` now sends the conference process
  `{chappe_sip_focus, subscribed, Dialog, Opts}`. Pass it to
  `chappe_sip_focus:handle_info/2` as before; the three-element form is still
  accepted.

## Planned

Gaps relative to drachtio, in rough order of impact.

- **Multi-app / outbound connection model**: drachtio decouples the SIP stack
  from the app over a control socket (`connect` inbound, `listen` outbound),
  so one server fronts many apps, one app fronts many servers, and an app
  restarts without dropping the stack. We embed the stack in the node, so a
  remote-app split and outbound cloud-scaling are not available yet.
- **Multi-homed contacts**: one contact per transport today; binding several
  listen addresses on the same transport is not supported.
- **SIP capture (HEP/Homer)**: no native trace export to a capture agent.

## Non-goals

- Media plane. chappe_sip moves SIP signaling and controls media
  engines through `chappe_sip_media`, but RTP never flows through the SIP
  processes: it stays in rtpengine and in the chappe_mix conference processes.
  chappe_sip is not a media relay or a media server itself.
