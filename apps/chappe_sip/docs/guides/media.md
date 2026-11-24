# Put media under a call

`chappe_sip_media` drives the media engines for your calls: you ask for a
capability (anchor a call's media, tap it, duck a party, put it in a
conference) and it talks to rtpengine or chappe_mix for you. The SIP
processes never touch RTP. Read this when you need to put media under a call,
fork it to another consumer, or run a conference. Why the facade sits in
chappe_sip and how it routes capabilities is in the
[media design](../design/media.md).

## When to use it

- Your calls cross NAT or mix WebRTC and plain SIP, and rtpengine must relay
  the media.
- You record, tap or transcribe a call.
- You run a conference on chappe_mix, without a media server.

## Configure a backend

Media is off by default. Turn it on with a `media` map, either as the option to
`chappe_sip:start/1` or as the `media` application env of `chappe_sip`. The
option wins when both are set. Configure each backend you use:

```erlang
chappe_sip:start(#{
    contact => <<"sip:0.0.0.0:5060">>,
    media => #{
        rtpengine => #{nodes => [#{name => rtpe1, host => "127.0.0.1",
                                   port => 22222}]},
        mix => #{ip => {10, 0, 0, 5}}
    }
}).
```

The same in `sys.config`:

```
{chappe_sip, [
    {media, #{rtpengine => #{nodes => [#{name => rtpe1, host => "127.0.0.1",
                                         port => 22222}]},
              mix => #{ip => {10, 0, 0, 5}}}}
]}
```

Configuring a backend starts its library. Omit a backend and its library stays
dormant (nothing in it runs).

The `mix` keys:

| Key | Default | What it does |
|---|---|---|
| `ip` | `{127, 0, 0, 1}` | Address the mixer legs bind to. |
| `advertise` | `ip` | Address written in the leg SDP; set it when `ip` is `{0, 0, 0, 0}`. |
| `rate` | `8000` | Rate of a room a join creates without a `rate`: `8000` (G.711) or `16000` (L16, rtpengine 13.4 or later in front). |
| `law` | `ulaw` | Codec of a leg the mixer offers in an 8 kHz room (`ulaw` is PCMU, `alaw` PCMA). |
| `depth` | chappe_mix default | Jitter buffer depth in frames. |

## Which capability you can ask for

| Capability | Backend | Operations |
|---|---|---|
| `anchor`, `relay` | rtpengine | `offer`, `answer`, `publish` |
| `transcode` | rtpengine | needs a transcoding-enabled rtpengine |
| `subscribe` | rtpengine | `subscribe`, `subscribe_answer`, `unsubscribe` |
| `duck` | rtpengine | `duck`, `unduck` |
| `play`, `record`, `dtmf` | rtpengine | `play`, `record`, `dtmf` |
| `conference` | chappe_mix | `conference`, `leave`, `mute`, `unmute` |

An operation the session's backend does not have returns
`{error, {unsupported, Op}}`.

## Anchor a call's media (rtpengine)

Anchor the caller's media through rtpengine, forward the rewritten offer to the
callee, then feed the callee's answer back to the caller. Do this inside your
INVITE handler. You start one session per call, keyed by the caller's identity;
you supply the callee's tag when you answer.

```erlang
chappe_sip:invite(fun(Req, Res) ->
    %% one rtpengine session for the call, keyed by the caller
    {ok, S} = chappe_sip_media:session(
                #{call_id => chappe_sip_req:call_id(Req),
                  from_tag => chappe_sip_req:from_tag(Req)},
                #{capability => anchor}),

    %% anchor the caller's offer; send the rewritten SDP to the callee
    {ok, OfferB} = chappe_sip_media:offer(S, chappe_sip_req:body(Req)),
    {ok, DialogB} = chappe_sip:create_uac(<<"sip:bob@example.com">>,
                                    #{local_sdp => OfferB}),

    %% feed the callee's answer back, tagged with the callee leg
    {ok, AnswerA} = chappe_sip_media:answer(
                      S, chappe_sip_dialog:remote_sdp(DialogB),
                      #{to_tag => chappe_sip_dialog:remote_tag(DialogB)}),
    {ok, _DialogA} = chappe_sip:create_uas(Req, Res, #{local_sdp => AnswerA})
end).
```

You can pass a dialog handle to `session/2` instead of the identity map once the
dialog exists; it reads out the Call-ID and tags for you. Use the explicit map
when you anchor before the dialog is created, as above.

Play a prompt, record the call, or send DTMF against the same session:

