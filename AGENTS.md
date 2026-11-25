# Agents

Instructions for AI coding agents working on this project.

## Project Overview

`chappe` is an opensource SIP/media platform for Erlang/OTP 29.1.2 or later (older 29 releases have TLS
CVEs; every rebar.config sets `minimum_otp_vsn`), a rebar3
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
apps/chappe_audio/       Audio intake and store: a WebSocket sink for
                         mod_audio_fork and mod_audio_stream, SIPREC RTP
                         intake, the recording store. SIP-free. Facade
                         module: chappe_audio.
apps/chappe_cluster/     Ownership across a cluster on Ra (Raft): fenced
                         leases, a small KV with watches, singletons, one
                         Ra group per region. SIP-free. Facade module:
                         chappe_cluster.
apps/chappe_mrf/         Media resource function (drachtio-fsmrf style):
                         IVR endpoints on FreeSWITCH, bridging, conferences
                         on chappe_mix or mod_conference. An orchestration
                         app. Facade module: chappe_mrf.
demo/sbc/                A runnable SBC on chappe_sip and chappe_mrf
                         (`make demo`). CI compiles it (`make demo-compile`).
demo/cluster/            Three nodes on chappe_cluster: registrar, room,
                         trunk pinger (`make demo-cluster`). CI runs its
                         walkthrough (`make demo-cluster-smoke`).
docs/                    Umbrella docs: concepts, architecture, decisions,
                         navigation, contributor workflows, plans.
scripts/                 compliance.escript and compliance/ (requirement
                         matrices), advisories.py and advisories_test.py
                         (security advisories check).
```

Layers: leaf (chappe_rtpengine, chappe_mix, chappe_esl, chappe_audio,
chappe_cluster; see `docs/decisions/0003-leaf-apps.md`), core (chappe_sip),
orchestration (chappe_mrf). See `docs/architecture.md`.

Inside the umbrella the apps reference each other by name (no fetched cross
deps). External deps (`livery`, `ws`, `ra`, `hlc`, `instrument`) are git/hex. Each app is published to hex
independently. Module prefixes are `chappe_sip_*` / `chappe_rtpengine_*` /
`chappe_esl_*` / `chappe_mix_*` / `chappe_audio_*` / `chappe_cluster_*` / `chappe_mrf_*`; only the app-named facade modules carry the
`chappe_` brand.

sofia-sip is vendored in `apps/chappe_sip/c_src/sofia-sip` (no git submodule), so
the NIF builds from a clean clone with no network. It is LGPL-2.1 (see NOTICE)
and linked, not forked. The vendored tree stays as upstream ships it; fixes we
need go as patches in `apps/chappe_sip/c_src/sofia-patches`, each with an
upstream ticket and a repro, applied at build time (see its README).

## First principle: compliance, latest spec, safety

chappe faces untrusted peers: phones, carriers, browsers, and whatever
reaches its listening ports. Every change that touches how SIP messages,
SDP, RTP, RTCP, DTMF events, WebSocket frames, rtpengine NG, ESL or HEP are
read, parsed or written, or how a transaction, dialog, subscription, call,
leg or room changes state, must pass three checks before it is called done,
committed or opened as a pull request:

1. **Compliance**: the behaviour matches the governing spec section, and a
   test shows the accept and the reject path. The test fails on main
   without the change.
2. **Latest specification**: you checked that the spec you cite is the
   current one (not obsoleted, no newer RFC or draft revision that changes
   the rule), and you read the section itself instead of quoting from
   memory.
3. **Safety**: the change does not open a known abuse class (amplification,
   resource exhaustion, floods, toll fraud through an auth bypass, call or
   dialog hijack) and every per-peer resource it touches stays bounded.

Use the [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
skill to run them. When in doubt whether a change is protocol code, it is.

## Specification issues are bugs, not security issues

A report is a specification issue when the fix is to make chappe do what a
spec it implements says (see [Specifications](#specifications)):

- a message accepted, rejected or answered differently from the spec
  (requests, responses, headers, URIs, SDP, RTP and RTCP packets, DTMF
  events, WebSocket frames);
- a wrong status code, or a transaction, dialog, subscription or
  offer/answer state the spec does not allow;
- a missing or wrong bound that the spec or an option defines (timers,
  retransmissions, `Max-Forwards`, session expiry, subscription expiry,
  jitter buffer and payload sizes).

This holds even when the report calls it amplification, denial of service
or a remote crash. Treat it as a bug:

- fix it in a public pull request, with a public issue if one is needed;
- list it under **Fixed** in the app's CHANGELOG, in plain English, citing
  the spec section;
- do not open a GitHub Security Advisory, request a CVE, embargo the fix,
  give it a severity, or describe how to attack it;
- when it arrived as an advisory, close the advisory as not a
  vulnerability and link the pull request that fixes it.

Only the problems listed in
[SECURITY.md](SECURITY.md#what-is-a-security-issue) go through private
reporting. Memory corruption or a VM crash through the NIF, and peer
authentication, stay security issues even where a spec describes the
input or the check. If unsure, ask the maintainer before treating anything
as a security issue.

## Required Checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt          # auto-format, always first (erlfmt, 80 cols; it writes)
rebar3 fmt --check  # what CI runs
rebar3 compile      # must compile cleanly (warnings_as_errors; builds the NIF)
rebar3 lint         # Elvis linter (config: elvis.config)
rebar3 xref         # cross-reference analysis
rebar3 dialyzer     # type checking
rebar3 eunit        # unit + property tests
rebar3 ct           # Common Test suites (chappe_sip_*, chappe_rtpengine_*, chappe_mix_*, chappe_esl_*, chappe_audio_*, chappe_cluster_*, chappe_mrf_*_SUITE)
```

