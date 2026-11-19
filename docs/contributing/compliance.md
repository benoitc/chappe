# Add or update a compliance row

Each app keeps a catalogue of the behaviours it promises, one row per
normative statement, and `make compliance` joins it with the tests that claim
each row and their results in the newest run. The output is a generated matrix
per app, committed next to the catalogue. CI fails if a hard requirement of
the `demo` tier is not passing, or if a committed matrix differs from the one
CI produces. Use this page when you close a protocol gap, add a feature that
makes a promise, or want to know which test proves a behaviour.

## Before you start

- [glossary.md: Compliance row](../glossary.md#compliance-row).
- The catalogue of the app you change:
  `apps/<app>/docs/compliance/requirements.tsv`.

## Where to look

| Piece | Where |
|---|---|
| Catalogues | `apps/{chappe_sip,chappe_mix,chappe_rtpengine,chappe_esl,chappe_mrf}/docs/compliance/requirements.tsv` |
| Generated matrices (do not edit) | `apps/<app>/docs/compliance.md` |
| The generator | `scripts/compliance/chappe_sip_compliance.erl`, eunit in `test/chappe_sip_compliance_tests.erl` |
| The entry point | `scripts/compliance.escript` |
| The make targets | `compliance` and `compliance-full` in the root `Makefile` (`COMPLIANCE_APPS`) |
| EUnit reports | `_build/test/logs/eunit/TEST-*.xml`, set by `eunit_opts` in the `test` profile of `rebar.config` |
| The CI gate | the `conformance` job in `.github/workflows/ci.yml` |

## How the matrix is computed

1. `make compliance` runs `rebar3 as test compile`, then, per app,
   `scripts/compliance.escript REQS.tsv TESTDIR CTLOGDIR OUT.md [--gate TIER]`.
2. Claims are read from every `apps/<app>/test/*_SUITE.erl` and
   `apps/<app>/test/*_tests.erl`: a `%% req:` line (ids separated by spaces or
   commas) directly above a CT case or an EUnit test function. The claim is
   keyed `Module:Function`.
3. CT results come from the newest `ct_run.*` directory under
   `_build/test/logs` only. Older runs are ignored, so a result never outlives
   its run: after `rebar3 ct --suite X`, only X has results.
4. EUnit results come from the surefire reports in
   `_build/test/logs/eunit`, which `make eunit` clears before it runs. A
   generator (`name_test_()`) counts as one test: it fails when one of its
   tests failed, and passes when all of them passed.
5. A row passes when every test claiming it passed. It fails when one of them
   failed. It is untested when no test claims it, or when any claiming test
   was skipped or has no result: a skipped or missing test proves nothing.
6. With `GATE=demo`, the run exits 1 if any row of tier `demo` whose keyword is
   MUST, MUST NOT, SHALL, SHALL NOT or REQUIRED is not `pass`. It also exits 1,
   with one line per row, when a `deviation` row has empty notes, or when a
   case in `apps/<app>/interop/conformance/expected-fail` does not name a
   `deviation` row in its reason.
7. Each matrix opens with a Deviations section: one line per `deviation` row
   with its id, source, section, a short form of the text and the notes as the
   reason.

## The catalogue format

`requirements.tsv` is tab separated, one header line, ten columns. A line with
another column count, or a duplicate id, stops the generator.

| Column | Meaning |
|---|---|
| `id` | stable, never renumbered: `R<rfc>-<n>` (chappe_sip, chappe_mix), `RNG-<n>` (chappe_rtpengine), `ESL-<n>` (chappe_esl), `MRF-<n>` (chappe_mrf) |
| `source`, `section`, `line` | where the sentence is: an RFC and its line, or the protocol and area with `-` as line |
| `keyword` | the strongest RFC 2119 keyword of the sentence |
| `actor` | uac, uas, ua, dialog, transaction, transport, b2bua, notifier, focus, mixer, client, ... |
| `row` | the area the matrix groups by: invite, reinvite, refer, timers, rtcp, framing, ... |
| `tier` | `demo`, `platform`, `n/a`, `deviation`, `spec-defect` |
| `text` | the sentence, verbatim for an RFC, plain words otherwise |
| `notes` | what a test observes, or why the row is n/a or a deviation |

Tiers:

- `demo`: a duty the demo flows exercise. `GATE=demo` fails on these.
- `platform`: a duty of the platform the demo does not exercise (WebSocket,
  TLS, TCP, the proxy, the registrar).
- `n/a`: a role the app does not play, or a rule that holds by construction
  and no test can observe. The notes start with the reason; "holds by
  construction:" names the code that makes it so.
- `deviation`: not met on purpose; the notes say why.
- `spec-defect`: a later RFC changed it (RFC 7647 replaces the 202 to REFER).

## Steps

1. Find the row, or add it at the end of the app's catalogue with the next
   free id.
2. Claim it from the CT case that proves it:

   ```text
   %% RFC 3261 17.2.1: 100 Trying when the TU takes longer than 200 ms.
   %% req: R3261-309
   trying_100(Config) -> sipp(?FUNCTION_NAME, Config).
   ```

   or from an EUnit test, for a rule a pure module meets:

   ```text
   %% req: RNG-09
   nesting_depth_bounded_test() ->
       ?assertEqual({error, too_deep}, chappe_rtpengine_bencode:decode(nested(65))).
   ```

3. Run the test on the old code and see it fail, then on the new code.
4. Regenerate from the inputs CI uses (EUnit, then one CT run with the
   conformance lab, which needs docker):

   ```sh
   make compliance-full GATE=demo
   ```

5. Commit the `requirements.tsv` change and the regenerated
   `apps/<app>/docs/compliance.md` together.

## Record a deviation

A deviation is a requirement chappe does not meet on purpose. Record it so a
user can read what chappe does instead and decide whether it matters to them.

1. Set the row's `tier` to `deviation`.
2. Write the reason in `notes`: what chappe does instead, and why. For
   example: "nta adds received only when the source differs from the Via
   host; sofia-sip is vendored as upstream ships it".
3. If a conformance case fails because of it, list the case in
   `apps/chappe_sip/interop/conformance/expected-fail` and name the row id in
   its reason:

   ```text
   rport_response   response Via has rport=N but no received (deviation R3581-010)
   ```

4. Regenerate. The row appears under Deviations at the top of
   `apps/<app>/docs/compliance.md`, which is where users read them; the
   [docs map](../README.md) links each app's section.

The gate refuses a deviation with empty notes, and an expected-fail case that
names no deviation row.

## The committed matrices and CI

The committed matrices are the ones the CI `conformance` job produces. That
job runs `make compliance-full GATE=demo`, then
`git diff --exit-code -- 'apps/*/docs/compliance.md'`, and uploads the
matrices it produced as the `compliance-matrices` artifact. A row whose result
changed, a new claim or a new row all change the matrix, so the job fails until
the matrix in the branch matches.

The CI run is the reference because its inputs are fixed: EUnit, every CT
suite in one run with `CONFORMANCE=1`, and the other docker labs skipped. A
local `make check` skips the conformance suite, so the rows it claims show
untested there; do not commit that matrix. Either:

- run `make compliance-full` on a machine with docker, which feeds the
  generator the same inputs; or
- push, download the `compliance-matrices` artifact of the failed run, copy
  its files over `apps/*/docs/compliance.md`, and commit them.

Only the newest CT run counts, so do not run `make interop-conformance` after
`make ct` and expect both: the second run replaces the first.

## Tests to add or run

- `rebar3 eunit --module=chappe_sip_compliance_tests` when you change the
  generator.
- The suites that claim the rows you touched, then `make compliance`.

## How to know it works

- `make compliance GATE=demo` exits 0.
- The CI `conformance` job passes its "Committed matrices match this run"
  step.
- Its output lists no `unknown requirement id`: a typo in a `%% req:` line is
  reported and covers nothing.
- The row shows `pass` in the regenerated matrix.

## Per-app notes

- **chappe_sip.** The catalogue covers the RFCs it implements. The proxy rules
  of RFC 3261 16 and the registrar rows (RFC 3261 10.3, RFC 3327, RFC 5626 6)
  are `platform`. sofia is vendored as upstream ships it, so where nta deviates the row
  is a `deviation` with the reason (nta adds `received` only when the source
  differs from the Via host, against RFC 3581 4). Many rows are claimed by
  `chappe_sip_conformance_SUITE`, so they pass only in a run with
  `CONFORMANCE=1` (`make compliance-full`).
- **chappe_mix.** RFC 3550, 3551, 3605, 4733 and 5761: the RTP, RTCP and
  telephone-event rules a mixer meets, `demo` where the conference flows use
  them.
- **chappe_rtpengine.** There is no RFC for the NG protocol: `source` is
  `rtpengine NG`, every row is `platform`. The bencode and framing rows are
  claimed by EUnit tests (`chappe_rtpengine_bencode_tests`,
  `chappe_rtpengine_stream_tests`).
- **chappe_esl.** No RFC for the event socket: `source` is `FreeSWITCH
  mod_event_socket`, `section` the protocol area, `line` `-`, every row
  `platform`. "chappe behaviour" in `notes` marks a client choice.
- **chappe_mrf.** No RFC for a media resource function API (drachtio-fsmrf is
  the model): `source` is `chappe_mrf`, every row `platform`.
  `chappe_mrf_SUITE` claims the rows on fakes, so they hold without docker;
  the SIP rules it relies on are in the chappe_sip catalogue.

## Related

- [add-sip-feature.md](add-sip-feature.md)
- [add-tests.md](add-tests.md)
- [labs.md](labs.md)