```erlang
ok = chappe_sip_media:play(S, #{file => <<"/var/prompts/hello.wav">>}),
ok = chappe_sip_media:record(S, #{}),
ok = chappe_sip_media:dtmf(S, #{code => 1, duration => 250}).
```

## Tap a call to an external consumer (rtpengine)

Fork one party's media to another listener, for example an STT receiver. Call
`subscribe/2`: you get back an SDP offer for the tapped streams and a to-tag that
names the subscription. Answer it with the consumer's listening address, and
remove it with the same to-tag when you are done. The fork defaults to PCMU so
your receiver needs no codec logic (a transcoded fork needs an rtpengine built
with transcoding support; without it the rtpengine error is returned to you).

```erlang
%% tap the caller's media
{ok, #{sdp := TapOffer, to_tag := SubTag}} =
    chappe_sip_media:subscribe(S, #{party => caller}),

%% point the fork at your consumer (its listening SDP)
ok = chappe_sip_media:subscribe_answer(S, #{to_tag => SubTag, sdp => ConsumerSdp}),

%% stop the tap
ok = chappe_sip_media:unsubscribe(S, #{to_tag => SubTag}).
```

Use `party => caller | callee` to tap one leg, or omit `party` to tap the whole
call.

## Anchor a recording (SIPREC) call (rtpengine)

A recording server is a call with one leg. The recorder sends you an INVITE whose
`multipart/mixed` body is an SDP offer with one sendonly `m=audio` per recorded
party (each with an `a=label`) plus an `application/rs-metadata+xml` part. You
receive every stream and fork each one out; you never bridge an onward leg, so
there is no `answer/2` to make and no UAC to originate.

Use `publish/2` for that anchor: the media engine answers the offer itself and
gives you the SDP for your 200 OK. `chappe_sip_req:body/1` hands you the multipart
untouched, so split it and pass the SDP part in.

```erlang
chappe_sip:invite(fun(Req, Res) ->
    {ok, S} = chappe_sip_media:session(
                #{call_id => chappe_sip_req:call_id(Req),
                  from_tag => chappe_sip_req:from_tag(Req)},
                #{capability => anchor}),

    %% the recorder's N sendonly streams, answered by rtpengine itself
    {ok, AnswerSdp} = chappe_sip_media:publish(S, SrcOfferSdp),
    {ok, _Dialog} = chappe_sip:create_uas(Req, Res, #{local_sdp => AnswerSdp})
end).
```

Then fork each recorded party to its own receiver. One subscription per stream,
each answered with only that stream live: `subscribe/2` reports the offered
streams in m-line order with their labels, and
`chappe_rtpengine_sdp:fork_answer/3` builds the aligned answer.

```erlang
{ok, #{sdp := TapOffer, to_tag := SubTag, streams := Streams}} =
    chappe_sip_media:subscribe(S, #{party => caller, ptime => 20}),
#{label := Label} = hd(Streams),
{ok, Answer} = chappe_rtpengine_sdp:fork_answer(
                 TapOffer, {label, Label},
                 #{address => <<"198.51.100.7">>, port => 40000, ptime => 20}),
ok = chappe_sip_media:subscribe_answer(S, #{to_tag => SubTag, sdp => Answer,
                                            flags => [allow_transcoding]}).
```

Each receiver gets its own PCMU flow at its own ip:port, so a transcriber runs per
participant. rtpengine has no request-side selector for one media stream of a
participant: the answer decides, which is why the selection lives there. See the
`chappe_rtpengine` subscriptions guide for the wire-level detail and for feeding
several receivers from a single subscription.

To record a call to a recording server, use `chappe_sip_siprec:start/3`
([Record a call with SIPREC](siprec.md)); to write the streams of an
incoming recording to the store, `chappe_sip_siprec_srs:serve/3`. To build
the SIPREC INVITE yourself, `create_uac/2` takes
`body` plus `content_type` instead of `local_sdp`, so you can send the
`multipart/mixed` yourself; the peer's answer is on the dialog
(`chappe_sip_dialog:remote_sdp/1`).

## Duck a party while a prompt plays (rtpengine)

Block or silence one party's media, play into the call, then restore it. `duck/2`
blocks by default (`mode => silence` mutes but keeps packets flowing); `unduck/2`
reverses whichever you used.

```erlang
ok = chappe_sip_media:duck(S, #{party => caller}),
ok = chappe_sip_media:play(S, #{file => <<"/var/prompts/hold.wav">>}),
ok = chappe_sip_media:unduck(S, #{party => caller}).
```

`party` picks the leg (omit for the whole call) and is resolved against the tags
rtpengine stored when you ran offer/answer, so duck after you have anchored the
call.


## Run a conference (chappe_mix)

