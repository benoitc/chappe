# chappe_mrf lab

This lab runs chappe_mrf against rtpengine and two real FreeSWITCH media
servers. The CT suite is the chappe node, on your machine; its callers and
callees are small softphones on the host whose audio goes through rtpengine.
Run it when you change endpoints, bridging, recording, either conference
backend, or how a node going down is handled.

## What it proves

`apps/chappe_mrf/test/chappe_mrf_live_SUITE.erl`. Prompts are wav files of one
marker tone each, written to the shared `/media`, so a caller tells which
prompt played by the tone it hears.

| Case | Proves |
|---|---|
| `ivr_menu` | the menu plays, the caller presses 2 (RFC 2833 through rtpengine), `play_collect` returns it, the branch's prompt plays |
| `bridge_sip_target` | `bridge/3` to a SIP callee: audio both ways, no re-INVITE to the caller, the endpoint's channel goes |
| `fork_same_flags_second_answers` | after a menu, `bridge/3` with `{parallel, Dests}` to two softphones: the caller hears the endpoint while they ring, the second answers, audio both ways, the first gets a CANCEL, no re-INVITE to the caller |
| `fork_own_flags_second_answers`, `fork_own_flags_first_answers` | the same with flags of their own, so one rtpengine offer per via-branch, each branch winning in turn |
| `fork_same_flags_failed_then_bridge`, `fork_own_flags_failed_then_bridge` | every branch busy: the caller stays on the endpoint, audio both ways, and the next fork works |
| `fork_same_flags_failed_keeps_callee`, `fork_own_flags_failed_keeps_callee` | the old B is a softphone: after a failed fork, audio both ways |
| `failed_bridge_other_interface` | a failed bridge naming another rtpengine interface: the endpoint still hears the caller |
| `fork_again_after_win`, `fork_fails_after_win` | own-flags fork after own-flags fork on one call, each reusing the via-branches of the last: the winner has audio both ways, also when the next fork fails |
| `reinvite_after_win` | after a win, a re-INVITE from either side goes through with audio both ways |
| `fork_after_create_b2bua_fork` | a call begun as an own-flags fork of `create_b2bua/4` forks again |
| `endpoint_bridge` | `create_endpoint/1`, then `bridge/3` moves the caller onto it |
| `record_playback` | `record/3` writes the caller's audio; playing it back returns the caller's tone |
| `native_conference` | three callers in a chappe_mix room behind rtpengine: audio, a room prompt, mute, kick, talker events, the room outlives its first caller |
| `native_endpoint` | an endpoint in a native room, re-INVITEd to the mixer through rtpengine |
| `fs_conference` | three callers in a mod_conference room, each entering a PIN; moderator kick |
| `endpoint_verbs` | a missing file is `not_found`, `play_info` reports the time played and honours `limit_secs`, the owner gets playback events, `say` plays mod_say_en's files, `speak` runs mod_flite, `detect_tones` hears the caller's 700 Hz, variables and mute |
| `fs_conference_record_transfer` | an fs room is recorded to a file, mute comes back as an event, a member moves to another room and is heard there, `max_members` refuses the next join |
| `native_conference_transfer` | a member of a native room moves to another one and is heard there, without a re-INVITE |
| `owner_killed` | the owner of an endpoint dies with an audio fork running: fork stopped, channel killed, caller gets a BYE |
| `node_down_failover` | fs1 stops under a live endpoint: its owner hears `node_down`, the next caller lands on fs2 |

`chappe_mrf_SUITE` runs the same flows on fakes (`test/chappe_mrf_fake.erl`)
and claims the `MRF-` compliance rows, so they hold without docker. This lab
checks that the fakes tell the truth.

## Services

`docker-compose.yml`, compose project `chappe-mrf`:

| Service | Ports on the host | Role |
|---|---|---|
| `rtpengine` | NG `MRF_NG_PORT` (17222/udp), RTP `MRF_RTP_MIN`-`MRF_RTP_MAX` (31200-31299/udp) | anchors callers; interface `host` advertised as 127.0.0.1, `docker` as its own address |
| `fs1`, `fs2` | SIP `MRF_FS1_SIP`/`MRF_FS2_SIP` (17081, 17082/udp), ESL `MRF_FS1_ESL`/`MRF_FS2_ESL` (127.0.0.1:17031, 17032) | FreeSWITCH (`chappe-esl-fs:lab`, built from `apps/chappe_esl/interop/freeswitch`) with `conf/freeswitch.xml` (an `en` language on `/media/sounds`, the `chappe_700` tone descriptor, codecs OPUS, G722, PCMU, PCMA in that order, conference profiles `default` at 8 kHz and `wideband` at 16 kHz): the `mrf` extension hands the channel to the chappe_mrf listener at `host.docker.internal:MRF_SOCKET_PORT` |

