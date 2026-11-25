# Changelog

All notable changes to chappe_sip, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

- HD conference rooms: a room can mix at 16 kHz instead of 8 kHz, so
  callers on G.722 or Opus hear each other in wideband while G.711
  callers still join. The media facade gives the rtpengine settings that
  convert each caller to the room's audio. These rooms need rtpengine 13.4
  or later.

### Changed

- A room keeps the rate it was created with: a join asking for another
  rate is refused, and recording a 16 kHz room with SIPREC is refused for
  now.

### Fixed

- Ending a call the proxy anchored on rtpengine no longer waits on a reply
  that may not arrive: the proxy asks rtpengine to leave the call
  statistics out of the delete reply, which could otherwise be split into
  IP fragments that some networks drop.

## [0.3.0] - 2026-11-23

### Before you upgrade

- Use Erlang/OTP 29.1.2 or later.
- Replace the removed functions listed under Breaking, and call
  `chappe_sip_flow:ensure_secret/0` instead of
  `chappe_sip_route:ensure_secret/0`.
- Drop `ws`, `wss` and `*` from native and TLS contacts, fix
  invalid start options, and keep the message size limit between 1 KiB and
  64 MiB, or the start fails.
- Reload the SIP engine library with `chappe_sip_nif:replace/0`
  while the stack is stopped.
- Build the registrar with `chappe_sip:registrar/1`, and give it
  `auth` or set `allow_unauthenticated => true`, or it fails to start.
- Remove `freeswitch` from the `chappe_sip_media` configuration;
  run conferences on chappe_mix and drive FreeSWITCH through chappe_mrf.

### Breaking

- Erlang/OTP 29.1.2 or later is required: earlier OTP 29 releases let a
  TLS 1.3 server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
- Removed: `chappe_sip:registrar/0`, `chappe_sip:bye/1` and `update/1`,
  `chappe_sip_engine:unhandle/1`, `respond/3` and `unreg_handle/1`,
  `chappe_sip_msg:new_response/3`, `chappe_sip_req:can_form_dialog/1` and
  `chappe_sip_res:final_ref/1`.
- Moved: `chappe_sip_route:ensure_secret/0` is now
  `chappe_sip_flow:ensure_secret/0`.
- sofia's own WebSocket transport is never opened: a native or TLS contact
  naming `ws`, `wss` or `*` fails the start, and a TLS contact naming no
  transport binds TLS only. The `ws` and `wss` options serve WebSocket.
- An invalid start option fails the start instead of being ignored, and
  the message size limit must be between 1 KiB and 64 MiB.
- An in-place upgrade of the SIP engine library is refused, as it could
  leave the stack unable to start or unload the library under a live call.
  Use `chappe_sip_nif:replace/0` with the stack stopped.
- A registrar with no `auth` fails to start unless you set
  `allow_unauthenticated => true`. Before, it accepted unauthenticated
  REGISTER requests by default.
- The FreeSWITCH media backend of `chappe_sip_media` is removed
  (`chappe_sip_media_freeswitch`, `chappe_sip_media_esl_mgr`), and a media
  configuration naming `freeswitch` returns an error. Conferences run on
  chappe_mix; FreeSWITCH is driven through chappe_mrf.

### New

- Several nodes, with chappe_cluster in the release as
  `{chappe_cluster, load}`: the registrar runs on every node, a device can
  be called from any node, concurrent registrations are never lost, and
  with most nodes unreachable a registration is refused with a retry delay
  while calls go on. A TCP, TLS or WebSocket device whose node stops is
  unreachable until it registers again. A trunk can be pinged from one node
  for all, and message-waiting updates reach subscribers on every node.
- Call correlation: one reference per call, on every leg, call record and
  Homer capture. You can pass your own and find a call's processes from any
  node.
- SIPREC: record a call or a native room to a recording server, with pause,
  resume and party changes, or act as a recording server that hands each
  stream and its metadata to your app and writes it to the recording store.
  The recording server takes its audio through chappe_audio, which must run
  on the node, and refuses an offer with no stream it can take with 488.
