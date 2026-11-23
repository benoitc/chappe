# Changelog

All notable changes to chappe_mix, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

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
