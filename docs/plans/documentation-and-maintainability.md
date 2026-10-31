# Documentation and maintainability plan

This is a plan, not documentation. It records what a human developer meets
today when they open the repository, what is missing or misleading, and the
order in which to fix it. No source code is changed by this plan; code
findings are listed so they can be planned separately.

Baseline: `main` at `e539f8d` (after #18). Measurements are code lines (no
blanks, no comments) unless stated.

## 1. What a newcomer meets today

| Area | Size | State |
|---|---|---|
| chappe_sip | 84 modules, 21.5k lines, plus a 2.6k-line C NIF | 21 guides, 4 design docs, a 536-line `features.md` |
| chappe_rtpengine | 15 modules, 2.5k lines | README, 6 guides, overview |
| chappe_esl | 14 modules, 2.2k lines | README, 8 guides, overview |
| chappe_mix | 12 modules, 2.2k lines | **no README, no guide, no design doc** |
| chappe_mrf | 10 modules, 1.6k lines | README, 3 guides, a drachtio mapping |
| demo/sbc | one 560-line module | the best end-to-end walkthrough, linked from nowhere |

Main problems, in the order a newcomer hits them:

1. **No starting point.** The root README lists four of the five apps, omits
   chappe_mrf and the demo, contains no link, and says nothing about how the
   apps fit together. The dependency rules (leaf, core, orchestration) exist
   only in `AGENTS.md`, which is written for AI agents.
2. **No vocabulary.** There is no glossary. `nta`, NG, ESL, B2BUA, UAS/UAC,
   anchor, flow, Timer C, focus, MRF are used before being defined. "Leg"
   means three different things (an nta leg, a B2BUA side, a mixer
   participant).
3. **No "why".** The big decisions (a NIF over sofia nta, one process per
   call, SIP-free leaf apps, rtpengine kept external, a home-grown mixer,
   chappe_mrf as a separate orchestration app) are asserted, never argued.
   The evidence for some of them is buried in lab notebooks
   (`apps/chappe_mix/test/audit/ATTEMPTS.md`, `PERF.md`).
4. **No "where".** Guides almost never point to the module or the test that
   implements what they describe. Features shipped in #17 and #18 (forking,
   `replace_b`, `relay_async`, `hangup/2`, in-dialog requests, the
   registration client, the guard, metrics) have no guide at all, only
   `features.md` bullets.
5. **Stale and contradicting statements.** Examples:
   - `apps/chappe_sip/AGENTS.md:29` says erlfmt is not applied, while CI
     enforces it;
   - `apps/chappe_sip/AGENTS.md:53` speaks of a sofia submodule, though sofia
     is vendored;
   - `apps/chappe_sip/docs/design/overview.md` shows a supervision tree
     missing nine children, and promises `chappe_sip_mN_SUITE` suites that do
     not exist;
   - two CHANGELOGs with different versions (root 0.1.0, chappe_sip 0.2.0);
   - "Planned: multi-app model" in `features.md`, "dropped" in `plan.md`,
     "draft" in `remote-app.md`, none linking the others;
   - two copies of the leaf-library contract that disagree;
   - getting-started guides that clone standalone repos that are no longer
     the source.
6. **Unclear public surface.** No module is marked internal. The ex_doc
   groups in `apps/chappe_sip/rebar.config` expose internals
   (`ws_transport`, `route`, `registry`) and omit user-facing modules (refer,
   presence, mwi, regc, cdr, focus, peers, guard). chappe_mix and chappe_mrf
   have no ex_doc configuration, and there is no umbrella docs target.
7. **No contributor guide.** There is no `CONTRIBUTING.md`, and none of these
   is written down:
   - how to add a guide, a module, an app, a test or fake, or an interop lab;
   - how to debug a call;
   - what all the `make interop-*` targets do, in one place.

## 2. Recommended structure

The documentation is a path from orientation to implementation. Each level
links to the next. User guides stay with their app, because each app is
published on its own. Everything that spans apps moves to a new umbrella
`docs/`.

