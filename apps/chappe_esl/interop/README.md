# FreeSWITCH lab

This directory brings up two FreeSWITCH nodes for the live suite. Use it to
check chappe_esl end to end against a real event socket rather than the
in-process fake: after a change to the connection, a command, the outbound
listener or the node registry, or to chase a wire-level difference the fake
does not reproduce.

## What it proves

`apps/chappe_esl/test/chappe_esl_live_SUITE.erl`, three groups:

| Group | Proves |
|---|---|
| `conn` | inbound auth, `api` and `bgapi`, events of an originated call, a conference |
| `call` | outbound sockets: fs1 calls `sip:socket-<port>@fs2:5080`, fs2's dialplan connects back to a chappe_esl listener on your machine, and the suite drives the call (prompts, recordings, an audio fork to a websocket sink) |
| `nodes` | the node registry: HEARTBEAT load, a call raising a node's session count, fs1 stopped and restarted going down and back up |

## Services

Both nodes run `chappe-esl-fs:lab`, built from `freeswitch/Dockerfile`:
`drachtio/drachtio-freeswitch-mrf` (FreeSWITCH 1.10.10, arm64 and amd64) plus
mod_audio_stream, which is AGPL-3.0, built for this lab only and never shipped
with chappe. They use `conf/freeswitch.xml` as their whole configuration: HEARTBEAT
every second, ESL on 8021 with an allow-all ACL, one unauthenticated SIP
profile on 5080 inside the compose network, a dialplan with `park`,
`conf-<name>` and `socket-<port>`, mod_sndfile for wav prompts and recordings,
and both fork modules, mod_audio_fork and mod_audio_stream.

| Node | ESL on the host | Variable |
|---|---|---|
| fs1 | 127.0.0.1:18021 | `FS1_ESL_PORT` |
| fs2 | 127.0.0.1:18022 | `FS2_ESL_PORT` |

The outbound listener the dialplan connects back to is `ESL_SOCKET_PORT`
(18084); the audio fork sink is that port plus one. `ESL_MEDIA_DIR`
(`_build/esl-media`) is mounted as `/media` on both nodes.

## Run it

From the umbrella root:

```sh
make interop-esl
```

It runs `apps/chappe_esl/test/e2e.sh`: start fs1 and fs2, wait for their
healthchecks, run the suite with `FS_REQUIRED=1` (an unreachable node fails
the run instead of skipping), tear them down. The suite stops and starts fs1
itself through `FS_COMPOSE`.

Without `FS_HOST` the suite skips every case; without `FS2_PORT` it skips the
`nodes` group; without `ESL_MEDIA_DIR` it skips the `call` group.

## Keep it up

`e2e.sh` always tears down. Run the lab by hand:

```sh
mkdir -p _build/esl-media
export ESL_MEDIA_DIR=$PWD/_build/esl-media
docker compose -p chappe-esl -f apps/chappe_esl/interop/docker-compose.yml up -d --wait
FS_HOST=127.0.0.1 FS_PORT=18021 FS2_PORT=18022 FS_PASSWORD=ClueCon \
  FS_COMPOSE="docker compose -p chappe-esl -f $PWD/apps/chappe_esl/interop/docker-compose.yml" \
  rebar3 ct --dir apps/chappe_esl/test --suite chappe_esl_live_SUITE
docker compose -p chappe-esl -f apps/chappe_esl/interop/docker-compose.yml \
  exec fs1 /usr/local/freeswitch/bin/fs_cli -x 'show channels'
docker compose -p chappe-esl -f apps/chappe_esl/interop/docker-compose.yml down
```

`make demo-esl` uses the same compose file to start both nodes and a shell
with chappe_esl monitoring them (`apps/chappe_esl/examples/README.md`).

`ESL_PROJECT` names the compose project; with `FS1_ESL_PORT`, `FS2_ESL_PORT`
and `ESL_SOCKET_PORT` it moves a second copy out of the way.

## Add a case

1. Write it first against `chappe_esl_fake_server` in the non-gated suite of
   the area (`conn`, `call`, `outbound`, `nodes`), with its `%% req:` line if
   it proves an `ESL-` row.
2. Add the live case to the matching group of `chappe_esl_live_SUITE`. A call
   case goes in `?CALL_CASES`, so it gets the outbound listener and its
   cleanup.
3. If the dialplan needs a new extension, add it to `conf/freeswitch.xml`.

## Troubleshooting

- "FreeSWITCH did not become healthy": `e2e.sh` prints the compose logs. The
  first run builds the image and needs network access to GitHub and Debian.
- `call` cases time out: fs2 reaches your machine at `host.docker.internal`;
  check that `ESL_SOCKET_PORT` is free.
- The ACL and SIP profile are test-only; never ship them.

See also [docs/contributing/labs.md](../../../docs/contributing/labs.md).
