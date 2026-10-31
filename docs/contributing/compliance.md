# Add or update a compliance row

Each app keeps a catalogue of the behaviours it promises, one row per
normative statement, and `make compliance` joins it with the tests that claim
each row and their latest CT results. The output is a generated matrix per
app, and CI fails if a hard requirement of the `demo` tier is not passing. Use
this page when you close a protocol gap, add a feature that makes a promise,
or want to know which test proves a behaviour.

## Before you start

- [concepts.md: Compliance row](../concepts.md#compliance-row).
- The catalogue of the app you change:
  `apps/<app>/docs/compliance/requirements.tsv`.

## Where to look

| Piece | Where |
|---|---|
| Catalogues | `apps/{chappe_sip,chappe_mix,chappe_rtpengine,chappe_esl,chappe_mrf}/docs/compliance/requirements.tsv` |
| Generated matrices (do not edit) | `apps/<app>/docs/compliance.md` |
| The generator | `apps/chappe_sip/test/chappe_sip_compliance.erl`, eunit in `chappe_sip_compliance_tests.erl` |
| The entry point | `scripts/compliance.escript` |
| The make target | `compliance` in the root `Makefile` (`COMPLIANCE_APPS`) |
| The CI gate | the `conformance` job in `.github/workflows/ci.yml` |

## How the matrix is computed

1. `make compliance` runs `rebar3 as test compile`, then, per app,
   `scripts/compliance.escript REQS.tsv TESTDIR CTLOGDIR OUT.md [--gate TIER]`.
2. Claims are read from every `apps/<app>/test/*_SUITE.erl`: a `%% req:` line
   (ids separated by spaces or commas) directly above a case function.
3. Results come from the newest `suite.log` of each case under
   `_build/test/logs`.
4. A row passes when every case claiming it passed on its latest run. It fails
   when one of them failed. It is untested when no case claims it, or every
   claim was skipped: a skipped case proves nothing.
5. With `GATE=demo`, the run exits 1 if any row of tier `demo` whose keyword is
   MUST, MUST NOT, SHALL, SHALL NOT or REQUIRED is not `pass`.

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

3. Run the case on the old code and see it fail, then on the new code.
4. Regenerate:

   ```sh
   rebar3 ct
   make compliance GATE=demo
   ```

5. Commit the `requirements.tsv` change and the regenerated
   `apps/<app>/docs/compliance.md` together.

## Tests to add or run

- `rebar3 eunit --module=chappe_sip_compliance_tests` when you change the
  generator.
- The suites that claim the rows you touched, then `make compliance`.

## How to know it works

- `make compliance GATE=demo` exits 0.
- Its output lists no `unknown requirement id`: a typo in a `%% req:` line is
  reported and covers nothing.
- The row shows `pass` in the regenerated matrix.

## Per-app notes

- **chappe_sip.** The catalogue covers the RFCs it implements. The proxy rules
  of RFC 3261 16 and the registrar rows (RFC 3261 10.3, RFC 3327, RFC 5626 6)
  are `platform`. sofia is vendored unmodified, so where nta deviates the row
  is a `deviation` with the reason (nta adds `received` only when the source
  differs from the Via host, against RFC 3581 4). Many rows are claimed by
  `chappe_sip_conformance_SUITE`, so they pass only after
  `make interop-conformance`.
- **chappe_mix.** RFC 3550, 3551, 3605, 4733 and 5761: the RTP, RTCP and
  telephone-event rules a mixer meets, `demo` where the conference flows use
  them.
- **chappe_rtpengine.** There is no RFC for the NG protocol: `source` is
  `rtpengine NG`, every row is `platform`.
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