```
README.md                       orientation: what, who, the five apps, start here
CONTRIBUTING.md                 how to work in this repo (checks, conventions, PRs)
CHANGELOG.md                    single changelog (merge apps/chappe_sip/CHANGELOG.md)
docs/
  README.md                     documentation map, by reader and by question
  concepts.md                   mental model and glossary
  architecture.md               how the apps fit, dependency rules, main flows
  decisions/                    short records: one decision, its reason, its cost
  navigation.md                 concept -> app -> directory -> module -> tests
  contributing/                 "If you want to..." workflows
  plans/                        plans like this one (maintainer-facing)
apps/<app>/
  README.md                     the app in one page: role, start here, public modules
  docs/README.md                the app's documentation index
  docs/design/overview.md       internal architecture of the app (contributors)
  docs/guides/*.md              task guides (users)
  docs/features.md              capability tracker, short, with links
  docs/compliance*              generated matrix and how to extend it
```

`AGENTS.md` files stay for AI agents. They should link to the human
documents instead of being the only home of a rule.

## 3. The starting point

The root `README.md` becomes the single entry. In one screen it says:

- what chappe is (an Erlang platform for building voice services, signalling
  in Erlang, media in rtpengine, FreeSWITCH or chappe_mix) and who it is for;
- the five apps in one table: role, depends on, start reading at;
- one diagram of the system (apps, external media servers, peers);
- three ways in:
  1. "Run the demo" (`make demo`, `demo/sbc/README.md`);
  2. "Build your first service" (chappe_sip getting started);
  3. "Understand the code" (`docs/README.md`);
- how to run the checks (`make check`), with a link to `CONTRIBUTING.md`.

## 4. Proposed documents

Each document is listed with its intent, reader, what the reader understands
afterwards, where it points next, and its depth.

### Umbrella

| Document | Intent | Reader | Understands after | Points to | Depth |
|---|---|---|---|---|---|
| `README.md` (rewrite) | Orientation | Everyone | What chappe is, the five apps, where to start | demo, getting started, `docs/README.md` | One screen |
| `docs/README.md` (new) | Map of all docs, by role and by question ("I want to answer calls", "I want to change the B2BUA") | Everyone | Which page answers their question | Every doc | Index only |
| `docs/concepts.md` (new) | Mental model and glossary. Leg (three meanings), A/B, anchor, direct media, flow, binding, AOR, Timer C, early media, late offer, 3PCC, owner and notify process, middleware, handler, NG, ESL inbound and outbound, MRF/MRFC/MRFP, node, peer, room, relation, talker, focus, CDR, HEP | New developers, users | The words used everywhere else | `architecture.md` | Short entries, one paragraph each |
| `docs/architecture.md` (new) | How the apps fit. Leaf apps (rtpengine, mix, esl), core (sip), orchestration (mrf), and why the dependency rules exist. Supervision at a glance. The five main flows as diagrams: inbound INVITE, anchored B2BUA, connect a caller to FreeSWITCH, native conference, registration | Developers understanding the system | Where execution enters, which app owns what, what talks to what | `decisions/`, `navigation.md`, app overviews | Medium; diagrams first, prose second |
| `docs/decisions/NNNN-*.md` (new) | One decision per page: context, decision, consequences, status. Candidates in §6 | Contributors about to change a boundary | Why a boundary exists and what breaks if moved | `architecture.md` | Half a page each |
| `docs/navigation.md` (new) | The developer guide. A table from concept to app, directory, entry module, internal modules, tests, interop lab and guide. Also: public vs internal modules per app, and where configuration and startup live | Contributors | Where to look before opening the tree | App overviews, `contributing/` | Tables |
| `CONTRIBUTING.md` (new) | How to work here: checks, commit and PR style, no em-dash, share code, tests first, labs, where AI-agent rules live | Contributors | How to get a change accepted | `contributing/` | Short |
| `docs/contributing/*.md` (new) | "If you want to..." workflows, see §8 | Contributors | The exact files, tests and checks for a task | `navigation.md` | One page each |
| `CHANGELOG.md` (merge) | Single user-facing history | Users | What changed and what it means | none | Unchanged style |

### chappe_sip

