# Media integration (chappe_sip_media)

`chappe_sip_media` is the media control-plane facade. You ask for a capability (anchor
a call's media, tap it, duck a party, run a conference) and it drives the right
external engine for you: rtpengine anchors and relays RTP and rewrites SDP;
FreeSWITCH (over ESL) terminates a media leg for conferencing, IVR, and
recording. The RTP stays in those daemons; only the control plane runs in the
BEAM. Reach for this page when you need to put media under a call, fork it to
another consumer, or add a backend.

## Configure a backend

Media is off by default. Turn it on by passing a `media` map to `chappe_sip:start/1`
(or by setting the `media` application env). List the nodes for each backend you
use:

```erlang
chappe_sip:start(#{
    contact => <<"sip:0.0.0.0:5060">>,
    media => #{
        rtpengine => #{nodes => [#{name => rtpe1, host => "127.0.0.1",
                                   port => 22222}]},
        freeswitch => #{nodes => [#{name => fs1, host => "127.0.0.1",
                                    port => 8021, password => <<"ClueCon">>}]}
    }
}).
```

Configuring a backend starts its library and registers the nodes. Omit a backend
and its library stays dormant (nothing in it runs).

## Which backend does what

The two engines do different shapes of media work, so each capability has a
natural home:

- **rtpengine anchors packets.** It takes SDP in, gives SDP out, and relays or
  rewrites the RTP with no SIP leg of its own. Reach for it to put media under a
  call, hide topology, fork a stream, or duck a party.
- **FreeSWITCH terminates a leg.** You originate a SIP leg into it and drive the
  channel over ESL, so it can mix, prompt, and run menus. Reach for it when you
  need a conference or an IVR, not just anchoring.

| Capability | Backend | What you get |
|---|---|---|
| `anchor`, `relay` | rtpengine | anchor or relay the call's RTP and rewrite SDP (`offer`/`answer`) |
| `transcode` | rtpengine | codec transcoding (needs a transcoding-enabled rtpengine) |
| `subscribe` | rtpengine | fork a party's media to another consumer (a tap) |
| `duck` | rtpengine | block or silence a party while a prompt plays |
| `conference` | FreeSWITCH | multi-party mixing in a room |
| `ivr` | FreeSWITCH | menus and prompts on a channel |
| `play`, `record`, `dtmf` | either (rtpengine by default) | play a file, record, send DTMF; both engines implement these |

- **rtpengine only:** `offer`/`answer`/`publish`, `relay`, `transcode`,
  `subscribe`, `duck`. On FreeSWITCH these return `{error, unsupported}` or
  `{error, {unsupported, _}}` (subscribe/duck): that backend has no SDP for you
  to rewrite and no anchored RTP to tap.
- **FreeSWITCH only:** `conference` and `ivr`, which need a mixing bridge
  rtpengine does not provide.
- **Either engine:** `play`, `record`, `dtmf`. The default routes them to
  rtpengine; pass `backend => freeswitch` on a session to run them on a
  FreeSWITCH channel instead.

The rest of this page shows each capability in use, grouped by backend.

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

To originate a SIPREC INVITE rather than receive one, `create_uac/2` takes
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

## Run a conference (FreeSWITCH)

FreeSWITCH terminates a media leg over SIP, so media does not flow through
chappe_sip here. Originate a UAC leg to FreeSWITCH, bridge your inbound
dialog to it, and drive the resulting channel over ESL. A session pairs a
FreeSWITCH node with that channel's UUID (the leg you originated toward
FreeSWITCH), so pass both:

```erlang
{ok, S} = chappe_sip_media:session(
            #{call_id => chappe_sip_req:call_id(Req)},
            #{capability => conference, node => fs1, uuid => ChannelUuid}),
ok = chappe_sip_media:conference(S, <<"room-42">>, #{}),
ok = chappe_sip_media:play(S, #{file => <<"/var/prompts/joined.wav">>}).
```

On this backend `offer/2` and `answer/2` return `{error, unsupported}`: the SDP
rides the real SIP leg, so there is nothing for you to rewrite. `subscribe`,
`duck`, and their variants return `{error, {unsupported, _}}` too (they operate
on anchored RTP, which is an rtpengine job).

## Session lifetime

A session is bound to the process that created it (your call handler). When that
process exits, the backend session is torn down for you: an rtpengine session is
owned directly by the caller and deleted on its exit; the ESL control
connections are pooled per node under `chappe_sip_media_sup` and reconnect on failure.
You do not clean up on the normal BYE path, but you can tear a session down early
with `chappe_sip_media:stop/1`.

## Override the default routing

Each capability has a default backend (see Which backend does what). Override the
choice for one session with `backend => rtpengine | freeswitch` in the session
options, or change the default map globally with a
`capabilities => #{Capability => Backend}` entry in the media config.

To add a backend, write an adapter module exposing the operation set (`start/2`,
`offer/4`, `answer/4`, `publish/4`, `play/2`, `record/2`, `stop_record/1`, `dtmf/2`,
`conference/3`, `subscribe/3`, `subscribe_answer/2`, `unsubscribe/2`, `duck/2`,
`unduck/2`, `stop/1`, `info/1`, `configure/1`) and dispatch to it from
`chappe_sip_media`. Return `{error, {unsupported, Capability}}` for anything the
backend does not provide.

## Why this lives in chappe_sip

The two engines are driven by SIP-free leaf libraries kept as dependencies:
`chappe_rtpengine` speaks the rtpengine NG protocol, `chappe_esl` speaks the
FreeSWITCH Event Socket. Neither touches SIP. `chappe_sip_media` does the opposite: it
binds media to SIP, reading dialog identity, originating legs, and tying session
lifetime to the call process. That coupling is why it belongs here rather than in
a third leaf library. No non-SIP consumer drives media today, so there is no
`signaling` behaviour and no separate media app: the media facade is the in-repo
`chappe_sip_media` module. Because the facade is a
clean module boundary, extracting it later (behind a `signaling` behaviour that
chappe_sip implements) stays cheap if one ever appears.

## Testing

The fast run drives the facade against in-suite fakes that speak each wire
protocol (`test/chappe_sip_media_SUITE` for rtpengine, `test/chappe_sip_media_fs_SUITE` for
ESL). Live coverage runs against real engines: rtpengine over the
`chappe_rtpengine` interop harness, and FreeSWITCH under the INTEROP-gated
`chappe_sip_media_fs_e2e_SUITE` (see `interop/README.md`).
