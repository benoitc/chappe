# Changelog

All notable changes to chappe_mix, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

- HD rooms: a room can mix at 16 kHz instead of 8 kHz, so callers on
  G.722 or Opus keep the band above 3.4 kHz. The mixer then exchanges
  16-bit linear audio (L16) with rtpengine, which converts each caller's
  codec to it and back. rtpengine needs the L16 codec: the labs test
  26.3.1.4, 11.5 (Ubuntu 24.04's package) has none, and upstream releases
  have it from 13.4.1.1 on. Taps of such a room carry
  16 kHz audio, and DTMF events use the 16 kHz clock.
- A room's statistics, leg list and taps report its rate.

### Changed

- A room's rate is fixed when it starts: a leg cannot move to a room of
  another rate, and a G.711 leg cannot join a 16 kHz room directly
  (rtpengine converts it). An 8 kHz room mixes exactly as before.

### Breaking

- An 8 kHz room refuses a leg that names a payload type: G.711 always
  goes on its standard one. Before, the setting was ignored.
- A leg whose DTMF payload type is its audio payload type is refused, when
  it opens and when its far end changes. Before, every such packet was
  taken as audio and the digits were lost.

### Fixed

- A room given an `ssrc_draw` function that only returned SSRCs already
  in use hung when a leg joined or an SSRC collided: it asked for another
  one forever. It now asks 16 times, then picks a free SSRC itself.

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