| Document | Action | Intent and notes |
|---|---|---|
| `README.md` | **Rewrite** | Role in one paragraph, public modules, three-step quickstart from the umbrella (not a standalone clone), links. |
| `AGENTS.md` | **Rewrite** | Fix the stale build and fmt notes, the module layers and the suite path. Link to `docs/design/overview.md` instead of repeating it. |
| `CHANGELOG.md` | **Merge** into root | Removes the version contradiction. |
| `docs/README.md` | Keep | Becomes the app index; add every guide (`sbc`, `b2bua-reinvite`, `capture` are missing today) and the design docs. |
| `docs/design/overview.md` | **Rewrite** | Current supervision tree. The layers of `src/` and what each directory owns. Entry points (inbound, outbound, boot). Public vs internal. A test map by area. |
| `docs/design/engine.md` | Keep, extend | Add the NIF event contract (now only in `src/engine/chappe_sip_nif.erl`), a "risky regions" section, and the reasons for the NIF. Move the M0 abort audit to an appendix. Fix the `doc/` path cited in the C header. |
| `docs/design/media.md` | **Split** | Keep the boundary and reasoning as design. Move the configuration recipes into a guide (`guides/media.md`). Link chappe_rtpengine, chappe_mix and chappe_mrf. |
| `docs/design/remote-app.md` | Keep, mark as draft | Add a status line and link it from `features.md` "Planned" and from `decisions/`. |
| `docs/design/b2bua.md` (new) | New | The B2BUA as a subsystem: modules (`b2b`, `relay`, `fork`, `early`, `media`, `replace`, `requests`, `async`, `hdr`), the relay loop, `replace_b`, ownership. |
| `docs/design/ws-transport.md` (new) | New | Why WS has its own transaction layer, how it mirrors nta, and where the two must stay in step. |
| `docs/features.md` | **Split** | Keep a short capability tracker, each line linking to its guide. Move the 270 lines of option prose into guides and moduledocs. Move "Breaking changes" to the CHANGELOG and "Planned" to issues or `decisions/`. |
| `docs/plan.md` | **Move** to `docs/history/` or remove | It stops at M16 and is maintainer history. |
| New guides | **New** | `b2bua-forking.md` (parallel fork, `pass_failure`, hunting); `b2bua-call-control.md` (`hangup`, in-dialog requests, `relay_info`, `replace_b`, `relay_async`, `set_owner`); `register-to-a-carrier.md` (regc); `protect-the-edge.md` (guard, ACL, flood, `drop`); `metrics.md`; `media.md` (from the split) |
| `docs/guides/*` | Keep; add a "Where it lives" footer | Each guide ends with modules, tests and the related lab. |
| `interop/sbc`, `interop/conformance` | **New README** each | What the lab proves, how to run it, how to add a case. |

### chappe_rtpengine, chappe_esl

- **Keep** the READMEs and guides.
- **Fix** the getting-started guides, which point to standalone repos.
- **Update** the overviews:
  - chappe_rtpengine is missing `_sdp`, `_dtmf`, `_resolve` and `_ws_handler`, and wrongly says "SDP opaque";
  - chappe_esl is missing `chappe_esl_call` and `chappe_esl_exec`.
- **Merge** the two `leaf-library-contract.md` copies into one decision record, `docs/decisions/0003-leaf-apps.md`, and leave a short pointer in each app.
- **Add** `docs/compliance/README.md` for chappe_rtpengine, or link the shared contributing page.

### chappe_mix

| Document | Action | Intent |
|---|---|---|
| `README.md` | **New** | What the mixer is, when to use it rather than a FreeSWITCH conference, and how it is reached (through `chappe_sip_media` or standalone). |
| `docs/design/overview.md` | **New** | The clock and tick model, N-1 mixing, the jitter buffer, RTCP, socket ownership, relations. Today the code and `PERF.md` are the only source. |
| `docs/guides/conference.md` | **New** | Running a room, standalone and behind rtpengine. |
| `test/audit/PERF.md`, `ATTEMPTS.md` | Keep in place, excluded from user docs | Lab notebooks. Strip the scratch path and the product names, and link them from the overview as evidence. |
| ex_doc | **Add** | Same shape as the other apps. |

### chappe_mrf