A room is one chappe_mix conference. Each call that joins gets its own mixer
leg (a UDP socket in that conference) and hears every other unmuted leg, never
itself. Start a conference session, then join it to a room with the call's
offer; the mixer answers it, and that answer goes in your 200 OK:

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

The answer carries one G.711 codec (the first PCMU or PCMA in the offer),
`a=ptime:20` and `a=sendrecv`. The offer's `a=ptime` reaches the leg (the
mixer takes packets of any size up to 200 ms); an `a=maxptime` under 20 is
refused with `{error, {maxptime, Ms}}`, since the mixer sends 20 ms. An offer
with `telephone-event/8000` is answered with it on the offer's payload type
and `a=fmtp:<pt> 0-16`; the leg then forwards RFC 4733 events to and from
the room, sending the far end only the events its fmtp lists (0 to 15
without one). The mixer's own offer carries `telephone-event/8000` on 101,
and an answer that keeps it turns forwarding on for the leg. A media-level
`a=rtcp:<port> [IN IP4 <addr>]` (RFC 3605) in an offer or an answer sends the
leg's RTCP there; it is ignored at session level and with `a=rtcp-mux`. It keeps `a=rtcp-mux` when the offer has it;
without it, RTCP goes on the next port up. Other m-lines (video) are rejected
with port 0.

When you place the call yourself, join without `sdp`: the mixer offers (one
codec, `law` from the config or the `law` option, RTCP muxed). Feed the
callee's answer back so the leg knows where to send:

```erlang
{ok, S} = chappe_sip_media:session(#{call_id => CallId},
                                   #{capability => conference}),
{ok, Offer} = chappe_sip_media:conference(S, <<"room-42">>, #{}),
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@example.com">>,
                                     #{local_sdp => Offer}),
ok = chappe_sip_media:set_remote(S, chappe_sip_dialog:remote_sdp(Dialog)).
```

`set_remote/2` also takes `{Ip, Port}` when you know the address another way.

Act on the leg while the call lasts:

```erlang
ok = chappe_sip_media:mute(S),    %% hears the room, is not mixed into it
ok = chappe_sip_media:unmute(S),
ok = chappe_sip_media:leave(S).   %% out of the room; the room stops with its last leg
```

`chappe_sip_media:info/1` reports the room, the leg, its codec, its local
address and whether it is muted.

Join options:

| Option | What it does |
|---|---|
| `room` | Room name (in the map for `conference/2`, apart for `conference/3`). |
| `sdp` | The call's offer. The mixer answers it; without it the mixer offers. |
| `owner` | Owner of the room, when this join creates it. Default: the joining call's process. |
| `rate` | `8000` or `16000`: the rate of a room this join creates (default the configured one). A join asking another rate than a running room's gets `{error, {rate_mismatch, RoomRate}}`; one without a `rate` takes the room's. |
| `law` | `ulaw` or `alaw` for a leg the mixer offers in an 8 kHz room. |
| `mute` | Join muted. |
| `name` | SDES NAME the other legs see for this leg's source. |

## Put rtpengine in front of the mixer

The mixer speaks G.711 over plain RTP/AVP only. A WebRTC caller (DTLS-SRTP,
opus) or any call with another codec reaches it through rtpengine: rtpengine
answers the caller and offers toward the mixer leg, transcoding to G.711 and
terminating SRTP/DTLS on the way.

```erlang
chappe_sip:invite(fun(Req, Res) ->
    CallId = chappe_sip_req:call_id(Req),
    {ok, Anchor} = chappe_sip_media:session(
                     #{call_id => CallId,
                       from_tag => chappe_sip_req:from_tag(Req)},
                     #{capability => anchor}),
    %% rtpengine's offer toward the mixer leg: plain RTP, PCMU added
    {ok, ToMixer} = chappe_sip_media:offer(
                      Anchor, chappe_sip_req:body(Req),
                      #{params => #{codec => #{transcode => ['PCMU']},
                                    transport_protocol => <<"RTP/AVP">>,
                                    ice => remove}}),
    {ok, Conf} = chappe_sip_media:session(#{call_id => CallId},
                                          #{capability => conference}),
    {ok, MixAnswer} = chappe_sip_media:conference(
                        Conf, <<"room-42">>, #{sdp => ToMixer}),
    %% rtpengine's answer toward the caller goes in the 200 OK
    {ok, ToCaller} = chappe_sip_media:answer(
                       Anchor, MixAnswer, #{to_tag => <<"mixer">>}),
    {ok, _Dialog} = chappe_sip:create_uas(Req, Res, #{local_sdp => ToCaller})
end).
```

