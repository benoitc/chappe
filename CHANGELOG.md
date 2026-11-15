# Changelog

All notable changes to the chappe umbrella and its apps, newest first. Each
app is published on its own; an entry names the app it concerns when it is
not chappe_sip. The history of chappe_sip before the umbrella (as
`enki_sipserver`) is at the end.

## Unreleased

- chappe_esl, a breaking change: the outbound listener now listens on
  127.0.0.1 only, unless you give it an address. Before, it listened on
  every interface and gave a call to anyone who connected. When FreeSWITCH
  runs on another host, give the listener the address to listen on and the
  networks FreeSWITCH connects from; a peer outside them is closed at once.
  The listener also closes a connection that does not send its channel data
  in time, and new ones past a limit while others still wait, so a peer
  that opens connections and sends nothing can no longer pile them up.
- chappe_mrf, a breaking change that follows: its event socket listener
  listens on 127.0.0.1 only by default. When FreeSWITCH runs on another
  host, set the address to listen on and the networks FreeSWITCH connects
  from in chappe_mrf's configuration, or FreeSWITCH can no longer reach it.
- chappe_esl and chappe_mrf: the fork docs now say that a stereo
  mod_audio_stream fork sends nothing unless both directions carry audio,
  and to fork in mono or mixed instead when you need the caller's audio
  whatever the other side does.
- SIPREC recording server, a change of behaviour: an offer with no stream
  the server can take is now refused with 488 and a warning that says why,
  and serving it returns an error. Before, unless the streams were SRTP, it
  was accepted with every stream turned down, leaving your app to hang up an
  empty session. An app that relied on that empty session must handle the
  error instead.
- chappe_audio: a listener can now be put under your own supervisor, so it
  is restarted on its port when it dies and lives as long as your app.
  Before, a listener that crashed stayed down.
- SIPREC recording server: the declared result of serving a session left
  out keys it really returns, so dialyzer told an app calling it that the
  success case could never happen. It now describes the session as it is.
- SIPREC recording server: the ports its receivers bind can now be limited
  to a range, per server or for the whole node. Before, each stream took a
  random port, so a recording client could not reach a server running in a
  container that publishes only a range.
- chappe_audio, a new app: it receives the audio FreeSWITCH forks over a
  WebSocket, from mod_audio_fork or mod_audio_stream, checks the path and a
  token, and hands each stream to a process of yours, with a bound on what
  waits for it. Before, you had to write this listener yourself.
- Recording store: chappe now ships a default store for recordings, a folder
  of WAV files with a JSON file next to each naming the call, the parties
  and the source. A recording in progress is never listed, a call's
  recordings are found by its reference from any node, and old ones can be
  swept. You choose the folder, or plug in your own store. Forks, FreeSWITCH
  recordings, conference recordings and SIPREC sessions can all land there.
- SIPREC recording server: with the default store, each recorded stream is
  now written to the recording store, so a call recorded to chappe is found
  next to its other recordings. chappe_audio must run on that node.
- chappe_mrf conferences: a native room can now be recorded, its mix sent
  through SIPREC to the recording server you name. A FreeSWITCH room can be
  recorded too, into the store. Rooms take a member limit and flags, report
  mute, digits and finished prompts, and a member can be moved to another
  room. Before, only the FreeSWITCH backend could record and nothing moved
  a member.
- chappe_mrf conferences: a member can now transfer itself out of a room by
  REFER, blind or attended, and a party can be added to or removed from a
  room by REFER, on both backends. FreeSWITCH does not handle REFER in a
  conference, so chappe does.
- chappe_mrf playback: playing a missing file is now an error, you can learn
  how long a prompt played and how it ended, digit collection can return the
  terminator and the invalid digits, and a prompt can start at an offset and
  stop after a time limit. Before, the result of a prompt was dropped.
- chappe_mrf endpoints: the owner can now ask for playback start and stop,
  custom and channel events. Endpoints can be muted and unmuted, their
  variables read, several variables set at once or exported, and an
  application run without waiting for it.