- **Keep** the README, the 3 guides and `drachtio-mapping.md`.
- **New:**
  - `docs/design/overview.md`, covering the MRFC/MRFP split, the endpoint lifecycle, the correlation header, the loopback middleware, the two conference backends and the backend callback contract;
  - `docs/features.md`;
  - `interop/README.md`.
- **Add** an ex_doc configuration and an umbrella docs target.

### demo/sbc

- Keep the README.
- Link it from the root README, the chappe_sip `sbc.md` guide and chappe_mrf.
- See finding M19: the demo is not compiled by CI.

## 5. Concepts that need dedicated explanations

1. **A call is a process.** Who owns a dialog, what happens when the owner
   dies, and the owner versus notify roles. This idea is behind every API
   that takes an `owner` or `notify` option.
2. **Legs, A and B, and the relay.** How the B2BUA bridges two dialogs and
   which side sees what.
3. **Media anchoring vs direct media**, and why `replace_b` needs anchoring.
4. **Transport flows and NAT** (RFC 5626 flows, `received`, sending to the
   source address).
5. **Two transaction layers:** sofia nta for UDP, TCP and TLS, and the Erlang
   one for WebSocket.
6. **The engine boundary:** handles, the event contract, threads, and what
   survives a restart.
7. **Media resource function:** controller vs processors, an endpoint, the
   outbound ESL socket, and correlation.
8. **The mixer's timing model.**
9. **Compliance tracking:** requirement rows, test claims, gates.

## 6. Design decisions to record, and questions for the maintainer

Each becomes a page in `docs/decisions/`. Where the reason cannot be inferred
from the repository, it is a question, not an invented answer.

| # | Decision | What the repository shows | Question for the maintainer |
|---|---|---|---|
| 0001 | SIP transactions in sofia nta through a NIF | `engine.md` explains the mechanism only | Why not a pure-Erlang transaction layer: maturity, RFC coverage, performance? |
| 0002 | One process per call | Asserted in `overview.md:32` | Confirm the reasons: isolation, crash containment, a simple owner model? |
| 0003 | Leaf apps take no SIP dependency | A rule in `AGENTS.md` | Is publishing each app on its own the main reason? Should chappe_mix count as a media leaf, given that the contract says "no media concept"? |
| 0004 | rtpengine stays an external daemon | Implicit | Confirm: SRTP/DTLS/ICE and transcoding are out of scope for Erlang? |
| 0005 | chappe_mix exists next to FreeSWITCH conferences | Evidence only in `ATTEMPTS.md` and `PERF.md` | Confirm the reasons: density, latency, control over relations, the rtpengine mixer not usable? |
| 0006 | chappe_mrf is an orchestration app | A rule in `AGENTS.md` | Confirm the placement rule for future orchestration apps. |
| 0007 | WebSocket has its own Erlang transaction layer | Moduledoc only | Why not sofia's WS transport? |
| 0008 | The remote-app model | `remote-app.md` draft, `plan.md` "dropped", `features.md` "planned" | Which is true now? Keep as draft, mark rejected, or delete? |
| none | Versioning and publishing | Root 0.1.0, chappe_sip 0.2.0, per-app `source_url` to old repos | One version for the umbrella, or one per app on hex? Are the old per-app repos mirrors or retired? |
| none | Product references in open-source docs | Skills and notebooks name product repos (i3_bridge, chappe_pbx) | Acceptable, or should they be removed? |
| none | Public API stability | Nothing stated | Which modules are public, and what is the deprecation policy? |

## 7. Developer navigation guide (seed for `docs/navigation.md`)

