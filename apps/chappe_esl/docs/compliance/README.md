# Compliance catalogue

`requirements.tsv` lists the event socket protocol behaviours chappe_esl
implements, one row each. How rows are written, claimed in a test with a
`%% req:` line and turned into the generated [matrix](../compliance.md) is
the same for every app: see the shared
[compliance page](../../../../docs/contributing/compliance.md). This page
only keeps what is specific to chappe_esl.

## What is specific here

There is no RFC for the FreeSWITCH event socket, so:

- ids are `ESL-<n>`, stable; never renumber.
- `source` is `FreeSWITCH mod_event_socket`, `section` is the protocol area,
  and `line` is `-`.
- `text` states the wire behaviour in plain words. Rows marked "chappe
  behaviour" in `notes` are client choices (error handling), not FreeSWITCH
  rules.
- every row is tier `platform`.

Only `*_SUITE.erl` cases count toward the matrix. eunit tests may carry the
same `%% req:` line as a pointer, but they do not prove a row on their own.
