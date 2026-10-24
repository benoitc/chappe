# Changelog

## Unreleased

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