| If you care about | App, directory | Start at | Internal modules | Tests | Lab |
|---|---|---|---|---|---|
| Answering and placing calls | chappe_sip `src/api`, `src/dialog`, `src/uac` | `chappe_sip`, `chappe_sip_dialog`, `chappe_sip_uac` | `chappe_sip_dialog_fsm`, `chappe_sip_uac_fsm` | `core`, `core_uac`, `uas`, `uac`, `indialog`, `dialog_ops`, `handler` | conformance |
| Inbound request pipeline | `src/engine`, `src/conn` | `chappe_sip_engine` (`handle_event`, `dispatch`), `chappe_sip_request_worker` | `chappe_sip_middleware`, `chappe_sip_guard` | `pipeline` (fake engine), `guard`, `ood` | none |
| B2BUA | `src/api/chappe_sip_b2b*` | `chappe_sip_b2b` | `b2b_relay`, `_fork`, `_early`, `_media`, `_replace`, `_requests`, `_async`, `_hdr` | `b2bua`, `b2b_relay`, `forked_2xx`, `webrtc_gateway` | sbc |
| Proxy | `src/proxy` | `chappe_sip_proxy` | `_proxy_rules`, `_proxy_dialog`, `_route` | `proxy_conf`, `proxy_forking`, `proxy_record_route`, `proxy_media` | conformance |
| Registrar and location | `src/api/chappe_sip_registrar`, `src/conn/chappe_sip_registry` | `chappe_sip:registrar/1` | `_registry`, `_registry_keeper`, `_qualify` | `registrar`, `digest` | conformance |
| Registering to a carrier | `src/api/chappe_sip_regc` | `chappe_sip:register_client/2` | `_regc_sup` | `regc` | none |
| WebSocket and WebRTC | `src/ws` | `chappe_sip_ws_listener` | `_ws_transport`, `_ws_conn` | `websocket`, `ws_conf`, `webrtc_gateway` | sip-interop (JsSIP) |
| Presence, MWI, subscriptions | `src/api` (packages), `src/dialog` (subscriber, refer) | `chappe_sip:event_package/2` | `_notifier`, `_subscriber`, `_notify_router` | `subscribe`, `subscriber`, `presence`, `refer` | none |
| Peers, OPTIONS, failover | `src/peers` | `chappe_sip:peer_add/2` | `_peer`, `_peers` | `peers` | sbc |
| Media facade | `src/media` | `chappe_sip_media` | `_media_rtpengine`, `_media_mix` | `media` (fake), `proxy_media` | interop |
| The C engine | `c_src`, `src/engine/chappe_sip_nif` | `docs/design/engine.md` | `chappe_sip_engine_nif.c` | `engine_lifecycle`, `engine_smoke`, `ops` | asan |
| rtpengine control | chappe_rtpengine | `chappe_rtpengine`, `chappe_rtpengine_session` | `_client`, `_pool`, `_ng`, `_bencode` | `client`, `pool`, `session`, `dtmf`, `live`, `e2e` | interop |
| Conference mixing | chappe_mix | `chappe_mix` | `_conf`, `_room`, `_leg`, `_dsp`, `_jbuf` | `chappe_mix`, `rfc`, `live`, `ref` | interop-mix, interop-ref |
| FreeSWITCH control | chappe_esl | `chappe_esl`, `chappe_esl_call` | `_conn`, `_exec`, `_node`, `_nodes` | `conn`, `call`, `outbound`, `nodes`, `live` | interop-esl |
| IVR, bridging, conferences | chappe_mrf | `chappe_mrf`, `chappe_mrf_conf` | `_endpoint`, `_esl`, `_registry`, `_conf_native`, `_conf_fs` | `chappe_mrf`, `live` | interop-mrf |
| Compliance | `apps/*/docs/compliance` | `requirements.tsv` | `apps/chappe_sip/test/chappe_sip_compliance.erl`, `scripts/compliance.escript` | all suites (`%% req:` lines) | conformance |
| Configuration | `chappe_sip_config` (defaults); app env per app | `chappe_sip_config:get/1` | none | each app's suites | none |

## 8. Contributor workflows ("If you want to...")

One page each under `docs/contributing/`. Every page names real directories,
modules, tests and the check to run.

1. **Run and read the checks and labs:** what `make check` does, every
   `make interop-*` target, what each lab proves, the env gates
   (`RTPENGINE_HOST`, `FS_HOST`, `MRF`, `INTEROP`, `CONFORMANCE`), and `*_KEEP`
   to keep a lab up.
2. **Debug a call through the system:** HEP capture, CDR events, SIPp traces,
   `chappe_rtpengine:query`, `fs_cli`, and which process owns what.
