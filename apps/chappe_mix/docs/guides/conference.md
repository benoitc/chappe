# Run a conference

A conference is a room where every participant hears every other one, never
themselves. This guide shows you how to run one with chappe_mix, first on
its own, then behind rtpengine and from a SIP call. Read it when you add
rooms, whispers or listen-only participants to a service.

## When to use it

- You want the room in your own Erlang node, with per-pair control over who
  hears whom.
- Your legs are G.711, or rtpengine can transcode them to G.711 (an
  8 kHz room) or to L16 (a 16 kHz room, for HD callers).
- You do not need mod_conference features (recording into the room, PIN
  prompts, TTS). For those, use a FreeSWITCH room through `chappe_mrf`.

## Start a room and add legs

```erlang
{ok, _} = application:ensure_all_started(chappe_mix),
{ok, Conf} = chappe_mix:start(#{ip => {10, 0, 0, 5}, law => ulaw}),
{ok, Alice, #{ip := Ip, port := PortA}} = chappe_mix:add_leg(Conf, #{name => <<"alice">>}),
{ok, Bob, #{port := PortB}} = chappe_mix:add_leg(Conf, #{name => <<"bob">>}).
```

Each leg is one UDP socket bound to `ip`. Put `Ip` and the leg's port in the
SDP you send to that participant. The default `ip` is `127.0.0.1`, so
nothing is exposed until you choose an address.

The room is bound to the process that called `start/1` and stops when it
exits. Pass `owner => Pid` to bind it to another process.

## Run a 16 kHz (HD) room

An 8 kHz room, the default, cuts every caller to the telephone band. For
callers on G.722 or Opus, start the room at 16 kHz: every leg then speaks
L16 at 16000 (RFC 3551 4.5.11, 16-bit samples, most significant octet
first) and rtpengine turns each caller's codec into it and back.

```erlang
{ok, Hd} = chappe_mix:start(#{ip => {10, 0, 0, 5}, rate => 16000}),
{ok, Leg, #{ip := Ip, port := Port}} = chappe_mix:add_leg(Hd, #{pt => 97}).
```

Write `a=rtpmap:97 L16/16000` (and `telephone-event/16000` for digits) in
the SDP toward rtpengine for that leg. `pt` defaults to 96.

- The rate is fixed: `rate` is 8000 or 16000, anything else is
  `{error, {bad_option, rate}}`. `law` is a bad option in a 16 kHz room,
  `pt` in an 8 kHz one.
- rtpengine needs the L16 codec: the labs test 26.3.1.4, 11.5.1.18
  (Ubuntu 24.04) has none, and upstream tags have it from 13.4.1.1 (not
  tested here). The
  offer toward the mixer carries `codec => #{mask => [<<"all">>],
  transcode => [<<"L16/16000/1">>, <<"telephone-event/16000">>]}`;
  `chappe_sip_media:mixer_params/2` gives you these flags.
- A PCMU caller in a 16 kHz room is heard and hears through 8 kHz; the
  others keep their band.
- A leg moves only to a room of its rate.

## Tell a leg where to send

