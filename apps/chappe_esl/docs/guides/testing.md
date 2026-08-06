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

Common Test drives the connection and outbound listener against an in-process
fake FreeSWITCH (`test/chappe_esl_fake_server.erl`), so no external server is needed.

```sh
rebar3 ct
```

The live suite (`test/chappe_esl_live_SUITE.erl`) skips unless `FS_HOST` is set.

## Live interop

Bring up a FreeSWITCH and point the suite at it:

```sh
docker compose -f interop/docker-compose.yml up -d
FS_HOST=127.0.0.1 FS_PORT=8021 FS_PASSWORD=ClueCon \
  rebar3 ct --suite test/chappe_esl_live_SUITE
docker compose -f interop/docker-compose.yml down
```

See `interop/README.md` for details.

## Static checks

```sh
make test-static   # lint, xref, dialyzer, fmt -c
```