- chappe_mrf audio forks: a fork can now be named, sent in stereo, paused,
  resumed and sent text, on both fork modules where the module allows it.
- chappe_mrf speech and detection: endpoints can now say numbers and dates
  with mod_say, speak text with a text to speech module, and detect tones
  and faxes, with events to the owner. The FreeSWITCH lab image now builds
  mod_flite for this.
- chappe_mix: a tap now hands the decoded audio of a party or of the whole
  room to a process, for calls that never touch FreeSWITCH.
- chappe_rtpengine: you can now list the calls of a node, read its
  statistics, and start and stop forwarding a call's media.
- Call correlation in the media apps: endpoints, FreeSWITCH call control,
  rtpengine sessions and mixer legs now carry the call's reference and
  return it in their events, so one call is followed across all of them.

- B2BUA: an anchored call no longer strips encryption from a caller that
  offers encrypted media (SRTP with keys in the SDP). Before, the caller was
  answered with plain media unless your app asked otherwise; now each leg is
  answered in the media profile it used itself, encrypted or not, and your
  app can still choose another.
- SIPREC: chappe's recording server now takes encrypted media (SRTP with
  keys in the SDP), as the SIPREC standard requires, and decrypts it itself.
  Before, it refused every encrypted stream, so a recording client that
  encrypts its media, chappe's own client on an encrypted call included,
  could not record to it without an rtpengine in front. Forged and replayed
  packets are dropped and counted. The keys must reach the server over TLS:
  an encrypted stream offered over plain SIP is refused, unless you tell the
  server your network is trusted.
- Call correlation: each call now gets one reference, carried on every leg it
  creates, in every call record and in the capture sent to Homer. You can give
  your own, for example one coming from upstream, and find the processes
  serving a call from any node of the cluster. Before, each part had its own
  id and following one call across legs, records and capture took guesswork.
- B2BUA: your application now hears when the outgoing leg sends its INVITE,
  gets a provisional answer or an early dialog, so it learns that leg's
  Call-ID and can cancel it while it rings. Before, these events were dropped.
- B2BUA: you can now add headers to the answer sent back to the caller,
  follow redirects on the outgoing leg and keep the original request URI
  when you do, and compute the outgoing offer, the credentials and the
  answer of a call you take yourself from a function.
- Middleware can now hand data to the request handler with the request it
  passes on. Middleware written for the earlier form keeps working.
- Dialogs now tell their owner of hold, unhold, session refreshes and
  in-dialog PUBLISH, and you can follow every dialog's state as it changes.
- Transfers: the B2BUA can now carry out a blind or attended transfer
  itself, on either leg, including on calls bridged to FreeSWITCH, which
  never sees the REFER. Every transfer goes through your policy; without
  one, a transfer to another network is refused, and a call takes a bounded
  number of transfers. Your application can also decide each transfer
  itself. A REFER to a conference focus can add or remove a participant.
  Before, the B2BUA refused every REFER unless your application took it.
- Call recording: chappe can now record a call or a native conference room
  to a SIPREC recording server, with pause, resume and the party changes
  sent as they happen, and can act as a recording server itself, handing
  each stream and its metadata to your application.
- Deployment behind 1:1 NAT: a listen address can now advertise a public
  address while bound to the local one, and show the local address to the
  networks you list. A provisional answer relayed by the B2BUA now carries
  the address the caller should reach, local or public.
- New start options: the SIP timers, an outbound proxy or a preloaded route,
  a keep-alive ping on idle TCP connections, the size past which a request
  goes over TCP, and other names of the node. Each is checked when the stack
  starts. The keep-alive does not reach TLS connections.
- Edge protection: guard rules can now match any header, not only the
  User-Agent, and act per transport, for example a silent drop on TCP and a
  403 on UDP.
- Proxy: redirects can now be followed, within limits you set, and a branch
  that stays silent or never answers can be dropped before the call-wide
  timer.
- Metrics: chappe_sip can now serve its metrics on a port of its own, with
  no web server of yours.