`make check` runs all of them. CI (`.github/workflows/ci.yml`) runs
`format`/`lint`/`xref`/`dialyzer` as fast-fail static checks, then gates
`build`/`eunit`/`ct` on them. `ct` also runs `make cover`, which fails under
the `MIN_COVERAGE` floor set in the workflow (raise it, never lower it). The
docker jobs run the conformance lab and the compliance gate
(`make interop-conformance`, `make compliance GATE=demo`), the JsSIP/Kamailio
suite, the SBC lab (`make interop-sbc`), `make interop`, `make interop-mix`,
`make interop-esl`, `make interop-mrf`, the cluster lab (`make interop-cluster`: nodes partitioned and killed on a seeded schedule, checked for overlapping leases), the cluster demo walkthrough (`make demo-cluster-smoke`), and the C NIF
under AddressSanitizer with a short fuzz run (`make asan`, `make fuzz`),
ThreadSanitizer (`make tsan`) and the C linters (`make lint-c`; see
`apps/chappe_sip/test/asan/`). The `build` job also runs
`make demo-compile`. Separate workflows run the advisories check
(`advisories.yml`, `make advisories-test` first) and a longer scheduled fuzz
(`fuzz.yml`).

## Pull Requests

Work on one issue goes in one pull request. Give each change a reviewer has
to look at its own commit, with its tests, rather than opening a pull
request per change. Docs and CHANGELOG entries go in the same pull request.

- Every bug fix and feature has a test. Show it failing on main.
- Never relax a limit or a check to make a peer pass; exclude the
  legitimate case precisely.
- Descriptions state what was wrong, the fix in a few lines, and breaking
  changes. Reference issues with `Fixes #N`. No test plan, no file-by-file
  walkthrough.
- No `Co-Authored-By`, "Generated with" or similar trailers, in commits or
  pull requests.
- CHANGELOG: plain English, what was wrong and what it means for the user,
  the spec section when there is one. No implementation details, no attack
  narratives.
- Follow "Write for the person who reads it" in
  [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it):
  plain English, no inflated or pseudo-technical wording, and a person has
  read the change before it is opened.

## Specifications

