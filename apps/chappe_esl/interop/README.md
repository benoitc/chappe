# Live interop testing

This directory brings up two FreeSWITCH nodes you can run the live suite
against. Use it when you want to check chappe_esl end to end against a real
event socket rather than the in-process fake.

## When to use it

- You changed the connection or command code and want a real FreeSWITCH to
  confirm auth, api, bgapi and events.
- You changed the node registry and want to see real HEARTBEAT load, a call
  raising a node's session count, and a stopped node going down and back up.
- You are debugging a wire-level difference the fake server does not reproduce.

## Run everything

From the umbrella root:

```sh
make interop-esl
```

It starts fs1 and fs2, waits for them to be healthy, runs
`test/chappe_esl_live_SUITE.erl` with `FS_REQUIRED=1` (no silent skip), and
tears them down. The suite stops and starts fs1 itself.

## Run by hand

```sh
docker compose -p chappe-esl -f apps/chappe_esl/interop/docker-compose.yml up -d --wait
FS_HOST=127.0.0.1 FS_PORT=18021 FS2_PORT=18022 FS_PASSWORD=ClueCon \
  FS_COMPOSE="docker compose -p chappe-esl -f $PWD/apps/chappe_esl/interop/docker-compose.yml" \
  rebar3 ct --dir apps/chappe_esl/test --suite chappe_esl_live_SUITE
docker compose -p chappe-esl -f apps/chappe_esl/interop/docker-compose.yml down
```

Without `FS_HOST` the suite skips every case; without `FS2_PORT` it skips the
node registry group.

## Notes

- Both nodes run `drachtio/drachtio-freeswitch-mrf` (FreeSWITCH 1.10.10,
  arm64 and amd64) with `conf/freeswitch.xml` as their whole configuration:
  HEARTBEAT every second, ESL on 8021 with an allow-all ACL, one
  unauthenticated SIP profile on 5080 inside the compose network, and a
  dialplan with `park` and `conf-<name>`. Test-only; never ship that ACL or
  profile.
- ESL is published on 127.0.0.1:18021 (fs1) and 18022 (fs2). Override with
  `FS1_ESL_PORT` / `FS2_ESL_PORT`, and the compose project with `ESL_PROJECT`.
- Calls go from fs1 to `sip:park@fs2:5080`, so no endpoint module beyond
  mod_sofia is needed.