The chappe node listens for SIP on `MRF_SIP_PORT` (17060) and for outbound
event sockets on `MRF_SOCKET_PORT` (17084). `MRF_MEDIA_DIR`
(`_build/mrf-media`) is `/media` in all three containers. The ports stay below
32768, out of Linux's ephemeral range.

## Run it

```sh
make interop-mrf
```

That runs `apps/chappe_mrf/test/e2e.sh`: it starts the lab and waits for the
FreeSWITCH healthchecks, finds the address rtpengine reaches the host at, runs
the suite with `MRF=1`, and tears the lab down. Without `MRF=1` the suite
skips.

## Keep it up

```sh
MRF_KEEP=1 make interop-mrf
docker compose -p chappe-mrf -f apps/chappe_mrf/interop/docker-compose.yml \
    exec fs1 /usr/local/freeswitch/bin/fs_cli -x 'show channels'
docker compose -p chappe-mrf -f apps/chappe_mrf/interop/docker-compose.yml down
```

To rerun the suite against a lab that is up, export what `e2e.sh` exports
(`MRF=1`, `MRF_MEDIA_IP`, `MRF_MEDIA_DIR`, `MRF_COMPOSE` and any port you
moved) and run
`rebar3 ct --dir apps/chappe_mrf/test --suite chappe_mrf_live_SUITE`.

`MRF_PROJECT` and the `MRF_*` ports move a second copy out of the way of the
first.

## HD rooms

`apps/chappe_mrf/test/chappe_mrf_hd_live_SUITE.erl` (run by `e2e.sh` after
the live suite) calls the room with three lab pjsua through
`apps/chappe_sip/interop/pjsua/hd.sh`, on the host network: A on G.722, B on
Opus, each playing the 16 kHz band probe for part of the call, and C on
PCMU, silent, in the middle. `native_hd_room` runs it in a native room at
`rate => 16000`, `fs_wideband_room` in a mod_conference room on the
`wideband` profile, the reference. Each direction passes the band check of
`chappe_mix_test_tone` with C in and after it left, and C hears both.

- `hd.sh` builds the `chappe-conf-pjsua` image only when it is missing:
  rebuild it from your branch (`docker build -t chappe-conf-pjsua
  apps/chappe_sip/interop/pjsua`) when another checkout built it, or the
  Opus caller has no codec and offers `m=audio 0`.
- The callers start 2 s apart: two pjsua started in the same second draw the
  same Call-ID and tags.
- pjsua's SIP ports start at `MRF_PJSUA_SIP` (19560, three of them), its RTP
  ports at `MRF_PJSUA_RTP` (19600, 20 per caller).

## Add a case

1. Add the flow to `chappe_mrf_SUITE` first, on `chappe_mrf_fake`, with its
   `%% req:` line, and see it fail on the old code.
2. Add the live case to `chappe_mrf_live_SUITE`. Callers and callees come
   from `test/chappe_mrf_live_ua.erl`. Write a new prompt with its own marker
   tone and assert on the tone the caller hears.
3. If the dialplan needs a new extension, add it to `conf/freeswitch.xml`.
4. A case that stops a node uses `MRF_COMPOSE` (the compose command) to stop
   and start it, as `node_down_failover` does, and leaves it running.

## Troubleshooting

- "the lab did not become healthy": `e2e.sh` prints the compose logs. The
  FreeSWITCH image is large; pull its base once, the digest the
  `FS_IMAGE` argument of `apps/chappe_esl/interop/freeswitch/Dockerfile`
  pins.
- No audio in a case: `MRF_MEDIA_IP` is empty when `host.docker.internal`
  does not resolve inside the rtpengine container. On Linux the compose file
  maps it to `host-gateway`.
- Prompts or recordings missing: `MRF_MEDIA_DIR` must be writable by the
  containers; `e2e.sh` creates it with mode 777 before docker would create it
  as root.
- The ESL ACL is allow-all and the SIP profile unauthenticated: test-only,
  never copy them to a deployment.

See also [docs/contributing/labs.md](../../../docs/contributing/labs.md) and
[docs/contributing/add-mrf-conference-backend.md](../../../docs/contributing/add-mrf-conference-backend.md).
