# Features

What chappe_mrf does today, and what is planned. Each line links to the page
that shows you how to use it.

## Working

- **Answer a caller with a FreeSWITCH endpoint** (`connect_caller/3`): the
  call is anchored in rtpengine and bridged to a node chappe_esl picks, with
  failover to the next up node on 408, 503 or a transport error.
  [IVR menu guide](guides/ivr-menu.md)
- **Endpoint commands**: play (a file or a list, from an offset, within a
  time limit), play and collect digits, record, record the session, send
  DTMF, set, multiset and export variables, read them, mute and unmute, api,
  any dialplan application (`execute/3`, or `execute/4` without waiting),
  hold and unhold. [IVR menu guide](guides/ivr-menu.md)
- **Playback results**: a missing file is `{error, not_found}`, `play_info/3`
  gives the length and response, `play_collect/2` with `result => full` the
  terminator and the invalid entry.
  [IVR menu guide](guides/ivr-menu.md#know-how-a-prompt-played)
- **Audio forks** to a WebSocket over mod_audio_fork or mod_audio_stream:
  named, mono or stereo, paused, resumed, sent text; into chappe_audio with
  `store => default` to record them. [IVR menu guide](guides/ivr-menu.md#other-commands)
- **Say and speak**: numbers, dates and digits with mod_say, text with a
  TTS module (flite in the lab).
  [IVR menu guide](guides/ivr-menu.md#say-numbers-and-speak-text)
- **Tone and fax detection** over mod_spandsp, with events to the owner.
  [IVR menu guide](guides/ivr-menu.md#detect-tones-and-faxes)
- **Endpoint events** to the owner: DTMF digits, hangup with its cause, node
  down, and on request playback start and stop, custom and channel events.
  [IVR menu guide](guides/ivr-menu.md#react-to-events)
- **Recordings into the store**: `record/3`, `record_session/3` and room
  recordings with `store => default` are adopted into chappe_audio's store
  under the call's `call_ref`.
  [Record a call](../../chappe_audio/docs/guides/record.md)
- **Endpoints with no caller** (`create_endpoint/1`), bridged in later.
  [Bridge guide](guides/bridge.md)
- **Bridge without a re-INVITE** to the caller (`bridge/2,3`): to another
  endpoint or to a SIP URI. [Bridge guide](guides/bridge.md)
- **Native conferences** on chappe_mix behind rtpengine: join a call, a
  caller not answered yet, or an endpoint, mute, deaf, kick, lock, per-pair relations (whisper, listen
  only), talker events, prompts on each caller's leg.
  [Conference guide](guides/conference.md)
- **HD native rooms** (`rate => 16000`): the mixer at 16 kHz on L16,
  rtpengine transcoding every member (G.722, Opus, PCMU, PCMA) to it and
  back (L16 tested on 26.3.1.4, upstream from 13.4.1.1). A party a REFER
  to the room brings in keeps the band too (tested live with a G.722
  callee). [Conference guide](guides/conference.md#run-an-hd-16-khz-native-room)
- **FreeSWITCH conferences** on mod_conference: join, mute, deaf, kick,
  lock, PIN entry, talker events, play into the room, recording, a member
  limit and room flags, mute, DTMF and prompt events.
  [Conference guide](guides/conference.md#freeswitch-rooms)
- **Native room recording** through SIPREC to a recording server
  (`record/3` with its URI). [Conference guide](guides/conference.md#record-a-native-room)
- **Rooms on a cluster**: with `cluster => chappe_cluster`, a room name has
  one owner in the region, `conference/2` on any node returns it, and a
  room whose lease is lost takes no new member.
  [Conference guide](guides/conference.md#run-rooms-on-a-cluster)
- **Move a member** to another room of the same backend (`transfer/3`).
  [Conference guide](guides/conference.md#move-a-member-to-another-room)
- **REFER in rooms**, both backends: a member transfers itself out, blind
  or attended, and a REFER to the room adds, removes or refers a party
  under your policy. [Conference guide](guides/conference.md#add-remove-or-refer-a-party-by-refer)
- **RFC 4575 conference state** for native rooms (`focus => true`,
  `focus_subscribe/2`). [Conference guide](guides/conference.md)
- **Cleanup**: an endpoint's channel is killed when its owner exits, after
  its audio forks and session recordings stop; a conference hangs up its
  members when it stops. [Design](design/overview.md#failure-handling)
- **Correlation** of SIP legs and ESL sockets by `X-Chappe-Call`; unknown
  channels are refused. [Design](design/overview.md#correlation-x-chappe-call)
- **Conference backends** behind the `chappe_mrf_conf_backend` behaviour:
  `native`, `fs`, or a module of your own.
  [Design](design/overview.md#the-backend-behaviour)
- **Compliance**: every MRF row passes on fakes ([matrix](compliance.md)).

## Also exported

These functions are exported and supported, but no guide shows them yet.

- `chappe_mrf:conferences/0` lists the running conferences as
  `[{Name, Conf}]`.
- `chappe_mrf:uuid/1` returns an endpoint's FreeSWITCH channel UUID.
- `chappe_mrf:fork_audio_resume/1,2` resumes a paused audio fork, and
  `fork_audio_send_text/2,3` sends the fork's server a text frame.
- `chappe_mrf:stop_detect_fax/1` stops the fax tone detection
  `detect_fax/1` started.
- `chappe_mrf_conf_refer:refer/3` answers a REFER to a room's URI.
- `chappe_mrf_conf_move:job/4` runs one member's move with the transfer
  fun you give; `rehome/4` moves a room's members after it lost its lease.

## Planned

- Move the loopback middleware and the node candidate selection out of the
  `chappe_mrf` facade into their own modules.
