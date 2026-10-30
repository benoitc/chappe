# Agents

Instructions for AI coding agents working on this project.

## Project Overview

`chappe` is an opensource SIP/media platform for Erlang/OTP 29, a rebar3
umbrella of composable apps you build voice services on. Products (an SBC, an AI
voice product, a PBX) live in their own repos and depend on these packages; they
are not here.

```
apps/chappe_sip/         SIP application server: UAS/UAC/B2BUA/proxy/registrar
                         over sofia-sip's `nta` via a plain-C NIF, SIP-over-
                         WebSocket, TLS, and the chappe_sip_media control-plane facade.
                         Public API module: `chappe_sip`. c_src/ vendors sofia-sip.
apps/chappe_rtpengine/   rtpengine NG control client (media relay/anchoring,
                         subscribe/duck). SIP-free. Facade module: chappe_rtpengine.
apps/chappe_esl/         FreeSWITCH Event Socket (ESL) client. SIP-free.
                         Facade module: chappe_esl.
apps/chappe_mix/         RTP audio conference mixer (G.711, N-1 mix, one
                         process per conference). SIP-free; rtpengine in
                         front handles SRTP and transcoding. Facade module:
                         chappe_mix.
apps/chappe_mrf/         Media resource function (drachtio-fsmrf style):
                         IVR endpoints on FreeSWITCH, bridging, conferences
                         on chappe_mix or mod_conference. An orchestration
                         app. Facade module: chappe_mrf.
demo/sbc/                A runnable SBC on chappe_sip and chappe_mrf
                         (`make demo`). Not compiled by CI.
docs/                    Umbrella docs: concepts, architecture, decisions,
                         navigation, contributor workflows, plans.
scripts/                 compliance.escript (requirement matrices).
```

Layers: leaf (chappe_rtpengine, chappe_mix, chappe_esl), core (chappe_sip),
orchestration (chappe_mrf). See `docs/architecture.md`.

Inside the umbrella the apps reference each other by name (no fetched cross
deps). External deps (`livery`, `ws`) are git/hex. Each app is published to hex
independently. Module prefixes are `chappe_sip_*` / `chappe_rtpengine_*` /
`chappe_esl_*` / `chappe_mix_*` / `chappe_mrf_*`; only the app-named facade modules carry the
`chappe_` brand.

sofia-sip is vendored in `apps/chappe_sip/c_src/sofia-sip` (no git submodule), so
the NIF builds from a clean clone with no network. It is LGPL-2.1 (see NOTICE);
keep it unmodified and linked, not forked.

## Required Checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt          # auto-format (always run first; erlfmt, 80 cols)
rebar3 compile      # must compile cleanly (warnings_as_errors; builds the NIF)
rebar3 lint         # Elvis linter (config: elvis.config)
rebar3 xref         # cross-reference analysis
rebar3 dialyzer     # type checking
rebar3 eunit        # unit + property tests
rebar3 ct           # Common Test suites (chappe_sip_*, chappe_rtpengine_*, chappe_mix_*, chappe_esl_*, chappe_mrf_*_SUITE)
```

`make check` runs all of them. CI (`.github/workflows/ci.yml`) runs
`format`/`lint`/`xref`/`dialyzer` as fast-fail static checks, then gates
`build`/`eunit`/`ct` on them. `ct` also runs `make cover`, which fails under
the `MIN_COVERAGE` floor set in the workflow (raise it, never lower it). The
docker jobs run the conformance lab and the compliance gate
(`make interop-conformance`, `make compliance GATE=demo`), the JsSIP/Kamailio
suite, the SBC lab (`make interop-sbc`), `make interop`, `make interop-mix`,
`make interop-esl`, `make interop-mrf`, and the C NIF under AddressSanitizer (`make asan`; see `apps/chappe_sip/test/asan/`).

## Build & Development Commands

```bash
rebar3 compile                                   # build (first run builds sofia)
SKIP_ENGINE_BUILD=1 rebar3 compile               # skip the C build (fake engine)
rebar3 ct --dir apps/chappe_sip/test             # one app's suites
rebar3 shell                                     # dev shell (all apps)
make asan                                        # NIF under ASan (Linux)
make cover MIN_COVERAGE=80                       # eunit + ct line coverage
make compliance GATE=demo                        # requirement matrices
```

## Where to read first

The human documentation is the source for the rules and the structure; this
file only summarises what an agent needs to act.

- `docs/README.md`: the map of every document.
- `docs/concepts.md`: the vocabulary (leg, owner, anchor, flow, node, ...).
- `docs/architecture.md`: the apps, supervision and the main call flows.
- `docs/navigation.md`: concept to module to test, public vs internal
  modules, where configuration lives.
- `docs/decisions/`: why each boundary exists. Read the record before you
  move a boundary.
- `docs/contributing/`: one workflow per task (labs, debug a call, change
  the B2BUA, add tests, add a lab, compliance rows, the C engine).
- `CONTRIBUTING.md`: checks, commit and PR style.
- Per-app design docs live under each app's `docs/design/`. The C engine and
  NIF design is in `apps/chappe_sip/docs/design/engine.md`.

## Conventions

- Run `rebar3 fmt` before committing; elvis must pass. New per-module elvis
  ignores go in `elvis.config` with a one-line reason.
- Commit messages: one imperative subject; body only for non-obvious "why". No
  phase references, no diff restatement, no "generated by" / "co-authored-by"
  trailers.
- Never use the em-dash character in code, docs, or messages.
- Never use the word "comprehensive" in tickets, comments, PRs, or MRs.
- OTP 29 only. sofia pin: freeswitch/sofia-sip v1.13.17-55 (vendored).
- Share code, do not copy it. Before writing a helper, look for one in the
  app (`grep -rn '^name(' apps/<app>/src`). When a second module needs a
  helper, export it from the module that owns the concept (`chappe_sip_hdr`
  for header grammar, `chappe_sip_uri` for URIs, `chappe_sip_dialog` for
  tags) instead of copying it. Helpers are not shared across apps: each app
  is published on its own and the leaf apps take no umbrella deps.
- Keep the leaf apps (chappe_rtpengine, chappe_esl, chappe_mix) SIP-free;
  SIP-coupled logic belongs in chappe_sip, an orchestration app or a
  consuming product.
- An orchestration app (chappe_mrf) may depend on chappe_sip and on the
  leaf apps. Nothing in the umbrella depends on it, and the leaf apps never
  depend on chappe_sip or on an orchestration app.
- Measure before you claim: chappe_mix keeps its thresholds and results in
  `apps/chappe_mix/test/audit/PERF.md` and what was tried and reverted in
  `ATTEMPTS.md`. Check the load average before timing anything, and run every
  new test against the code before the change to see it fail.
- `verify_none`/permissive TLS is test-only; never ship it in `src/`.
