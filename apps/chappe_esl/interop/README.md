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

- The event socket must listen on `0.0.0.0` for the host to reach it. If you
  build your own image, set `<param name="listen-ip" value="0.0.0.0"/>` and the
  password in `autoload_configs/event_socket.conf.xml`.
- `originate_and_events` and `conference` expect the default dialplan apps
  (`park`, `conference`) to be loaded. Adjust the commands in
  `test/chappe_esl_live_SUITE.erl` if your FreeSWITCH profile differs.
