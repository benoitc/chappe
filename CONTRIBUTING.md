# Contributing

This page tells you how to get a change into chappe: the checks it must
pass, the conventions reviewers hold it to, and how to write the commit and
the pull request. Read it before your first change. For a specific task
(change the B2BUA, add a lab, add a compliance row), go to the matching
workflow in [docs/contributing/](docs/README.md#if-you-want-to-change-something).

## Start here

1. Build: `make` (the first run builds the vendored sofia-sip; Erlang/OTP
   29.1.2 or later, rebar3, a C toolchain, autotools, OpenSSL).
2. Read [Concepts](docs/concepts.md), the [Glossary](docs/glossary.md) and
   [Architecture](docs/architecture.md).
3. Find the code with [Navigation](docs/navigation.md).

## Write for the person who reads it

Every issue, pull request and comment is read by a person. Make it easy for
them.

- Read what you send before you send it. You are responsible for every line,
  whether you wrote it or a tool did.
- Use plain English and short sentences. Say what happens, what you
  expected, and how to reproduce it. Explain any term a reader may not know.
- Don't inflate it. No buzzwords, no severity scores, CVSS or CWE labels, no
  "critical" for a bug, no long generated write-ups. If it takes a page to
  explain, cut it down until it doesn't.
- A bug report gives: the app versions (or the bundle) and the OTP version,
  the options you set, the peer and its version (phone, carrier,
  FreeSWITCH, rtpengine, browser), a minimal reproduction, what you got and
  what you expected. A SIP trace helps most: a pcap, a HEP capture, or a
  SIPp scenario that reproduces it.
- A pull request says what was wrong and why it matters, the fix in a few
  lines, and any breaking change. Link the issue. Don't walk through the diff
  file by file; the reviewer reads the code.
- A fix comes with a test that fails without it.

AI tools are fine to use. Before you open anything, you must have read the
change, run the checks, and be able to answer questions about it yourself.

Maintainers read every issue and pull request before acting on it. We close
without further review:

- text we cannot understand after one request to clarify;
- descriptions that don't match the code or the reproduction;
- reports that cannot be reproduced;
- submissions opened by an automated agent that no person has read.

## Security issues and specification bugs

chappe implements SIP and its extensions, SDP and offer/answer, RTP, RTCP,
SRTP, DTMF events, SIP over WebSocket and the other specifications listed
in [AGENTS.md](AGENTS.md#specifications).

When the fix is to make chappe do what one of these specifications says, it
is a bug, not a security issue. That includes reports described as
amplification, denial of service or a remote crash, when they come from:

- a message accepted, rejected or answered differently from the
  specification;
- a wrong status code, a transaction, dialog or subscription state the
  specification does not allow;
- an offer/answer, RTP or RTCP behaviour that does not follow the
  specification;
- a missing bound that the specification or an option defines.

Report these as a normal bug, in public. Cite the specification section.
The fix goes in a public pull request and in the app's CHANGELOG under
Fixed. We don't publish advisories or request CVEs for them, and advisories
filed for them are closed with a link to the fix.

Only the problems listed in
[SECURITY.md](SECURITY.md#what-is-a-security-issue) go through private
reporting. Memory corruption or a VM crash through the NIF is always one of
them, even when the input breaks a specification.

## Keeping the specifications current

The specifications chappe follows, and the version of each, are listed in
[AGENTS.md](AGENTS.md#specifications), with the newer versions not yet
followed under Pending updates. The list is checked before every release
and when a module it names changes.

Moving to a new RFC or draft revision is its own pull request: first the
list of what changed in the sections the code uses, then one commit per
change with its test, then the labs against peers on both revisions. The
steps are in
[Keeping the specifications current](AGENTS.md#keeping-the-specifications-current).
If you notice a spec has a newer version, open an issue naming it; that is
enough to get it on the list.

## Checks

Every change is formatted and passes every check before it is committed:

```sh
rebar3 fmt          # erlfmt, 80 columns; always first (it writes)
make check          # compile, eunit, ct, lint, xref, dialyzer, fmt check
```

erlfmt covers sources, tests, examples, lab nodes, demos and scripts.
`rebar3 fmt --check` (`make fmt-check`) is what CI runs.

`make check` runs these, each of which you can run alone:

| Check | Command | Notes |
|---|---|---|
| Format | `make fmt-check` | erlfmt, 80 columns, `rebar3 fmt --check` |
| Compile | `make compile` | `warnings_as_errors`; builds the NIF |
| Lint | `make lint` | elvis, `elvis.config` |
| Cross reference | `make xref` | |
| Types | `make dialyzer` | |
| Unit and property tests | `make eunit` | |
| Common Test suites | `make ct` | `rebar3 ct --dir apps/<app>/test` for one app |

## What CI enforces

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request. The static checks fail fast; the build and tests wait for them.

| Job | What it proves |
|-----|----------------|
| erlfmt, Elvis lint, XRef, Dialyzer | Formatting, lint, cross references and types |
| Docs check | `make docs-check`: every module is in an ex_doc group and named in its app's design overview, has a module doc and the right public or internal row in the navigation; every doc is an ex_doc extra; every relative link resolves |
| Package | Each app builds as a Hex package (`scripts/check_package.sh <app>`), and chappe_sip builds its NIF from the unpacked package with no git or network |
| Build (sofia NIF) | The vendored sofia-sip and the NIF build; `make demo-compile` |
| EUnit, Common Test | Unit and property tests, the suites, and line coverage over the `MIN_COVERAGE` floor (raise it, never lower it) |
| Conformance lab and compliance gate | SIPp and pjsua scenarios, then `make compliance GATE=demo`: every claimed requirement has a passing test |
| SIP interop | JsSIP and Kamailio |
| SBC interop | the SBC lab with FreeSWITCH, rtpengine and Kamailio (`make interop-sbc`) |
| rtpengine, chappe_mix, ESL and chappe_mrf interop | `make interop`, `make interop-mix`, `make interop-esl`, `make interop-mrf` against the real daemons |
| chappe_cluster lab, cluster demo | nodes partitioned and killed on a seeded schedule, checked for overlapping leases; `make demo-cluster-smoke` |
| NIF under ASan and UBSan, TSan, C static analysis | `make asan` with a short fuzz run, `make tsan`, `make lint-c` |

Separate workflows run the advisories check (`advisories.yml`, `make
advisories-test` first), CodeQL (`codeql.yml`), a longer scheduled fuzz
(`fuzz.yml`), the benchmark pass you start by hand (`bench.yml`) and the
bundle release (`release.yml`, see
[releasing](docs/contributing/releasing.md)). What each lab proves and how
to run it: [labs](docs/contributing/labs.md).

Pure Erlang work can skip the C build: `SKIP_ENGINE_BUILD=1 rebar3 compile`
uses the fake engine.

## Conventions

- **Format first.** Run `rebar3 fmt` before committing; elvis must pass.
  A new per-module elvis ignore goes in `elvis.config` with a one-line
  reason.
- **No em-dash character** anywhere: code, docs, commits, PRs.
- **Never the word "comprehensive"** in tickets, comments, PRs or MRs.
- **Share code, do not copy it.** Before writing a helper, look for one in
  the app (`grep -rn '^name(' apps/<app>/src`). When a second module needs
  a helper, export it from the module that owns the concept
  (`chappe_sip_hdr` for header grammar, `chappe_sip_uri` for URIs,
  `chappe_sip_dialog` for tags) instead of copying it; copies that drift
  apart are bugs. Helpers are not shared across apps: each app is
  published on its own. A one-line wrapper over a single BIF may stay
  local.
- **Dispatch messages by pattern, never by guard.** Each `handle_call`,
  `handle_cast`, `handle_info` or `receive` clause matches the message
  shape. Do not catch a variable and test it with `element/2`,
  `is_tuple/1` or a list of atoms: a variable clause breaks the compiler's
  jump table on arity and tag for the clauses around it, hides the message
  shapes from readers and dialyzer, and lets a malformed message fail far
  from where it arrived. When several requests share a policy, send them
  under one envelope tag (`{join, Req}`) and match each shape in a helper.
- **Keep the leaf apps SIP-free.** The leaf apps listed in
  [0003](docs/decisions/0003-leaf-apps.md) depend on no other chappe app.
  SIP-coupled logic belongs in chappe_sip, an orchestration app such as
  chappe_mrf, or a product. See also
  [0006](docs/decisions/0006-mrf-orchestration-app.md).
- **Tests first.** Write the test, run it against the code before your
  change and see it fail, then make it pass.
- **Measure before you claim.** A performance claim cites a measurement.
  chappe_mix keeps its thresholds and results in
  `apps/chappe_mix/test/audit/PERF.md` and what was tried and reverted in
  `ATTEMPTS.md`. Check the load average before timing anything.
- **TLS:** `verify_none` and permissive TLS are test-only; never in `src/`.
- **OTP 29.1.2 or later.** Every rebar.config sets `minimum_otp_vsn`, so
  rebar3 refuses an older OTP: earlier releases have TLS flaws (CVE-2026-89422, a TLS 1.3 server impersonation, and CVE-2026-105236, an SNI resumption bypass). sofia-sip is vendored at a pinned version. The vendored
  tree stays as upstream ships it; fixes we need go as patches in
  `apps/chappe_sip/c_src/sofia-patches`, each with an upstream ticket and a
  repro, applied at build time (see its README).

## Commits

- One imperative subject line ("add a guard drop action", not "added" or
  "adds").
- A body only for a "why" that is not obvious from the change.
- No phase references, no restatement of the diff, no "generated by" or
  "co-authored-by" trailers.

## Pull requests

Branch from `main` using the prefix that fits: `fix/`, `feat/`, `perf/`,
`refactor/`, `docs/`, `test/` or `chore/`. Sync a branch that has fallen
behind by merging `main` into it, not by rebasing.

A change to protocol code passes the three checks in
[AGENTS.md](AGENTS.md#first-principle-compliance-latest-spec-safety)
before it is opened: compliance with the spec section, the spec being the
current one, and safety against a hostile peer.

State the intent: what was wrong and why it matters. Then the solution in a
few lines, and any breaking change. Do not describe the diff file by file;
the reviewer reads the source. Keep it short, with no test plan section.

A user-visible change adds your line to the app's CHANGELOG,
`apps/<app>/CHANGELOG.md`, under `## [Unreleased]` and its Breaking, New or
Fixed heading: plain English, what was wrong or what is new and what it
means for the user, no code and no internal names. A change to the
repository that ships in no app (a lab, a make target, CI) goes under
"Umbrella and tooling" in the root [CHANGELOG.md](CHANGELOG.md). Releasing
is a separate step: see [Release the apps](docs/contributing/releasing.md).

There is no deprecation policy before the first release. An export nobody
calls is removed, not deprecated, and the CHANGELOG lists it as a
breaking change of the app it belongs to.

## How the documentation is organised

| Where | What |
|---|---|
| `README.md` | Orientation: what chappe is, the apps, where to start |
| `docs/README.md` | The map of every document |
| `docs/concepts.md`, `docs/glossary.md`, `docs/architecture.md`, `docs/navigation.md` | Mental model, vocabulary, how the apps fit, where the code is |
| `docs/decisions/` | One record per boundary and its reason |
| `docs/contributing/` | One workflow per task |
| `docs/plans/` | Maintainer plans |
| `apps/<app>/README.md`, `apps/<app>/docs/` | The app's guides, design and feature tracker |
| `AGENTS.md` | Rules for AI agents, the specifications chappe follows, pointing back here |
| `SECURITY.md` | Reporting a vulnerability, and what is a security issue |
| `.agents/skills/` | Task guides for agents (`.claude/skills` links to them) |

Guides are task-oriented and written in the second person: each opens with
one paragraph saying what it is and when you need it, then steps with code
and little prose. Erlang snippets call real exported functions. How to add
one: [write a guide](docs/contributing/write-a-guide.md).

## Read this next

- [Documentation map](docs/README.md)
- [Labs](docs/contributing/labs.md)
- [Add tests](docs/contributing/add-tests.md)
