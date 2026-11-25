# Media subscriptions

This guide covers tapping a call's media with rtpengine's subscription model. You need it for recording taps, supervisor listen-in, multi-stream recording (SIPREC), and building conference media graphs. Subscriptions require an rtpengine built with transcoding support.

## Tap a call

Request a subscription: rtpengine returns an SDP offer describing the tapped streams and a to-tag naming the subscription. Answer it with the consumer's SDP:

```erlang
{ok, Sub} = chappe_rtpengine_cmd:subscribe_request(Sess, #{flags => [all]}),
SubTag = maps:get(<<"to-tag">>, Sub),
OfferedSDP = chappe_rtpengine_ng:sdp(Sub),

%% hand OfferedSDP to the consumer (a recorder, another call leg),
%% get its answer SDP back
{ok, _} = chappe_rtpengine_cmd:subscribe_answer(Sess, #{to_tag => SubTag, sdp => ConsumerSDP}),

%% when done
{ok, _} = chappe_rtpengine_cmd:unsubscribe(Sess, #{to_tag => SubTag}).
```

Pass `party => caller | callee` (or `from_tags => [Tag]`) instead of `flags => [all]` to tap a single participant.

Pass `holder => pid()` to make the subscription that process's: the session monitors it and unsubscribes when it exits, however it exits, so a consumer that crashes leaves no fork running. `unsubscribe/2` of the to-tag still releases it early:

```erlang
{ok, Sub} = chappe_rtpengine_cmd:subscribe_request(Sess, #{party => caller, holder => Recorder}).
```

## Anchor a call with no second leg

A recording server or a publisher has nothing to negotiate with: it receives media and forks it, it never bridges an onward leg. Use `publish/2` instead of `offer/2` plus `answer/2`. rtpengine writes the answer itself, and the reply SDP is what you put in your 200 OK:

```erlang
{ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId}),
{ok, Reply} = chappe_rtpengine_session:publish(Sess, #{
    from_tag => SrcTag,
    sdp => InboundOffer,   % N sendonly m=audio lines
    ice => remove
}),
AnswerSDP = chappe_rtpengine_ng:sdp(Reply).
```