- Fixed: with several listen addresses, the ACK of a failed re-INVITE, and a
  CANCEL, could be lost, because the engine handed the SIP stack an address
  it then freed. They now always go out from the address the request left
  from.
- Fixed: over UDP the first retransmission of a request came a full second
  after it, whatever the T1 timer, so a request got fewer retransmissions
  than the RFC asks before it timed out. It now comes after T1.
- Fixed: a proxy listening on two addresses or transports record-routed the
  call once, so requests later in the call could reach it on the wrong side.
  It now adds one entry per side.
- Fixed: the call record of a proxied, record-routed call could miss a BYE
  that came right after the answer.
- Fixed: the proxy's handling of late answers after a call is set up now
  runs supervised and remembers a bounded number of them, so a downstream
  element sending answer after answer can no longer grow its memory.
- B2BUA: a call relayed in the background now runs supervised, and is hung
  up when the owner you name for it dies. Without one it runs until a party
  hangs up, as before.

- B2BUA and chappe_mrf: when you move a call to a new callee, you can now say
  who that callee sees as calling. Before, a phone rung after an IVR menu
  showed the PBX instead of the real caller. A malformed value is refused and
  the call goes on.
- B2BUA security: the caller identity you set when starting a call was sent
  unchecked, so an application building it from untrusted text, such as a
  caller's display name, could let that text add SIP headers to the outgoing
  call. It is now checked first: a bad value is never sent, the caller hears a
  500 and you get an error back. An application that chose to answer failures
  itself still does so here.
- chappe_esl call control: a slow api or audio fork command no longer stalls
  the call. While it waits, exec timeouts fire, other callers get answers, and
  if your process dies the fork stops and the channel is killed. Before, all of
  that waited up to 10 seconds. FreeSWITCH itself still holds back a connection's
  events during a slow api, so send slow commands with bgapi if you need a hangup
  or a digit meanwhile.
- chappe_esl call control: your process now hears `linger` when the channel hung
  up and its final events are still coming, and `disconnect` when FreeSWITCH has
  nothing more to send. Before, these notices were dropped and you only learned
  when the socket closed. A process that handles call messages with a closed set
  of cases must accept the two new ones.
- chappe_rtpengine: moved to erlang_ws 0.5.0. A reply the server sent together
  with its websocket upgrade response used to be lost; it now arrives. The
  websocket transport of chappe_sip moves to the same version.
- chappe_esl lab: mod_audio_stream is now v1.1.0. Earlier versions fail against a
  websocket server sending lowercase header names, so use v1.1.0 or newer on your
  nodes.
- B2BUA and chappe_mrf: moving a call to a new callee can now ring several
  destinations at once, so a caller coming out of an IVR reaches a user's
  desk phone and browser together. The first to answer takes the call and you
  learn which one it was. When nobody answers, the caller stays where it was
  and you can try again. Before, a call could only move to one destination.
  A failed move to a destination on another network no longer risks leaving
  the party the caller stays with unable to hear the caller.
- chappe_esl call control: an audio fork can now go through
  mod_audio_stream as well as mod_audio_fork. The call remembers which one
  started the fork, so stopping it, or the cleanup when your process dies,
  sends the right stop. Before, only mod_audio_fork was spoken and a
  mod_audio_stream fork kept running after the owner died.
- chappe_esl outbound listener: you can now choose the address it listens
  on, IPv4 or IPv6, and the length of its pending connection queue. Before,
  it always listened on every interface and the queue length you passed was
  ignored. A bad address or length is refused when you start the listener.
- SIP engine safety: the C part of the SIP stack now checks everything it is
  handed. A header, body, route or option holding a NUL byte is refused
  instead of being cut short, an invalid start option fails the start
  instead of being ignored, and the message size limit must be between
  1 KiB and 64 MiB. A message the engine has no memory for is refused with
  an error instead of going out with fields missing, events it could not
  deliver are counted in the engine stats, and a refused start no longer
  crashes the node. Three bugs in the bundled sofia-sip are fixed by small
  patches applied at build time: a URL byte that could skip the escaping
  check, a null pointer read while writing out a message, and a read past
  the end of a URL whose last parameter has a known name but no value.
