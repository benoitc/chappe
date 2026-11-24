# Changelog

All notable changes to chappe_mrf, newest first. The umbrella's
[CHANGELOG](https://github.com/benoitc/chappe/blob/main/CHANGELOG.md)
says how apps are released.

## [Unreleased]

### Breaking

- A conference backend of your own must update its dial callback: it now
  receives the REFER operation it dials for, so the room can report the
  outcome to every referrer and refuse a second dial of the same party,
  and the separate dial-out callback is gone. The two backends chappe
  ships are updated.
- In a conference without focus, a member's REFER handed to the room as
  a request in its dialog is now refused: the member's call carries its
  transfer out once the room agrees. A call you answer yourself and hand
  to such a room must be made with the transfer notify mode instead.

### Fixed

- A party a REFER brings into a native conference was a member, and could
  be heard, while it was still ringing; it now joins only once it
  answers, and a party that does not answer leaves the room as it was.
- A REFER could bring a party into a locked or full FreeSWITCH
  conference; both backends now check the lock and the member limit
  before dialing, counting the parties being dialed.
- A REFER sent again for the same party dialed it a second time; it now
  hears the outcome of the first one. Asking to add someone who is
  already in answers at once.
- A REFER to a conference's address dropped the call it asked to replace
  (Replaces) and the Referred-By on the way to the party.
- Removing a member by REFER picked the first member with a matching
  address; it now takes the member the roster names, refuses an
  ambiguous request (485), never looks at other conferences, and tells a
  referrer it does not trust nothing about who is in.
- When a conference ends, the REFERs still under way now get a final
  answer (487) and their calls are given up.
- A member joining a FreeSWITCH conference now shows in its roster.
- The call a REFER asked to replace (Replaces) now reaches the party the
  conference dials: FreeSWITCH never sent it the way it was passed. A
  party's early media no longer makes it a member before it answers.
- A conference policy that fails on a REFER it did not expect no longer
  takes the conference and its calls down: the REFER is refused. The same
  holds for a conference's dial function that fails on a target.
- A REFER target or Replaces ending in a line break passed the check on
  what may go into a FreeSWITCH dial string; it is now refused.
- A referrer the conference does not trust can no longer tell whether
  the conference is full.
- A REFER whose answer was never sent no longer holds a place in the
  conference: the room forgets it when the process handling it dies.
- Two REFERs bringing the same party in, from different callers, dial it
  once, and one of them that cannot be answered no longer cancels the
  other; two removals of different members from one caller both happen.
- A Replaces the conference cannot pass on as it is now refuses the
  REFER instead of being dropped, and a REFER asking the conference to
  refer a party passes the referrer's Referred-By on unchanged.
- A conference without focus refuses to dial its own address.

### New

- A REFER to a conference is answered only after the room's checks and
  its policy, which now also sees who the referrer is in the room
  (including from the call a Target-Dialog names) and which member a
  removal names.
- The referrer hears when the party rings (180 or 183), when the
  FreeSWITCH node sends those events.
- A focus conference can be asked by REFER to refer a party into it
  (method=REFER): it sends that party a REFER to the conference, and the
  referrer hears how the party answered.
- A caller whose INVITE replaces a member's call (Replaces) takes that
  member's place in the conference, and the member is hung up. By default
  only the member itself or a caller it referred may, never an anonymous
  caller; anyone else is refused, and so is a second caller replacing the
  same member while the first one's call is set up. A member is free
  again when that call fails or its caller goes away.
- A conference takes a replaces policy of its own, which decides who may
  replace a member in place of the default. The REFER policy is never
  asked about it, so a REFER policy that lets every REFER in lets nobody
  replace anyone.
- A member of a conference without focus can transfer itself attended
  (with Replaces) as well as blind; its call carries the transfer out
  once the conference's policy agrees.
- The conference roster shows each participant under its own address,
  one entry per call, marks parties a REFER brought in as dialed out and
  callers referred by someone as referred, keeps callers who asked for
  privacy anonymous, and shows a member who leaves as disconnected before
  it goes.

## [0.1.0] - 2026-11-23

### New

- Needs Erlang/OTP 29.1.2 or later: earlier OTP 29 releases let a TLS 1.3
  server be impersonated (CVE-2026-89422) or a resumed session skip
  authentication (CVE-2026-105236).
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
