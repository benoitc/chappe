# Changelog

All notable changes to chappe_rtpengine, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### Before you upgrade

- Use Erlang/OTP 29.1.2 or later.
- Call the session media commands on
  `chappe_rtpengine_cmd` instead of `chappe_rtpengine_session`.

### Breaking

- Erlang/OTP 29.1.2 or later is required: earlier OTP 29 releases let a
  TLS 1.3 server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
- The session media commands moved from `chappe_rtpengine_session` to
  `chappe_rtpengine_cmd`, with the same names and arguments.

### New

- List a node's calls, read its statistics, and start and stop forwarding.
- `publish` on sessions and nodes anchors a call with no second leg.
- `chappe_rtpengine_sdp:streams/1` and `fork_answer/2,3` answer a
  subscription with one chosen stream.
- Sessions carry the call's reference in their events.

### Fixed

- Security: only a UDP reply from the node asked is accepted, and request
  cookies are unguessable.
- Re-adding a node left extra health checks that could mark it down.
- Over TCP, a reply arriving in many small pieces used CPU out of
  proportion to its size and could stall other requests.
- On erlang_ws 0.5.0, a reply sent with the WebSocket upgrade is no longer
  lost.

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
