# Testing

chappe_esl tests run without a FreeSWITCH by default and add an opt-in suite
against a real one. Read this to run the tests and understand what each layer
covers.

## When to use it

- You changed the parser, the connection code, or the API and want to verify it.
- You want to run the live interop suite against a real FreeSWITCH.

## Unit tests

eunit covers the parser and the event decoders. The parser tests feed real
frames split at every byte boundary, so arbitrary TCP chunking is exercised.

```sh
rebar3 eunit
```

## Integration tests

Common Test drives the connection, the outbound listener and the node
registry against an in-process
fake FreeSWITCH (`test/chappe_esl_fake_server.erl`), so no external server is needed.

```sh
rebar3 ct
```

The live suite (`test/chappe_esl_live_SUITE.erl`) skips unless `FS_HOST` is set.

## Live interop

From the umbrella root, bring up two FreeSWITCH nodes, run the live suite and
tear them down:

```sh
make interop-esl
```

See `interop/README.md` for running it by hand.

## Static checks

```sh
make test-static   # lint, xref, dialyzer, fmt -c
```

## Where it lives

- Fake: `apps/chappe_esl/test/chappe_esl_fake_server.erl`, frames in `test/fixtures/`
- Lab: `apps/chappe_esl/interop/` (docker compose), run by `apps/chappe_esl/test/e2e.sh` through `make interop-esl`
- Requirements: `apps/chappe_esl/docs/compliance/requirements.tsv` ([how claims work](../compliance/README.md))
