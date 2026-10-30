# Features

What chappe_mrf does today, and what is planned. Each line links to the page
that shows you how to use it.

## Working

- **Answer a caller with a FreeSWITCH endpoint** (`connect_caller/3`): the
  call is anchored in rtpengine and bridged to a node chappe_esl picks, with
  failover to the next up node on 408, 503 or a transport error.
  [IVR menu guide](guides/ivr-menu.md)
- **Endpoint commands**: play (a file or a list), play and collect digits,
  record, record the session, send DTMF, set a variable, api, any dialplan
  application (`execute/3`), hold and unhold, audio forks to a WebSocket
  (mod_audio_fork). [IVR menu guide](guides/ivr-menu.md)
- **Endpoint events** to the owner: DTMF digits, hangup with its cause, node
  down. [Design](design/overview.md#endpoint-lifecycle)
- **Endpoints with no caller** (`create_endpoint/1`), bridged in later.
  [Bridge guide](guides/bridge.md)
- **Bridge without a re-INVITE** to the caller (`bridge/2,3`): to another
  endpoint or to a SIP URI. [Bridge guide](guides/bridge.md)
- **Native conferences** on chappe_mix behind rtpengine: join a call or an
  endpoint, mute, deaf, kick, lock, per-pair relations (whisper, listen
  only), talker events, prompts on each caller's leg.
  [Conference guide](guides/conference.md)
- **FreeSWITCH conferences** on mod_conference: join, mute, deaf, kick,
  lock, PIN entry, talker events, play into the room.
  [Conference guide](guides/conference.md)
- **RFC 4575 conference state** for native rooms (`focus => true`,
  `focus_subscribe/2`). [Conference guide](guides/conference.md)
- **Cleanup**: an endpoint's channel is killed when its owner exits, after
  its audio forks and session recordings stop; a conference hangs up its
  members when it stops. [Design](design/overview.md#failure-handling)
- **Correlation** of SIP legs and ESL sockets by `X-Chappe-Call`; unknown
  channels are refused. [Design](design/overview.md#correlation-x-chappe-call)
- **Compliance**: every MRF row passes on fakes ([matrix](compliance.md)).

## Out of scope

- `say` and `speak` (TTS needs FreeSWITCH modules the lab does not load):
  run them with `execute/3` where your nodes have them.

## Planned

- A `chappe_mrf_conf_backend` behaviour for the conference backends (today
  an implicit contract, see the [design](design/overview.md#the-backend-contract-not-yet-a-behaviour)).
- Move the loopback middleware and the node candidate selection out of the
  `chappe_mrf` facade into their own modules.
