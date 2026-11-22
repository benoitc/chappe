# Compliance catalogue

`requirements.tsv` lists the RTP, RTCP and SRTP rules the RTP receiver of
chappe_audio meets, one row each: the receiver the SIPREC recording server
of chappe_sip uses. How rows are written, claimed in a test with a
`%% req:` line and turned into the generated [matrix](../compliance.md) is
the same for every app: see the shared
[compliance page](../../../../docs/contributing/compliance.md). This page
only keeps what is specific to chappe_audio.

## What is specific here

- ids are `R<rfc>-<section>-<n>` (`R3550-6.1-1`), stable; never renumber.
- `source` is RFC 3550, 3711, 5761 or 7866. The SIP side of SIPREC is in
  the chappe_sip catalogue; this one holds only what the receiver does with
  the media.
- `actor` is `rtp-receiver`, or `srs` for an RFC 7866 media rule.
- `row` is `rtcp` or `srtp`. Every row is tier `platform`, `n/a` or
  `deviation`: the receiver only receives, so the sender rules of RFC 3550
  are `n/a`, and its RFC 3550 departures are `deviation` rows, listed with
  their reason in the [Deviations](../compliance.md#deviations) section.
- Claims come from `chappe_audio_rtp_SUITE` (the receiver on real sockets),
  `chappe_audio_rtcp_tests` (the pure RTCP packets and statistics) and
  `chappe_audio_srtp_tests` (SRTCP).
