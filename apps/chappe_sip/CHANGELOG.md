# Changelog

All notable changes to chappe_sip. Format loosely follows Keep a Changelog;
this project uses OTP 29 and semantic-ish versioning while pre-1.0.

## [0.2.0]

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

## [0.1.0]

- Baseline: RFC 3261 UAS/UAC/B2BUA/proxy/registrar over sofia-sip's `nta` via a
  plain-C NIF; SIP-over-WebSocket (RFC 7118); TLS listener; PRACK/100rel;
  RFC 3261/4475 compliance work (total parser, handling MUSTs, dialog route set,
  in-dialog CSeq).