By default a leg learns the far end from the first packet it receives. When
you already know the address (from the far end's SDP), set it:

```erlang
ok = chappe_mix:set_remote(Conf, Alice, {{10, 0, 0, 20}, 40000}),
ok = chappe_mix:set_remote(Conf, Bob, #{remote => {{10, 0, 0, 21}, 40002},
                                        dtmf_pt => 101}).
```

The map form also takes `rtcp_remote` (an `a=rtcp` address) and
`dtmf_events`. A new remote resets the source latch, so the next address
that sends is taken.

## Control who hears what

```erlang
ok = chappe_mix:mute(Conf, Alice, true),              %% hears the room, is not heard
ok = chappe_mix:direction(Conf, Bob, recvonly),       %% heard by all, hears nothing
ok = chappe_mix:relate(Conf, Alice, Bob, nohear),     %% Alice stops hearing Bob only
ok = chappe_mix:relate(Conf, Alice, Bob, hear).
```

A whisper is a coach leg that only the agent hears: set `nohear` from every
other leg to the coach. A listen-only supervisor is a leg with
`direction => sendonly`.

## Get talker events

```erlang
ok = chappe_mix:events(Conf, self()),
receive
    {chappe_mix, Conf, {talking, Leg, true}} -> io:format("~p talks~n", [Leg])
end.
```

Set `talk_threshold`, `talk_start_ms` and `talk_stop_ms` in `start/1` to
tune the detection (see [Configuration](../configuration.md)).

Give the room or a leg a `ref` (an opaque binary, such as a call's
correlation id) and read it back from the handle: `chappe_mix:ref(Conf)`
for the room, `legs/1` for each leg's `ref`. The events keep their
`{chappe_mix, Conf, Event}` shape either way.

## Move a leg to another room

```erlang
{ok, Room2} = chappe_mix:start(#{ip => {10, 0, 0, 5}}),
{ok, NewId} = chappe_mix:move_leg(Conf, Alice, Room2).
```

The socket, its port and the far end move with the leg, so the participant
needs no new SDP. The leg's relations are dropped.

- Moving a leg to the room it is in returns `{ok, Alice}` and changes
  nothing.
- If `Room2` is gone you get `{error, destination_down}` and the leg stays
  in `Conf` under its id. `{error, not_found}` means `Conf` has no such leg.
- A room of another rate refuses the leg (`{error, refused}`): the leg
  stays where it is, untouched.
- Moves between the same two rooms can run at the same time, in either
  direction: the rooms never wait on each other.

## Inspect and stop

```erlang
Legs = chappe_mix:legs(Conf),     %% per-leg state and counters
Stats = chappe_mix:stats(Conf),   %% ticks, overruns, lateness histogram
ok = chappe_mix:remove_leg(Conf, Bob),
ok = chappe_mix:stop(Conf).
```

Every leg gets an RTCP BYE when it is removed or the room stops.

## Put rtpengine in front

The mixer only takes G.711 (or L16 in a 16 kHz room) over plain RTP/AVP. A WebRTC caller, an SRTP
call or an Opus leg reaches it through rtpengine: rtpengine answers the
caller and offers towards the mixer leg in PCMU or PCMA.

With chappe_rtpengine alone, you ask rtpengine for an offer towards the
mixer, read the address it gives the leg, and answer with an SDP that names
the leg's address. Writing those two SDP bodies is your code:

```erlang
{ok, Reply} = chappe_rtpengine:offer(rtpe1, #{
    call_id => CallId,
    from_tag => FromTag,
    sdp => CallerSdp,
    transport_protocol => <<"RTP/AVP">>,
    ice => remove,
    codec => #{transcode => ['PCMU']}
}),
ToMixer = chappe_rtpengine_ng:sdp(Reply),
{ok, Leg, #{ip := Ip, port := Port}} = chappe_mix:add_leg(Conf, #{}),
ok = chappe_mix:set_remote(Conf, Leg, rtpengine_endpoint(ToMixer)),
{ok, _} = chappe_rtpengine:answer(rtpe1, #{
    call_id => CallId,
    from_tag => FromTag,
    to_tag => <<"mixer">>,
    sdp => mixer_answer_sdp(Ip, Port)
}).
```

`rtpengine_endpoint/1` and `mixer_answer_sdp/2` stand for your own SDP
code.

## Join from a SIP call

From a chappe_sip service you do not write SDP: `chappe_sip_media` makes the
leg and its SDP, and keeps rooms by name. Configure the mixer once:

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:10.0.0.5:5060">>,
    media => #{mix => #{ip => {10, 0, 0, 5}}}
}).
```

Then join each call to a room from its INVITE handler:

```erlang
chappe_sip:invite(fun(Req, Res) ->
    {ok, S} = chappe_sip_media:session(
                #{call_id => chappe_sip_req:call_id(Req)},
                #{capability => conference}),
    {ok, Answer} = chappe_sip_media:conference(
                     S, <<"room-42">>, #{sdp => chappe_sip_req:body(Req)}),
    {ok, _Dialog} = chappe_sip:create_uas(Req, Res, #{local_sdp => Answer})
end).
```

To put rtpengine in front of the mixer for that call, anchor it with an
`anchor` session and give the mixer the offer rtpengine makes: the steps
are in the chappe_sip [media design](https://github.com/benoitc/chappe/blob/main/apps/chappe_sip/docs/design/media.md),
section "Put rtpengine in front of the mixer".

## Tap a party or the room

A tap hands you the decoded audio of one leg, or of the whole room, every
20 ms, with no RTP leg to set up: a recorder or a transcriber in Erlang.

```erlang
{ok, Tap} = chappe_mix:tap(Conf, Leg, #{}),
{ok, RoomTap} = chappe_mix:tap(Conf, room, #{to => Recorder}),
receive
    {chappe_mix, Conf, {tap, Tap, Pcm}} -> ok
end,
ok = chappe_mix:untap(Conf, Tap).
```

`Pcm` is 20 ms of 16-bit signed little-endian PCM at the room's rate: 320
bytes at 8 kHz, 640 at 16 kHz (`chappe_mix:taps/1` gives the rate). A party's
tap carries what the room takes from it (silence while it is muted or
sends nothing); the room's carries every talker. A tap's ref (its own
`ref`, else the leg's, else the room's) is in `chappe_mix:taps/1`.

- The tap ends when its process dies, at `untap/2`, or with
  `{tap_closed, Tap}` when its leg leaves (removed or moved) or the room
  stops.
- Past `max_queue` messages waiting at the process (500), a frame is
  dropped and counted in `chappe_mix:taps/1`; the room's clock never
  waits for a reader.
- To keep the audio, write it to the recording store
  ([Record a call](https://github.com/benoitc/chappe/blob/main/apps/chappe_audio/docs/guides/record.md)).

## Notes

- The mixer always sends 20 ms packets and takes any size up to 200 ms.
- The codec is per leg (`law`): a PCMU leg and a PCMA leg can share an
  8 kHz room. Every leg of a 16 kHz room is L16.
- RFC 4733 events are forwarded, never mixed, to legs that set `dtmf_pt`.
  They run on the room's clock: telephone-event/8000 in an 8 kHz room,
  telephone-event/16000 in a 16 kHz one.
- RTCP runs the same at both rates; the jitter of the reports counts
  timestamp units of the room's rate.
- Numbers for latency, capacity and cost are in
  [`test/audit/PERF.md`](https://github.com/benoitc/chappe/blob/main/apps/chappe_mix/test/audit/PERF.md).

## Where it lives

- Modules: `chappe_mix` (API), `chappe_mix_conf` (the room process); the
  chappe_sip side is `chappe_sip_media` and `chappe_sip_media_mix`
- Tests: `apps/chappe_mix/test/chappe_mix_SUITE.erl`,
  `chappe_mix_rfc_SUITE.erl`
- Lab: `make interop-mix` (behind a real rtpengine,
  `chappe_mix_live_SUITE`), `make interop-ref` (against mod_conference)
