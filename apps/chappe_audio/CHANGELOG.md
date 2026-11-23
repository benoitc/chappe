# Changelog

All notable changes to chappe_audio, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

- Needs Erlang/OTP 29.1.2 or later: earlier OTP 29 releases let a TLS 1.3
  server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
- A new app. It receives the audio FreeSWITCH forks over WebSocket (from
  mod_audio_fork or mod_audio_stream), checks the path and a token, and
  hands each stream to your process. A listener can sit under your own
  supervisor.
- A recording store: WAV files with JSON metadata by default, or your own
  store. Recordings in progress are hidden, a call's recordings are found by
  its reference from any node, and old ones are swept, on one node for a
  shared store.
- The RTP and SRTP receiver used by the SIPREC recording server. It follows
  a sender that moves mid-stream and can take part in RTCP (off by
  default), with its departures from RFC 3550 listed in the compliance
  matrix. A packet that arrives late, after its sender said goodbye, is
  counted against that sender instead of restarting its statistics, while
  a sender that keeps sending new audio is heard again at once.
