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
on FreeSWITCH, and records a message. `1003` and `1004` are two HD (16 kHz)
conference rooms, one on chappe_mix and one on FreeSWITCH, that take
REFERs to add and remove members.

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
otherwise), written at 16 kHz to `_build/demo-media`, which is `/media`
in the FreeSWITCH nodes. An HD phone (G.722 or Opus) hears them in
wideband, a G.711 one at 8 kHz. The log follows the call:

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

## Talk in an HD room

Dial `1003` or `1004` to land in a 16 kHz conference room, with no IVR in
front: the room answers your call itself. Use them to hear what wideband
audio changes in a conference, and to compare chappe's room with the stock
FreeSWITCH one.

| number | room | what mixes it |
|--------|------|---------------|
| 1003 | `demo-hd` | chappe_mix at 16 kHz behind rtpengine: rtpengine converts each caller (G.722, Opus or PCMU) to the room's L16 and back |
| 1004 | `demo-hd-fs` | mod_conference on its `wideband` profile (16 kHz), each caller bridged to a FreeSWITCH node through rtpengine |

A 16 kHz room needs an rtpengine with the L16 codec, 13.4 or later; the
demo's is built from `mr26.3.1.4` (`apps/chappe_rtpengine/interop`).

1. Set two phones to G.722 or Opus only, or use the browser page for one
   of them (a WebRTC peer, which sends Opus). Set a third phone to PCMU
   only.
2. Call `1003` from the two HD phones. The log shows each one join:

   ```
   demo: call 9c1e...@...: member 3f5a... of demo-hd
   demo: demo-hd: {joined,<<"3f5a...">>,#{id => <<"3f5a...">>,name => <<"9c1e...">>,uri => <<"sip:alice@chappe.demo">>,...}}
   ```

   You hear each other in wideband: "s", "f" and "th" are crisp, and the
   voices sound close, not boxed in.
3. Call `1003` from the PCMU phone. It hears the room, and the room hears
   it, through 8 kHz: it sounds like an ordinary phone call. The two HD
   phones keep hearing each other in wideband.
4. Hang up and do the same on `1004`. The rooms should sound alike;
   listen for level, delay, and quiet syllables or breaths that
   mod_conference's energy gate (`energy-level` 100) leaves out.

From `make demo-shell`:

```erlang
demo_sbc:confs().
%% [{<<"demo-hd">>, native, 3}, {<<"demo-hd-fs">>, fs, 0}]
demo_sbc:members(<<"demo-hd">>).
```

`apps/chappe_mix/test/audit/QUALITY.md` has the two rooms measured
against each other with speech clips.

### Add and remove members by REFER

