# Agents

Instructions for AI coding agents working on chappe_sip. The umbrella rules
(checks, conventions, commit style) are in the root `AGENTS.md` and
`CONTRIBUTING.md`; this file adds what is specific to this app. Human
documentation is the source of truth: when this file and a doc disagree,
the doc wins and this file is stale.

## Project overview

`chappe_sip` is the SIP core of the chappe umbrella, a port of the drachtio
model (drachtio-server and drachtio-srf) to Erlang/OTP 29. It embeds
sofia-sip's `nta` transaction layer through a thin plain-C NIF; all
transaction-user logic (dialogs, UAC, B2BUA, proxy, registrar, digest,
middleware, events) is Erlang. Module prefix: `chappe_sip_`. The drachtio
repos are design references only.

sofia-sip is vendored unmodified in `c_src/sofia-sip` (not a submodule;
LGPL-2.1, see `NOTICE`). Keep it unmodified and linked, not forked.

## Required checks

Run from the umbrella root. All of them must pass before a commit:

```bash
rebar3 fmt          # erlfmt, 80 cols; enforced in CI (rebar3 fmt --check)
rebar3 compile      # warnings_as_errors; builds the NIF
rebar3 lint         # elvis (umbrella elvis.config)
rebar3 xref
rebar3 dialyzer
rebar3 eunit
rebar3 ct
```

`make check` at the umbrella root runs them all, plus the coverage floor.

## Build and test commands

From the umbrella root:

```bash
rebar3 compile                                    # first run builds sofia-sip and the NIF
SKIP_ENGINE_BUILD=1 rebar3 compile                # no C build; tests use chappe_sip_engine_fake
rebar3 eunit --module=chappe_sip_msg_tests        # one eunit module
rebar3 eunit --module=doc_snippets_tests          # the doc snippet check
rebar3 ct --dir apps/chappe_sip/test              # this app's suites
rebar3 ct --suite apps/chappe_sip/test/chappe_sip_b2bua_SUITE   # one suite
make interop                                      # JsSIP and Kamailio (node + docker)
make interop-conformance                          # SIPp, pjsua, dnsmasq lab
make interop-sbc                                  # FreeSWITCH, rtpengine, Kamailio lab
make asan                                         # the NIF under AddressSanitizer (Linux container)
make compliance GATE=demo                         # the requirement matrix
```

`c_src/build.sh` is stamp-gated: sofia-sip rebuilds only when its vendored
tree or its configure flags change, the NIF only when the shim changes.
`ENGINE_SANITIZE=address` builds the shim with ASan.

## Architecture

Read [docs/design/overview.md](docs/design/overview.md) before you change
code: it has the supervision tree, what each `src/` directory owns, the
entry points, public versus internal modules, and the test map. The C
engine, the NIF event contract and its risky regions are in
[docs/design/engine.md](docs/design/engine.md); the B2BUA in
[docs/design/b2bua.md](docs/design/b2bua.md); WebSocket in
[docs/design/ws-transport.md](docs/design/ws-transport.md); media in
[docs/design/media.md](docs/design/media.md).

The layers in one line each:

- `engine/`: `chappe_sip_engine` (the singleton that owns the NIF and
  dispatches every op to sofia or the WS transport by handle), `chappe_sip_nif`.
- `conn/`: request workers, the stack supervisor, the location store.
- `sip/`: the message model and pure protocol helpers.
- `dialog/`, `uac/`: dialog and client transaction fsms, REFER, the
  subscriber side of events, session timers.
- `proxy/`: the stateful proxy; `chappe_sip_route` there is cross-cutting
  (Record-Route, route secrets, flow tokens).
- `ws/`: the WebSocket transport and its own transaction layer.
- `media/`: the media facade over chappe_rtpengine and chappe_mix.
- `peers/`: OPTIONS-monitored peers and the registrar's qualify.
- `api/`: the `chappe_sip` facade, the extension points (`handler`,
  `middleware`, `guard`), the B2BUA (`chappe_sip_b2b` and eight
  `chappe_sip_b2b_*` helpers), `cdr` (a core service filed here), `regc`,
  `registrar`, `focus`, `confinfo`, and the event packages (`esc`,
  `notifier`, `presence`, `pidf`, `mwi`, `publisher`).
- root: `chappe_sip_app`, `chappe_sip_sup`, `chappe_sip_config` (every
  tunable and its default), `chappe_sip_metrics`.

"A call is a process": one `chappe_sip_request_worker` per inbound
out-of-dialog request runs the middleware and the handler and owns the call.

## Rules for this app

- Do not edit `c_src/sofia-sip`. Changes to `c_src/chappe_sip_engine_nif.c`
  need `make asan` and a read of the risky regions in `engine.md`.
- A new tunable goes in `chappe_sip_config` with a default and in
  `docs/configuration.md`.
- A new user-facing option needs a guide section (the guide's "Where it
  lives" footer names modules and tests) and a line in `docs/features.md`.
- WebSocket and native transports must stay in step; see
  `docs/design/ws-transport.md`.
- Claim RFC requirements in tests with `%% req:` lines
  (`docs/compliance/README.md`).

## Tests

- `test/chappe_sip_*_SUITE.erl`: Common Test suites named for the area they
  cover, driven by live UDP peers and WebSocket clients.
- `test/*_tests.erl`: eunit (message model, digest, SDP, routes, metrics).
- `test/doc_snippets_tests.erl`: parses every `erlang` block in the docs of
  every app, the umbrella `docs/` tree and `CONTRIBUTING.md`, and checks that
  each `chappe_*:fun/arity` it calls is exported. Use `...` for elisions.
- `test/chappe_sip_engine_fake.erl`: the pure-Erlang engine backend.
- `test/chappe_sip_compliance.erl`: the compliance matrix generator.
- `test/asan/`: the NIF under AddressSanitizer in a Linux container.

## Linting notes

elvis rules are in the umbrella `elvis.config`. Each per-module exemption
carries a reason there; the large modules exempt from size rules are listed
as findings in `docs/plans/documentation-and-maintainability.md`.
