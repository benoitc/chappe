# Documentation and maintainability plan

This is a plan, not documentation. It records what a human developer meets
when they open the repository today, what is missing or misleading, and the
order in which to fix it. No source code is changed by this plan. Code
findings are listed so they can be planned separately.

Baseline: `main` at `77dea16` (after #37). Line counts are code lines,
without blanks or comments. Function lengths add up every clause of a
function.

The first version of this plan (2026-10-31, baseline `e539f8d`) was carried
out in #19. Section 1 says what it left behind. The rest of the plan covers
what changed since: two new apps, SIPREC, call correlation, the cluster
users, and the security pass.

## 1. Where the first plan left the repository

The structure from #19 works and should stay:

- the orientation path: README, `docs/README.md`, concepts, architecture,
  decisions, navigation;
- one design overview, a configuration reference and a short `features.md`
  per app;
- 14 contributor workflows;
- a "Where it lives" footer on every chappe_sip guide;
- decisions 0001 to 0010.

The problem today is not structure but **drift**. PRs #20 to #37 added
chappe_audio and chappe_cluster, SIPREC, `call_ref`, a location store
behaviour, edge routes, cluster rooms and an MWI fan-out. Their user guides
were written. The cross-cutting pages were not updated:

| Page | What drifted |
|---|---|
| `README.md` | The apps table and the diagram show 5 of the 7 apps. They miss SIPREC, `make demo-cluster` and the cluster lab. "RTP never flows through a SIP process" (:53) is false since `chappe_sip_siprec_rtp`. |
| `docs/architecture.md` | Says "five apps" (:3). The core is described as using only rtpengine and mix (:50), with no edge to cluster or audio. Supervision trees miss 7 chappe_sip children, `chappe_audio_adopt_sup` and `chappe_cluster_hlc`. The rtpengine child order is wrong. |
| `docs/concepts.md` | No entry for lease, epoch, fence, singleton, region, quorum, HLC, `call_ref`, SIPREC (SRC, SRS), audio fork, stream, store, sweep, location backend, directory, pg scope or ESC. "Fork" is used in two senses (B2BUA fork, audio fork). |
| `docs/navigation.md` | No rows for audio, cluster, SIPREC, call correlation, location backends, transfer and join, SRTP or metrics HTTP. Existing rows miss newer modules and suites. Every name it gives still exists: the problem is omission. |
| `docs/README.md` | No chappe_cluster row. The guide list misses `siprec.md` and `follow-a-call.md`, and the labs list misses the mix, mrf and cluster labs. |
| `docs/contributing/labs.md`, `add-tests.md` | No `interop-cluster`, `demo-cluster`, `demo-esl`, `advisories` or `fuzz`. No audio or cluster fakes, no multi-node test helpers. |
| `apps/chappe_sip/docs/design/overview.md` | The supervision tree misses `pg`, `call`, `hlc`, `metrics_http`, `b2b_sup`, both siprec sups and `proxy_sup`. The boot section misses the cluster check and `prep_stop`. The directory table misses `siprec/`, the location backends and `lib`. The module counts are wrong (9 b2b modules, actually 12), and so is the test map. |
| `apps/chappe_mrf/docs/design/overview.md` | Never mentions the cluster. The module table misses `_conf_move`, `_conf_refer` and `_store`. The backend contract table is stale on both sides. `configuration.md` says "one key" (there are nine). |
| `apps/chappe_mix`, `chappe_esl`, `chappe_rtpengine` overviews | Miss `chappe_mix_move` and `_tap`, and `chappe_esl_cidr`. Give a wrong `ws` pin. Leave `holder =>` and `reoffer_tags` out. |
| ex_doc groups | About 30 chappe_sip modules are ungrouped, 5 of them public (`call`, `siprec`, `siprec_srs`, `location`, `multipart`). `siprec.md` and `follow-a-call.md` are not extras. chappe_cluster groups 3 of 13 modules; chappe_audio has no "Internal" group. |
| Contradictions | Some pages say chappe_cluster "starts on first use", while the code starts it at boot (chappe_sip `configuration.md:119`, chappe_mrf `README.md:21`). The remote-app model is "out of scope", "Open" and "Planned" in three places. Decision 0010 describes per-node ownership in the present tense. |

What this tells you about the fix: **pages that copy facts from the code
drift; pages that point to the code do not.** The supervision trees, the
module lists, the leaf-app list (kept in 4 places, two already wrong) and the
counts are all copies. The plan below removes copies where it can, and checks
the remaining ones in CI.

## 2. Recommended structure

Keep the #19 layout. Change four things:

```
README.md                  orientation; 7 apps; 3 ways in (unchanged role)
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
   and its main subtrees) and links to the overview. Today the same tree is
   kept in two places, and both are wrong.
3. **The leaf-app list lives once,** in decision 0003. Other pages link to
   it instead of listing the apps.
4. **chappe_cluster gets the same page set as the other apps:**
   `design/overview.md`, `configuration.md`, `features.md`, and its lab in
   the ex_doc extras.

## 3. The starting point

The root `README.md` stays the single entry point. Its job does not change:
in one screen, what chappe is, the apps, three ways in, and the checks. It
needs:

- the 7 apps in the table, each with one line and its layer;
- the diagram with chappe_audio, chappe_cluster and the SIPREC path;
- a fourth way in: "Run several nodes" (`make demo-cluster`,
  `demo/cluster/README.md`);
- the false RTP sentence corrected: "SIP processes never relay call media;
  a SIPREC receiver takes recorded audio in, see 0012";
- the OTP floor said once, with a link, not repeated in three files.

## 4. Proposed documents

For each: intent, reader, what they understand after, where it points next,
depth.

### Umbrella

| Document | Action | Intent and reader | Understands after | Points to | Depth |
|---|---|---|---|---|---|
| `README.md` | Update | Orientation, everyone | The 7 apps and where to start | demos, getting started, `docs/README.md` | One screen |
| `docs/README.md` | Update | The map. Add chappe_cluster, the two missing guides, the three labs, and the questions "run several nodes", "record with SIPREC", "follow a call across nodes" | Which page answers their question | every doc | Index only |
| `docs/concepts.md` | Rewrite (shorter) | Mental model, new developers. Add one section: ownership in a cluster (lease, epoch, fence; lookups on pg, ownership on Ra; a lost quorum stops claims, not calls) | Why chappe is shaped as it is | `glossary.md`, `architecture.md` | About 150 lines |
| `docs/glossary.md` | New | Terms, everyone. Every term in section 1's concepts row, plus the existing ones moved from concepts. "Fork" gets two entries. "Node" separates a FreeSWITCH or rtpengine node from a cluster node | The words used everywhere else | the page that owns each term | One paragraph per term |
| `docs/architecture.md` | Update | How the apps fit, developers. 7 apps, the real dependency edges (chappe_sip to cluster and audio, as optional siblings), one-level supervision, and three new flows (section 10) | Where execution enters and what talks to what | decisions, app overviews | Diagrams first |
| `docs/navigation.md` | Update | Concept to code, contributors. New rows for audio, cluster, SIPREC, call correlation, location backends, B2BUA transfer and join, SRTP and SDES, metrics HTTP, ESC. Fill in the missing modules and suites in the existing rows. Add audio and cluster to the public, startup and fakes tables | Where to look before opening the tree | app overviews, workflows | Tables |
| `docs/decisions/0011` to `0016` | New | Why, for contributors changing a boundary (section 6) | What breaks if the boundary moves | architecture | Half a page each |
| `docs/decisions/0010` | Update | Record what #37 moved onto the cluster, and close or keep open the question of bindings in the KV | The current state | cluster overview | Small edit |
| `docs/contributing/labs.md`, `add-tests.md`, `debug-a-call.md` | Update | Add the cluster lab and demo, `demo-esl`, `advisories`, `fuzz`, the audio and cluster fakes, `*_test_dist` and peer suites, and `call_ref` and HEP in debugging | Which lab or helper to use | each lab README | Rows |
| `docs/drachtio-parity.md` | Update | Align the remote-app status with 0008 | One answer | 0008 | Small edit |

### Per app

| App | Keep | Update | New |
|---|---|---|---|
| chappe_sip | guides (all have footers), `features.md` (96 lines, still a tracker), `configuration.md` (every key present) | `design/overview.md`: tree, boot and `prep_stop`, directories, counts, public modules, test map with Cluster and SIPREC rows. `AGENTS.md` layers. `configuration.md:119`. The sbc and conformance lab READMEs (missing cases). ex_doc groups and extras | `design/siprec.md`: SRC and SRS, the meta and body modules, where RTP enters, the store hand-off. `design/registrar.md` or a section of the overview: the location behaviour, CAS and read-retry, edge routes, why 430 and 503. Both reasons now exist only in moduledocs |
| chappe_cluster | README, `guides/cluster.md`, AGENTS | ex_doc: group all 13 modules, add the lab README as an extra | `design/overview.md`: supervision (who owns the holder table and why), the machine and its no-clock rule, the holder deadline, singletons, the directory seam, tests and the lab checker. `configuration.md` (moved from the README table). `features.md`. A "Where it lives" footer |
| chappe_audio | README, overview, configuration, features, guides | overview: `adopt_sup`, `adopt`, `lib`, a test map. ex_doc "Internal" group, `features.md` in extras. Footers on `fork.md` and `record.md` | none |
| chappe_mrf | README, guides, drachtio mapping | `design/overview.md`: a "Rooms in a cluster" section (claim in the caller, the waiting room, draining, `prep_stop` handoff, rehome, why fs rooms do not move, the timeouts and why), the module table, the backend contract, failure rows (clean stop, lost lease, no quorum). `configuration.md`: nine keys, read where. README wording on when chappe_cluster starts. Interop README: the cluster suite | none |
| chappe_mix | everything | overview: `_move`, `_tap` (and why a tap drops frames when the remote distribution buffer is full). `configuration.md`: tap options | none |
| chappe_esl | everything | overview: `_cidr`, `start_listener/4`. `configuration.md`: `bugname`. Outbound guide: the screen-before-spawn order and the accept backoff, in one paragraph | none |
| chappe_rtpengine | everything | overview `ws` pin. `features.md`: `stop_forwarding/2`, and drop the "seven gates" line. Subscriptions guide: `holder =>`. Sessions guide: via-branch re-offers | none |

The two `leaf-library-contract.md` stubs are 6-line pointers now. Remove
them, and remove their ex_doc extras and index lines: 0003 is the record.

## 5. Concepts that need a dedicated explanation

The nine from the first plan are written, in `concepts.md` and the design
docs. New ones:

1. **Ownership in a cluster.** Ownership needs consensus and lookups do not:
   that is why both pg and Ra are present. Epoch leases (one renewal keeps
   every lease of a node), fences, and what a lost quorum stops. Home:
   `concepts.md`, then the chappe_cluster overview.
2. **Time without wall clocks.** Monotonic deadlines on the holder, the
   leader's expiry timer, HLC for ordering. There is one clock per node:
   chappe_cluster's when it runs, otherwise chappe_sip's own
   (`chappe_sip_hlc`, both built on the `hlc` dep). This is written only in
   the `chappe_sip_hlc` moduledoc.
3. **Reaching a device registered on another node.** The edge route, the
   flow token tied to one boot, 430 when the flow is gone. Home: the
   registrar design section.
4. **Call correlation.** `call_ref`, the pg lookup, following a call across
   nodes. `follow-a-call.md` covers use, not the model.
5. **Recording paths.** Three ways audio leaves a call (an rtpengine fork, a
   FreeSWITCH `mod_audio_stream` fork, SIPREC to the built-in SRS), where
   each lands (chappe_audio streams and the store), and when you choose
   which. Today this is spread over five guides in three apps.
6. **Optional sibling apps.** chappe_sip and chappe_mrf use chappe_cluster
   and chappe_audio without listing them in `applications`, so that the
   stop order lets a node hand off before it stops. A release must include
   `{chappe_cluster, load}`. This is a rule every product that ships a
   release has to follow, and it is written only in code comments.

## 6. Decisions to record, and questions for the maintainer

Proposed records:

| # | Decision | Evidence today |
|---|---|---|
| 0011 | chappe_audio is a leaf app with a store behaviour | moduledocs, overview |
| 0012 | A SIPREC SRS lives in chappe_sip and takes RTP in | code, 0009 mentions it; contradicts the README rule and bends 0004 |
| 0013 | Calls are found across nodes through `call_ref` on pg, not owned | code, `follow-a-call.md` |
| 0014 | chappe_cluster and chappe_audio are optional siblings, started by their users, kept out of `applications` for the stop order | `chappe_sip_app.erl:36-41`, `chappe_mrf_app.erl:12-17` |
| 0015 | Registrar bindings sit behind a location behaviour; cross-node calls route through the edge node | `chappe_sip_location.erl:3-20`, `chappe_sip_route.erl:29-31` |
| 0016 | Security defaults: the ESL listener binds loopback with an allow list, sofia's own WS transport stays closed, the OTP floor, the advisory gate | #36, CHANGELOG |

Questions only a maintainer can answer. They are left as questions, with no
invented answers:

| # | Question | Why it matters |
|---|---|---|
| Q1 | 0008, the remote-app model: open, out of scope, or planned? Three pages disagree | One status to write everywhere |
| Q2 | 0002, 0004, 0005 and 0007 are still "Proposed, to confirm"; 0003 and 0006 have reasons still to confirm. Do you accept them as written? | Unconfirmed records read as guesses |
| Q3 | Registrar bindings in the region KV at scale (0010:176-179): accepted for now, or still open? | 0010 and 0015 must agree |
| Q4 | The README rule "RTP never flows through a SIP process": is the new rule "except a SIPREC receiver", or should the SRS move out of chappe_sip one day? | Decides whether 0012 is a permanent rule or an exception with a planned exit |
| Q5 | Public API stability: which modules are public, and what is the deprecation policy? (Unanswered since the first plan.) | The ex_doc groups and the "public" column in navigation depend on it |
| Q6 | chappe_mrf_conf backends: commit to a behaviour (finding M16), or keep the contract documented only? | Decides whether workflow 7 can say "implement this behaviour" |

## 7. Developer navigation guide: rows to add to `docs/navigation.md`

| If you care about | App, directory | Start at | Internal modules | Tests | Lab |
|---|---|---|---|---|---|
| Ownership in a cluster | chappe_cluster `src` | `chappe_cluster` | `_machine`, `_node`, `_ra`, `_lapse`, `_tab`, `_watch`, `_config` | `chappe_cluster_SUITE`, the PropEr machine tests, `test/lab` | `make interop-cluster` |
| Singletons | chappe_cluster | `chappe_cluster:singleton/2` | `_singleton`, `_singleton_sup` | cluster suites | `make interop-cluster` |
| Cross-region seam | chappe_cluster | `chappe_cluster_directory` | `_directory_local` | eunit | none |
| Location store | chappe_sip `src/conn` | `chappe_sip_location` (behaviour) | `_location_ets`, `_location_cluster`, `_registry_sweep` | `registrar_cluster`, `location_lagging`, `registry_lag_tests` | `make demo-cluster` |
| Edge routes, flow tokens | chappe_sip `src/proxy` | `chappe_sip_route` | `_proxy_dialog` (430) | `registrar_cluster`, `proxy_record_route` | `make demo-cluster` |
| Call correlation | chappe_sip `src/api` | `chappe_sip_call`, `chappe_sip:calls/1` | `chappe_sip_pg` | `call` | none |
| SIPREC client | chappe_sip `src/siprec` | `chappe_sip_siprec` | `_siprec_meta`, `_siprec_body`, `_siprec_tap`, `_siprec_peer` | `siprec`, `siprec_meta_tests` | `siprec_live` |
| SIPREC server | chappe_sip `src/siprec` | `chappe_sip_siprec_srs` | `_siprec_rtp`, `_siprec_rtp_sup` | `siprec`, `siprec_live` | `siprec_live` |
| SRTP and SDES | chappe_sip `src/media` | decision 0009 | `chappe_sip_srtp`, `chappe_sip_sdes` | `srtp_tests`, `sdes_tests` | none |
| B2BUA transfers and joins | chappe_sip `src/api` | `chappe_sip_b2b_transfer` | `_b2b_join` | `b2b_transfer`, `b2b_async`, `replaces` | `make interop-conformance` (pjsua REFER cases) |
| Audio forks and streams | chappe_audio | `chappe_audio` | `_listener`, `_conn`, `_stream`, `_ws`, `_pcm`, `_registry`, `_pg` | `chappe_audio_SUITE`, `pg_SUITE` | `chappe_audio_live_SUITE` |
| Recording store | chappe_audio | `chappe_audio_store` (behaviour) | `_store_srv`, `_store_file`, `_writer`, `_adopt`, `_wav` | `store_SUITE`, `wav_tests` | none |
| Rooms in a cluster | chappe_mrf | `chappe_mrf_conf` | `_conf_move`, `chappe_mix_move` | `chappe_mrf_cluster_SUITE` | `make demo-cluster` |
| ESL listener screening | chappe_esl | `chappe_esl:start_listener/4` | `_listener`, `_cidr` | `outbound`, `cidr_tests` | `make interop-esl` |

## 8. Contributor workflows

The 14 workflows from #19 exist. Update three (labs, add tests, debug a
call: see section 4). Add these, one page each, every page naming real
modules, tests and the check to run:

1. **Use the cluster in a feature** (lease or singleton): choose between a
   lease, a singleton and a pg lookup; handle `lost`; carry the fence on a
   side effect; check `valid/1` before acting; the four tests from the
   distributable rule; the lab checker. Start from `chappe_mrf_conf` (lease)
   and `chappe_sip_peers` (singleton).
2. **Add a location store backend:** the `chappe_sip_location` callbacks,
   the CAS contract, the read-retry, and `location_lagging` as the model
   test.
3. **Add an audio store backend:** the 11 `chappe_audio_store` callbacks,
   the two-step rename, retention and `sweep_guard`, and `store_SUITE` as
   the contract test.
4. **Add a cross-region directory backend:** the
   `chappe_cluster_directory` seam, what the fence's region is for, and why
   the directory never decides ownership (0010).
5. **Debug a call across nodes:** find it by `call_ref`, find which node
   holds the flow or the lease (`chappe_cluster:owner/1`), and read the
   lab's logs and checker output.

Workflow 7 (add a chappe_mrf conference backend) is wrong today: the
contract it describes is stale. Rewrite it after Q6.

## 9. Maintainability findings

Primary problem: **Doc** (documentation), **Nav** (navigation), **Name**
(naming), **Org** (module organisation), **Cx** (code complexity), **Arch**
(architecture). "Doc first" means the boundary is written down before any
split is planned.

Module growth since the first plan:

| Module | Then | Now | Exports | Fan-in |
|---|---|---|---|---|
| `chappe_mrf_conf` | 446 | 1127 | 41 | 5 |
| `chappe_esl_call` | 432 | 952 | 47 | 5 |
| `chappe_sip_registry` | 631 | 942 | 27 | 10 |
| `chappe_sip_b2b` | 501 | 723 | 20 | 15 |
| `chappe_sip_route` | 358 | 574 | 23 | 12 |
| `chappe_sip_engine` | 1891 | 2007 | 40 | 19 |
| `chappe_sip_dialog_fsm` | 1717 | 1791 | 11 | 6 |

The elvis `max_module_length` exemption list went from 8 modules to 12.
`chappe_sip_engine` is exempt from 12 rules.

### Findings, new or changed

| # | Area | Finding | Primary | Recommendation |
|---|---|---|---|---|
| N1 | `chappe_mrf_conf` (1127 lines, 105 functions, 41 exports) | It does five jobs: the room's public API; the cluster lifecycle (claim in the caller, waiting room, activate, lease lost, draining, handoff, rehome, mover watch); member operations; recordings (start, store, adopt orphans, SIPREC events); transfers and REFER. Its backends call back into it through an implicit API, and `_conf_move` and `_conf_refer` call it through `call/3` tags. You cannot describe it in one sentence, and you cannot change rehome without reading most of it. It grew 2.5x in two weeks. | Arch, Org | Doc first: the "Rooms in a cluster" section and a corrected backend contract. Then a plan, in this order: a `chappe_mrf_conf_backend` behaviour (M16, Q6); the cluster lifecycle as a helper module that the room process calls (as `_conf_move` already is); recordings as a helper. The process state stays in one place. Tests: `chappe_mrf_SUITE`, `chappe_mrf_cluster_SUITE`, `chappe_mrf_live_SUITE`. |
| N2 | `chappe_esl_call` (952 lines, 47 exports) | The typed verbs (one function per dialplan application) are mixed with the process: correlation of completions, helper processes for every blocking command, owner death. elvis says it is "one function per verb", which explains the exports but not the rest. | Org | Later: move the verb functions (argument checks and command building) next to `chappe_esl_exec`, and keep the process with correlation and lifecycle. Doc first: the overview states the split between `_call` and `_exec` (old M14). |
| N3 | `chappe_sip_registry` (942 lines) | RFC 3261 binding rules, the serialized writer, and the cluster path (CAS retry, edge routes, node-held bindings, purge) in one module. The location behaviour took the storage out; the cluster policy stayed. The moduledoc is good. | Doc, Org | Doc first (design section, 0015). The cluster write path could later move to `_location_cluster` or a helper if it grows again. |
| N4 | `chappe_sip_route` (574 lines) | Now holds three concepts under one secret: Record-Route markers, WS and connection flow tokens, and edge routes. It still lives in `proxy/` under the name "route", which hides that the registrar and the B2BUA depend on it. | Name | Old M6, now stronger. Rename or split along route and flow, or at least move it to `sip/` and document it in the registrar section. |
| N5 | The node clock | Two clock processes can exist (chappe_cluster's `chappe_cluster_hlc` and chappe_sip's `chappe_sip_hlc_clock`), and `chappe_sip_hlc` picks one. The design is one clock per node, but a reader who meets two names assumes two clocks. | Doc | Write the rule in the glossary and the cluster overview. No code change. |
| N6 | Optional sibling apps | The rule (start chappe_cluster from your own start, keep it out of `applications`, release with `{chappe_cluster, load}`) is in code comments only, and pages contradict each other on when the app starts. | Doc, Arch | 0014, and one paragraph in each user app's configuration page. |
| N7 | `src/api/` (30 modules) | Old M5, grown: it now also holds `chappe_sip_call` (a core lookup service), the b2b transfer and join modules, and `chappe_sip_esc`. | Nav, Org | Doc the layout in the overview first. A `b2b/` directory stays the most useful later move (12 modules). |
| N8 | Doc drift | Section 1: supervision trees, module lists and counts are copied into prose. | Nav | Remove the copies (section 2). For the rest, a docs check in CI: every `src` module appears in an ex_doc group, and every child in each `*_sup` appears in the app overview. It is a script under `scripts/` and touches no source. |
| N9 | `chappe_rtpengine_session:handle_event` (220 lines) | Longest function in the tree (was 197). State times reply, plus `holder` and re-offer branches. | Cx | Old M10. Doc the state model first. |

### Findings from the first plan, status

| # | Status |
|---|---|
| M1 `chappe_sip_engine` | Open, grown. 2007 lines, 123 functions; `handle_call` has 46 clauses over about 370 lines; the state has 17 fields (was 11); fan-in 19. The responsibility map in the overview exists. Next step is still a plan to move the stateless parts (UAS response building, dispatch policy). |
| M2 `chappe_sip_dialog_fsm` | Open; the longest state functions got shorter (`confirmed` 53 lines). The states doc exists. |
| M3 `chappe_sip_uac_fsm` | Open, unchanged. |
| M4 `chappe_sip_ws_transport` | Documented (`design/ws-transport.md`, 0007). Size unchanged. |
| M7 `chappe_sip` facade | Open: fan-in 30. |
| M8 public vs internal | Partly done; regressed (section 1, ex_doc). Q5 still open. |
| M16 mrf backend behaviour | Open, and more urgent: see N1. |
| M18 shared tooling | Open: `chappe_sip_compliance.erl` and `doc_snippets_tests.erl` still sit in `apps/chappe_sip/test`. |
| M19 demo in CI | Half done: `demo/cluster` runs in CI (`demo-cluster-smoke`); `demo/sbc` is still not compiled by any job. |
| M22 elvis reasons | Done: every exemption has a reason. The list grew to 12 modules. |
| M6, M5 | See N4, N7. |
| Others | Documentation items done in #19. |

### Unusually long functions

| Function | Lines |
|---|---|
| `chappe_sip_engine:handle_call` | about 370 (46 clauses) |
| `op_cb` in the NIF (3029 lines in all) | about 300 |
| `chappe_rtpengine_session:handle_event` | 220 |
| `chappe_sip_engine:handle_event` | 126 |
| `chappe_sip_engine:do_create_uas_1` | 78 |
| `chappe_rtpengine_session:reply` | 76 |
| `chappe_sip_engine:handle_info` | 67 |
| `chappe_mrf_conf:handle_info` | 60 |

Large and coherent, acceptable with the docs above: `chappe_cluster_machine`
(427 lines, one Ra machine), `chappe_sip_siprec_srs` (485),
`chappe_sip_siprec` (475), `chappe_sip_siprec_meta` (415),
`chappe_mrf_conf_refer` (475), `chappe_sip_b2b_transfer` (440).

## 10. Diagrams and examples

1. **System context**, updated: 7 apps, the SIPREC path, cluster nodes (README
   and architecture).
2. **Lease lifecycle** (sequence): claim, renew, leader expiry, `lost`, a
   takeover with a higher fence. (Cluster overview.)
3. **A call to a device registered on another node** (sequence): lookup,
   edge route, the forward over the held flow, 430 when it is gone.
   (Registrar section.)
4. **A room on a clean stop** (sequence): `prep_stop`, drain, handoff to a
   live node, members moved, the old room told. (mrf overview.)
5. **Recording paths** (one picture): rtpengine fork, `mod_audio_stream`
   fork, SIPREC SRC to SRS, all into chappe_audio streams and the store.
6. **A worked cluster example** in the cluster guide: three nodes in a
   shell, claim, kill, take over. It should be checked by
   `doc_snippets_tests` where it can run.

## 11. Implementation order

Each step is its own PR, documentation only unless stated.

1. **Drift fixes, no new pages.** README, `architecture.md` (one-level trees),
   `docs/README.md`, AGENTS files, the counts, the "starts on first use"
   contradictions, the leaf-app list to one place, the app overviews' module
   tables, the configuration pages, and the lab READMEs. Remove the
   leaf-library stubs.
2. **ex_doc groups and extras** for every app. This touches only the
   `rebar.config` files.
3. **Glossary and concepts split,** with the cluster and recording sections.
4. **Navigation rows** (section 7), and the labs, add-tests and debug-a-call
   updates.
5. **New design pages:** the chappe_cluster overview, configuration and
   features; the chappe_mrf "Rooms in a cluster" section and backend
   contract; chappe_sip `design/siprec.md` and the registrar section;
   decision 0010 updated.
6. **Decisions 0011 to 0016,** after the maintainer answers Q1 to Q4.
7. **New workflows** (section 8), and workflow 7 after Q6.
8. **Docs check in CI** (N8): a script and a CI job, no source change. Ask
   before adding the job.
9. **Code side, each with its own plan:** N1 with M16 first (it is growing
   fastest), then M19 for `demo/sbc`, M18, N4, N2, then M1 once its
   stateless parts are agreed.
