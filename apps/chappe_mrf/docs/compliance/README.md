# Compliance catalogue

`requirements.tsv` lists the behaviours chappe_mrf promises, one row each.
How rows are written, claimed in a test and turned into the matrix is the
same for every app: see the shared
[compliance page](https://github.com/benoitc/chappe/blob/main/docs/contributing/compliance.md). This page
only keeps what is specific to chappe_mrf.

## What is specific here

No RFC defines a media resource function's API (drachtio-fsmrf is the
model), so:

- ids are `MRF-<n>`, stable; never renumber.
- `source` is `chappe_mrf`, `section` is the area, and `line` is `-`.
- `text` states the behaviour in plain words; "chappe behaviour" in `notes`
  marks a choice of ours.
- every row is tier `platform`.

The SIP rules chappe_mrf relies on (the B2BUA, `replace_b/3`) are in the
chappe_sip catalogue.

`chappe_mrf_SUITE` (fakes) claims the rows, so they hold without docker;
`chappe_mrf_live_SUITE` runs the same flows on FreeSWITCH and rtpengine.
