# Agents

Instructions for AI coding agents working on this project.

## Project Overview

`chappe_sip` is drachtio (drachtio-server + drachtio-srf) ported to
Erlang/OTP. It embeds sofia-sip's `nta` transaction layer through a thin
plain-C NIF shim; all transaction-user logic (dialogs, UAC, B2BUA, proxy,
registrar, digest, middleware) is in Erlang. Module prefix: `chappe_sip_`. Requires
Erlang/OTP 29 and rebar3. The drachtio repos are design references only.

## Required Checks

Every change must build and pass all checks before committing:

```bash
rebar3 compile              # must compile cleanly (builds the NIF, warnings_as_errors)
rebar3 eunit                # unit tests
rebar3 ct                   # Common Test suites (chappe_sip_*_SUITE)
rebar3 lint                 # Elvis linter
rebar3 xref                 # cross-reference analysis
rebar3 dialyzer             # type checking
```

`make test` runs eunit + ct; `make test-static` runs lint + xref + dialyzer;
`make check` runs everything.

erlfmt is configured (`rebar3 fmt`, 80 cols) but has not been applied
codebase-wide, so `rebar3 fmt --check` currently reports the existing manual
formatting. Do not reformat whole files as a side effect of a change.

## Build & Development Commands

```bash
rebar3 compile                              # build (C engine via c_src/build.sh + Erlang)
SKIP_ENGINE_BUILD=1 rebar3 compile          # skip the C build (pure-Erlang, chappe_sip_engine_fake)
rebar3 eunit                                # all EUnit tests
rebar3 eunit --module=chappe_sip_msg_tests        # one module
rebar3 ct                                   # all CT suites
rebar3 ct --suite=test/chappe_sip_b2bua_SUITE        # one suite
rebar3 lint / xref / dialyzer               # static checks
rebar3 fmt / rebar3 fmt --check             # format / verify formatting
INTEROP=1 rebar3 ct --suite test/chappe_sip_interop_SUITE   # real JsSIP + Kamailio (needs node + docker)
test/asan/run.sh                            # C NIF under AddressSanitizer (Linux container)
rebar3 ex_doc                               # HTML docs into doc/ (git-ignored); `make docs`
```

The user guides live in `docs/` (task-oriented markdown); `rebar3 ex_doc`
renders them plus a module API reference (module docs come from specs, since
the `%% @doc` comments are markdown, not edoc markup).

The C engine is stamp-gated: `c_src/build.sh` rebuilds sofia-sip only when the
submodule SHA changes and the NIF only when the shim changes. `ENGINE_SANITIZE=address`
builds the shim with ASan (see `test/asan/`).

## Architecture

### Module layers (`src/`)

- **API** (`api/`): `chappe_sip` (facade), `chappe_sip_b2b` (B2BUA), `chappe_sip_handler`
  (structured UAS behaviour), `chappe_sip_middleware`.
- **Engine** (`engine/`): `chappe_sip_engine` (the singleton gen_server that owns the
  NIF and dispatches every op to the sofia backend or the WS transport by
  handle), `chappe_sip_nif` (NIF stubs).
- **Dialog** (`dialog/`): `chappe_sip_dialog` (handle + API), `chappe_sip_dialog_fsm`
  (gen_statem: `setup` -> `confirmed` -> `in_transaction` / `terminating`),
  `chappe_sip_dialog_sup`.
- **UAC** (`uac/`): `chappe_sip_uac`, `chappe_sip_uac_fsm` (gen_statem), `chappe_sip_uac_sup`.
- **Proxy** (`proxy/`): `chappe_sip_proxy` (forking + in-dialog forwarding),
  `chappe_sip_route` (Record-Route + flow tokens).
- **Media** (`media/`): `chappe_sip_media` (capability-based control-plane facade),
  `chappe_sip_media_rtpengine` / `chappe_sip_media_freeswitch` (backend adapters),
  `chappe_sip_media_esl_mgr` (pooled ESL control connections), `chappe_sip_media_sup`. The
  media plane stays external; these drive rtpengine (via the `chappe_rtpengine`
  dep) and FreeSWITCH (via the `chappe_esl` dep). Both deps are dormant unless
  `media` is configured. See `docs/design/media.md`.