3. **Change B2BUA behaviour:** the b2b modules, the relay loop, the tests to
   extend, and the sbc lab.
4. **Add a SIP feature or header:** `chappe_sip_hdr`, `chappe_sip_msg`, the
   facade, compliance rows.
5. **Add an event package:** notifier, subscriber, `event_package/2`, an
   example from presence or MWI.
6. **Add a media backend or capability:** `chappe_sip_media` capability
   routing, the backend adapter shape, the fake (`chappe_sip_test_rtpe`).
7. **Add a chappe_mrf conference backend:** today an implicit callback
   contract; see finding M16.
8. **Add an app to the umbrella:** where it sits (leaf, core,
   orchestration), the rebar, Makefile, CI, elvis and ex_doc wiring.
9. **Add tests:** fakes per app (`chappe_sip_engine_fake`,
   `chappe_rtpengine_fake_server`, `chappe_esl_fake_server`,
   `chappe_mrf_fake`), CT conventions, running a test against the old code
   first, flaky-test guidance.
10. **Add an interop lab:** the compose, script and env-gate pattern shared by
    the five labs.
11. **Add or update a compliance row:** one shared page, replacing three
    near-duplicate READMEs.
12. **Write or change a guide:** style, where it goes, adding it to ex_doc
    extras and the index, and how `doc_snippets_tests` checks snippets.
13. **Change the C engine:** read `engine.md` first, the risky regions, ASan.
14. **Extend the public API:** the facade, documenting the option, guide,
    CHANGELOG, compliance.

## 9. Maintainability findings

Primary problem: **Doc** (documentation), **Nav** (navigation), **Name**
(naming), **Org** (module organisation), **Cx** (code complexity), **Arch**
(genuine architecture). "Doc first" means the boundary should be written
down before any code split is planned.

