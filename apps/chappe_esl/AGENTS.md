# Agents

Instructions for AI coding agents working on this app.

## Overview

`chappe_esl` is a FreeSWITCH Event Socket (ESL) client, part of the `chappe`
platform umbrella. It is SIP-free. Facade module: `chappe_esl`. Internal module
prefix: `chappe_esl_*`.

Layers: `chappe_esl_parser` (streaming Content-Length frame parser), `chappe_esl_event`
(decode command/reply, api/response, event-plain/json), `chappe_esl_conn` (one
gen_statem per connection: inbound auth + outbound accept, FIFO command/reply
correlation, event delivery to an owner), `chappe_esl_inbound` (connect helper),
`chappe_esl_listener` / `chappe_esl_outbound_sup` (outbound dialplan sockets),
`chappe_esl_handler` (the outbound channel behaviour).

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

`chappe_esl_*` suites are `test/chappe_esl_*_SUITE` (with an in-suite fake FreeSWITCH event
socket); the live suite is gated on a real FreeSWITCH.

## Conventions

- Keep this lib SIP-free.
- Run `rebar3 fmt`; elvis must pass (`chappe_esl_conn` keeps `#data{}` state and calls a
  pluggable handler module; ignores are in the umbrella `elvis.config`).
- OTP 29. No em-dash in code/docs/messages; never the word "comprehensive".
- No generated/co-authored commit trailers; one imperative subject line.
