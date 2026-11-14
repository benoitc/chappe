# Agents

Instructions for AI coding agents working on this app.

## Overview

`chappe_audio` takes a call's audio in, part of the `chappe` platform
umbrella. It is SIP-free. Facade module: `chappe_audio`. Internal module
prefix: `chappe_audio_*`.

Layers: `chappe_audio_http` (pure: the upgrade request, the path and token,
the refusals), `chappe_audio_listener` (one per port: the listening socket and
its acceptor), `chappe_audio_conn` (one per opening handshake),
`chappe_audio_stream` (one per fork: owner, events, the bound),
`chappe_audio_ws` (the ws_handler relaying a connection to its stream),
`chappe_audio_registry` (streams waiting for their fork, by id),
`chappe_audio_pg` (its own pg scope, `chappe_audio`, started by its supervisor),
`chappe_audio_pcm` (L16 levels), and the recording store: `chappe_audio_store`
(the behaviour and the API), `chappe_audio_store_srv` (the node's store: config,
pg membership, sweep), `chappe_audio_writer` (one per recording being written),
`chappe_audio_store_file` (the default backend) and `chappe_audio_wav` (pure:
the RIFF header).

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

`chappe_audio_live_SUITE` runs real FreeSWITCH forks into a listener; it is
skipped unless `FS_HOST` is set (`make interop-esl` sets it).

## Conventions

- Keep this lib SIP-free. Its only dependency is erlang_ws (`ws`).
- Nothing a peer sends becomes an atom; nothing a peer sends is trusted
  before the path and token checks.
- Every new process follows the `chappe-erlang-patterns` skill, with its four
  tests (owner death, own crash, a `peer` node, a flood past the bound).
- OTP 29. No em-dash in code, docs or messages; never the word "comprehensive".
- No generated or co-authored commit trailers; one imperative subject line.
