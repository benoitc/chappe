# Changelog

All notable changes to chappe_esl, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### Before you upgrade

- Use Erlang/OTP 29.1.2 or later.
- Give the outbound listener its address and allowed networks
  when FreeSWITCH runs on another host, and stop calling
  `chappe_esl_outbound_sup:start_conn/2`.

### Breaking

- Erlang/OTP 29.1.2 or later is required: earlier OTP 29 releases let a
  TLS 1.3 server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
- The outbound listener listens on 127.0.0.1 only unless you give it an
  address; before, anyone who connected got a call. Give it the networks
  FreeSWITCH connects from when it runs on another host.
- Removed: `chappe_esl_outbound_sup:start_conn/2`.

### New

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

### Fixed

- The outbound listener ignored the backlog you passed.
- A command on a closed or refused connection crashed the caller.

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
