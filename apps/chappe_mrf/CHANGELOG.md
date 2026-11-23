# Changelog

All notable changes to chappe_mrf, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### New

- A new app, a media resource function in the drachtio-fsmrf style: answer
  a caller with a FreeSWITCH endpoint you drive from Erlang, move it to a
  phone or another endpoint unnoticed, and put it in a conference on
  chappe_mix or FreeSWITCH, with mute, kick, lock, PIN and talker events.
  The channel hangs up when its owner dies. Its event socket listener
  listens on 127.0.0.1 unless you set an address and the networks
  FreeSWITCH connects from.
- Endpoints: playback results (duration, how it ended, missing files as
  errors), offsets and time limits, digit terminators and invalid digits,
  mute, variables, asynchronous applications, events to the owner, mod_say,
  text to speech, and tone and fax detection.
- Forks can be named, stereo, paused, resumed and sent text.
- Conferences: record a native room through SIPREC or a FreeSWITCH room
  into the store, set member limits and flags, move members between rooms,
  join a caller not yet answered, and add, remove or transfer members by
  REFER on both backends. Backends are a documented behaviour you can add
  to.
- Rooms across nodes with chappe_cluster: one room per name, moved to a live
  node when its node stops cleanly. After a crash, callers keep their calls
  but lose the room audio until the next caller reopens it. FreeSWITCH rooms
  do not move.
- Endpoints and rooms carry the call's reference in their events.
