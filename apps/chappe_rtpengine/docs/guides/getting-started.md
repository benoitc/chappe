# Getting started

This guide takes you from an empty project to relaying a call's media through rtpengine. You need it the first time you use chappe_rtpengine, or when setting up a development environment.

## Get the code

chappe_rtpengine is an app of the chappe umbrella. To work on it or try it, clone the umbrella and open a shell with every app loaded:

```sh
git clone https://github.com/benoitc/chappe.git
cd chappe
rebar3 shell
```

To use it from your own project, depend on the umbrella repository and list `chappe_rtpengine` in your application's `applications` so it boots with your release. rebar3 finds the app inside the repository:

```erlang
%% rebar.config
{deps, [
    {chappe_rtpengine, {git_subdir, "https://github.com/benoitc/chappe.git",
                        {branch, "main"}, "apps/chappe_rtpengine"}}
]}.
```

If you drive rtpengine from a chappe_sip service, you usually do not call this app directly: configure `media => #{rtpengine => ...}` in `chappe_sip:start/1` and use `chappe_sip_media` (see the chappe_sip [media design](https://github.com/benoitc/chappe/blob/main/apps/chappe_sip/docs/design/media.md)).

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

- Parameters are maps with atom keys; underscores map to the NG wire names (`call_id` becomes `call-id`, `ice` becomes `ICE`, `media_address` becomes `media address`, `t38` becomes `T.38`). Binary keys pass through unmapped.
- Atom values in `flags`, `replace`, `rtcp_mux`, `ice`, `ice_lite`, `dtls`, `dtls_reverse`, `osrtp`, `t38` and `record_call` are NG option words and hyphenate (`trust_address` becomes `trust-address`); any other atom value goes out as written (`sdes => [unencrypted_srtp]`). A float or tuple value returns `{error, {bad_param, Key, Value}}`.
- A reply may carry a `warning` key next to `result`; it stays in the reply map. A node shedding load replies `{error, load_limit, Reply}`.
- SDP bodies go to rtpengine and come back untouched; your SIP stack owns them. The only SDP helpers are in `chappe_rtpengine_sdp`, for subscription answers (see [Media subscriptions](subscriptions.md)).
- For per-call use, prefer a media session over raw commands: see [Media sessions](sessions.md).
- App env and node options are listed in [Configuration](../configuration.md).

## Where it lives

- Modules: `chappe_rtpengine` (API), `chappe_rtpengine_client` (one per node), `chappe_rtpengine_ng` (parameters and replies)
- Tests: `apps/chappe_rtpengine/test/chappe_rtpengine_client_SUITE.erl`, `chappe_rtpengine_ng_tests.erl`
- Lab: `make interop` (rtpengine in docker, `apps/chappe_rtpengine/interop/`)
