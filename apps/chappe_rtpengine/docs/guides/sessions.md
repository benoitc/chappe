# Media sessions

This guide covers `chappe_rtpengine_session`, the per-call state machine. You need it whenever your application handles calls rather than raw commands: a session selects and pins a node, tracks the call's tags, survives re-INVITEs and forking, and guarantees the rtpengine session is deleted when the call ends, however it ends.

## Start a session and negotiate

The calling process becomes the owner. The session monitors it: if it dies, the rtpengine session is deleted.

```erlang
{ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId}),

{ok, OfferReply} = chappe_rtpengine_session:offer(Sess, #{from_tag => FromTag, sdp => CallerSDP}),
SDPForCallee = chappe_rtpengine_ng:sdp(OfferReply),

{ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{to_tag => ToTag, sdp => CalleeSDP}),
SDPForCaller = chappe_rtpengine_ng:sdp(AnswerReply),

{ok, Stats} = chappe_rtpengine_session:query(Sess),
ok = chappe_rtpengine_session:stop(Sess).
```

Pass `node => Name` in the start options to bypass pool selection. NG flags (`ice`, `transport_protocol`, `flags`, ...) go in the offer and answer params unchanged.

## Re-INVITE and hold

Offer again from an established session. The stored tags are reused; a callee-initiated re-INVITE swaps the tag direction on the wire, which is what rtpengine requires:

```erlang
%% caller re-INVITEs (hold, codec change, ...)
{ok, Reply} = chappe_rtpengine_session:offer(Sess, #{sdp => NewCallerSDP}),

%% callee re-INVITEs
{ok, Reply2} = chappe_rtpengine_session:offer(Sess, #{sdp => NewCalleeSDP, initiator => callee}).
```

Any offer while an offer/answer exchange is open (the first offer, a re-INVITE, or a publish still waiting for its reply or its answer) returns `{error, glare}` immediately. SIP owns glare resolution (491 and offset retry timers); resolve it in signalling and offer again.

If the peer rejects the re-INVITE (488 or any other final error), roll the session back to `established` with the tags it had:

```erlang
{ok, _} = chappe_rtpengine_session:offer(Sess, #{sdp => NewCallerSDP}),
%% the callee answered 488
ok = chappe_rtpengine_session:reoffer_rejected(Sess).
```

`reoffer_rejected/1` returns `{error, no_reoffer}` outside a re-INVITE (an initial offer that fails ends the call: stop the session). A failed answer to a re-INVITE leaves the session in `offered` with its to-tag unchanged, so you can answer again or roll back.

Hold itself is an SDP concern (`a=sendonly` in the re-INVITE offer); your SIP stack rewrites the SDP, the session just relays it.

## Forked calls

Answer once per branch with its to-tag; mark the winner and the session deletes the losing branches on rtpengine:

```erlang
{ok, _} = chappe_rtpengine_session:answer(Sess, #{to_tag => Branch1Tag, sdp => SDP1}),
{ok, _} = chappe_rtpengine_session:answer(Sess, #{to_tag => Branch2Tag, sdp => SDP2}),
%% branch 2 sent the 200
{ok, _} = chappe_rtpengine_session:answer(Sess, #{to_tag => Branch2Tag, sdp => SDP2, final => true}).
```

Repeated answers with the same to-tag (183 early media then 200) need no special handling; just answer again.

## Owner notifications

Your process receives `{chappe_rtpengine_session, Pid, Event}` messages:

```erlang
receive
    {chappe_rtpengine_session, Sess, {node_down, Node}} ->
        %% the pinned node stopped answering
        ...;
    {chappe_rtpengine_session, Sess, {node_restarted, Node}} ->
        %% the node came back restarted, or replied "unknown call-id":
        %% the media session on it is gone. Re-offer through a new
        %% negotiation, or tear the call down.
        ...;
    {chappe_rtpengine_session, Sess, {dtmf, Event}} ->
        %% see the media features guide
        ...
end.
```

The library never re-offers on its own; the decision and the new SDP belong to signalling.

## Cleanup guarantees

- `stop/1` deletes the rtpengine session and stops the process. It works with a request in flight: that request's caller gets `{error, stopped}` and `stop/1` still returns `ok` once the delete is answered.
- Owner death triggers the same delete, also with a request in flight.
- Any other exit path (crash, supervisor shutdown) makes a best-effort synchronous delete in `terminate/3`.
- The node pin is always released.