Every m-line of the offer comes back answered (`recvonly`, at rtpengine's own addresses) and the session goes straight to `established`. Subscriptions work from there as usual. Without a session, the same command is `chappe_rtpengine:publish(Node, #{call_id => CallId, from_tag => SrcTag, sdp => InboundOffer})`.

## Fork each stream to its own receiver

A participant can carry several media streams: a SIPREC recording offer is one dialog and one from-tag with one sendonly `m=audio` per recorded party, each carrying an `a=label`. A subscription always covers *all* of the tapped participant's streams, in m-line order, because rtpengine has no request-side selector for a single one. The selection is in the answer: an m-line answered with a port receives that stream, an m-line answered with port 0 is rejected.

So to send each recorded party to its own receiver, subscribe once per stream and answer each subscription with only that stream live. `chappe_rtpengine_sdp` builds those answers; `streams/1` gives you the offer's m-line order and labels:

```erlang
{ok, Sub} = chappe_rtpengine_cmd:subscribe_request(Sess, #{
    from_tags => [SrcTag],
    codec => #{mask => [all], transcode => ['PCMU']},
    ptime => 20
}),
SubTag = maps:get(<<"to-tag">>, Sub),
OfferSDP = chappe_rtpengine_ng:sdp(Sub),
[#{index := 0, label := <<"1">>} | _] = chappe_rtpengine_sdp:streams(OfferSDP),

%% this subscription carries label 1 to one receiver, nothing else
{ok, Answer} = chappe_rtpengine_sdp:fork_answer(OfferSDP, {label, <<"1">>},
                                                #{address => <<"198.51.100.7">>,
                                                  port => 40000,
                                                  ptime => 20}),
{ok, _} = chappe_rtpengine_cmd:subscribe_answer(Sess, #{
    to_tag => SubTag, sdp => Answer, flags => [allow_transcoding]
}).
```

Repeat that for `{label, <<"2">>}` and `{label, <<"3">>}` and you have three subscriptions, each a PCMU stream at 20 ms landing at its own receiver ip:port. Select by position instead with `{index, N}` (0-based, m-line order).

The `siprec` flag on the request relabels the streams zero-based, in m-line order: on rtpengine 26.3 a three-stream tap comes back with `labels` of `["0"]`, `["1"]`, `["2"]` and the source labels are gone. Older daemons (11.5) keep the source label and add the zero-based one beside it (`["1","0"]`, `["2","1"]`, `["3","2"]`), so `{label, <<"1">>}` matches two streams and the earlier m-line wins. Use `{index, N}` when you want the position rather than the name: it means the same on both.

One subscription can also feed several receivers, which costs the daemon three times fewer ports for the same three flows. Pass the routes as a list:

```erlang
{ok, Answer} = chappe_rtpengine_sdp:fork_answer(OfferSDP, [
    {{label, <<"1">>}, #{address => <<"198.51.100.7">>, port => 40000}},
    {{label, <<"2">>}, #{address => <<"198.51.100.8">>, port => 40000}},
    {{label, <<"3">>}, #{address => <<"198.51.100.9">>, port => 40000}}
]).
```

Notes:

- `chappe_rtpengine_sdp` is the one place this library looks inside SDP, and it is opt-in: build the answer yourself if you prefer. The rule it encodes is that the answer stays aligned with the offer, one m-line per offered stream, in order.
- Unknown keys on a subscribe request are ignored by rtpengine, so a made-up selector fails silently by tapping everything. Check what you got with `streams/1`.
- An IPv6 receiver address (`<<"2001:db8::7">>`) gets `IN IP6` in the answer's `o=` and `c=` lines; each accepted m-line carries its own receiver's address family.
- `fork_answer` returns an error instead of an answer when a selector does not name a stream (`{no_such_stream, Sel}`), names one twice (`{duplicate_stream, Sel}`), names an m-line the offer already rejected with port 0 (`{rejected_stream, Sel}`), or is not `{label, L}` or `{index, N}` (`{bad_selector, Sel}`).

## An STT feed

For live transcription, fork one party's media to an RTP receiver in a known plain codec so decoding stays trivial. Mask the source codecs and transcode to PCMU with a fixed ptime, and answer with the receiver's address. The `allow_transcoding` flag on the answer lets the receiver accept fewer codecs than the source party uses:

```erlang
{ok, Sub} = chappe_rtpengine_cmd:subscribe_request(Sess, #{
    party => caller,
    codec => #{mask => [all], transcode => ['PCMU']},
    ptime => 20
}),
SubTag = maps:get(<<"to-tag">>, Sub),
{ok, _} = chappe_rtpengine_cmd:subscribe_answer(Sess, #{
    to_tag => SubTag,
    sdp => ReceiverSDP,   % PCMU-only, recvonly, the receiver's ip:port
    flags => [allow_transcoding]
}).
```

The receiver then gets clean 20 ms PCMU frames for the caller's speech, one subscription per party. The session does not write SDP: the receiver's answer comes from your media receiver (or from `chappe_rtpengine_sdp:fork_answer/2,3` when you route streams as shown above).

## Conference graphs

A conference is a set of calls on one rtpengine node plus subscriptions between them: each participant's session subscribes to the media of the others (SFU style, the endpoints mix). Build it by iterating `subscribe_request`/`subscribe_answer` over the participant pairs, and `unsubscribe` when someone leaves.

Notes:

- No from-tag is injected automatically on subscription commands. On every other session command the stored from-tag identifies the call; here it selects which participant to tap, so the default is yours to choose.
- Without a session, the same commands work on a node: `chappe_rtpengine:cmd(Node, subscribe_request, #{call_id => CallId, flags => [all]})`.
- rtpengine has no built-in audio mixer for live conferencing. For mixed conferences, put a mixer behind it: chappe_mix in the umbrella (see its [conference guide](https://github.com/benoitc/chappe/blob/main/apps/chappe_mix/docs/guides/conference.md)), or a media server such as FreeSWITCH.

## Where it lives

- Modules: `chappe_rtpengine_cmd` (`subscribe_request/2`, `subscribe_answer/2`, `unsubscribe/2`), `chappe_rtpengine_sdp` (fork answers)
- Tests: `apps/chappe_rtpengine/test/chappe_rtpengine_sdp_tests.erl`, `chappe_rtpengine_session_SUITE.erl`
- Lab: `make interop` (`chappe_rtpengine_siprec_SUITE`, `chappe_rtpengine_live_SUITE`)