- **WebSocket** (`ws/`): `chappe_sip_ws` (handle-range helper), `chappe_sip_ws_sup`,
  `chappe_sip_ws_listener` (a livery HTTP service upgrading `GET /ws`), `chappe_sip_ws_conn`
  (the ws_handler), `chappe_sip_ws_transport` (the Erlang WS transaction layer).
- **Connection / registrar** (`conn/`): `chappe_sip_registry`, `chappe_sip_registry_keeper`
  (owns the location ETS), `chappe_sip_stack_sup`, `chappe_sip_request_sup`,
  `chappe_sip_request_worker`.
- **SIP messages** (`sip/`): `chappe_sip_msg`, `chappe_sip_hdr`, `chappe_sip_uri`, `chappe_sip_req`,
  `chappe_sip_res`, `chappe_sip_digest`, `chappe_sip_hdr_io`.
- **Root**: `chappe_sip_app`, `chappe_sip_sup`, `chappe_sip_config` (all tunables + defaults).

### Supervision tree

`chappe_sip_app` -> `chappe_sip_sup` (one_for_one) -> `chappe_sip_registry_keeper`,
`chappe_sip_registry`, `chappe_sip_ws_sup`, `chappe_sip_media_sup`, `chappe_sip_stack_sup`. The keeper and registry sit
above the stack so location bindings survive engine restarts (and a registry
crash). `chappe_sip_stack_sup` (rest_for_one) -> `chappe_sip_engine`, `chappe_sip_request_sup`
(request workers, simple_one_for_one temporary), `chappe_sip_dialog_sup`,
`chappe_sip_uac_sup`.

### Call model

"A call is a process": one `chappe_sip_request_worker` per inbound out-of-dialog
request runs the middleware chain and the handler, and blocks as the dialog
owner for the whole call. The engine multiplexes each operation to the sofia
NIF or the WS transport by handle magnitude (`?IS_WS`, WS handles >=
`16#4000000000000000`). WS has no sofia retransmit timers, so the WS transport
carries its own client/server transaction timers.

### Key files

- `include/chappe_sip.hrl`, `include/chappe_sip_dialog.hrl`, `include/chappe_sip_uac.hrl`
- `docs/design/engine.md` (engine + NIF design, ASan procedure), `docs/features.md`
  (feature tracker + API), `docs/plan.md` (milestone history)

### Tests

- `test/chappe_sip_*_SUITE.erl` — feature-scoped Common Test suites named for what
  they exercise (e.g. `chappe_sip_uac_SUITE`, `chappe_sip_registrar_SUITE`,
  `chappe_sip_websocket_SUITE`), driven by live UDP peers and `ws:connect` clients.
- `test/*_tests.erl` — EUnit (message model, digest, RFC 4475 corpus).
- `test/chappe_sip_engine_fake.erl` — pure-Erlang engine backend (no NIF).
- `test/chappe_sip_interop_SUITE.erl` — opt-in (`INTEROP=1`) real-stack interop
  (JsSIP over WS, Kamailio over UDP); harness in `interop/`.
- `test/asan/` — the C NIF under AddressSanitizer in a Linux container.

## Linting Notes

Elvis rules are in `elvis.config` (`erl_files_strict` ruleset). Notable
per-module exceptions (see the file for the full list):
- gen_server/gen_statem modules that use `#s{}` / `#data{}` / map state are
  excluded from `state_record_and_type`.
- `chappe_sip_engine` is excluded from `no_invalid_dynamic_calls` (it dispatches to a
  pluggable backend `Mod:...`), `max_module_length`, and `no_deep_nesting`.
- call-owner loops (`chappe_sip_b2b`, `chappe_sip_handler`, `chappe_sip_dialog`) are excluded from
  `no_receive_without_timeout` (they block on messages / a monitor `DOWN`).
- `max_line_length` limit is 90; atom naming regex is
  `^[a-z](_?[a-zA-Z0-9]+)*(_SUITE)?$`.
