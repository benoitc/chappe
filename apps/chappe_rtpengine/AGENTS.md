# Agents

Instructions for AI coding agents working on this app.

## Overview

`chappe_rtpengine` is a client for the rtpengine NG control protocol (bencode
over UDP/TCP/WS), part of the `chappe` platform umbrella. It is SIP-free: it
takes opaque SDP and params and speaks to rtpengine; it never touches a dialog,
tag, or SIP message. Facade module: `chappe_rtpengine`. Internal module prefix:
`chappe_rtpengine_*`.

Layers: `chappe_rtpengine_bencode` (codec), `chappe_rtpengine_stream` (pure NG-over-TCP framer), `chappe_rtpengine_ng` (NG command/result model), `chappe_rtpengine_client`
(one process per node, cookie/retransmit/timeout), `chappe_rtpengine_pool` (node registry +
health + call pinning), `chappe_rtpengine_session` (per-call gen_statem: offer/answer,
subscribe/duck, node pinning, owner-death teardown), `chappe_rtpengine_dtmf`.

## Required Checks

Run from the umbrella root (`chappe/`), which owns the shared gate config:

```bash
rebar3 fmt        # erlfmt, 80 cols (run first)
rebar3 compile    # warnings_as_errors
rebar3 lint       # Elvis (config: ../../elvis.config)
rebar3 xref
rebar3 dialyzer
rebar3 eunit
rebar3 ct
```

`chappe_rtpengine_*` suites are `test/chappe_rtpengine_*_SUITE`; the live suite is gated on
`RTPENGINE_HOST` (a real rtpengine, via the `interop/` docker harness).

## Conventions

- Keep this lib SIP-free; correlation is by call-id + tags supplied by the
  caller, never parsed here.
- Run `rebar3 fmt`; elvis must pass (per-module ignores live in the umbrella
  `elvis.config` with a one-line reason; `chappe_rtpengine_session` is the handle-event
  gen_statem, `chappe_rtpengine_bencode` uses throw as parser control flow).
- OTP 29. No em-dash in code/docs/messages; never the word "comprehensive".
- No generated/co-authored commit trailers; one imperative subject line.
