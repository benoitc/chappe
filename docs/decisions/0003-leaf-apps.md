# 0003: Leaf apps take no SIP dependency

This record is the contract for the leaf apps of the umbrella
(chappe_rtpengine, chappe_mix, chappe_esl): what a leaf app may depend on,
how it is laid out, built and tested. Read it before you start a new leaf
app, review one, or add a dependency to one. It replaces the two copies of
`leaf-library-contract.md` that lived in `apps/chappe_rtpengine/docs/design/`
and `apps/chappe_esl/docs/design/`.

## Status

Accepted as a rule (`AGENTS.md`, "Conventions"). The reason is to confirm by
the maintainer.

## Context

What the repository shows:

- `AGENTS.md`: "Keep the leaf apps (chappe_rtpengine, chappe_esl,
  chappe_mix) SIP-free; SIP-coupled logic belongs in chappe_sip, an
  orchestration app or a consuming product", and "the leaf apps never
  depend on chappe_sip or on an orchestration app".
- Each app is published to hex on its own (`AGENTS.md`, root `rebar.config`
  comment).
- `AGENTS.md`: "Helpers are not shared across apps: each app is published
  on its own and the leaf apps take no umbrella deps."
- The `applications` lists confirm it: chappe_rtpengine needs `ws`,
  chappe_mix `crypto`, chappe_esl nothing beyond kernel and stdlib
  (`apps/*/src/*.app.src`).

The two copies of the contract disagreed on four points:

| Point | chappe_rtpengine copy | chappe_esl copy |
|---|---|---|
| Which apps it covers | chappe_rtpengine and chappe_mix | chappe_esl and chappe_rtpengine |
| Dependencies | `{deps, []}` by default; a protocol-required dep pinned with `~>` from hex, lock committed (chappe_rtpengine takes erlang_ws) | `{deps, []}` and an empty `rebar.lock`, no exception |
| Parser example | names `chappe_rtpengine_stream` | none |
| gen_statem callback mode | `state_functions` by default, `handle_event_function` when most events are handled alike or a reply depends on the state (`chappe_rtpengine_session`) | `state_functions` only |

This record takes the rtpengine copy on each point, since it is a superset
and matches the code: chappe_rtpengine depends on `ws`, and
`chappe_rtpengine_session` uses `handle_event_function`. The scope covers
all three leaf apps.

## Decision

### Scope

- A leaf app speaks exactly one wire protocol (rtpengine NG, RTP mixing,
  FreeSWITCH Event Socket). No dependency on chappe_sip, on SIP, or on
  another chappe app.
- No runtime dependency beyond kernel and stdlib unless the protocol needs
  one. Prefer OTP built-ins (the `json` module, for example).
- `{deps, []}` and an empty `rebar.lock` by default. A dependency the
  protocol needs is pinned with `~>` from hex and the lock is committed
  (chappe_rtpengine takes `ws` for NG over WebSocket).

### Layout

- The public facade is named `chappe_<thing>`; every internal module carries
  the app prefix (`chappe_rtpengine_`, `chappe_mix_`, `chappe_esl_`).
- `src/` for code, `test/` for tests (flat), `docs/` for authored markdown,
  `doc/` for generated ex_doc HTML (git-ignored), `interop/` for a live test
  harness.
- An SPDX header on every file:

  ```
  %% Copyright 2026 Benoit Chesneau
  %% SPDX-License-Identifier: Apache-2.0
  ```

  Use `#` comments in Makefiles, YAML and shell files.

### Architecture

- One process owns each socket. Incoming bytes accumulate in a buffer and an
  incremental parser takes one complete message at a time, returning
  unchanged state on a partial frame. Never assume one message per packet.
- The parser is a pure module with no process (`chappe_rtpengine_stream` for
  NG over TCP, `chappe_esl_parser`). It never throws on malformed input. It
  is the riskiest component and is unit tested with real frames split at
  every byte boundary.
- gen_statem modules keep their state in a `#data{}` record and name states
  after protocol phases. Use `callback_mode() -> state_functions` by
  default. Use `handle_event_function` when most events are handled the
  same in several states, or when the reply to a call depends on the state
  it lands in (an async reply arriving after a stop, for example);
  `chappe_rtpengine_session` is built this way. The `#data{}` record is why
  such modules carry an elvis `state_record_and_type` ignore, not the
  callback mode.
- Errors are tagged tuples. Bad input from the socket is logged, not thrown.

### Toolchain

- Erlang/OTP 29, rebar3.
- `{erl_opts, [debug_info, warnings_as_errors]}` on the default profile; the
  `test` profile adds `nowarn_export_all`.
- Project plugins: `rebar3_lint`, `erlfmt` (print width 80),
  `rebar3_ex_doc`.
- elvis with the `erl_files_strict` ruleset and a 90-column limit
  (`elvis.config`).
- dialyzer with `{warnings, [error_handling, unknown]}` and the four xref
  checks.

### Verification

All of these pass before a change lands, wired into the Makefile and CI:
`rebar3 compile`, `eunit`, `ct`, `lint`, `xref`, `dialyzer`, `fmt -c`.

### Testing

- eunit `*_tests.erl` for pure modules, with real captured frames and
  byte-boundary splitting.
- CT `*_SUITE.erl` against a scriptable in-process fake of the remote
  server (`chappe_rtpengine_fake_server`, `chappe_esl_fake_server`), so unit
  and integration tests need no live server.
- A live `*_SUITE.erl` gated on an environment variable that returns
  `{skip, ...}` when unset, driven by a harness under `interop/`.

### Documentation

- Task-oriented guides in the second person, each opening with one
  paragraph saying what the page is and when to use it.
- A `docs/features.md` tracker and a `docs/design/overview.md`.
- No em-dash character, never the word "comprehensive".

## Consequences

- A leaf app can be used by a product that has no SIP at all, and a change
  to chappe_sip cannot break it.
- chappe_sip reaches the leaves only through `chappe_sip_media` and its
  adapters (`chappe_sip_media_rtpengine`, `chappe_sip_media_mix`), so SIP
  concepts stop there.
- Code needing SIP and a leaf at once goes to chappe_sip or to an
  orchestration app ([0006](0006-mrf-orchestration-app.md)).
- A small helper may exist in two apps on purpose; that is not a copy to
  remove.

## Open questions

- Is publishing each app on its own the main reason for the rule?
- Should chappe_mix count as a media leaf, given that the contract says "no
  media concept"? The rtpengine copy listed chappe_mix as a leaf while
  saying "No dependency on chappe_sip, SIP, or any media concept".
