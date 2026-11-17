# 0012: A SIPREC recording server: SIP in chappe_sip, audio in chappe_audio

This record explains why chappe's SIPREC recording server (SRS, RFC 7866)
is split in two: the SIP session in chappe_sip, the recorded RTP in
chappe_audio. It is the rule "SIP processes carry no media" applied to the
one place where chappe receives media itself. Read it before you add a
feature that would make a SIP process open a media socket.

## Status

Accepted (the maintainer's decision, 2026-11-17).

## Context

What the repository shows:

- `README.md`: "RTP never flows through a SIP process: SIPREC audio is
  taken in by chappe_audio."
- [0004](0004-rtpengine-external.md): the SIP processes never touch RTP; it
  stays in rtpengine and in the chappe_mix rooms.
- `chappe_sip_siprec_srs` (`apps/chappe_sip/src/siprec/`) runs in the
  INVITE handler. It checks the INVITE is a recording session, reads its SDP
  and metadata, and starts one receiver per recorded stream through
  `chappe_audio:rtp_receiver/1` (`take/7`, then the `receiver/9`
  function). Each receiver is a `chappe_audio_rtp` process, SRTP through
  `chappe_audio_srtp` ([0009](0009-srtp-in-erlang.md)).
- Without chappe_audio running, `answer/6` finds no
  `chappe_audio_rtp_sup`, logs `siprec_srs_chappe_audio_not_running`,
  refuses every stream (488 when none is left) and returns
  `{error, no_audio}`.
- chappe_audio is an optional application of chappe_sip
  (`optional_applications` in `apps/chappe_sip/src/chappe_sip.app.src`).
- The CHANGELOG, "Unreleased": "the SIPREC recording server now takes its
  audio in through chappe_audio, so chappe_sip itself never handles
  media", and the receiver modules moved out of chappe_sip (#41).

## Decision

- The SRS's SIP side (the INVITE, the offer and answer, re-INVITEs, the
  metadata, the BYE) is in chappe_sip.
- Every recorded stream's RTP is received, decrypted and decoded in
  chappe_audio, by a process chappe_audio supervises.
- No process of chappe_sip opens a media socket. A future feature that
  needs to receive media follows the same split.

## Consequences

- To record with SIPREC, you run chappe_audio next to chappe_sip. Without
  it, a recording session is refused with 488 and the rest of chappe_sip
  runs as before.
- A crash of the store never drops a live recorded stream, since the
  receivers are supervised apart ([0011](0011-chappe-audio-leaf.md)).
- The SIP side holds the stream pids and hands them a new key on a
  re-INVITE (`chappe_audio_rtp:rekey/2`), so the two sides talk by message
  only.

## Open questions

None.
