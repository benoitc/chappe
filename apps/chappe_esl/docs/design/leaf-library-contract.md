# Leaf library contract

This is the shared contract for the chappe stack's leaf protocol clients
(chappe_esl for FreeSWITCH Event Socket, chappe_rtpengine for the rtpengine NG
protocol). Read it before starting or reviewing a leaf library so both are built
the same way. A leaf library speaks one wire protocol and depends on nothing
else in the stack.

## Scope

- Speak exactly one wire protocol. No dependency on chappe_sip,
  SIP, or any media concept.
- No runtime dependencies beyond kernel and stdlib unless the protocol truly
  needs one. Prefer OTP built-ins (for example the `json` module).
- `{deps, []}` and an empty `rebar.lock`.

## Layout

- Public facade module named `chappe_<thing>`; every internal module prefixed with
  a short tag (`chappe_esl_`, `chappe_rtpengine_`).
- `src/` for code, `test/` for tests (flat), `docs/` for authored markdown,
  `doc/` for generated ex_doc HTML (git-ignored), `interop/` for a live test
  harness.
- SPDX header on every file:

  ```
  %% Copyright 2026 Benoit Chesneau
  %% SPDX-License-Identifier: Apache-2.0
  ```

  Use `#` comment style for Makefile, YAML, and shell files.

## Architecture

- One process owns each socket. Incoming bytes accumulate in a buffer and an
  incremental parser peels one complete message at a time, returning unchanged
  state on a partial frame. Never assume one message per packet.
- The parser is a pure module with no process. It never throws on malformed
  input. It is the highest-risk component and is unit tested by feeding real
  frames split at every byte boundary.
- gen_statem modules use `callback_mode() -> state_functions`, keep state in a
  `#data{}` record, and name states after protocol phases.
- Errors are tagged tuples. Bad input from the socket is logged, not thrown.

## Toolchain

- Erlang/OTP 29, rebar3.
- `{erl_opts, [debug_info, warnings_as_errors]}` on the default profile; a
  `test` profile adds `nowarn_export_all`.
- Project plugins: `rebar3_lint`, `erlfmt` (print width 80), `rebar3_ex_doc`.
- elvis with the `erl_files_strict` ruleset and a 90-column limit.
- dialyzer with `{warnings, [error_handling, unknown]}` and the four xref
  checks.

## Verification gates

All must pass before a change lands, wired into the Makefile and CI:

- `rebar3 compile` (warnings as errors)
- `rebar3 eunit`
- `rebar3 ct`
- `rebar3 lint`
- `rebar3 xref`
- `rebar3 dialyzer`
- `rebar3 fmt -c`

## Testing

- eunit `*_tests.erl` for pure modules, with real captured frames and
  byte-boundary splitting.
- CT `*_SUITE.erl` running against a scriptable in-process fake of the remote
  server, so unit and integration tests need no live server.
- A live/interop `*_SUITE.erl` gated on an environment variable that returns
  `{skip, ...}` when unset, driven by a harness under `interop/`.

## Documentation

- Task-oriented guides: second person, a one-paragraph intro saying what the
  page is and when to use it, then steps with minimal prose between code blocks.
- A `docs/features.md` tracker and a `docs/design/overview.md`.
- Do not use the em-dash character. Do not use the word "comprehensive".
