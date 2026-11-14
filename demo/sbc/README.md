# Demo SBC

A small SBC built on chappe_sip that you run on your machine and call
through with softphones or a browser. It registers two users, `alice` and
`bob`, bridges calls between them through the B2BUA, decides per call
whether rtpengine anchors the media, and keeps Kamailio and itself pinging
each other with OPTIONS. Use it to see the SBC features work end to end
before you build your own.

It also fronts a pool of two FreeSWITCH nodes: `1000` echoes, `1001` plays
a tone and `1002` joins a conference. `2000` is an IVR built on chappe_mrf:
a menu that calls bob, echoes, or puts you in a conference on chappe_mix or
on FreeSWITCH, and records a message.

The node runs in the foreground of `make demo` on your machine; rtpengine,
Kamailio and the FreeSWITCH nodes fs1 and fs2 run in docker
(`docker-compose.yml`). The node's code is one module,
`src/demo_sbc.erl`; its settings, users and passwords are in `demo.config`.

## Start it

```sh
make demo
```

You should see:

```
demo: demo up: SIP 127.0.0.1:5060, WS 5066, page http://localhost:5067/
demo: peer kamailio is up
demo: FreeSWITCH fs1 is up
demo: peer fs1 is up
```

Each FreeSWITCH node is seen twice, under one name: as a chappe_esl node
(`FreeSWITCH fs1 is up`, its event socket and load) and as a chappe_sip peer
(`peer fs1 is up`, its OPTIONS).

To listen on another address (to call from your phone on the LAN), set
`DEMO_IP` to your machine's LAN address; rtpengine then advertises it too:

```sh
DEMO_IP=192.168.1.10 make demo
```

`DEMO_SIP_PORT`, `DEMO_WS_PORT` and `DEMO_HTTP_PORT` move the node's
ports, and `DEMO_MRF_PORT` the IVR's event socket listener (18084). If
another SIP app already holds 5060 on your machine, the node fails with
`nta_agent_create failed`; move it:

```sh
DEMO_SIP_PORT=5080 make demo
```

The containers keep their ports (rtpengine 22223 and 31000-31100/udp,
Kamailio 15070/udp, fs1 and fs2 15081, 15082/udp and 18031, 18032/tcp).
Stop the node with Ctrl-C, then the containers with `make demo-down`.

## Register two phones

Use Linphone, Zoiper or the bundled page, one per user:

| user  | password     | domain        | server               |
|-------|--------------|---------------|----------------------|
| alice | `alice-demo` | `chappe.demo` | `127.0.0.1:5060` UDP |
| bob   | `bob-demo`   | `chappe.demo` | `127.0.0.1:5060` UDP |

For the browser, open http://localhost:5067/, keep the WebSocket
`ws://localhost:5066/ws`, and press Register. The log shows `registered as
alice`.

## Call each other

Call `bob` from `alice`. The demo log shows the call and its media mode:

```
demo: call 3f2a...@... alice -> bob up, media anchor
```

The mode comes from `chappe_sip_media:bypass/2`:

- a browser on either side: always `anchor` (rtpengine bridges WebRTC to
  plain RTP);
- a softphone whose SDP address is not the address its packets come from
  (it is behind a NAT, Docker Desktop included): `anchor`;
- two endpoints in one of the `networks` of `demo.config`: `direct`.

Hang up from either side: the other side gets the BYE, with its Reason.

## Call the FreeSWITCH pool

Call `1000` (echo), `1001` (a tone) or `1002` (a conference) from any
phone. chappe_esl picks the node with the fewest sessions, the call goes to
its SIP address with an `X-Chappe-Call` header, and the node's
CHANNEL_CREATE event brings that header back, so the demo knows the
FreeSWITCH channel of the call:

```
demo: call 3f2a...@... alice -> 1000 up, media anchor
demo: call 3f2a...@... is channel 86bb4fb3-... on fs1
```

These calls are always anchored: FreeSWITCH sends its media to rtpengine
inside docker, and rtpengine to your phone.

```erlang
demo_sbc:calls().
%% [#{call_id => ..., to => <<"1000">>, media => anchor,
%%    fs_node => fs1, fs_uuid => <<"86bb4fb3-...">>}]
demo_sbc:nodes().
%% [{fs1, up, #{sessions => 1, max_sessions => 200, idle_cpu => 98.7}},
%%  {fs2, up, #{sessions => 0, max_sessions => 200, idle_cpu => 99.0}}]
```

Stop fs1 and call again:

```sh
docker compose -f demo/sbc/docker-compose.yml stop fs1
```

The log shows `FreeSWITCH fs1 is down` and `peer fs1 is down`, and the
next call lands on fs2. A call that reaches a node that stopped between two
OPTIONS fails over to the next peer of the pool on its 408 or 503.
`start fs1` brings it back.

Drain a node to stop sending it calls while its calls finish:

```erlang
demo_sbc:drain(fs2).
%% ok, and the log shows: FreeSWITCH fs2 is draining
demo_sbc:resume(fs2).
```

## Call the IVR

Dial `2000` from any phone. chappe_mrf bridges the call, anchored in
rtpengine, to a FreeSWITCH node; the node's `mrf` extension hands the
channel back to the demo over its event socket, and the demo plays the menu
and waits for a digit:

| digit | what happens |
|-------|--------------|
| 1 | bob's phone rings; once he answers, the IVR's channel goes and you talk to bob |
| 2 | you move to a new FreeSWITCH endpoint that echoes you |
| 3 | you join `demo-native`, a conference on chappe_mix behind rtpengine |
| 4 | you enter the PIN `1234` and join `demo-fs`, a mod_conference room |
| 8 | you speak for 10 s while the demo prints your level, from a fork into chappe_audio |
| 9 | you record a message after the prompt; it plays back, then the menu again |