- The SIPREC recording server takes SRTP (keys over TLS or WSS only, unless
  you mark the network trusted), answers re-offers as RFC 3264 asks
  (pause, added and removed streams, UPDATE offers, moves and codec
  changes), sends and reads RTCP as RFC 7866 asks (a stream without shared
  RTCP takes two ports), and can bind its ports within a range for
  containers.
- B2BUA forking and hunting: ring all of a user's devices at once, each with
  its own flow, headers and rtpengine flags, learn which one answered, or
  take over every failure and try the next target unseen by the caller.
  Registrar bindings say which flow reaches each device.
- B2BUA leg control: hear the outgoing INVITE, provisional answers and early
  dialogs and cancel while ringing, add headers to the caller's answer,
  follow redirects, compute offer, credentials and answer from a function,
  end a call with a reason, and receive or forward REFER, INFO (DTMF) and
  MESSAGE.
- B2BUA moves: move an anchored call to another callee or a media server
  without the caller noticing, across networks, to several destinations at
  once (first answer wins, the caller stays if none does), choosing who the
  new callee sees as calling.
- B2BUA caller identity: the identity you set for the outgoing leg is
  checked, so untrusted text cannot add SIP headers; a bad value is never
  sent and you get an error.
- B2BUA transfers: blind or attended, on either leg, FreeSWITCH-bridged
  calls included, through your policy or your app. Without a policy, a
  transfer to another network is refused and transfers per call are
  bounded. A REFER to a conference focus adds or removes a participant.
- B2BUA media: one option anchors a whole call in rtpengine, a helper picks
  direct or anchored per call, and a live call can switch. An SRTP caller
  stays encrypted unless your app chooses otherwise. The SDP hook
  tells offers from answers. INVITE and re-INVITE without an offer work end
  to end, UPDATE crosses while ringing, and hold and unhold reach your app.
- B2BUA: a call can run in its own process; a background call runs
  supervised and hangs up when its named owner dies.
- Dialogs report hold, unhold, session refreshes and in-dialog PUBLISH, and
  their state changes can be followed. Middleware can hand data to the
  request handler.
- A registration client that keeps a registration to a carrier alive.
- Presence and message-waiting: PUBLISH is taken only from authenticated
  users for their own address, unless your app decides otherwise or you
  allow unauthenticated PUBLISH, and stored publications are capped.
- Peers watched with OPTIONS and picked by priority, turn or weight; a call
  to a group fails over on 408, 503 or a transport error. The registrar can
  keep UDP contacts open with OPTIONS.
- A guard against scanners, unwanted networks and floods, with rules on any
  header and per transport; a dropped source costs no memory.
- The proxy follows redirects within limits and can drop a silent branch
  early.
- Prometheus metrics for requests, responses, dialogs, registrations and
  peers, optionally on their own port.
- 1:1 NAT: a listen address can advertise a public address and show the
  local one to the networks you list.
- Start options for SIP timers, an outbound proxy or preloaded route, TCP
  keep-alives, the size past which a request goes over TCP, and node
  aliases.
- Registrations record their transport, and requests, call records and
  registrations over WebSocket say WS or WSS.
- `chappe_sip_media:publish/2,3` anchors a call with no second leg,
  `chappe_sip_media:subscribe/2` reports the tapped streams, and
  `chappe_sip:create_uac/2` takes a body that is not SDP.

### Fixed

- Security: bundled sofia-sip 1.13.19 fixes a DNS answer that froze
  outbound routing (CVE-2026-116792), memory corruption in sofia's
  WebSocket transport (CVE-2026-116791) and a multipart over-read
  (CVE-2026-110658). Its unused WebSocket and HTTP code is no longer built.
- Security: livery 0.14 and instrument 2.0 bring a hackney without its five
  published flaws and an ssl_verify_fun that matches wildcards correctly.
- Security: digest authentication refuses a request whose Request-URI was
  changed after signing; before, only user, host and port were compared.
- The SIP engine refuses NUL bytes in headers, bodies, routes and options
  instead of cutting them short, refuses a message it cannot allocate
  instead of sending it incomplete, and no longer crashes the node on a
  refused start. Three sofia-sip parser bugs are patched at build time.
