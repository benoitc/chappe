# Getting started

This guide takes you from an empty project to relaying a call's media through rtpengine. You need it the first time you use chappe_rtpengine, or when setting up a development environment.

## Add the dependency

```erlang
%% rebar.config
{deps, [
    {chappe_rtpengine, {git, "https://github.com/benoitc/chappe_rtpengine.git", {branch, "main"}}}
]}.
```

Add `chappe_rtpengine` to your application's `applications` list so it boots with your release.

## Run an rtpengine for development

```sh
docker run -d --name rtpe -p 12222:12222/udp drachtio/rtpengine:latest \
    rtpengine --interface=127.0.0.1 --listen-ng=0.0.0.0:12222 \
    --foreground --log-stderr
```

## Connect and ping

```erlang
{ok, _} = application:ensure_all_started(chappe_rtpengine),
ok = chappe_rtpengine:add_node(rtpe1, #{host => "127.0.0.1", port => 12222}),
{ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(rtpe1).
```

## Anchor a call

Send the caller's SDP as an offer, give the rewritten SDP to the callee, then send the callee's SDP as the answer:

```erlang
{ok, OfferReply} = chappe_rtpengine:offer(rtpe1, #{
    call_id => CallId,
    from_tag => FromTag,
    sdp => CallerSDP
}),
SDPForCallee = chappe_rtpengine_ng:sdp(OfferReply),

{ok, AnswerReply} = chappe_rtpengine:answer(rtpe1, #{
    call_id => CallId,
    from_tag => FromTag,
    to_tag => ToTag,
    sdp => CalleeSDP
}),
SDPForCaller = chappe_rtpengine_ng:sdp(AnswerReply),

%% when the call ends
{ok, _} = chappe_rtpengine:delete(rtpe1, #{call_id => CallId, from_tag => FromTag}).
```

Notes:

- Parameters are maps with atom keys; underscores map to the NG wire names (`call_id` becomes `call-id`, `ice` becomes `ICE`). Binary keys pass through unmapped.
- SDP bodies are opaque binaries. The library never parses SDP; your SIP stack owns it.
- For per-call use, prefer a media session over raw commands: see the sessions guide.
