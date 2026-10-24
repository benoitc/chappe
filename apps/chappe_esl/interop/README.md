# Live interop testing

This directory brings up a FreeSWITCH you can run the live suite against. Use it
when you want to check chappe_esl end to end against a real event socket rather
than the in-process fake.

## When to use it

- You changed the connection or command code and want a real FreeSWITCH to
  confirm auth, api, bgapi, events, and outbound handling.
- You are debugging a wire-level difference the fake server does not reproduce.

## Start FreeSWITCH

```sh
docker compose -f interop/docker-compose.yml up -d
```

Wait for it to report healthy:

```sh
docker compose -f interop/docker-compose.yml ps
```

## Run the suite

```sh
FS_HOST=127.0.0.1 FS_PORT=8021 FS_PASSWORD=ClueCon \
  rebar3 ct --suite test/chappe_esl_live_SUITE
```

Without `FS_HOST` the suite skips every case, so it is safe in normal CI.

## Stop FreeSWITCH

```sh
docker compose -f interop/docker-compose.yml down
```

## Notes

- `conf/event_socket.conf.xml` and `conf/acl.conf.xml` are mounted into the
  container: the socket listens on `0.0.0.0` with an allow-all ACL so the host
  reaches the published port. Test-only; never ship that ACL.
- `make interop-esl` from the umbrella root brings the container up, waits for
  it to be healthy, runs the suite with `FS_REQUIRED=1` (no silent skip) and
  tears it down. Docker Desktop for Mac can reset the published ESL
  connection; run it on Linux.
- `originate_and_events` and `conference` expect the default dialplan apps
  (`park`, `conference`) to be loaded. Adjust the commands in
  `test/chappe_esl_live_SUITE.erl` if your FreeSWITCH profile differs.
