# Compliance catalogue

This directory lists every normative statement (MUST, SHOULD, MAY...) of the
RFCs chappe_sip implements, one row each, and `make compliance` joins it with
the tests that prove each row. You need it when you close a protocol gap or
check what is still untested before a release. The mixer has its own
catalogue in `apps/chappe_mix/docs/compliance/`.

## Read the matrix

```bash
rebar3 ct                 # the matrix uses the latest CT results
make compliance           # writes apps/<app>/docs/compliance.md
make compliance GATE=demo # exit 1 if a MUST of the demo tier is not passing
```

A row passes only when every test claiming it passed on its latest run. It
fails when one of them failed, and it is untested when no test claims it or
the only claims were skipped.

## Claim a requirement in a test

Put the ids on a `%% req:` line directly above the Common Test case (a
suite fragment, so it is not a checked snippet):

```text
%% The app answers late: the server transaction still sends 100 Trying
%% within 200 ms.
%% req: R3261-309 R3261-310
trying_within_200ms(Config) ->
    ...
```

Run the test against the code before your change and see it fail first. An
id that is not in the catalogue is reported by `make compliance`, so a typo
cannot cover anything.

## Add or change a row

`requirements.tsv` is tab separated, ten columns:

| Column | Meaning |
| --- | --- |
| id | `R<rfc>-<n>`, stable; never renumber |
| source, section, line | where the sentence is in the RFC text |
| keyword | the strongest RFC 2119 keyword of the sentence |
| actor | uac, uas, ua, dialog, transaction, transport, b2bua, notifier, focus... |
| row | the area: invite, reinvite, cancel, refer, replaces, timers, events... |
| tier | demo, platform, n/a, deviation, spec-defect |
| text | the RFC sentence, verbatim |
| notes | what a test observes on the wire, or why the row is n/a |

- `demo`: a duty the demo flows exercise; `GATE=demo` fails on these.
- `platform`: a chappe duty the demo does not exercise (WebSocket, TLS, TCP).
- `n/a`: a role chappe does not play (a redirect server).
- The proxy rules of RFC 3261 16 are `platform`: `chappe_sip:proxy_request/3`.
- The registrar rows (RFC 3261 10.3, RFC 3327, RFC 5626 6) are `platform`:
  `chappe_sip:registrar/1` plays that role.
- `deviation`: chappe does not meet it on purpose; say why in notes.
- `spec-defect`: a later RFC changed it (RFC 7647 replaces the 202 to REFER).

## Notes

- sofia-sip is vendored unmodified, so where nta deviates the row is a
  `deviation` with the reason: nta adds `received` only when the source
  address differs from the Via host (RFC 3581 4 asks for it always).
- The generator is `test/chappe_sip_compliance.erl`; keep it in step with the
  copy in the i3_bridge product repo.
