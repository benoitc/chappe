# 0009: SRTP is decrypted in Erlang where chappe receives media itself

This record explains why chappe decrypts SRTP in Erlang at its SIPREC
recording server, and why that does not move the media boundary of
[0004](0004-rtpengine-external.md). Read it before you add SRTP to another
process that receives RTP, or before you propose sending SRTP from Erlang.

## Status

Accepted (the maintainer's decision, 2026-11-14).

## Context

What the repository shows:

- RFC 7866 12.2 says "the SRC and the SRS MUST support RTP/SAVP [RFC3711]
  and RTP/SAVPF [RFC5124]" and "At a minimum, the SRC and SRS MUST support
  the SDP security descriptions key negotiation mechanism [RFC4568]".
- chappe's recording server receives each recorded stream itself, one
  process per stream (`apps/chappe_audio/src/chappe_audio_rtp.erl`),
  with no rtpengine in front. Before this record it answered every
  `RTP/SAVP` stream with port 0, and an offer left with no stream with 488,
  so a recording client that follows 12.2 could not record to it
  (`chappe_sip_siprec_srs.erl`, moduledoc, at the merge base of this
  change).
- chappe's own recording client already offers its taps of an SRTP call as
  `RTP/SAVP`, keyed by rtpengine apart from the call's keys
  (`apps/chappe_sip/src/siprec/chappe_sip_siprec_tap.erl`, `srtp/1`).
- OTP's `crypto` application gives AES-128 in counter mode and HMAC-SHA1,
  the two primitives the SRTP suites `AES_CM_128_HMAC_SHA1_80` and `_32`
  need (RFC 3711 4.1.1, 4.2.1).
- Decision 0004 asks that SRTP, DTLS and ICE for media chappe relays stay in
  rtpengine, and left "SRTP/DTLS/ICE out of scope for Erlang?" open.

## Decision

chappe may decrypt SRTP in Erlang where it receives media itself and is the
media's last stop. Today that is the SIPREC recording server only:

- receive only for media: chappe never encrypts or sends SRTP. The one
  thing it protects is the receiver's own RTCP reports (RFC 7866 8.1.1
  requires RTCP), as SRTCP with the key of its SDP answer
  (`chappe_audio_srtp:protect_rtcp/2`, added 2026-11-19);
- SDES keys only (RFC 4568 `a=crypto`, `inline` key method), suites
  `AES_CM_128_HMAC_SHA1_80` and `AES_CM_128_HMAC_SHA1_32`, through OTP
  `crypto` (`apps/chappe_audio/src/chappe_audio_srtp.erl`);
- no DTLS-SRTP, no MIKEY, no other cipher.

rtpengine stays in charge of every stream chappe relays, anchors, forks or
mixes: encryption, decryption toward another leg, DTLS and ICE stay there,
as 0004 decides. What changes in 0004 is its open question, answered here:
SRTP decryption is in scope for Erlang at a terminating receiver, and the
rest stays out.

## Consequences

- An SRS deployment needs no rtpengine on the receive side, and a
  recording client that follows RFC 7866 12.2 records to chappe as it is.
- chappe now holds SRTP master keys in the stream process. They never go
  to a log, an error term or a crash report (the module keeps them in a
  closure, and the stream's `format_status/1` drops them).
- Per stream, the receiver keeps a bounded number of SSRC contexts and a
  fixed replay window; forged and replayed packets are dropped and counted,
  and logged once per window, never once per packet.
- Another receiving process that wants SRTP reuses `chappe_audio_srtp`; a
  process that relays media keeps going through rtpengine.

## Open questions

- Answered: the SRS refuses SDES keys that arrive over a transport that is
  not encrypted (RFC 4568 8.3), unless the app passes
  `keys_over_tls => false` for a network it trusts.
- DTLS-SRTP at the SRS (a WebRTC recording client) would need DTLS in
  Erlang (OTP `ssl` has DTLS, not the `use_srtp` extension).
