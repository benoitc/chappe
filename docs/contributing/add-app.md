# Add an app to the umbrella

Each app under `apps/` is published to hex on its own and has a place in the
dependency layers: leaf, core or orchestration. Use this page when a new
concern does not fit an existing app, for example a client for another media
server, or a new orchestration layer over chappe_sip.

## Before you start

- [architecture.md](../architecture.md): the layers and why the dependency
  rules exist.
- [docs/decisions/](../decisions/): the records on leaf apps and on chappe_mrf
  as an orchestration app.
- [AGENTS.md](../../AGENTS.md): the conventions every app follows.

## Where it sits

| Layer | Apps | May depend on | Rule |
|---|---|---|---|
| Leaf | the apps listed in [0003](../decisions/0003-leaf-apps.md) | no umbrella app | SIP-free; one concern; no helper shared across apps |
| Core | chappe_sip | leaf apps: the media apps through `chappe_sip_media` only, chappe_audio and chappe_cluster as optional | owns SIP |
| Orchestration | chappe_mrf | chappe_sip and leaf apps | composes them; owns no protocol |

Pick the lowest layer that works. A leaf app that needs SIP is not a leaf:
put the SIP-aware part in chappe_sip or in an orchestration app.

## Where to look

| Wiring | File | Copy from |
|---|---|---|
| App resource | `apps/<app>/src/<app>.app.src` | `apps/chappe_esl/src/chappe_esl.app.src` |
| Build, ex_doc, fmt, dialyzer, xref | `apps/<app>/rebar.config` | `apps/chappe_esl/rebar.config` |
| Umbrella build | root `rebar.config` (`project_app_dirs` picks up `apps/*`; add the app to `shell` `apps`) | |
| Lint | root `elvis.config` covers `apps/*/src` already; per-module ignores go there with a one-line reason | |
| Format | root `rebar.config` `erlfmt` globs cover `apps/*/src` | |
| Compliance | `apps/<app>/docs/compliance/requirements.tsv`, and `COMPLIANCE_APPS` in the root `Makefile` | `apps/chappe_esl/docs/compliance/` |
| Lab target | root `Makefile` (`interop-<app>`) and a CI job in `.github/workflows/ci.yml` | `interop-esl` |
| Licence | `apps/<app>/LICENSE`, `NOTICE` if it vendors code | `apps/chappe_esl/` |
| Changelog | `apps/<app>/CHANGELOG.md`, opening with `## [Unreleased]` | `apps/chappe_esl/CHANGELOG.md` |
| Hex package | `links` and `files` in the `.app.src`, `rebar3_hex` in `project_plugins`, the app in the `package` matrix of `.github/workflows/ci.yml` | `apps/chappe_esl/`, [releasing](releasing.md) |
| Docs | `apps/<app>/README.md`, `docs/design/overview.md`, `docs/guides/`, `docs/features.md` | `apps/chappe_esl/` |
| Agent rules | `apps/<app>/AGENTS.md` and a `CLAUDE.md` holding `@AGENTS.md` | `apps/chappe_esl/` |

## Steps

1. Name it `chappe_<name>`. Modules are `chappe_<name>_*`; only the facade
   module `chappe_<name>` carries the bare name.
2. Create `src/`, `test/`, `docs/`, the `.app.src` and `rebar.config`. List
   only real runtime deps. A sibling in `applications` is also a
   default-profile dep with a `~>` pin (`{chappe_sip, "~> 0.2.0"}`), which
   the umbrella resolves to the local app; an optional sibling is neither.
3. Write the facade module first, with a `-spec` on every export: it is the
   public API and what ex_doc shows under "Public API".
4. Add `docs/compliance/requirements.tsv` (the 10-column header, see
   [compliance.md](compliance.md)) and add the app to `COMPLIANCE_APPS`, or
   `make compliance` will not see it.
5. Add a fake for the external system in `test/` so the CT suites run without
   docker ([add-tests.md](add-tests.md)), then a lab if the app talks to a
   daemon ([add-interop-lab.md](add-interop-lab.md)).
6. Add the app to the tables in the root `README.md`, `docs/architecture.md`
   and `docs/navigation.md`.

## Tests to add or run

```sh
rebar3 compile
rebar3 ct --dir apps/chappe_<name>/test
make check
```

## How to know it works

- `make check` passes from the root, with the new app's suites in the CT
  summary.
- `make compliance` prints a line for the new app.
- `rebar3 xref` reports no call into another app outside its declared
  dependencies.
- `rebar3 ex_doc` from `apps/chappe_<name>` renders the README, the guides and
  the module groups.

## Notes

- Leaf apps take no umbrella dependency, so a helper they need is written
  again in the app, not imported from chappe_sip. Inside one app, share it.
- `verify_none` and permissive TLS are test-only; never in `src/`.

## Related

- [extend-public-api.md](extend-public-api.md)
- [add-media-backend.md](add-media-backend.md)
- [write-a-guide.md](write-a-guide.md)