The prompts are spoken by macOS `say` when it is there (a tone each
otherwise), written to `_build/demo-media`, which is `/media` in the
FreeSWITCH nodes. The log follows the call:

```
demo: call 5c1f...@... in the IVR on fs1
demo: call 5c1f...@...: member 492ae7ba344e194ee9d5 of demo-native
demo: call 5c1f...@... ended {done,a_bye}
```

Your phone never sees a re-INVITE: each move (to bob, to the echo, into a
conference) swaps the leg behind rtpengine.

Call `2000` from two or three phones and press 3 (or 4, then `1234`) on
each: you hear each other. From `make demo-shell`:

```erlang
demo_sbc:confs().
%% [{<<"demo-native">>, native, 2}]
demo_sbc:members(<<"demo-native">>).
%% [#{id => <<"492ae7...">>, name => <<"5c1f...">>, mute => false,
%%    deaf => false, moderator => false, talking => true}, ...]
demo_sbc:kick(<<"demo-native">>, <<"492ae7...">>).
%% ok, and that phone gets a BYE
```

When the last member leaves, `demo-native` stays: `confs()` shows it with
0 members, and the next caller joins the same room. Stop fs1 while a call
is in the IVR (`docker compose -f demo/sbc/docker-compose.yml stop fs1`):
that call ends, and the next `2000` lands on fs2.

A browser can call `2000` too. Option 1 calls bob wherever he registered
(a browser bob gets WebRTC media from rtpengine).

## See your voice level, and find the recordings

Press 8 in the IVR and speak. FreeSWITCH forks your audio (mod_audio_fork)
into chappe_audio on port 18090 (`DEMO_AUDIO_PORT`), and the log prints a
level line twice a second:

```
demo: call 5c1f...@...: forking to ws://host.docker.internal:18090/audio/9b0e...
demo: call 5c1f...@...: fork connected from {{192,168,65,1},53012}
demo: call 5c1f...@...: fork metadata {"call":"75a5294a0517ae328579"}
demo: call 5c1f...@...:  -23.4 dBFS ##################
demo: call 5c1f...@...:  -71.0 dBFS
demo: call 5c1f...@...: fork closed (peer_closed); recordings: [#{id => ..., source => <<"fork">>, ...}]
```

The fork is also written to the recording store, and the message you
record with 9 is adopted into it once it has played back. Both land in
`demo/sbc/recordings/YYYY/MM/DD/<call_ref>/`, each `.wav` with its `.json`
next to it. Find them by the call's ref from `make demo-shell`:

```erlang
demo_sbc:recordings(<<"75a5294a0517ae328579">>).
%% [#{id => <<"20261114-...">>, source => <<"fork">>, duration_ms => 10020,
%%    path => <<"demo/sbc/recordings/2026/11/14/75a5.../20261114-....wav">>},
%%  #{id => <<"20261114-...">>, source => <<"freeswitch">>, ...}]
```

## Put the call on hold

Press hold on either phone. The log shows the event the B2BUA sends:

```
demo: call [<<"3f2a...">>]: {hold,a}
```

Unhold shows `{unhold,a}`; the callee's side is `b`.

## Switch the media of a live call

Open a shell on the node:

```sh
make demo-shell
```

Then:

```erlang
demo_sbc:calls().
%% [#{call_id => <<"3f2a...">>, from => <<"alice">>, to => <<"bob">>, media => anchor}]
demo_sbc:direct(<<"3f2a...">>).
%% ok
demo_sbc:anchor(<<"3f2a...">>).
%% ok
```

Each switch re-INVITEs the caller without an offer and carries its new
offer to the callee, through rtpengine or around it. The call keeps going.

## Watch the peers

```erlang
demo_sbc:peers().
%% [{fs1, up, 200}, {fs2, up, 200}, {kamailio, up, 200}]
```

Stop Kamailio and watch it go down after two missed OPTIONS:

```sh
docker compose -f demo/sbc/docker-compose.yml stop kamailio
```

The log shows `peer kamailio is down`; `start kamailio` brings it back up.
Calling `kamailio` sends the call to it, and you get its 404.

## Replay it without a softphone

`run-sipp.sh` plays bob (registers and answers) and alice (calls, holds,
unholds, keeps the call up 20 s, then hangs up) with SIPp in docker:

```sh
demo/sbc/run-sipp.sh
```

While the call is up, `demo_sbc:direct/1` and `demo_sbc:anchor/1` from
`make demo-shell` switch its media. It ends with `done rc=0`, and the demo
log shows the call, `{hold,a}` and `{unhold,a}`.

## Notes

- The passwords in `demo.config` are for this machine only.
- A phone behind a NAT (SIPp in Docker Desktop, say) sends a Contact the
  node cannot reach. The node sends its requests where the phone's REGISTER
  or INVITE came from instead, so calls, hold, media switches and the
  OPTIONS keepalive work all the same.
- Registered UDP contacts get an OPTIONS every 30 s (the registrar's
  `qualify_interval_ms`); a phone that stops answering loses its
  registration, and the log says so.
- `route/1` in `demo_sbc.erl` maps a dialled user to where the call goes:
  a registered user, a number of the FreeSWITCH pool (`extensions` in
  `demo.config`), or one of `routes`.
- `run-sipp.sh 1000` calls the pool with SIPp.
- The IVR listens for the FreeSWITCH event sockets on 18084
  (`DEMO_MRF_PORT`, `mrf_port` in `demo.config`); `make demo` passes the
  same port to the containers.
- Text to speech is out of scope: the menu is a wav file. See
  `apps/chappe_mrf/docs` to build your own IVR.