Both rooms are focus rooms (RFC 4579): their URI, `sip:demo-hd@<the
node>` (and `sip:demo-hd-fs@...`), takes REFERs that bring a party in or
remove a member. Two senders may REFER them: the users registered here,
and the demo shell, whose REFERs carry a random token made at start as
their From user. A party brought in must be a user or a number of the
demo (`users` and `extensions` in `demo.config`); any other sender or
target gets 403. The From is not authenticated (see
[Notes](#notes)). A room's roster (a SUBSCRIBE to its URI, the
conference package) goes to registered users only, on the same From.

From a phone in the room, press transfer and dial `bob` (registered). Your
phone sends the REFER in its call with the room, the room dials bob from
the FreeSWITCH pool through this node, and bob's phone rings:

```
demo: demo-hd: REFER add sip:bob@chappe.demo from <sip:alice@chappe.demo>: allowed
demo: call fab7...: dialed out by demo-hd
demo: demo-hd: {joined,<<"9f00...">>,#{id => <<"9f00...">>,name => <<"sip:bob@chappe.demo">>,...}}
```

Most phones hang up once a blind transfer succeeds: dial `1003` again to
come back.

From `make demo-shell`, the same REFER, sent by the node to the room's
URI, with each NOTIFY it gets back:

```erlang
demo_sbc:refer_add(<<"demo-hd">>, <<"sip:bob@chappe.demo">>).
%% REFER sip:demo-hd@127.0.0.1:5060: 200
%% NOTIFY 100
%% NOTIFY 200 (done)
%% {ok,200}
demo_sbc:refer_remove(<<"demo-hd">>, <<"sip:bob@chappe.demo">>).
%% REFER sip:demo-hd@127.0.0.1:5060: 200
%% NOTIFY 100
%% NOTIFY 200 (done)
%% {ok,200}
```

The removal sends Refer-To `<sip:bob@chappe.demo;method=BYE>`: bob's phone
gets a BYE and the log shows `{left,<<"9f00...">>,kicked}`. Bob's phone is
offered Opus, G.722, PCMU and PCMA, so a PCMU phone can be brought in too
(narrowband, as when it calls). The pool calls every party through this
node, which routes it as any call: it never calls out. A party that is
neither a user nor a number of the demo (`sip:someone@10.0.0.7:5060`) is
refused:

```erlang
demo_sbc:refer_add(<<"demo-hd">>, <<"sip:someone@10.0.0.7:5060">>).
%% REFER sip:demo-hd@127.0.0.1:5060: 403
%% {ok,403}
```

A party that does not answer gives its status in the final NOTIFY (480,
486, 408 after 30 s), and the room stays as it was.

### Check the band with pjsua

Without phones, `apps/chappe_sip/interop/pjsua/hd.sh` places one call
with one codec, plays a wav and records what it hears. Write the band
probe and judge the recordings as
[The HD peer](../../docs/contributing/labs.md#the-hd-peer) shows, then
call the room from two of them, the second 2 s later (two pjsua started in
the same second draw the same Call-ID):

```sh
hd.sh -c G722 -r 16000 -p probe.wav -o out/a.wav -d 20 \
    -l 25060 -m 25100 sip:1003@127.0.0.1:5060 &
sleep 2
hd.sh -c opus -r 16000 -p probe.wav -o out/b.wav -d 16 \
    -l 25062 -m 25200 sip:1003@127.0.0.1:5060
```

Each recording holds the other caller's probe (a room never sends you
your own voice): judge `out/a.wav` from 5 s on and `out/b.wav` from 3 s
on. Both pass on `1003` and on `1004`.

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

## Record a call with SIPREC

Register bob, then dial `3001` from alice. The demo calls bob with the
media anchored in rtpengine and records the call: it taps each party in
rtpengine and sends a SIPREC INVITE to its own recording server, the route
`sip:srs@` of the same node. The recording server writes each party's
stream to the recording store, next to the fork and the messages:

```
demo: call 7a1e...@... alice -> bob up, media anchor
demo: call 7a1e...@... recorded to sip:srs@127.0.0.1:5060
demo: recording 5b0c...: 2 streams
demo: recording 5b0c... ended: demo_sbc:recordings(<<"5b0c...">>)
```

Talk, hang up, and list them from `make demo-shell` with the ref the log
printed:

```erlang
demo_sbc:recordings(<<"5b0c...">>).
%% [#{id => <<"20261114-...">>, source => <<"siprec">>, duration_ms => 6000,
%%    path => <<"demo/sbc/recordings/2026/11/14/5b0c.../20261114-....wav">>},
%%  #{id => <<"20261114-...">>, source => <<"siprec">>, ...}]
```

Each file is one party (16-bit, 8 kHz, mono; `afplay` plays it), with
its JSON next to it naming the party.

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
- Nothing but REGISTER is authenticated. Anyone who reaches the node's
  SIP port (`DEMO_IP` on your LAN, say) can:
  - call the registered users, the FreeSWITCH numbers, the IVR (which
    calls bob), `3001` (which records a call to bob) and the HD rooms;
  - REFER an HD room as a registered user, by putting that user in the
    From (`refer_policy/2` in `demo_sbc.erl` trusts it): bring in a user
    or a number of the demo, or remove a member. It cannot make the pool
    call anyone outside the demo, and it cannot pass as the demo shell
    without its token, which never leaves the node;
  - read an HD room's roster (who is in, from which address) the same
    way;
  - take a member's place in an HD room with an INVITE whose Replaces
    names that member's call with the room, by putting a registered user
    in the From or the Referred-By (`replaces_policy/2` trusts the same
    senders as `refer_policy/2`). The room checks only that the Replaces
    names a member's call (its Call-ID and both tags), which a party to
    that call or one it told knows.

  Before the demo leaves your machine, change the passwords, keep the
  node on a network you trust, and authenticate INVITE, REFER and
  SUBSCRIBE (digest).
- The IVR listens for the FreeSWITCH event sockets on 18084
  (`DEMO_MRF_PORT`, `mrf_port` in `demo.config`); `make demo` passes the
  same port to the containers. The pool connects from the docker network,
  so the listener binds every interface and takes only loopback and
  docker's address pools (`mrf_ip`, `mrf_allow`; `DEMO_MRF_IP`,
  `DEMO_MRF_ALLOW` win).
- Text to speech is out of scope: the menu is a wav file. See
  `apps/chappe_mrf/docs` to build your own IVR.