The specs chappe implements, at the version the code follows. Where a newer
one exists it is listed under [Pending updates](#pending-updates). Each app
that speaks a protocol claims what it implements in
`apps/<app>/docs/compliance/requirements.tsv` (chappe_cluster speaks none
and has no matrix), and `make compliance GATE=demo` checks the claims
against the tests.
Last checked: 2026-11-24.

### SIP core

| Spec | Scope in chappe | Code |
|---|---|---|
| RFC 3261 SIP | messages, transactions (sofia-sip nta in the NIF), dialogs, UAC, UAS, B2BUA, stateful proxy, registrar | `chappe_sip_engine`, `chappe_sip_msg`, `chappe_sip_hdr`, `chappe_sip_uri`, `chappe_sip_dialog_fsm`, `chappe_sip_uac_fsm`, `chappe_sip_b2b`, `chappe_sip_proxy`, `chappe_sip_registrar` |
| RFC 3263 locating SIP servers | where the requests chappe sends go | `chappe_sip_engine` (sofia-sip nta), `chappe_sip_b2b_fork` |
| RFC 6026 2xx responses to INVITE | the proxy's Accepted state, 2xx retransmission | `chappe_sip_proxy_accepted`, `chappe_sip_engine` |
| RFC 3581 rport | responses to the source address and port | `chappe_sip_flow`, `chappe_sip_ws_msg` |
| RFC 5626 outbound, RFC 3327 Path | flows, keepalives, Path on registration | `chappe_sip_engine_conns`, `chappe_sip_flow`, `chappe_sip_registrar`, `chappe_sip_registry`, `chappe_sip_qualify` |
| RFC 5658 Record-Route | double Record-Route in the proxy | `chappe_sip_proxy`, `chappe_sip_route` |
| RFC 5630 SIPS, RFC 5922 domain certificates | `sips:` routing, TLS peer names | `chappe_sip_proxy_rules`, `chappe_sip_engine_opts` |
| RFC 7118 SIP over WebSocket, RFC 6455 WebSocket | ws and wss in Erlang (sofia-sip's own transport is not built) | `chappe_sip_ws_*`, `chappe_audio_conn` |
| RFC 8996 TLS 1.0 and 1.1 deprecated | a TLS 1.2 floor on SIP over TLS and on wss | `c_src/nif/stack.c`, `chappe_sip_ws_listener` |

### SIP extensions

| Spec | Scope in chappe | Code |
|---|---|---|
| RFC 3262 PRACK | reliable provisional responses | `chappe_sip_uac_early`, `chappe_sip_res`, `chappe_sip_b2b_early` |
| RFC 3311 UPDATE | offer/answer inside a dialog | `chappe_sip_dialog_offer`, `chappe_sip_b2b_relay` |
| RFC 6086 INFO | INFO relayed across the B2BUA | `chappe_sip_b2b_requests` |
| RFC 4028 session timers | refresh and expiry | `chappe_sip_session_timer`, `chappe_sip_b2b_hdr` |
| RFC 3326 Reason | Reason on BYE and CANCEL | `chappe_sip_b2b_hdr`, `chappe_sip_dialog` |
| RFC 3323 privacy, RFC 3325 asserted identity | Privacy and P-Asserted-Identity at trust boundaries | `chappe_sip_b2b_hdr` |
| RFC 8760 and RFC 7616 digest (RFC 7616 obsoletes RFC 2617) | SHA-256 and MD5 digest, nonce counts | `chappe_sip_digest`, `chappe_sip_digest_nc`, `chappe_sip_uac_auth`, `chappe_sip_registrar` |

### Events

| Spec | Scope in chappe | Code |
|---|---|---|
| RFC 6665 SIP events (updated by RFC 7621) | subscriptions, NOTIFY, forked notifications | `chappe_sip_dialog_sub`, `chappe_sip_subscription`, `chappe_sip_notifier` |
| RFC 3903 PUBLISH | event state compositor | `chappe_sip_esc`, `chappe_sip_publisher` |
| RFC 3856 presence, RFC 3863 PIDF | presence package and documents | `chappe_sip_presence`, `chappe_sip_pidf` |
| RFC 3842 message waiting | message-summary package | `chappe_sip_mwi` |
| RFC 4575 conference event package | roster documents | `chappe_sip_confinfo`, `chappe_sip_focus`, `chappe_mrf_conf_focus` |

### REFER and transfer

| Spec | Scope in chappe | Code |
|---|---|---|
| RFC 3515 REFER (updated by RFC 7647, RFC 8217) | REFER and its implicit subscription | `chappe_sip_refer`, `chappe_sip_refer_sub`, `chappe_sip_b2b_transfer` |
| RFC 7647 REFER with RFC 6665 | 200 answers, the `id` parameter | `chappe_sip_refer` |
| RFC 3420 message/sipfrag | NOTIFY bodies | `chappe_sip_sipfrag` |
| RFC 3891 Replaces | attended transfer, dialog lookup | `chappe_sip_dialog_index`, `chappe_sip_b2b_transfer` |
| RFC 3892 Referred-By (updated by RFC 8217) | Referred-By on REFER and the referred request | `chappe_sip_hdr`, `chappe_sip_refer` |
| RFC 4488 Refer-Sub | REFER without a subscription | `chappe_sip_refer` |
| RFC 4538 Target-Dialog | an out-of-dialog REFER bound to a dialog | `chappe_sip_hdr`, `chappe_sip_refer` |
| RFC 5589 call transfer | blind and attended transfer in the B2BUA | `chappe_sip_b2b_transfer` |
| RFC 4579 conferencing for user agents | the focus, `isfocus`, REFER to a conference | `chappe_sip_focus`, `chappe_mrf_conf_refer` |
| RFC 5368 multiple REFER targets | a Refer-To naming a URI list, at the focus | `chappe_sip_focus` |

### Recording

| Spec | Scope in chappe | Code |
|---|---|---|
| RFC 7866 SIPREC (updated by RFC 9806), RFC 7865 metadata, RFC 6341 requirements | recording client and server, metadata | `chappe_sip_siprec`, `chappe_sip_siprec_meta`, `chappe_sip_siprec_srs`, `chappe_audio_rtp` |

### Media

| Spec | Scope in chappe | Code |
|---|---|---|
| RFC 8866 SDP, RFC 3264 offer/answer | parsing, offer/answer in dialogs, the mixer's answers | `chappe_sip_sdp`, `chappe_sip_dialog_offer`, `chappe_sip_media_mix_sdp` |
| RFC 3550 RTP and RTCP, RFC 3551 audio profile | mixer legs, the recording receiver | `chappe_mix_leg`, `chappe_mix_rtcp`, `chappe_audio_rtp`, `chappe_audio_rtcp` |
| RFC 3605 `a=rtcp`, RFC 5761 rtcp-mux, RFC 7022 CNAME | RTCP ports and identity | `chappe_mix_rtp`, `chappe_sip_media_mix_sdp`, `chappe_audio_rtp_rtcp` |
| RFC 3711 SRTP, RFC 4568 SDES | SRTP on the recording server's legs (rtpengine terminates SRTP everywhere else) | `chappe_audio_srtp`, `chappe_sip_sdes` |
| RFC 4733 DTMF events (updated by RFC 4734, RFC 5244) | telephone-event forwarding in the mixer | `chappe_mix_room`, `chappe_mix_leg` |

### Protocols with no RFC

Checked against their source, named with the version or commit you read:

| Protocol | Version the labs run | Code |
|---|---|---|
| rtpengine NG (`docs/ng_control_protocol.md`, `daemon/call_interfaces.c`) | 26.3.1.4, built from the upstream release (`apps/chappe_rtpengine/interop/Dockerfile`) | `chappe_rtpengine_ng`, `chappe_rtpengine_cmd`, `chappe_rtpengine_bencode` |
| FreeSWITCH event socket (`mod_event_socket.c` and the dptools apps it drives) | FreeSWITCH 1.10.10 | `chappe_esl_parser`, `chappe_esl_conn`, `chappe_esl_verbs` |
| mod_audio_fork and mod_audio_stream (each module's README and source) | mod_audio_stream v1.1.0 | `chappe_esl_exec`, `chappe_audio_ws` |
| HEPv3 (the sipcapture specification) | heplify-server 1.60.3 | `chappe_sip_hep` |

### Not implemented

RFC 5627 GRUU (the deviation rows R6665-17 and R7647-01), RFC 4235 dialog
event package, RFC 7614 explicit REFER subscriptions and RFC 4508 feature
tags in Refer-To are not implemented. A change that adds one adds its row
above and its requirement rows.

### Keeping the specifications current

A spec changes under the code when an RFC is obsoleted or updated, or a
draft gets a new revision. Check the list:

- before every release;
- when you change a module listed in it, for the specs that module follows;
- when a peer the labs run (FreeSWITCH, rtpengine, Kamailio, SIPp, pjsua,
  JsSIP) moves to a newer version, since interop breaks first.

Check an RFC with `curl -sL https://www.rfc-editor.org/rfc/rfcNNNN.json`
(`obsoleted_by`, `updated_by`) and its errata on
https://www.rfc-editor.org/errata/rfcNNNN. Check a draft's latest revision
on `https://datatracker.ietf.org/doc/draft-.../`. Then set "Last checked"
above.

When a newer version exists, it is its own piece of work, not a side
change:

1. Add it under [Pending updates](#pending-updates) with what is known to
   differ.
2. Diff the sections the code relies on, old version against new, and list
   every change: header fields, parameters, status codes, MUST and SHOULD
   changes, removed features.
3. Decide per change: follow it now, or keep the old behaviour and say why.
4. Make the change in one pull request, one commit per item, each with a
   test, run through the
   [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
   checks, and run the labs against peers on both versions where they
   exist.
5. Update the citations in the code it touches, the requirement rows, the
   row in the tables above and the "Last checked" date, and remove it from
   Pending updates. Add a CHANGELOG entry when behaviour changes, saying
   which version is now followed.

A new RFC number that only renumbers the same text still updates the
citations and the table, with no CHANGELOG entry.

### Pending updates

Found on 2026-11-24 in the `updated_by` lists of the RFCs above. None has
been diffed yet (step 2). The last two rows are citations to move to the
current RFC, section by section.

| Spec followed | Newer document | Known to differ |
|---|---|---|
| RFC 3261 SIP | RFC 3853, 4320, 4916, 5393, 5621, 5954, 6141, 6878, 7462, 7463, 8591, 8898 | RFC 4320 is cited by the engine; the others are not cited in the code. RFC 5393 adds loop and fork-bomb limits for proxies. |
| RFC 3263 locating SIP servers | RFC 7984, RFC 8553 | Not diffed. |
| RFC 3264 offer/answer | RFC 6157, RFC 8843 (obsoleted by RFC 9143) | BUNDLE is handled by rtpengine; not diffed. |
| RFC 3325 asserted identity | RFC 5876, RFC 8217 | RFC 5876 allows P-Asserted-Identity in more requests. |
| RFC 3326 Reason | RFC 8606, RFC 9366 | RFC 9366 allows several Reason values, one per protocol. |
| RFC 3550 RTP | RFC 5506, 6051, 6222, 7160, 7164, 8083, 8108, 8860 | RFC 5506 allows reduced-size RTCP; RFC 8083 adds circuit breakers. |
| RFC 3551 audio profile | RFC 5761, RFC 7007, RFC 8860 | RFC 7007 updates the RTCP rules when RTCP is not sent. |
| RFC 3711 SRTP | RFC 5506, RFC 6904, RFC 9335 | Reduced-size SRTCP; encryption of header extensions and of the whole header. |
| RFC 5761 rtcp-mux | RFC 8035, RFC 8858 | `a=rtcp-mux-only`. |
| RFC 5368 multiple REFER targets | RFC 8262 | Content-ID header field. |
| RFC 6455 WebSocket | RFC 7936, RFC 8307, RFC 8441 | RFC 8441 bootstraps WebSocket over HTTP/2. |
| RFC 8866 SDP | (citations) | The code still cites RFC 4566, which RFC 8866 obsoletes, with RFC 4566 section numbers. |
| RFC 7616 digest | (citations) | `chappe_sip_digest` and two requirement rows still cite RFC 2617, which RFC 7616 obsoletes. |

A newer version found later goes in this table, with what is known to
differ, and needs the diff in step 2 before any code changes.

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
- `docs/concepts.md`: the mental model.
- `docs/glossary.md`: the vocabulary (leg, owner, anchor, flow, lease, ...).
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

- Run `rebar3 fmt` before committing; elvis must pass. erlfmt covers
  sources, tests, examples, lab nodes, demos and scripts.
- Commit messages: one imperative subject; body only for non-obvious "why". No
  phase references, no diff restatement, no "generated by" / "co-authored-by"
  trailers.
- Never use the em-dash character in code, docs, or messages.
- Never use the word "comprehensive" in tickets, comments, PRs, or MRs.
- OTP 29.1.2 or later. sofia pin: freeswitch/sofia-sip v1.13.19 (vendored).
- Share code, do not copy it. Before writing a helper, look for one in the
  app (`grep -rn '^name(' apps/<app>/src`). When a second module needs a
  helper, export it from the module that owns the concept (`chappe_sip_hdr`
  for header grammar, `chappe_sip_uri` for URIs, `chappe_sip_dialog` for
  tags, `chappe_sip_lib` for ASCII and byte helpers) instead of copying it;
  copies that drift apart are bugs. Helpers are not shared across apps: each
  app is published on its own and the leaf apps take no umbrella deps. A
  one-line wrapper over a single BIF may stay local.
- Dispatch messages by pattern, never by guard. A `handle_call`,
  `handle_cast`, `handle_info` or `receive` clause matches the message
  shape (`{join, Req}`, `{set, Id, Flag, Value}`); do not catch a variable
  and test it with `element/2`, `is_tuple/1` or a list of atoms. When
  several requests share a policy (a lock, a check), group them under one
  envelope tag and dispatch inside a helper that matches each shape. Pattern
  clauses compile to a jump table on arity and tag, keep the exact message
  shapes visible to readers and dialyzer, and fail at the right place.
- Keep the leaf apps (chappe_rtpengine, chappe_esl, chappe_mix, chappe_audio,
  chappe_cluster; `docs/decisions/0003-leaf-apps.md`) SIP-free;
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
- Build for fully distributable Erlang apps: every long-lived process is
  supervised, isolated (one per call, stream, session or room), owned (it
  monitors its owner, sends it events, cleans up when it dies), reachable from
  another node (pids and references as handles, `pg` in a scope named after the
  app that owns the lookup), and bounded. No state in the process dictionary. The
  `chappe-erlang-patterns` skill has the checklist and the tests it asks for.

## Skills

Task guides for agents live in `.agents/skills/<name>/SKILL.md`; read the one
that matches the task before starting. `.claude/skills` links to the same
directories, so there is one copy. A review states the result of each that
applies.

- [chappe-phase-plan](.agents/skills/chappe-phase-plan/SKILL.md): plan one
  phase in plan mode.
- [chappe-lane](.agents/skills/chappe-lane/SKILL.md): brief or work one lane
  of a plan.
- [chappe-erlang-patterns](.agents/skills/chappe-erlang-patterns/SKILL.md):
  supervision, isolation, ownership, distribution.
- [rfc-compliance](.agents/skills/rfc-compliance/SKILL.md): check a change
  against the specs it claims, from their text.
- [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md):
  the three checks above (compliance, latest spec, safety), per commit,
  before a commit or a merge that touches a protocol.

## Linting Notes

Elvis rules are configured in `elvis.config`, the only lint configuration.
`rebar3 lint` reads that file and ignores any `{elvis, ...}` entry in
`rebar.config` while it exists, so an exemption added to `rebar.config` has
no effect. A new per-module ignore goes in `elvis.config` with a one-line
reason. `rebar3_lint` is pinned in `rebar.config` (it changed how it
resolves `elvis.config` within the 5.0 range, and plugins are not locked).
The lint covers `apps/*/src`; the line limit is 90 for erlfmt's 80 columns.
