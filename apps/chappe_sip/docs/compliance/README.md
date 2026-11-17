# Compliance catalogue

`requirements.tsv` lists every normative statement of the RFCs chappe_sip
implements, one row each, and `make compliance` joins it with the tests that
claim each row into [compliance.md](../compliance.md). How rows, tiers,
`%% req:` claims and gates work is shared by every app and described in
[contributing: compliance](../../../../docs/contributing/compliance.md).

## Notes for chappe_sip

- The proxy rules of RFC 3261 16 are `platform` rows:
  `chappe_sip:proxy_request/3` plays that role. So are the registrar rows
  (RFC 3261 10.3, RFC 3327, RFC 5626 6): `chappe_sip:registrar/1`.
- sofia-sip is vendored, patched at build time from `c_src/sofia-patches`
  only for crashes and undefined behaviour, so where nta deviates the row is a
  `deviation` with the reason: nta adds `received` only when the source
  address differs from the Via host (RFC 3581 4 asks for it always).
- The generator is `scripts/compliance/chappe_sip_compliance.erl`, and it
  serves every app.
- The mixer has its own catalogue in `apps/chappe_mix/docs/compliance/`.