- B2BUA forking: each destination of a fork or a list can now carry its own
  flow, extra headers and rtpengine flags, so a call to a user can ring a
  browser and a desk phone together with the right media for each. The call
  result also tells you which destination answered.
- B2BUA hunting: when your app tries targets one after another and an early
  one already made the caller ring, the target that answers now keeps the
  same dialog. Before, the caller's hang-up got no answer.
- Registrar: every binding of a user now says which flow reaches it, NAT
  included, so a call can ring all of a user's devices, not only the first.
- Conferences (chappe_mrf): a caller you have not answered yet can join a
  native room directly; you no longer need to answer it with a placeholder
  call first.
- Security: a presence publisher can no longer change another user's state.
  An authenticated user may publish only its own address unless your app
  decides otherwise, and a server set up without authentication now refuses
  every PUBLISH unless you say it may take them unauthenticated. Stored
  publications are capped in number, per address and in size, so a flood of
  publications cannot fill memory.
- Conferences: moving a participant between two rooms can no longer freeze
  or crash them, even when two moves cross, the target room is gone, or the
  source and target are the same room.
- rtpengine over TCP: a reply arriving in many small pieces no longer burns
  CPU out of proportion to its size, so a slow or hostile node cannot stall
  the other requests on that connection.
- rtpengine nodes: removing and adding a node again no longer leaves extra
  health checks running, and a check started for the old node can no longer
  mark the new one down.
- Security: digest authentication now refuses a request whose Request-URI
  was changed after it was signed, for example with a parameter or header
  added that could reroute it. Before, only the user, host and port were
  compared.
- Security: chappe_rtpengine only accepts a UDP reply from the rtpengine
  node it asked, and its request cookies are now unguessable. Before, a
  forged reply from any address carrying a live cookie was accepted. UDP to
  rtpengine still belongs on a trusted network.
- New: `chappe_mrf`, a media resource function in the drachtio-fsmrf style.
  A caller can be answered by a FreeSWITCH endpoint you drive from Erlang
  (play a menu, collect digits, record, stream the audio), moved to a phone
  or another endpoint without noticing, and put in a conference that runs
  on chappe_mix or on FreeSWITCH, with mute, kick, lock, PIN and talker
  events. The channel is hung up when the process that owns it dies.
- B2BUA: a call can run in a process of its own, so the process that set it
  up can drive a media server meanwhile.
- B2BUA: moving a call to a new callee now works with a real rtpengine:
  before, the caller stopped hearing the new callee (rtpengine had moved
  the caller to ports it never learned), and the new callee could be sent
  to ports rtpengine was not listening on. The new callee can also sit on
  another network than the old one.
- Conferences on chappe_mix can now outlive their first caller: a room
  owned by a conference process stays up between callers.
- Demo: dial 2000 for an IVR that calls bob, echoes you, puts you in a
  conference (on chappe_mix, or on FreeSWITCH with a PIN) or records a
  message and plays it back. FreeSWITCH hang-ups now reach the caller in the
  demo.
- CI: an `mrf-interop` job runs chappe_mrf against rtpengine and two real
  FreeSWITCH nodes, including a node stopped mid-call.
- B2BUA: a call can ring all of a user's devices at once; the first to answer
  takes the call and the others stop ringing.
- B2BUA: an app can now take over every failure itself, including a callee
  that never answers, and try the next target without the caller noticing.
- B2BUA: an app can end a call with a reason, receive transfers, INFO and
  MESSAGE requests from either side, and forward INFO (DTMF) to the other
  side.
- B2BUA: an anchored call can be moved to another callee, or to a media
  server, without the caller seeing anything.
- New: chappe can register to a carrier or registrar and keep the
  registration alive, without being challenged again on every refresh.
