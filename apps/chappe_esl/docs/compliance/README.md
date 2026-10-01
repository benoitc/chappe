# Compliance catalogue

`requirements.tsv` lists the event socket protocol behaviours chappe_esl
implements, one row each, in the same ten-column format as the chappe_sip
catalogue. You need it when you change the parser, the connection state
machine or a command, and want to know which test proves a behaviour.

## What differs from an RFC catalogue

There is no RFC for the FreeSWITCH event socket, so:

- ids are `ESL-<n>`, stable; never renumber.
- `source` is `FreeSWITCH mod_event_socket`, `section` is the protocol area,
  and `line` is `-`.
- `text` states the wire behaviour in plain words. Rows marked "chappe
  behaviour" in `notes` are client choices (error handling), not FreeSWITCH
  rules.
- every row is tier `platform`.

## Claim a row in a test

Put the ids on a `%% req:` line directly above the Common Test case:

```text
%% A -ERR answer to the password fails connect with the reply text.
%% req: ESL-14
auth_failure(_Config) ->
    ...
```

Only `*_SUITE.erl` cases count toward the matrix. eunit tests may carry the
same line as a pointer, but they do not prove a row on their own.
