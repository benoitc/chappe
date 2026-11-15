# Agents

Instructions for AI coding agents working on this app.

## Overview

`chappe_mrf` is a media resource function in the drachtio-fsmrf style, part
of the `chappe` platform umbrella. It is the controller (MRFC); FreeSWITCH,
rtpengine and chappe_mix are the media processors (MRFP). It is an
orchestration app: it depends on `chappe_sip`, `chappe_esl`, `chappe_audio`
(the recording store) and, through `chappe_sip_media`, on `chappe_rtpengine`
and `chappe_mix`. Facade module:
`chappe_mrf`. Internal module prefix: `chappe_mrf_*`.

Modules: `chappe_mrf` (setup, connect_caller, create_endpoint, bridge, the
endpoint commands), `chappe_mrf_endpoint` (one gen_statem per FreeSWITCH
channel: correlation, answer, events to the owner, cleanup),
`chappe_mrf_esl` (the outbound socket handler that finds the endpoint by
X-Chappe-Call), `chappe_mrf_registry` (the ETS table of who waits for
what), `chappe_mrf_conf` (one gen_server per conference) with its backends
`chappe_mrf_conf_native` (chappe_mix behind rtpengine, via a loopback
INVITE) and `chappe_mrf_conf_fs` (mod_conference), `chappe_mrf_conf_refer` (REFER to a room
and a member's transfer), `chappe_mrf_store` (FreeSWITCH
recordings adopted into the chappe_audio store), `chappe_mrf_lib`.

## Required Checks

Run from the umbrella root (`chappe/`):

```bash
rebar3 fmt && rebar3 compile && rebar3 lint && rebar3 xref && rebar3 dialyzer
rebar3 ct --dir apps/chappe_mrf/test     # chappe_mrf_SUITE, on fakes
make interop-mrf                         # chappe_mrf_live_SUITE, real FreeSWITCH and rtpengine
```

## Conventions

- Nothing in the umbrella depends on chappe_mrf. Shared helpers live in
  `chappe_mrf_lib`; never copy one from another app.
- OTP 29. No em-dash in code, docs or messages; never the word
  "comprehensive".
- No generated or co-authored commit trailers; one imperative subject line.
