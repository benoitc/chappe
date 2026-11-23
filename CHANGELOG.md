# Changelog

All notable changes to the chappe umbrella and its apps, newest first. Each
app is published on its own; an entry names the app it concerns when it is
not chappe_sip. The history of chappe_sip before the umbrella (as
`enki_sipserver`) is at the end.

## Unreleased

### Before you upgrade

- All apps: use Erlang/OTP 29.1.2 or later.
- chappe_sip: replace the removed functions listed under chappe_sip, and
  call `chappe_sip_flow:ensure_secret/0` instead of
  `chappe_sip_route:ensure_secret/0`.
- chappe_sip: drop `ws`, `wss` and `*` from native and TLS contacts, fix
  invalid start options, and keep the message size limit between 1 KiB and
  64 MiB, or the start fails.
- chappe_sip: reload the SIP engine library with `chappe_sip_nif:replace/0`
  while the stack is stopped.
- chappe_sip: build the registrar with `chappe_sip:registrar/1`, and give it
  `auth` or set `allow_unauthenticated => true`, or it fails to start.
- chappe_sip: remove `freeswitch` from the `chappe_sip_media` configuration;
  run conferences on chappe_mix and drive FreeSWITCH through chappe_mrf.
- chappe_esl: give the outbound listener its address and allowed networks
  when FreeSWITCH runs on another host, and stop calling
  `chappe_esl_outbound_sup:start_conn/2`.
- chappe_rtpengine: call the session media commands on
  `chappe_rtpengine_cmd` instead of `chappe_rtpengine_session`.

### chappe_sip

#### Breaking

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

#### New

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

#### Fixed

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

### chappe_audio

#### New

- A new app. It receives the audio FreeSWITCH forks over WebSocket (from
  mod_audio_fork or mod_audio_stream), checks the path and a token, and
  hands each stream to your process. A listener can sit under your own
  supervisor.
- A recording store: WAV files with JSON metadata by default, or your own
  store. Recordings in progress are hidden, a call's recordings are found by
  its reference from any node, and old ones are swept, on one node for a
  shared store.
- The RTP and SRTP receiver used by the SIPREC recording server. It follows
  a sender that moves mid-stream and can take part in RTCP (off by
  default), with its departures from RFC 3550 listed in the compliance
  matrix. A packet that arrives late, after its sender said goodbye, is
  counted against that sender instead of restarting its statistics, while
  a sender that keeps sending new audio is heard again at once.

### chappe_mix

#### New

- A new app: a G.711 RTP conference mixer in your node, one process per
  room, each party hearing everyone but itself, with gain control, RFC 4733
  digits, talker events and leg roles. rtpengine in front handles SRTP and
  transcoding.
- A room owned by a conference process outlives its first caller, and
  parties can be moved between rooms safely.
- A tap hands the decoded audio of a party or the room to a process.
- Legs carry the call's reference in their events.
- A late packet from a party that has just said goodbye is not mixed back
  in, while a party that goes on sending, as some phones do on hold and
  unhold, is heard again at once.

### chappe_mrf

#### New

- A new app, a media resource function in the drachtio-fsmrf style: answer
  a caller with a FreeSWITCH endpoint you drive from Erlang, move it to a
  phone or another endpoint unnoticed, and put it in a conference on
  chappe_mix or FreeSWITCH, with mute, kick, lock, PIN and talker events.
  The channel hangs up when its owner dies. Its event socket listener
  listens on 127.0.0.1 unless you set an address and the networks
  FreeSWITCH connects from.
- Endpoints: playback results (duration, how it ended, missing files as
  errors), offsets and time limits, digit terminators and invalid digits,
  mute, variables, asynchronous applications, events to the owner, mod_say,
  text to speech, and tone and fax detection.
- Forks can be named, stereo, paused, resumed and sent text.
- Conferences: record a native room through SIPREC or a FreeSWITCH room
  into the store, set member limits and flags, move members between rooms,
  join a caller not yet answered, and add, remove or transfer members by
  REFER on both backends. Backends are a documented behaviour you can add
  to.
- Rooms across nodes with chappe_cluster: one room per name, moved to a live
  node when its node stops cleanly. After a crash, callers keep their calls
  but lose the room audio until the next caller reopens it. FreeSWITCH rooms
  do not move.
- Endpoints and rooms carry the call's reference in their events.

### chappe_esl