- Over UDP the first retransmission ignored T1 and came after a second.
- With a separate TLS contact, the ACK of a failed re-INVITE and a CANCEL
  could be lost; they now leave from the address the request used.
- A proxy listening on two transports record-routed only one side.
- A proxy kept every late answer, so a peer could grow its memory.
- A UA with a private Contact address is now reached where its requests
  come from.
- Cancelling a request after the stack stopped crashed it, and hold missed
  media lines in an SDP with mixed line endings.
- A request handler that ended normally after answering was logged as a
  crash.

## [0.2.0]

chappe_sip moved into the chappe umbrella at this version (the umbrella's
0.1.0). The move:

Initial chappe umbrella. The SIP/media platform, previously the separate
`enki_sipserver`, `enki_rtpengine`, and `enki_esl` repositories, is consolidated
here and rebranded with the `chappe_` prefix:

- `chappe_sip` (was `enki_sipserver`) - SIP application server on sofia-sip via a
  plain-C NIF; UAS/UAC/B2BUA/proxy/registrar, WebSocket, TLS, PRACK, the
  `chappe_sip_media` control-plane facade, the media-anchoring proxy, and request
  source-IP exposure. Public API module stays `chappe_sip`.
- `chappe_rtpengine` (was `enki_rtpengine`) - rtpengine NG client. Facade module
  renamed to `chappe_rtpengine`.
- `chappe_esl` (was `enki_esl`) - FreeSWITCH ESL client. Facade module renamed to
  `chappe_esl`.

Notable in this move:
- sofia-sip is vendored (no git submodule), so the NIF builds from a clean
  clone with no network.
- Apps live in one umbrella and reference each other by name (no cross-repo git
  deps); each is published to hex independently.
- Internal module prefixes (`chappe_sip_*`, `chappe_rtpengine_*`, `chappe_esl_*`) and the public `chappe_sip`
  facade now carry the `chappe_` brand, matching their app names (they were
  `esip`/`esip_*`, `rtpe_*`, and `esl_*`).

Before the umbrella, as `enki_sipserver`:

### Added
- Media control plane (`chappe_sip_media`): a capability-based facade over the
  external media engines. rtpengine (via `chappe_rtpengine`) anchors/relays media
  with `offer/2`, `answer/2`, plus `play`, `record`, `dtmf`, `subscribe` (tap a
  party's media to an external consumer), and `duck` (block/silence a party
  while a prompt plays). FreeSWITCH (via `chappe_esl`) drives a channel over ESL
  for `conference`. The media libraries are dormant unless a `media` config is
  passed to `chappe_sip:start/1`.
- Media-anchoring proxy: `chappe_sip:proxy_request/3` gains an opt-in `media` option
  that anchors SDP through rtpengine (offer on the forwarded request, answer on
  1xx/2xx replies, release on the in-dialog BYE) while preserving the Call-ID.
  Additive: a plain proxy without the option is byte-identical to before.
- Request source address surfaced to handlers: `chappe_sip_req:source_ip/1` and
  `source_port/1`, taken from the transport peer via the NIF (the trust anchor
  for a source-IP ACL; the Via sent-by is spoofable).

### Changed
- `test/asan/run.sh` seeds the private media deps from the host so the offline
  AddressSanitizer container does not try to re-fetch them.

### Notes
- Consuming chappe_sip as a git dependency does not build its C NIF (rebar3
  does not fetch the `sofia-sip` submodule and no prebuilt binary is shipped);
  use rebar3 `_checkouts` or a vendored build until this is resolved.
  Resolved in the umbrella [0.1.0]: sofia-sip is vendored. The FreeSWITCH
  `conference` backend was later replaced by chappe_mix.

## [0.1.0]

- Baseline: RFC 3261 UAS/UAC/B2BUA/proxy/registrar over sofia-sip's `nta` via a
  plain-C NIF; SIP-over-WebSocket (RFC 7118); TLS listener; PRACK/100rel;
  RFC 3261/4475 compliance work (total parser, handling MUSTs, dialog route set,
  in-dialog CSeq).