| # | Area | Measurements | Finding | Primary | Recommendation |
|---|---|---|---|---|---|
| M1 | `chappe_sip_engine` | 1891 lines, 116 funcs, 39 exports; `handle_call` 354 lines (about 60 clauses), `handle_event` 125, `handle_info` 100; 11-field state; fan-in 15, fan-out 21 | Eight responsibilities: NIF lifecycle and health, config snapshot, route registry, inbound dispatch policy (merge, stray, unhandled), worker pool, handle table, UAS response building, sofia/WS multiplexing. No one sentence describes it. It also depends upward on the proxy. | Org, then Arch | Doc first: a responsibility map in the overview. A later split can move out the stateless parts (UAS response building, dispatch policy). Keep the process state in place. Tests only use a narrow API, so internals can move. |
| M2 | `chappe_sip_dialog_fsm` | 1717 lines, 134 funcs, 47-field data; `confirmed` 124, `in_transaction` 83 | State machine, subscription lifecycle, SDP hold rewriting, session-timer glue, request building and the index, in one module. The state is partly implicit in flags. The moduledoc is stale ("M3"). | Cx, Org | Doc the states and the variants. Later, move SDP hold to the sdp module, `requested_expires` to hdr, and subscription teardown to its own module. Tests: `dialog_fsm_tests`, `indialog`, `dialog_ops`, `subscribe`, `session_timer`, `replaces`, `prack*`. |
| M3 | `chappe_sip_uac_fsm` | 1228 lines; `handle_response` 143 | A long chain of status classes; auth and redirect are pure and separable | Cx | Later: extract auth and redirect helpers (low risk, nothing calls the fsm directly). |
| M4 | `chappe_sip_ws_transport` | 1102 lines, 85 funcs | A second transaction layer mirroring nta in one gen_server | Arch | Doc first (`design/ws-transport.md`, decision 0007). A split along server, client and wire helpers would help later. |
| M5 | `src/api/` directory | 26 modules | Mixes the facade, extension behaviours, feature subsystems (b2b x9, focus, cdr, regc, registrar) and event packages. Event packages are split between `api/` and `dialog/`. The CDR is a core service filed as API. | Nav, Org | Doc the layout first. Later, `b2b/` and `events/` directories, with cdr moved to core. |
| M6 | `chappe_sip_route` | 358 lines | Record-Route, HMAC markers and the boot secret, WS flow tokens and NAT `received_flow`, used by the engine, dialogs, uac, b2b and the registrar. "route" under `proxy/` hides that. | Name | Rename or split (`route`, `flow`), or at least document. |
| M7 | `chappe_sip` facade | 427 lines, 49 exports, fan-out 26 | Core modules (engine, refer, media, request worker) call back into the facade, which creates cycles | Arch | Move the shared helpers the core uses out of the facade. |
| M8 | Public vs internal | none marked | ex_doc groups expose internals and omit public modules. Doc comment styles differ (`%% @doc` in chappe_sip, plain `%%` elsewhere, no `-moduledoc`). Several moduledocs are stale or missing (`chappe_sip`, `dialog_fsm`, `b2b_hdr`, `focus`, `confinfo`, `hdr`). | Doc, Nav | Mark internal modules in ex_doc, fix the groups, and settle one doc comment convention. These are doc-only changes to source comments. |
| M9 | `chappe_sip_hdr` and `hdr_io` | 695 lines; `hdr_io` has one function | The scope has grown beyond what the moduledoc says; `hdr_io` sits next to `hdr` but serializes. | Name, Doc | Update the moduledoc. Possibly fold `hdr_io` into `msg`. |
| M10 | `chappe_rtpengine_session` | 682 lines, 33 exports; `handle_event` 197, `reply` 68 | A state x reply cross-product, plus about 20 thin command wrappers | Org, Cx | Later, move the command wrappers to their own module. Doc the state model. |
| M11 | `chappe_rtpengine_client` | 585 lines | UDP retransmit, the TCP stream and WS in one gen_server, branching on transport | Arch | Later, a transport behaviour. |
| M12 | `chappe_rtpengine_pool` | `handle_call` 58 | Lock-free reads in the caller while the gen_server writes, generation counters | Doc | Document the concurrency model in the overview. |
| M13 | `chappe_mix_conf`, `_dsp`, `_jbuf` | 456 lines and smaller | The timing model, RTCP schedule and socket ownership are hard; the code is cohesive | Doc | New design overview. |
| M14 | `chappe_esl_call` and `chappe_esl_exec` | 432 lines, 29 exports | Correlation is split across two modules for size reasons; the reader must know both | Nav, Org | Document the split, or regroup by concept. |
| M15 | `chappe_esl_conn` | 325 lines | One FSM for inbound (authenticating) and outbound (accepting) mode | Arch | Doc first; a split by mode later if it grows. |
| M16 | `chappe_mrf_conf` and its backends | 446 lines, 33 exports | The public API is mixed with an implicit backend callback API (`call`, `emit`, `gone`, `talking`, `member`), and calls run both ways | Arch, Org | Define a `chappe_mrf_conf_backend` behaviour and document it. This also makes workflow 7 possible. |
| M17 | `chappe_mrf` facade | 347 lines, 30 exports | Also holds the loopback middleware, node candidate selection and focus code | Org | Later, move those into their own modules. |
| M18 | Shared tooling inside one app | `chappe_sip_compliance.erl` and `doc_snippets_tests.erl` live in `apps/chappe_sip/test` but serve all apps | Hard to find, and it couples every app to chappe_sip's test dir | Nav, Org | Move to an umbrella `tools/` (or `test/`) directory. |
| M19 | `demo/sbc` | 560 lines | Not compiled by any test or CI job, so it can rot | Org | Compile it in CI (and run the scripted SIPp walk). |
| M20 | Configuration keys | `env []` in every `.app.src` | App env keys are documented only in code or scattered guides (`chappe_mrf` `esl_port` only in an `.app.src` comment) | Doc | One configuration reference per app, linked from `navigation.md`. |
| M21 | The C NIF | 2619 lines; `op_cb` about 300 lines (14 ops), `nif_start` about 155 | Risky regions (state CAS, root rwlock, dtor and down, table drain ownership, stray 2xx handling) are only partly marked | Doc, Cx | A "risky regions" section in `engine.md` with line anchors. |
| M22 | elvis ignore lists | 8 modules exempt from size and duplication rules | The ignore list is an implicit debt register, and the reasons sit next to only some entries | Doc | Give each exemption a reason and link it to the finding here. |

