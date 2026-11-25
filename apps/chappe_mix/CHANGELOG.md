# Changelog

All notable changes to chappe_mix, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

- HD rooms: a room can mix at 16 kHz instead of 8 kHz, so callers on
  G.722 or Opus keep the band above 3.4 kHz. The mixer then exchanges
  16-bit linear audio with rtpengine, which must be 13.4 or later and
  converts each caller's codec to it and back. Taps of such a room carry
  16 kHz audio, and DTMF events use the 16 kHz clock.
- A room's statistics, leg list and taps report its rate.

### Changed

- A room's rate is fixed when it starts: a leg cannot move to a room of
  another rate, and a G.711 leg cannot join a 16 kHz room directly
  (rtpengine converts it). An 8 kHz room mixes exactly as before.

## [0.1.0] - 2026-11-23

### New

- Needs Erlang/OTP 29.1.2 or later: earlier OTP 29 releases let a TLS 1.3
  server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
- A new app: a G.711 RTP conference mixer in your node, one process per
  room, each party hearing everyone but itself, with gain control, RFC 4733
  digits, talker events and leg roles. rtpengine in front handles SRTP and
  transcoding.
- A room owned by a conference process outlives its first caller, and
  parties can be moved between rooms safely.
- A tap hands the decoded audio of a party or the room to a process.
- Legs carry the call's reference in their events.
- A late packet from a party that has just said goodbye is not mixed back
  in, while a party that goes on sending, as some phones do on hold and
  unhold, is heard again at once.
