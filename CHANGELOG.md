# Changelog

All notable changes to the chappe umbrella and its apps, newest first. Each
app is published on its own; an entry names the app it concerns when it is
not chappe_sip. The history of chappe_sip before the umbrella (as
`enki_sipserver`) is at the end.

## Unreleased

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
