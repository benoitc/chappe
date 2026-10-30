# Compliance catalogue

`requirements.tsv` lists the behaviours chappe_mrf promises, one row each,
in the same ten-column format as the chappe_sip catalogue. You need it when
you change how endpoints are correlated, cleaned up, bridged or put in a
conference, and want to know which test proves a behaviour.

## What differs from an RFC catalogue

No RFC defines a media resource function's API (drachtio-fsmrf is the
model), so:

- ids are `MRF-<n>`, stable; never renumber.
- `source` is `chappe_mrf`, `section` is the area, and `line` is `-`.
- `text` states the behaviour in plain words; "chappe behaviour" in `notes`
  marks a choice of ours.
- every row is tier `platform`.

The SIP rules chappe_mrf relies on (the B2BUA, `replace_b/3`) are in the
chappe_sip catalogue.

## Claim a row in a test

Put the ids on a `%% req:` line directly above the Common Test case:

```text
%% A channel nobody waits for is hung up.
%% req: MRF-02
unknown_channel_refused(Config) ->
    ...
```

`chappe_mrf_SUITE` (fakes) claims the rows, so they hold without docker;
`chappe_mrf_live_SUITE` runs the same flows on FreeSWITCH and rtpengine.