Both sessions are bound to the call process, so a BYE (or the process exiting)
tears down the rtpengine call and takes the leg out of the room.

### An HD (16 kHz) room

For callers on G.722 or Opus, make the room at 16 kHz and let rtpengine
(13.4 or later, the first with L16) transcode each caller to L16/16000 and
back. `chappe_sip_media:mixer_params/2` gives the flags for each side:
`mixer` for a caller's offer on its way to the mixer, `endpoint` for the
mixer's offer on its way to an endpoint.

```erlang
Params = maps:merge(chappe_sip_media:mixer_params(16000, mixer),
                    #{transport_protocol => <<"RTP/AVP">>, ice => remove}),
{ok, ToMixer} = chappe_sip_media:offer(Anchor, chappe_sip_req:body(Req),
                                       #{params => Params}),
{ok, MixAnswer} = chappe_sip_media:conference(
                    Conf, <<"room-hd">>, #{sdp => ToMixer, rate => 16000}).
```

The mixer answers with `L16/16000` on rtpengine's payload type and
`telephone-event/16000`; the caller keeps its own codec. `mixer_params/2`
is `#{}` at 8000.

## Conference limits

- G.711 (PCMU, PCMA) in an 8 kHz room, L16/16000 in a 16 kHz room. The
  mixer takes packets of 10, 30 or any other number of ms up to 200 and
  sends 20 ms ones; put rtpengine in front for anything else.
- A room's rate is fixed by the join that creates it. A PCMU offer to a
  16 kHz room is refused with `{error, no_common_codec}`; a SIPREC
  recording of a 16 kHz room with `{error, {unsupported, {rate, 16000}}}`.
- One codec per leg, fixed when the leg opens. An answer in another law is
  refused with `{error, {law_mismatch, Law}}`.
- A leg's direction follows SDP: an offer that only sends (`a=sendonly`, at
  media or session level) gets `a=recvonly` back and a leg the room only
  takes from; `a=recvonly` gets `a=sendonly`; `a=inactive` gets
  `a=inactive`. The `direction` join option narrows it (or sets the
  mixer's own offer), and an answer to the mixer's offer can narrow it
  too. `mute/1` and `deaf/1` (with `unmute/1`, `undeaf/1`) take the
  mixing and the sending away on top of that without new SDP, and
  `relate/3` keeps one leg from hearing another of the same room.
- A join with `talk_events => true` makes the calling process get
  `{chappe_sip_media, {talking, Room, true | false}}` when its party starts
  (60 ms over -40 dBFS) or stops (300 ms under it) talking.
- One leg per session; a second join returns `{error, already_joined}`.
- A room lives on one node.

## Dialog handles and tags

`session/2` takes a dialog handle as well as an identity map. It reads the
Call-ID and the tags and maps them by role, the way rtpengine expects: the
dialog's From tag becomes `from_tag`. On a UAS dialog that is the peer's tag,
on a UAC dialog it is ours. The role comes from the dialog index; pass
`role => uas | uac` in the options for a dialog that is not confirmed yet (it
is taken as UAS otherwise).

## Override the default backend

Override it for one session with `backend => rtpengine | mix` in the session
options, or for every session with `capabilities => #{Capability => Backend}`
in the media config.

## Notes

- A session is bound to the process that created it. When that process
  exits, an rtpengine session is deleted and a conference leg leaves its
  room. Tear one down early with `chappe_sip_media:stop/1`.
- A room joined with `persist => true` stays up with no leg until its owner
  exits, and `talk_tag` names a leg in its talker events, so one process can
  own a room and all its legs (chappe_mrf's native conferences do this).
- For a B2BUA, prefer `media => anchor` on `create_b2bua/4` over driving the
  session yourself; see [Handle re-INVITE in a B2BUA](b2bua-reinvite.md).
- To run IVRs and conferences on FreeSWITCH instead, see chappe_mrf
  (`apps/chappe_mrf/README.md`).

## Where it lives

- Modules: `chappe_sip_media` (the facade), `chappe_sip_media_rtpengine` and
  `chappe_sip_media_mix` (backend adapters), `chappe_sip_media_mix_sdp`,
  `chappe_sip_media_sup`; the engines are driven by `chappe_rtpengine` and
  `chappe_mix`.
- Tests: `chappe_sip_media_SUITE` (an in-suite NG fake, real chappe_mix
  rooms; the `rtpengine_live` group with `RTPENGINE_HOST` and
  `RTPENGINE_MEDIA_IP`), `chappe_sip_proxy_media_SUITE`.
- Design: [Media design](../design/media.md).
- Lab: `make interop` and `make interop-mix`.