#### Breaking

- The outbound listener listens on 127.0.0.1 only unless you give it an
  address; before, anyone who connected got a call. Give it the networks
  FreeSWITCH connects from when it runs on another host.
- Removed: `chappe_esl_outbound_sup:start_conn/2`.

#### New

- Call control: drive a FreeSWITCH call step by step, each command waiting
  for completion, with prompts, digits, recording, audio streams to a
  WebSocket, timeouts, and hang-up when the owner dies. Your call process
  also hears `linger` and `disconnect` as the channel winds down. A slow
  command does not hold up timeouts or other callers; use bgapi if you need
  FreeSWITCH events meanwhile.
- Audio forks through mod_audio_fork or mod_audio_stream (v1.1.0 or
  newer). A stereo mod_audio_stream fork sends nothing unless both
  directions carry audio; fork in mono or mixed if that matters.
- A node registry: several FreeSWITCH nodes kept connected and health
  checked, picked by sessions, idle CPU or weight, drained on demand, with
  up and down notices.
- The outbound listener takes an IPv4 or IPv6 address, a backlog and an
  allow list, and closes peers that send nothing in time or pile up.
- Commands for one channel's events, dropping subscriptions, and sending a
  message or event with a body.
- Call control carries the call's reference in its events.

#### Fixed

- The outbound listener ignored the backlog you passed.
- A command on a closed or refused connection crashed the caller.

### chappe_rtpengine

#### Breaking

- The session media commands moved from `chappe_rtpengine_session` to
  `chappe_rtpengine_cmd`, with the same names and arguments.

#### New

- List a node's calls, read its statistics, and start and stop forwarding.
- `publish` on sessions and nodes anchors a call with no second leg.
- `chappe_rtpengine_sdp:streams/1` and `fork_answer/2,3` answer a
  subscription with one chosen stream.
- Sessions carry the call's reference in their events.

#### Fixed

- Security: only a UDP reply from the node asked is accepted, and request
  cookies are unguessable.
- Re-adding a node left extra health checks that could mark it down.
- Over TCP, a reply arriving in many small pieces used CPU out of
  proportion to its size and could stall other requests.
- On erlang_ws 0.5.0, a reply sent with the WebSocket upgrade is no longer
  lost.

### chappe_cluster

#### New

- A new app that lets chappe nodes agree on one owner for anything that
  must not run twice (a room, a registration, a trunk pinger), share a small
  key-value store, and run a job on exactly one node. With most nodes
  unreachable nothing new is claimed, calls already up are never touched,
  and node clocks need not agree.

### Umbrella and tooling

#### Breaking

- Every app needs Erlang/OTP 29.1.2 or later: earlier OTP 29 releases let a
  TLS 1.3 server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).

#### New

- `make demo` runs a small SBC with a registrar, a WebRTC page and an IVR on
  2000; `make demo-cluster` runs three nodes sharing a registrar, a room
  and a trunk pinger.
- Interop labs against real rtpengine, FreeSWITCH and Kamailio run in CI
  and by hand (`make interop`, `interop-sbc`, `interop-esl`, `interop-mrf`).

## [0.1.0]

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

## chappe_sip before the umbrella

These releases of chappe_sip predate the umbrella; they were merged here
from `apps/chappe_sip/CHANGELOG.md`. Their content is part of the [0.1.0]
umbrella release above, and the chappe_sip app still carries version 0.2.0.

### chappe_sip [0.2.0]

#### Added
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

#### Changed
- `test/asan/run.sh` seeds the private media deps from the host so the offline
  AddressSanitizer container does not try to re-fetch them.

#### Notes
- Consuming chappe_sip as a git dependency does not build its C NIF (rebar3
  does not fetch the `sofia-sip` submodule and no prebuilt binary is shipped);
  use rebar3 `_checkouts` or a vendored build until this is resolved.
  Resolved in the umbrella [0.1.0]: sofia-sip is vendored. The FreeSWITCH
  `conference` backend was later replaced by chappe_mix.

### chappe_sip [0.1.0]

- Baseline: RFC 3261 UAS/UAC/B2BUA/proxy/registrar over sofia-sip's `nta` via a
  plain-C NIF; SIP-over-WebSocket (RFC 7118); TLS listener; PRACK/100rel;
  RFC 3261/4475 compliance work (total parser, handling MUSTs, dialog route set,
  in-dialog CSeq).