Unusually large functions worth reviewing:

| Function | Lines |
|---|---|
| `chappe_sip_engine:handle_call` | 354 |
| `op_cb` in the NIF | about 300 |
| `chappe_rtpengine_session:handle_event` | 197 |
| `nif_start` | about 155 |
| `chappe_sip_uac_fsm:handle_response` | 143 |
| `chappe_sip_engine:handle_event` | 125 |
| `chappe_sip_dialog_fsm:confirmed` | 124 |
| `chappe_sip_engine:handle_info` | 100 |
| `chappe_sip_dialog_fsm:in_transaction` | 83 |

Large and coherent, so acceptable as they are, with better docs:

| Module | Lines | Role |
|---|---|---|
| `chappe_sip_registry` | 631 | the location store |
| `chappe_sip_proxy` | 500 | RFC 3261 section 16 |
| `chappe_sip_msg` | 418 | the message model |
| `chappe_sip_subscriber` | 473 | the RFC 6665 subscriber |
| `chappe_sip_regc` | 392 | the registration client |
| `chappe_sip_confinfo` | 466 | pure rendering |

## 10. Diagrams and examples

1. **System context.** The five apps, external rtpengine, FreeSWITCH
   nodes, SIP peers, browsers, and the dependency arrows (for `README.md` and
   `architecture.md`).
2. **Sequence diagrams for the five flows in §7 of `architecture.md`.**
   Inbound INVITE, anchored B2BUA, `connect_caller` to FreeSWITCH, native
   conference join through the loopback, registration.
3. **Supervision trees.** One small tree per app, generated or kept short.
4. **Dialog states.** The dialog fsm states and their variants.
5. **The B2BUA relay and `replace_b`.** Who sends what to whom; A sees no
   re-INVITE.
6. **Engine threads and handles.** This already exists in `engine.md`; link
   it.
7. **The mixer tick.** Packets in, tick, N-1 mixes out.
8. **The compliance pipeline.** TSV rows, `%% req:` claims, CT logs, matrix,
   gate.
9. **A worked example per concept page.** A runnable snippet (checked by
   `doc_snippets_tests`).

## 11. Implementation order

Each step is its own PR, documentation only unless stated.

1. **Orientation and quick fixes.**
   - Root `README.md`, `docs/README.md`, `docs/concepts.md`.
   - The stale statements listed in §1.5, including both AGENTS files, the
     chappe_sip README quickstart and the getting-started repo links.
   - Merge the CHANGELOGs.
2. **Architecture and decisions.**
   - `docs/architecture.md` with the context and flow diagrams.
   - `docs/decisions/` for 0001 to 0008, after the maintainer answers §6.
   - Merge the leaf-library contracts into 0003.
3. **Navigation.**
   - `docs/navigation.md`.
   - Fix the ex_doc groups, mark internal modules, add ex_doc to chappe_mix and
     chappe_mrf, and add an umbrella `make docs`. This touches only the
     rebar.config files and doc comments.
4. **App overviews.**
   - Rewrite the chappe_sip `overview.md`.
   - New overviews for chappe_mix and chappe_mrf, the chappe_mix README, and
     updates to the rtpengine and esl overviews.
   - New `design/b2bua.md` and `design/ws-transport.md`.
5. **Contributor guide.** `CONTRIBUTING.md` and the 14 workflows, starting
   with labs, debugging a call, and adding tests.
6. **Missing user guides** for #17 and #18 features, and a "Where it lives"
   footer on every guide.
7. **Reorganise existing pages.**
   - Split `features.md` and `media.md`.
   - Archive `plan.md`.
   - Add READMEs to the sbc and conformance labs.
8. **Maintainability, documentation side.** Address M8, M12, M13, M20, M21 and
   M22. These need no code change.
9. **Maintainability, code side.** Each gets its own plan, in this order:
   1. M19 (demo in CI)
   2. M18 (shared tooling)
   3. M16 (mrf backend behaviour)
   4. M6 (route naming)
   5. M5 (directories)
   6. M1, M2, M3, M4, M7 and M10 to M11, refactors that only start once their
      boundary is documented.
