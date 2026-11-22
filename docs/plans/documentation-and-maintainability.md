# Documentation and maintainability plan

This is a plan, not documentation. It records what a human developer meets
when they open the repository today, what is missing or misleading, and the
order in which to fix it. Every step below is documentation only.

Baseline: `main` at `e62b356` (after #41). Line counts are code lines,
without blanks or comments.

History:

- The first version of this plan (2026-10-31, baseline `e539f8d`) was
  carried out in #19.
- The second version (2026-11-17, baseline `77dea16`) found drift and
  growing modules. The maintainer chose to fix the code first. #38 (mrf
  conference backends), #39 (leaf apps and the demo build) and #41
  (chappe_sip boundaries) did that. Section 7 lists what they changed.
- This third version describes the layout after those PRs and records the
  maintainer's answers (section 6).
- The release review of 2026-11-22 (baseline `878b5c9`, after #73) is
  section 12: what changed since, the drift it left, and what to fix
  before the first release since 0.1.0.

## Status

Done (2026-11-18). Each step of section 11 shipped as its own PR:

| Step | PR |
|---|---|
| 1. Drift fixes, five leaf apps in 0003 | #43 |
| 2. Decisions 0002 to 0016 | #45 |
| 3. ex_doc groups and extras | #46 |
| 4. Glossary and the concepts split | #48 |
| 5. Navigation rows, labs, add-tests, debug-a-call | #49 |
| 6. Design pages: cluster, SIPREC, registrar, rooms in a cluster | #50 |
| 7. Workflows: cluster, location, audio store, directory | #51 |
| 8. `make docs-check` in CI | #52 |

Test races found on the way were fixed in #44 and #47. The open code
findings of section 9 stay open, each for its own plan. `make docs-check`
now keeps the groups, extras, supervisor names and links from drifting
again; the facts it cannot check (prose, trees, counts) are the ones
section 1 says to point at rather than copy.

## 1. Where the repository stands

The structure from #19 works and stays:

- the orientation path: README, `docs/README.md`, concepts, architecture,
  decisions, navigation;
- one design overview, a configuration reference and a short `features.md`
  per app;
- 14 contributor workflows;
- a "Where it lives" footer on every chappe_sip guide;
- decisions 0001 to 0010.

The code PRs updated the pages that named the modules they moved (AGENTS
files, `navigation.md` paths, `engine.md`, `media.md`, the siprec guide,
decision 0009, workflow 7). The cross-cutting drift from #20 to #37 is still
there:

| Page | What drifted |
|---|---|
| `README.md` | The apps table and the diagram show 5 of the 7 apps. They miss SIPREC, `make demo-cluster` and the cluster lab. The RTP rule (:53) is true again since #41, but reads as if no exception was ever considered: say where SIPREC audio goes (chappe_audio). |
| `docs/architecture.md` | Says "five apps" (:3). The core is described as using only rtpengine and mix (:50), with no edge to cluster or audio. Supervision trees miss 7 chappe_sip children, `chappe_audio_adopt_sup`, `chappe_audio_rtp_sup` and `chappe_cluster_hlc`. |
| `docs/concepts.md` | No entry for lease, epoch, fence, singleton, region, quorum, HLC, `call_ref`, SIPREC (SRC, SRS), audio fork, stream, store, sweep, location backend, directory, pg scope or ESC. "Fork" is used in two senses (B2BUA fork, audio fork). |
| `docs/navigation.md` | No rows for audio, cluster, SIPREC, call correlation, location backends, flows, transfer and join, SRTP or metrics HTTP. Rows for chappe_sip predate `src/b2b`, `src/events`, `src/core` and the engine split. |
| `docs/README.md` | No chappe_cluster row. The guide list misses `siprec.md` and `follow-a-call.md`, and the labs list misses the mix, mrf and cluster labs. |
| `docs/contributing/labs.md`, `add-tests.md` | No `interop-cluster`, `demo-cluster`, `demo-compile`, `demo-esl`, `advisories` or `fuzz`. No audio or cluster fakes, no multi-node test helpers. The umbrella `test/` directory (doc snippets, compliance tests) is not described. |
| `apps/chappe_sip/docs/design/overview.md` | The supervision tree misses `pg`, `call`, `hlc`, `metrics_http`, `b2b_sup`, the siprec sups and `proxy_sup`. The boot section misses the cluster check and `prep_stop`. The directory table misses `b2b/`, `events/`, `core/`, `siprec/`, the location backends and `lib`, and still puts the route module under `proxy/`. The engine section does not name `chappe_sip_dispatch` and `chappe_sip_uas_response`. The test map is stale. |
| `apps/chappe_mrf/docs/design/overview.md` | Never mentions the cluster. The module table misses `_conf_backend`, `_conf_cluster`, `_conf_transfer`, `_conf_focus`, `_conf_fs_join`, `_conf_move`, `_conf_refer` and `_store`. `configuration.md` says "one key" (there are nine). |
| `apps/chappe_audio/docs/design/overview.md` | Misses `chappe_audio_rtp`, `_rtp_sup`, `_srtp`, `_adopt_sup`, `_adopt` and `lib`, and the SIPREC path into the store. |
| `apps/chappe_mix`, `chappe_esl`, `chappe_rtpengine` overviews | Miss `chappe_mix_move` and `_tap`, `chappe_esl_cidr` and `chappe_esl_verbs`. Give a wrong `ws` pin. Leave `holder =>` and `reoffer_tags` out. |
| ex_doc groups | About 30 chappe_sip modules are ungrouped, 5 of them public (`call`, `siprec`, `siprec_srs`, `location`, `multipart`), and the modules added by #41 are in no group. `siprec.md` and `follow-a-call.md` are not extras. chappe_cluster groups 3 of 13 modules; chappe_audio has no "Internal" group. |
| Contradictions | Some pages say chappe_cluster "starts on first use", while the code starts it at boot (chappe_sip `configuration.md:119`, chappe_mrf `README.md:21`). The remote-app model is "out of scope", "Open" and "Planned" in three places. Decision 0010 describes per-node ownership in the present tense and leaves the KV question open. |

What this tells you about the fix: **pages that copy facts from the code
drift; pages that point to the code do not.** The supervision trees, the
module lists, the leaf-app list (kept in 4 places, two already wrong) and the
counts are all copies. The plan removes copies where it can, and checks the
remaining ones in CI.

## 2. Recommended structure

Keep the #19 layout. Change four things:

```
README.md                  orientation; 7 apps; 4 ways in
docs/
  README.md                map, by reader and by question
  concepts.md              the mental model only (about 150 lines)
  glossary.md              NEW: one-paragraph terms, alphabetical, linked from everywhere
  architecture.md          apps, dependency rules, main flows; NO full supervision trees
  decisions/               + 0011 to 0016 (section 6)
  navigation.md            concept -> module -> test, one row per subsystem
  contributing/            + 5 workflows (section 8)
  plans/                   this plan
apps/<app>/docs/design/overview.md   the ONLY home of the app's supervision tree and module list
```

1. **Split `concepts.md`.** At 343 lines it mixes a mental model with a
   glossary, and the new terms would push it past 450. The model (a call is
   a process, owner and notify, legs, anchoring, flows, the engine boundary,
   ownership in a cluster) stays in `concepts.md`. The definitions move to
   `glossary.md`.
2. **Supervision trees live once, in each app's overview.**
   `architecture.md` keeps a one-level picture (each app's top supervisor
   and its main subtrees) and links to the overview.
3. **The leaf-app list lives once,** in decision 0003. Other pages link to
   it instead of listing the apps.
4. **chappe_cluster gets the same page set as the other apps:**
   `design/overview.md`, `configuration.md`, `features.md`, and its lab in
   the ex_doc extras.

## 3. The starting point

The root `README.md` stays the single entry point: in one screen, what
chappe is, the apps, the ways in, and the checks. It needs:

- the 7 apps in the table, each with one line and its layer;
- the diagram with chappe_audio, chappe_cluster and the SIPREC path (SIP
  signalling to chappe_sip, recorded RTP to chappe_audio);
- a fourth way in: "Run several nodes" (`make demo-cluster`,
  `demo/cluster/README.md`);
- the RTP rule kept, with one clause: "a SIPREC recording's audio is taken
  in by chappe_audio, see 0012";
- the OTP floor said once, with a link, not repeated in three files.

## 4. Proposed documents

### Umbrella

| Document | Action | Intent and reader | Understands after | Points to | Depth |
|---|---|---|---|---|---|
| `README.md` | Update | Orientation, everyone | The 7 apps and where to start | demos, getting started, `docs/README.md` | One screen |
| `docs/README.md` | Update | The map. Add chappe_cluster, the two missing guides, the three labs, and the questions "run several nodes", "record with SIPREC", "follow a call across nodes" | Which page answers their question | every doc | Index only |
| `docs/concepts.md` | Rewrite (shorter) | Mental model, new developers. Add one section: ownership in a cluster (lease, epoch, fence; lookups on pg, ownership on Ra; a lost quorum stops claims, not calls) | Why chappe is shaped as it is | `glossary.md`, `architecture.md` | About 150 lines |
| `docs/glossary.md` | New | Terms, everyone. Every term in section 1's concepts row, plus the existing ones moved from concepts. "Fork" gets two entries. "Node" separates a FreeSWITCH or rtpengine node from a cluster node | The words used everywhere else | the page that owns each term | One paragraph per term |
| `docs/architecture.md` | Update | How the apps fit, developers. 7 apps, the real dependency edges (chappe_sip and chappe_mrf to cluster and audio, as optional siblings), one-level supervision, and three new flows (section 10) | Where execution enters and what talks to what | decisions, app overviews | Diagrams first |
| `docs/navigation.md` | Update | Concept to code, contributors. The rows of section 7, the new chappe_sip directories, and audio and cluster in the public, startup and fakes tables | Where to look before opening the tree | app overviews, workflows | Tables |
| `docs/decisions/0011` to `0016` | New | Why, for contributors changing a boundary (section 6) | What breaks if the boundary moves | architecture | Half a page each |
| `docs/decisions/0010` | Update | Record what #37 moved onto the cluster, and close the KV question: bindings stay in the region KV, limited by `max_keys` (100,000 by default) and the write rate of one Ra group | The current state and its limit | cluster overview | Small edit |
| `docs/decisions/0002`, `0003`, `0004`, `0005`, `0006`, `0007` | Update | Mark them Accepted; drop "to confirm" | The records are decisions, not guesses | none | One line each |
| `docs/decisions/0008`, `docs/drachtio-parity.md` | Update | One status everywhere: the remote-app model is planned | One answer | 0008 | Small edit |
| `docs/contributing/labs.md`, `add-tests.md`, `debug-a-call.md` | Update | Add the cluster lab and demo, `demo-compile`, `demo-esl`, `advisories`, `fuzz`, the audio and cluster fakes, `*_test_dist` and peer suites, the umbrella `test/` directory, and `call_ref` and HEP in debugging | Which lab or helper to use | each lab README | Rows |
| `CONTRIBUTING.md` | Update | Say that the first release has no deprecation policy: an unused export is removed, and the CHANGELOG lists it under "breaking" | What to do with an export nobody calls | CHANGELOG | One paragraph |

### Per app

| App | Keep | Update | New |
|---|---|---|---|
| chappe_sip | guides (all have footers), `features.md`, `configuration.md` | `design/overview.md`: tree, boot and `prep_stop`, the new directories, the engine split (`_engine`, `_dispatch`, `_uas_response`, the proxy forwarder), counts, public modules, the test map with Cluster and SIPREC rows. `configuration.md:119`. The sbc and conformance lab READMEs. ex_doc groups and extras | `design/siprec.md`: SRC and SRS, the meta and body modules, the hand-off of RTP to `chappe_audio:rtp_receiver/1`, the 488 when chappe_audio is not running. `design/registrar.md`: the location behaviour and its callbacks, the serialized and CAS write modes, edge routes and flow tokens (`chappe_sip_flow`), why 430 and 503 |
| chappe_cluster | README, `guides/cluster.md`, AGENTS | ex_doc: group all 13 modules, add the lab README as an extra | `design/overview.md`: supervision (who owns the holder table and why), the machine and its no-clock rule, the holder deadline, singletons, the directory seam, tests and the lab checker. `configuration.md` (moved from the README table). `features.md`. A "Where it lives" footer |
| chappe_audio | README, configuration, features, guides | overview: `rtp`, `rtp_sup`, `srtp`, `adopt_sup`, `adopt`, `lib`, the SIPREC receiver, a test map. ex_doc "Internal" group, `features.md` in extras. Footers on `fork.md` and `record.md` | none |
| chappe_mrf | README, guides, drachtio mapping, workflow 7 (rewritten in #38) | `design/overview.md`: the backend behaviour and its optional callbacks, a "Rooms in a cluster" section (claim in the caller through `_conf_cluster`, the waiting room, draining, `prep_stop` handoff, rehome, why fs rooms do not move, the timeouts and why), transfers as `{Reply, Members, Actions}`, the module table, failure rows (clean stop, lost lease, no quorum). `configuration.md`: nine keys, read where. README wording on when chappe_cluster starts. Interop README: the cluster suite | none |
| chappe_mix | everything | overview: `_move`, `_tap` (and why a tap drops frames when the remote distribution buffer is full). `configuration.md`: tap options | none |
| chappe_esl | everything | overview: `_verbs` (argument checks and command building) next to `_call` (the process), `_cidr`, `start_listener/4`. `configuration.md`: `bugname`. Outbound guide: the screen-before-spawn order and the accept backoff | none |
| chappe_rtpengine | everything | overview: `_cmd` (the media commands) next to `_session` (the state machine), the `ws` pin. `features.md`: `stop_forwarding/2`, and drop the "seven gates" line. Subscriptions guide: `holder =>`. Sessions guide: via-branch re-offers | none |

The two `leaf-library-contract.md` stubs are 6-line pointers. Remove them,
their ex_doc extras and their index lines: 0003 is the record.

## 5. Concepts that need a dedicated explanation

1. **Ownership in a cluster.** Ownership needs consensus and lookups do not:
   that is why both pg and Ra are present. Epoch leases (one renewal keeps
   every lease of a node), fences, and what a lost quorum stops. Home:
   `concepts.md`, then the chappe_cluster overview.
2. **Time without wall clocks.** Monotonic deadlines on the holder, the
   leader's expiry timer, HLC for ordering. There is one clock per node:
   chappe_cluster's when it runs, otherwise chappe_sip's own
   (`chappe_sip_hlc`). This is written only in the `chappe_sip_hlc`
   moduledoc.
3. **Reaching a device registered on another node.** The edge route, the
   flow token tied to one boot, 430 when the flow is gone. Home: the
   registrar design page.
4. **Call correlation.** `call_ref`, the pg lookup, following a call across
   nodes. `follow-a-call.md` covers use, not the model.
5. **Recording paths.** Three ways audio leaves a call (an rtpengine fork, a
   FreeSWITCH `mod_audio_stream` fork, SIPREC to the built-in SRS), and all
   three now land in chappe_audio (streams, the RTP receiver, the store).
   Today this is spread over five guides in three apps.
6. **Optional sibling apps.** chappe_sip and chappe_mrf use chappe_cluster
   and chappe_audio without listing them in `applications`, so that the
   stop order lets a node hand off before it stops. A release must include
   `{chappe_cluster, load}`, and SIPREC needs chappe_audio running. This is
   written only in code comments and `optional_applications`.

## 6. Decisions to record, and the maintainer's answers

Answers given on 2026-11-17:

| # | Question | Answer | What the docs say |
|---|---|---|---|
| Q1 | 0008, the remote-app model | Planned | 0008 and `drachtio-parity.md` say "planned" |
| Q2 | Records marked "Proposed, to confirm" (0002, 0004, 0005, 0007) and reasons to confirm (0003, 0006) | Accepted as written | Status Accepted |
| Q3 | Registrar bindings in the region KV at scale | Keep them in the KV; document the limit | 0010 and 0015: `max_keys` (100,000 by default) and one Ra group's write rate; a deployment above that splits regions |
| Q4 | SIPREC RTP in a SIP process | Move it to chappe_audio (done in #41) | 0012 is a rule, not an exception: SIP processes carry no media |
| Q5 | Public API and deprecation | No deprecation policy for the first release; unused exports are removed | `CONTRIBUTING.md`, the ex_doc groups |
| Q6 | chappe_mrf_conf backends | A behaviour (done in #38) | Workflow 7 and the mrf overview say "implement `chappe_mrf_conf_backend`" |

Records to write:

| # | Decision | Evidence |
|---|---|---|
| 0011 | chappe_audio is a leaf app with a store behaviour, and takes in recorded RTP | moduledocs, `chappe_audio:rtp_receiver/1` |
| 0012 | A SIPREC SRS: SIP in chappe_sip, audio in chappe_audio; SIP processes carry no media | #41, `chappe_sip_siprec_srs` |
| 0013 | Calls are found across nodes through `call_ref` on pg, not owned | code, `follow-a-call.md` |
| 0014 | chappe_cluster and chappe_audio are optional siblings, started by their users, kept out of `applications` for the stop order | `chappe_sip_app.erl`, `chappe_mrf_app.erl`, `optional_applications` |
| 0015 | Registrar bindings sit behind a location behaviour; cross-node calls route through the edge node; bindings stay in the region KV up to its limit | `chappe_sip_location`, `chappe_sip_flow` |
| 0016 | Security defaults: the ESL listener binds loopback with an allow list, sofia's own WS transport stays closed, the OTP floor, the advisory gate | #36, CHANGELOG |

## 7. Developer navigation guide

What the code PRs changed, which the navigation and the overviews must
describe:

| Concept | Before | Now |
|---|---|---|
| Conference backends | `case` on the backend inside `chappe_mrf_conf` | `chappe_mrf_conf_backend` behaviour; the room calls `Mod:F`; a missing optional callback answers `{error, {unsupported, Backend}}` |
| Rooms in a cluster | inside `chappe_mrf_conf` | `chappe_mrf_conf_cluster` (caller-side start, lease decisions) |
| Transfers out of a room | inside `chappe_mrf_conf` | `chappe_mrf_conf_transfer`, pure, returns `{Reply, Members, Actions}` |
| ESL verbs | inside `chappe_esl_call` | `chappe_esl_verbs`; `chappe_esl_call` keeps the process and one-line wrappers |
| rtpengine media commands | `chappe_rtpengine_session` | `chappe_rtpengine_cmd` |
| SIPREC audio | `chappe_sip_siprec_rtp`, `chappe_sip_srtp` | `chappe_audio_rtp`, `chappe_audio_srtp`, `chappe_audio_pcm:decode/2` |
| Flow tokens, edge routes | `chappe_sip_route` in `proxy/` | `chappe_sip_flow` in `sip/`; `chappe_sip_route` keeps Record-Route |
| Registrar cluster policy | `chappe_sip_registry` | the `chappe_sip_location` callbacks, implemented in `_location_cluster`; `_registry_store`, `_registry_contact` |
| Engine dispatch and UAS responses | `chappe_sip_engine` | `chappe_sip_dispatch`, `chappe_sip_uas_response`, both pure |
| B2BUA, events, core | `src/api/` | `src/b2b/`, `src/events/`, `src/core/` |
| UAC auth, SDP hold, subscriptions | inside the fsms | `chappe_sip_uac_auth`, `chappe_sip_sdp:hold/2`, `chappe_sip_subscription` |
| Compliance generator, doc snippets | `apps/chappe_sip/test` | `scripts/compliance/`, umbrella `test/` |
| Facade calls from inside the stack | 13 | none; an xref query in `rebar.config` keeps it so |

Rows to add to `docs/navigation.md`:

| If you care about | App, directory | Start at | Internal modules | Tests | Lab |
|---|---|---|---|---|---|
| Ownership in a cluster | chappe_cluster `src` | `chappe_cluster` | `_machine`, `_node`, `_ra`, `_lapse`, `_tab`, `_watch`, `_config` | `chappe_cluster_SUITE`, the PropEr machine tests, `test/lab` | `make interop-cluster` |
| Singletons | chappe_cluster | `chappe_cluster:singleton/2` | `_singleton`, `_singleton_sup` | cluster suites | `make interop-cluster` |
| Cross-region seam | chappe_cluster | `chappe_cluster_directory` | `_directory_local` | eunit | none |
| Location store | chappe_sip `src/conn` | `chappe_sip_location` (behaviour) | `_location_ets`, `_location_cluster`, `_registry_store`, `_registry_contact`, `_registry_sweep` | `registrar_cluster`, `location_lagging`, `registry_lag_tests` | `make demo-cluster` |
| Edge routes, flow tokens | chappe_sip `src/sip` | `chappe_sip_flow` | `chappe_sip_route`, `_proxy_dialog` (430) | `registrar_cluster`, `proxy_record_route`, `route_tests` | `make demo-cluster` |
| Engine dispatch | chappe_sip `src/engine` | `chappe_sip_engine` | `_dispatch`, `_uas_response` | `dispatch_tests`, `uas_response_tests` | `make interop-conformance` |
| Call correlation | chappe_sip `src/core` | `chappe_sip_call`, `chappe_sip:calls/1` | `chappe_sip_pg` | `call` | none |
| SIPREC client | chappe_sip `src/siprec` | `chappe_sip_siprec` | `_siprec_meta`, `_siprec_body`, `_siprec_tap`, `_siprec_peer` | `siprec`, `siprec_meta_tests` | `siprec_live` |
| SIPREC server | chappe_sip `src/siprec`, chappe_audio | `chappe_sip_siprec_srs` | `chappe_audio_rtp`, `_rtp_sup`, `_srtp` | `siprec`, `siprec_live`, chappe_audio rtp cases | `siprec_live` |
| SRTP and SDES | chappe_audio, chappe_sip `src/media` | decision 0009 | `chappe_audio_srtp`, `chappe_sip_sdes` | `srtp_tests`, `sdes_tests` | none |
| B2BUA transfers and joins | chappe_sip `src/b2b` | `chappe_sip_b2b_transfer` | `_b2b_join` | `b2b_transfer`, `b2b_async`, `replaces` | `make interop-conformance` |
| Audio forks and streams | chappe_audio | `chappe_audio` | `_listener`, `_conn`, `_stream`, `_ws`, `_pcm`, `_registry`, `_pg` | `chappe_audio_SUITE`, `pg_SUITE` | `chappe_audio_live_SUITE` |
| Recording store | chappe_audio | `chappe_audio_store` (behaviour) | `_store_srv`, `_store_file`, `_writer`, `_adopt`, `_wav` | `store_SUITE`, `wav_tests` | none |
| Conference backends | chappe_mrf | `chappe_mrf_conf_backend` | `_conf_native`, `_conf_fs`, `_conf_fs_join`, `_conf_focus` | `chappe_mrf_SUITE`, `chappe_mrf_conf_backend_SUITE` | `make interop-mrf` |
| Rooms in a cluster | chappe_mrf | `chappe_mrf_conf` | `_conf_cluster`, `_conf_move`, `_conf_transfer`, `chappe_mix_move` | `chappe_mrf_cluster_SUITE` | `make demo-cluster` |
| ESL verbs | chappe_esl | `chappe_esl_call` | `_verbs`, `_exec` | `chappe_esl_call_SUITE` | `make interop-esl` |
| ESL listener screening | chappe_esl | `chappe_esl:start_listener/4` | `_listener`, `_cidr` | `outbound`, `cidr_tests` | `make interop-esl` |

Check every name against the tree when the step is done: this table is a
plan, and the PR writes what exists.

## 8. Contributor workflows

The 14 workflows from #19 exist; workflow 7 was rewritten in #38. Update
three (labs, add tests, debug a call: see section 4). Add these, one page
each, every page naming real modules, tests and the check to run:

1. **Use the cluster in a feature** (lease or singleton): choose between a
   lease, a singleton and a pg lookup; handle `lost`; carry the fence on a
   side effect; check `valid/1` before acting; the four tests from the
   distributable rule; the lab checker. Start from `chappe_mrf_conf_cluster`
   (lease) and `chappe_sip_peers` (singleton).
2. **Add a location store backend:** the `chappe_sip_location` callbacks
   (`write_mode/0`, `start/0`, `stop/0`, `periodic/2`, `held/4`, `mine/0`,
   `view/2`, `edge/1` and the storage ones), the CAS contract, the
   read-retry, and `location_lagging` as the model test.
3. **Add an audio store backend:** the `chappe_audio_store` callbacks, the
   two-step rename, retention and `sweep_guard`, and `store_SUITE` as the
   contract test.
4. **Add a cross-region directory backend:** the
   `chappe_cluster_directory` seam, what the fence's region is for, and why
   the directory never decides ownership (0010).
5. **Debug a call across nodes:** find it by `call_ref`, find which node
   holds the flow or the lease (`chappe_cluster:owner/1`), and read the
   lab's logs and checker output.

## 9. Maintainability, after the code PRs

Module sizes:

| Module | Before (#37) | Now |
|---|---|---|
| `chappe_mrf_conf` | 1127 | 497 |
| `chappe_esl_call` | 952 | 497 (+ `_verbs` 465) |
| `chappe_sip_registry` | 942 | 476 |
| `chappe_sip_route` | 574 | 323 (+ `_flow` 258) |
| `chappe_sip_engine` | 2007 | 492 (+ `_dispatch`, `_uas_response`, `_opts`, `_backend`, `_events`, `_handles`, `_conns`) |
| `chappe_rtpengine_session` | 766 | 489 (+ `_cmd`, `_offer`) |
| `chappe_sip_dialog_fsm` | 1791 | 483 (+ `_dialog_route`, `_offer`, `_out`, `_sub`, `_st`, `_owner`) |
| `chappe_sip_uac_fsm` | 1157 | 418 (+ `_uac_req`, `_early`, `_retry`, `_sdp`) |
| `chappe_sip_ws_transport` | 1099 | 472 (+ `_ws_msg`, `_ws_txn`, `_ws_ctxn`) |

The elvis `max_module_length` list went from 12 modules to 3
(`chappe_sip_hdr`, `chappe_rtpengine_client`, `chappe_sip_b2b`), each with
its reason. The engine went from nine exemptions to one; the dynamic calls
it made to the NIF backend are in `chappe_sip_engine_backend`, which carries
that exemption alone. `chappe_esl_call` stays in `no_god_modules` because it
keeps one wrapper per verb.

Findings, status:

| # | Area | Status |
|---|---|---|
| M2 | `chappe_sip_dialog_fsm` | Done in #55. |
| M3 | `chappe_sip_uac_fsm` | Done in #54; the in-dialog request bytes are shared with the dialog fsm since #56. |
| M4 | `chappe_sip_ws_transport` | Done in #58. |
| M1 | `chappe_sip_engine` | Done in #59. |
| N9 | `chappe_rtpengine_session:handle_event` | Done in #57. |
| T1 | Test-only exports | Open: about 50 exports are used only by tests. A sweep of the rest is its own plan. |

The splits also found and fixed two bugs the tests had been hiding: a NOTIFY
from another fork of a subscription could be answered 500 (#62), and a
WebSocket timeout while creating a UAC dialog leg crashed the engine (#59).

## 10. Diagrams and examples

1. **System context**, updated: 7 apps, the SIPREC path (SIP to chappe_sip,
   RTP to chappe_audio), cluster nodes (README and architecture).
2. **Lease lifecycle** (sequence): claim, renew, leader expiry, `lost`, a
   takeover with a higher fence. (Cluster overview.)
3. **A call to a device registered on another node** (sequence): lookup,
   edge route, the forward over the held flow, 430 when it is gone.
   (Registrar page.)
4. **A room on a clean stop** (sequence): `prep_stop`, drain, handoff to a
   live node, members moved, the old room told. (mrf overview.)
5. **Recording paths** (one picture): rtpengine fork, `mod_audio_stream`
   fork, SIPREC SRC to SRS, all into chappe_audio streams and the store.
6. **A worked cluster example** in the cluster guide: three nodes in a
   shell, claim, kill, take over, checked by `doc_snippets_tests` where it
   can run.

## 11. Implementation order

Each step is its own PR, documentation only.

1. **Drift fixes, no new pages.** README, `architecture.md` (one-level
   trees), `docs/README.md`, the counts, the "starts on first use"
   contradictions, the leaf-app list to one place, the app overviews' module
   tables, the configuration pages, and the lab READMEs. Remove the
   leaf-library stubs.
2. **Decisions:** 0002 to 0007 Accepted, 0008 planned, 0010 updated, and
   0011 to 0016 written. `CONTRIBUTING.md` on removed exports.
3. **ex_doc groups and extras** for every app. This touches only the
   `rebar.config` files.
4. **Glossary and concepts split,** with the cluster and recording sections.
5. **Navigation rows** (section 7), and the labs, add-tests and debug-a-call
   updates.
6. **New design pages:** the chappe_cluster overview, configuration and
   features; the chappe_mrf overview (backend behaviour, rooms in a
   cluster); chappe_sip `design/siprec.md` and `design/registrar.md`; the
   chappe_audio overview.
7. **New workflows** (section 8).
8. **Docs check in CI:** every `src` module appears in an ex_doc group, and
   every child of each `*_sup` appears in the app overview. A script under
   `scripts/` and a CI job. Ask before adding the job.

## 12. Release review, 2026-11-22

Baseline `878b5c9`, after #73. Sixteen PRs merged since section 11 was
done: the last three module splits (#57 rtpengine session, #58 WebSocket
transport, #59 engine), the export sweep (#67), CI hardening (#61, #63,
#65, #66, #68), and the outside-audit fixes (#69 strict compliance gate,
#70 NIF replace, #71 RTCP in chappe_audio, #72 SIPREC recording server
re-offers, #73 RTCP at the recording server). `make docs-check` passes;
the drift below is in places it does not look at.

### 12.1 What still works for a new reader

The reading path holds: `README.md`, `docs/README.md`, `architecture.md`
(seven apps, which matches the code), `concepts.md`, then the app
overviews. Keep it. Every module added since 2026-11-18 is in an ex_doc
group, and all but one open with a purpose-first `@doc`.

### 12.2 Drift to fix (documentation)

| # | Where | What is wrong | Action |
|---|---|---|---|
| D1 | `docs/glossary.md:95` | Says the matrix comes from "the last CT results". Since #69: the newest CT run and the EUnit reports, a row passes only when every claim passed, a Deviations section, `CHECK=1`. | Rewrite as a short paragraph linking to `contributing/compliance.md`. |
| D2 | `docs/contributing/add-tests.md:43` | "Only `*_SUITE.erl` cases count": wrong since EUnit claims count. | Rewrite. |
| D3 | `docs/README.md:135-145`, `contributing/compliance.md:21` and `:182-204` | chappe_audio has a matrix since #71 but is missing from both lists; it has no `docs/compliance/README.md`, unlike esl, mrf, rtpengine and sip. | Add the entries and the README. |
| D4 | `docs/navigation.md:39, :44, :49, :53, :89, :93` | Rows behind the splits: no `_ws_txn`, `_ws_ctxn`, `_ws_msg`, `_engine_*`, `_nif_reload`, `nif_upgrade_SUITE`, `chappe_rtpengine_offer`, `_srs_stream`, `chappe_audio_rtcp`, `chappe_audio_rtp_rtcp`. | Add them. |
| D5 | `docs/navigation.md:89` vs `apps/chappe_sip/rebar.config:252` | `chappe_sip_siprec_srs_stream` is Internal in one, in the public SIPREC group in the other. | Maintainer decides (12.7 question 1), then fix the other. |
| D6 | `apps/chappe_sip/docs/design/overview.md:196-213` | Its own public/internal list contradicts navigation.md and ex_doc (b2b join and transfer are public; no SIPREC or location rows) and says no deprecation policy exists, which `CONTRIBUTING.md:111` contradicts. | Replace with a pointer to navigation.md. |
| D7 | `overview.md:122`, `engine.md:246-318`, `overview.md:273-281`, `contributing/change-c-engine.md:69-78` | `chappe_sip_nif_reload` and `chappe_sip_nif_upgrade_SUITE` are named nowhere; the C engine workflow has no step for the reload path. | Add them; add a "If you change load, unload or the singleton" step. |
| D8 | `apps/chappe_sip/docs/guides/siprec.md`, `features.md` | The guide mentions a pause answered inactive but not the rest of #72 (an added or removed stream, a sender that moves, an RTP/SRTP switch, keys judged per request transport); features.md has no line. Only `design/siprec.md:189-213` covers it. The "Where it lives" footer (`:344-350`) misses `_srs_stream`, `chappe_audio_rtcp` and the RTCP tests. | Add a short "When the client re-offers" section, a features line, and the footer entries. |
| D9 | `apps/chappe_audio/docs/configuration.md:86-100` | A hand-written list of RFC 3550 departures repeats the matrix's six deviation rows; its "never sends SR" line is the n/a row R3550-6.4-1 (a receiver only sends RR). | Keep the matrix as the one source and link to it. |
| D10 | `apps/chappe_rtpengine/src/chappe_rtpengine_offer.erl:4` | Plain `%%` header, no `@doc`: ex_doc shows nothing. | Change to `@doc`. |
| D11 | `docs/glossary.md` | 46 terms, none for RTCP, SRTP/SDES or deviation, all now used across three apps. | Add short entries. |
| D12 | `apps/chappe_sip/docs/design/engine.md` (503 lines) | The abort-audit appendix (`:488`) is history, not design. | Move it under `docs/history`. |

### 12.3 The CHANGELOG before the release

The Unreleased section is 502 lines and 119 entries in one flat list,
since 0.1.0. Someone upgrading cannot scan it.

- 6 entries are marked breaking, in two spellings ("breaking:" and "a
  breaking change").
- At least 3 breaking changes are not marked: removed functions in
  chappe_esl and chappe_cluster (`CONTRIBUTING.md:112` says removals are
  breaking), an empty SIPREC offer now refused with 488, and recording
  streams without rtcp-mux now taking two ports.
- 25 entries carry code spans and 8 name a function and arity; one
  (`:49-52`) explains a NOTIFY race in internal terms. The project rule is
  plain English with no implementation detail; function names belong only
  in the lines that list removed API.
- Prefixes mix app names (44 entries) and topics ("SIPREC recording
  server:", "Security:").

Action: before the version bumps, rewrite the section grouped by app, then
Breaking, New, Fixed, with a "Before you upgrade" list at the top that
gathers every breaking change. Each app's release section is then that
app's part as is (the release notes reuse it).

### 12.4 Decisions that live only in code or design pages

None of these has a decision record. Each is a short record, or a line in
an existing one:

- An in-place NIF upgrade is refused; the library is replaced by purge then
  load, with the engine slot reserved (`engine.md:296-302`).
- The compliance rule: a row passes only when every claim passed, a
  skipped claim makes it untested, and an expected failure must name a
  deviation row.
- RTCP at the recording server: receiver reports only, a fixed session
  bandwidth, no reconsideration, one CNAME per recording, two ports
  without rtcp-mux (each departure is a deviation row; the why is not
  written down).
- The 1 s move grace of the RTP receiver: the behaviour is in
  `chappe_audio/docs/configuration.md:116`, not why 1 s or why it is fixed.
- `a=record` (R7866-6.1.2-1) stays a deviation: the maintainer's choice of
  2026-11-19, recorded only in the row's notes.

### 12.5 Module size and complexity

Code lines without blanks or comments (`apps/*/src`, 236 modules, about
46,000 lines; chappe_sip is 135 modules and 28,400 lines).

| Signal | Measurement | Reading |
|---|---|---|
| Modules at the lint ceiling | 17 modules sit between 470 and 500 lines, against elvis `max_module_length` 500: `chappe_sip_proxy`, `_media_mix`, `_engine`, `_b2b_relay`, `_focus`, `_refer`, `_dialog_fsm`, `_registry`, `_siprec`, `_ws_transport`, `chappe_mrf_conf_refer`, `chappe_mrf_conf`, `chappe_esl_call`, `chappe_mix_conf`, `chappe_rtpengine_session`, `chappe_mrf`, `chappe_audio_rtp` | The splits of section 9 stopped at the limit. The next feature in any of them trips lint, and the easy fix is a split by size rather than by responsibility. **Module organisation.** No action now; when one trips, split along a responsibility its overview names, or exempt it with a reason. |
| Exempt from the length rule | `chappe_sip_hdr` 764 (one parser per header, coherent), `chappe_sip_b2b` 723 (every B2BUA option next to its entry point), `chappe_rtpengine_client` 595 (four transports in the process that owns the socket) | Reasons hold. Keep. |
| Longest functions | `chappe_rtpengine_client:handle_info` 76, `chappe_sip_b2b:start_b` 74, `chappe_rtpengine_session:call` 74, `chappe_sip_proxy:on_response` 68, `chappe_sip_uac_fsm:trying` 64, `chappe_sip_b2b_relay:loop` 63 (span lines, comments included) | Review only when next changed. **Code complexity**, low. |
| The C NIF | `chappe_sip_engine_nif.c` 3,234 lines, about 154 top-level functions; longest `op_cb` 181, `stack_main` 168, `deliver_request` 129, `nif_start` 118 | One file holds lifecycle, the op queue, event delivery and TLS. `engine.md` maps its risky regions, which is what a contributor needs first. A split of the file is a question (Q4), not a recommendation: it is covered by ASan, TSan and the fuzzer as one unit. **Architecture.** |
| New since section 9 | `chappe_sip_siprec_srs` 338, `_srs_stream` 323, `chappe_audio_rtcp` 356, `chappe_audio_rtp_rtcp` 157, `chappe_audio_srtp` 275, `chappe_sip_nif_reload` 21 | Each has one responsibility. Fine. |

T1 of section 9 (test-only exports) is done in #67.

### 12.6 What `make docs-check` cannot catch

It checks ex_doc groups, extras, supervisors named in overviews, and
links and anchors. It does not check public versus internal agreement
between navigation.md and ex_doc (D5), modules missing from overview
tables and navigation rows (D4, D7), a missing `@doc` (D10), counts and
lists in prose (D3), or CHANGELOG markings. Cheap additions: every module
of an "Internal" group is in navigation.md's internal column and the
reverse; every src module is named in its app overview; every module has
a `@doc`. Ask before changing the CI job.

### 12.7 Questions for the maintainer

1. Is `chappe_sip_siprec_srs_stream` public API or internal (D5)?
2. The CHANGELOG rewrite (12.3): is "by app, then Breaking, New, Fixed,
   with a Before you upgrade list" the shape you want, and is it a release
   blocker?
3. Should chappe_audio keep dropping a source at its BYE at once
   (deviation R3550-6.2.1-1) while chappe_mix keeps a grace delay?
4. The C NIF stays one file, mapped by `engine.md`, or gets split by area
   (lifecycle, ops, events, TLS) in a later plan?
5. R7866-6.1.1-1 (actor srs) and R7866-6.1.1-4 (actor src) carry the same
   SRC sentence. Intended, or should the srs row hold the SRS side?
6. Should the docs check grow the three checks of 12.6?

Answers (2026-11-22): 1, public, so navigation.md follows ex_doc. 2, yes,
the rewrite is a release blocker. 3, asked back: what the delay is for.
4, split the NIF file, in its own plan. 5, not intended: the srs row
takes the part that concerns the receiving side. 6, yes.

### 12.8 Order

Documentation only, each its own PR, one open at a time:

1. **Before the release:** D1 to D10 with answers 1 and 5, in one drift
   PR; then the CHANGELOG rewrite (12.3).
2. **After it:** the docs check additions (12.6); decision records
   (12.4), D11, D12.
3. **Its own plan:** the NIF file split (answer 4).
