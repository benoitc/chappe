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
mkdir -p _build/esl-media
export ESL_MEDIA_DIR=$PWD/_build/esl-media
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
  dialplan with `park`, `conf-<name>` and `socket-<port>`, mod_sndfile
  for wav prompts and recordings, and mod_audio_fork (the image ships it) for
  the fork case, which streams to a websocket sink the suite opens on
  `ESL_SOCKET_PORT` + 1. Test-only; never ship that ACL or
  profile.
- ESL is published on 127.0.0.1:18021 (fs1) and 18022 (fs2). Override with
  `FS1_ESL_PORT` / `FS2_ESL_PORT`, and the compose project with `ESL_PROJECT`.
- Calls go from fs1 to `sip:park@fs2:5080`, so no endpoint module beyond
  mod_sofia is needed.
- The `call` group of the suite has fs1 call `sip:socket-<port>@fs2:5080`;
  fs2's dialplan runs `socket host.docker.internal:<port> async full`, which
  connects back to a chappe_esl listener on this machine (`ESL_SOCKET_PORT`,
  default 18084). Both nodes mount `ESL_MEDIA_DIR` (default
  `_build/esl-media`) as `/media`: the suite writes its prompt there and
  checks the recordings. The group is skipped without `ESL_MEDIA_DIR`.
