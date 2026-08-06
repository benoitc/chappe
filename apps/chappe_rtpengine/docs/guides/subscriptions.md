# Media subscriptions

This guide covers tapping a call's media with rtpengine's subscription model. You need it for recording taps, supervisor listen-in, and building conference media graphs. Subscriptions require an rtpengine built with transcoding support.

## Tap a call

Request a subscription: rtpengine returns an SDP offer describing the tapped streams and a to-tag naming the subscription. Answer it with the consumer's SDP:

```erlang
{ok, Sub} = chappe_rtpengine_session:subscribe_request(Sess, #{flags => [all]}),
SubTag = maps:get(<<"to-tag">>, Sub),
OfferedSDP = chappe_rtpengine_ng:sdp(Sub),

%% hand OfferedSDP to the consumer (a recorder, another call leg),
%% get its answer SDP back
{ok, _} = chappe_rtpengine_session:subscribe_answer(Sess, #{to_tag => SubTag, sdp => ConsumerSDP}),

%% when done
{ok, _} = chappe_rtpengine_session:unsubscribe(Sess, #{to_tag => SubTag}).
```

Pass `party => caller | callee` (or `from_tags => [Tag]`) instead of `flags => [all]` to tap a single participant.

## An STT feed

For live transcription, fork one party's media to an RTP receiver in a known plain codec so decoding stays trivial. Mask the source codecs and transcode to PCMU with a fixed ptime, and answer with the receiver's address. The `allow_transcoding` flag on the answer lets the receiver accept fewer codecs than the source party uses:

```erlang
{ok, Sub} = chappe_rtpengine_session:subscribe_request(Sess, #{
    party => caller,
    codec => #{mask => [all], transcode => ['PCMU']},
    ptime => 20
}),
SubTag = maps:get(<<"to-tag">>, Sub),
{ok, _} = chappe_rtpengine_session:subscribe_answer(Sess, #{
    to_tag => SubTag,
    sdp => ReceiverSDP,   % PCMU-only, recvonly, the receiver's ip:port
    flags => [allow_transcoding]
}).
```

The receiver then gets clean 20 ms PCMU frames for the caller's speech, one subscription per party. The library keeps SDP opaque: the receiver's answer SDP comes from your media receiver, not from here.

## Conference graphs

A conference is a set of calls on one rtpengine node plus subscriptions between them: each participant's session subscribes to the media of the others (SFU style, the endpoints mix). Build it by iterating `subscribe_request`/`subscribe_answer` over the participant pairs, and `unsubscribe` when someone leaves.

Notes:

- No from-tag is injected automatically on subscription commands. On every other session command the stored from-tag identifies the call; here it selects which participant to tap, so the default is yours to choose.
- Without a session, the same commands work on a node: `chappe_rtpengine:cmd(Node, subscribe_request, #{call_id => CallId, flags => [all]})`.
- rtpengine has no built-in audio mixer for live conferencing. For large mixed conferences, put a dedicated media server behind the B2BUA as a SIP endpoint.
