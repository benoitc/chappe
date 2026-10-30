# Run a conference

A conference is a room where every participant hears every other one, never
themselves. This guide shows you how to run one with chappe_mix, first on
its own, then behind rtpengine and from a SIP call. Read it when you add
rooms, whispers or listen-only participants to a service.

## When to use it

- You want the room in your own Erlang node, with per-pair control over who
  hears whom.
- Your legs are G.711, or rtpengine can transcode them to G.711.
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

## Move a leg to another room

```erlang
{ok, Room2} = chappe_mix:start(#{ip => {10, 0, 0, 5}}),
{ok, NewId} = chappe_mix:move_leg(Conf, Alice, Room2).
```

The socket, its port and the far end move with the leg, so the participant
needs no new SDP. The leg's relations are dropped.

## Inspect and stop

```erlang
Legs = chappe_mix:legs(Conf),     %% per-leg state and counters
Stats = chappe_mix:stats(Conf),   %% ticks, overruns, lateness histogram
ok = chappe_mix:remove_leg(Conf, Bob),
ok = chappe_mix:stop(Conf).
```

Every leg gets an RTCP BYE when it is removed or the room stops.

## Put rtpengine in front

The mixer only takes G.711 over plain RTP/AVP. A WebRTC caller, an SRTP
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
are in the chappe_sip [media design](../../../chappe_sip/docs/design/media.md),
section "Put rtpengine in front of the mixer".

## Notes

- The mixer always sends 20 ms packets and takes any size up to 200 ms.
- The codec is per leg (`law`): a PCMU leg and a PCMA leg can share a room.
- RFC 4733 events are forwarded, never mixed, to legs that set `dtmf_pt`.
- Numbers for latency, capacity and cost are in
  [`test/audit/PERF.md`](../../test/audit/PERF.md).

## Where it lives

- Modules: `chappe_mix` (API), `chappe_mix_conf` (the room process); the
  chappe_sip side is `chappe_sip_media` and `chappe_sip_media_mix`
- Tests: `apps/chappe_mix/test/chappe_mix_SUITE.erl`,
  `chappe_mix_rfc_SUITE.erl`
- Lab: `make interop-mix` (behind a real rtpengine,
  `chappe_mix_live_SUITE`), `make interop-ref` (against mod_conference)
