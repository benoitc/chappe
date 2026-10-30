# Changelog

## Unreleased

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