- New: a guard that refuses SIP scanners, unwanted networks and floods. A
  dropped source costs no memory, even under a flood.
- New: Prometheus metrics for requests, responses, dialogs, registrations and
  peers.
- Registrar: each registration now records its transport.
- A request handler that ends normally after answering is no longer logged as
  a crash.
- `chappe_esl`: you can now drive a FreeSWITCH call step by step. Each
  command waits until FreeSWITCH has finished it, so you can play a prompt,
  collect digits, record, or stream the call's audio to a WebSocket, and you
  are told about digits and hang-ups. A command that takes too long is
  stopped instead of finishing later, file paths with spaces work, and a call
  whose controlling process dies is cleaned up and hung up.
- `chappe_esl` is back in the umbrella. It can now register several
  FreeSWITCH nodes, keep each one connected (reconnecting with a growing
  delay), watch its health with heartbeats and periodic checks, report its
  load, and pick a node for a new call by fewest sessions, most idle CPU or
  weight, skipping nodes that are down, drained or full. You can drain a
  node, run commands on it, and be told when it goes up or down.
- `chappe_esl`: commands to receive only one channel's events, to drop event
  subscriptions, and to send a message or an event with a body.
- `chappe_esl`: a command on a connection that is already closed now returns
  an error instead of crashing the caller, and a refused connection no longer
  takes the caller down with it.
- CI: an `esl-interop` job runs the ESL suite against two real FreeSWITCH
  nodes, including a node stopped and started during the run.
- B2BUA: the SDP hook now tells an offer from an answer, so an app can rewrite
  or refuse each one; the older two-argument hook keeps working.
- B2BUA: calls can be anchored in rtpengine with one option, for the whole
  call: every re-offer from either side goes through it, and a refused
  re-offer no longer leaves rtpengine stuck. A new helper decides direct or
  anchored per call (WebRTC, NAT, private networks), and a live call can move
  between the two.
- B2BUA: a re-INVITE without an offer now reaches the other side, and the
  answer in the ACK follows it; before, the leg answered it alone with a
  stale SDP. UPDATE now crosses while the callee rings. Hold and unhold reach
  the app as events.
- Peers: SIP peers can be watched with OPTIONS, picked by priority, in turn
  or by weight, and a B2BUA call to a group moves to the next live peer on
  408, 503 or a transport error. The registrar can keep UDP contacts open
  with OPTIONS and drops the ones that stop answering.
- B2BUA: an INVITE without an offer now works, the answer in the caller's
  ACK reaching the callee; anchored calls take it through rtpengine too.
- NAT: a UA whose Contact is a private address is now reached where its
  requests come from: calls to it, the requests of its calls, and the
  registrar's keepalive. Before, those went to the private address and were
  lost.
- An SBC interop lab runs real calls through the B2BUA to two FreeSWITCH
  nodes, with rtpengine and Kamailio, in CI and with `make interop-sbc`.
- `make demo` starts a small SBC to try by hand: a registrar for two users,
  a WebRTC page, and calls between them, direct or anchored.

- `chappe_rtpengine`: `publish` on sessions and nodes, the one-sided anchor for
  a call with no second leg (a recording server, a publisher). rtpengine writes
  the answer and the session goes straight to established.
- `chappe_rtpengine_sdp`: `streams/1` for a subscription offer's m-line order
  and labels, `fork_answer/2,3` to answer it with one stream (by `a=label` or
  m-line index) routed to one receiver and the rest rejected. rtpengine has no
  request-side stream selector, so the selection lives in the answer.
- `chappe_sip_media`: `publish/2,3`, and `subscribe/2` now reports the tapped
  `streams` alongside the SDP and the to-tag.
- `chappe_sip`: `create_uac/2` accepts `body` plus `content_type` for a request
  body that is not application/sdp (a SIPREC multipart/mixed, for instance).
- CI: an `interop` job runs the rtpengine-gated suites against the `interop/`
  container, so the anchor, the per-stream forks and the interpreter inject are
  verified against the real daemon on every change.

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
