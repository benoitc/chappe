# chappe_rtpengine

An Erlang/OTP client for controlling [rtpengine](https://github.com/sipwise/rtpengine) media proxies over the NG protocol. You use it from a SIP application (a B2BUA such as chappe_sip) to anchor media: send it your SDP offers and answers, and it returns the rewritten SDP pointing at rtpengine. Pure Erlang, no NIFs, one dependency ([erlang_ws](https://github.com/benoitc/erlang_ws), for the WebSocket transport). SIP signalling stays outside this library. The client and the sessions pass SDP bodies through untouched; the only SDP it reads is in the opt-in `chappe_rtpengine_sdp` helpers, which build subscription answers that route chosen streams.

## Requirements

- Erlang/OTP 29
- rebar3
- an rtpengine instance with an NG listener (`--listen-ng`)

## Quick start

Add the application and connect a node:

```erlang
{ok, _} = application:ensure_all_started(chappe_rtpengine),
ok = chappe_rtpengine:add_node(rtpe1, #{host => "192.168.1.10", port => 2223}).
```

Check the node answers:

```erlang
{ok, #{<<"result">> := <<"pong">>}} = chappe_rtpengine:ping(rtpe1).
```

Anchor a call. Send the caller's SDP as an offer, give the rewritten SDP to the callee, then send the callee's SDP as the answer:

```erlang
{ok, OfferReply} = chappe_rtpengine:offer(rtpe1, #{
    call_id => CallId,
    from_tag => FromTag,
    sdp => CallerSDP,
    ice => remove,
    flags => [trust_address]
}),
SDPForCallee = chappe_rtpengine_ng:sdp(OfferReply),

{ok, AnswerReply} = chappe_rtpengine:answer(rtpe1, #{
    call_id => CallId,
    from_tag => FromTag,
    to_tag => ToTag,
    sdp => CalleeSDP
}),
SDPForCaller = chappe_rtpengine_ng:sdp(AnswerReply).
```

Inspect and tear down the session when the call ends:

```erlang
{ok, Stats} = chappe_rtpengine:query(rtpe1, #{call_id => CallId}),
{ok, _} = chappe_rtpengine:delete(rtpe1, #{call_id => CallId, from_tag => FromTag}).
```

## Parameters and results

Parameters are maps with atom keys. Underscored atoms map to the NG wire names (`call_id` becomes `call-id`, `transport_protocol` becomes `transport-protocol`); irregular casings are handled (`ice` becomes `ICE`, `dtls` becomes `DTLS`). Atom values under the option-word keys (`flags`, `replace`, `rtcp_mux`, `ice`, `ice_lite`, `dtls`, `dtls_reverse`, `osrtp`, `t38`, `record_call`) hyphenate the same way, so `flags => [trust_address]` goes out as `trust-address`; every other atom value is sent verbatim, so SDES suite names and codec names keep their underscores. Floats and tuples are refused with `{error, {bad_param, Key, Value}}`. Binary keys and values pass through untouched, which covers anything not mapped yet. Any other NG command is reachable through `chappe_rtpengine:cmd(Node, Command, Params)`.

Results are:

- `{ok, Reply}` where `Reply` is the decoded dictionary with binary keys
- `{error, Reason, Reply}` when rtpengine answered with an error
- `{error, timeout}` when all attempts went unanswered
- `{error, client_down}` when the node's client process is not running

## Timeouts and retries

Each request is retransmitted with the same cookie until a reply arrives, then rtpengine serves duplicates from its reply cache, so retries are safe. Tune per node:

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "192.168.1.10",
    port => 2223,
    timeout => 1000,   % per attempt, milliseconds
    attempts => 3      % total attempts before {error, timeout}
}).
```

Per-node transport counters are available with `chappe_rtpengine:stats(Node)`.

## TCP transport

If your SDP bodies outgrow safe datagram sizes (ICE candidate lists, many m-lines), run the node over NG-TCP instead. Point it at rtpengine's `--listen-tcp-ng` listener:

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "192.168.1.10",
    port => 2224,
    transport => tcp
}).
```

The API is identical. Timeouts still bound every request, nothing is retransmitted (the transport is reliable), and a broken connection fails in-flight requests with `{error, closed}` and reconnects in the background; requests made while disconnected return `{error, {send_failed, not_connected}}`.

## WebSocket transport

To cross firewalls or ride 443, point the node at rtpengine's HTTP interface (`--listen-http` / `--listen-https`). NG rides a WebSocket negotiating the `ng.rtpengine.com` subprotocol:

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "rtpengine.example.net",
    port => 443,
    transport => wss,
    tls_opts => [{verify, verify_peer}]
}).
```

Use `transport => ws` for plain HTTP; `path` defaults to `/`. Reliability semantics match TCP. See the [nodes guide](docs/guides/nodes.md).

## Documentation

Task-oriented guides live in `docs/guides/`:

- [Getting started](docs/guides/getting-started.md)
- [Nodes, health and transports](docs/guides/nodes.md)
- [Media sessions](docs/guides/sessions.md)
- [Playback, recording and DTMF](docs/guides/media-features.md)
- [Media subscriptions](docs/guides/subscriptions.md)
- [Testing](docs/guides/testing.md)

Reference pages:

- [Documentation index](docs/README.md)
- [Configuration](docs/configuration.md): app env and node options
- [Design overview](docs/design/overview.md)
- [Features](docs/features.md)

Render them with the API reference into `doc/` with `rebar3 ex_doc`.

## Tests

From the umbrella root:

```sh
rebar3 eunit --app chappe_rtpengine        # codecs and SDP helpers
rebar3 ct --dir apps/chappe_rtpengine/test # suites against the in-process fake
make check                                 # every gate, all apps
```

For the end-to-end suites against a real dockerized rtpengine (offer/answer rewriting, SRTP and DTLS negotiation, RTP relayed both ways, NG over TCP and WebSocket, the interpreter primitives):

```sh
make interop
```

See the [testing guide](docs/guides/testing.md) and `interop/README.md` for running against your own instance.

## Node pool

Every node you add is health-checked (periodic ping plus timeout reports; consecutive failures mark it down, recovery bumps its generation). Pick the least-loaded healthy node per call, or let a session do it for you:

```erlang
{ok, Node} = chappe_rtpengine:select_node(),
[#{name := _, status := _, generation := _} | _] = chappe_rtpengine:list_nodes(),
ok = chappe_rtpengine_pool:subscribe().   % receive {chappe_rtpengine_pool, {node_down, N} | {node_up, N, Gen}}
```

A generation bump on `node_up` means the node flapped: rtpengine loses all sessions on restart, so calls pinned before the flap have lost their media.

## Media sessions

For per-call use, start a supervised session instead of issuing raw commands. It selects and pins a node, tracks the call's tags, and deletes the rtpengine session when you stop it, when your process dies, or when it terminates for any reason:

```erlang
{ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId}),
{ok, OfferReply} = chappe_rtpengine_session:offer(Sess, #{from_tag => FromTag, sdp => CallerSDP}),
{ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{to_tag => ToTag, sdp => CalleeSDP}),
%% re-INVITE later: offer again from established; a competing
%% re-INVITE while one is in flight returns {error, glare}
{ok, Stats} = chappe_rtpengine_session:query(Sess),
ok = chappe_rtpengine_session:stop(Sess).
```

A callee-initiated re-INVITE swaps the tag direction on the wire for you: `chappe_rtpengine_session:offer(Sess, #{sdp => SDP, initiator => callee})`. On forked calls, answer once per branch with its to_tag and mark the winner with `final => true`; the session deletes the losing branches.

Media commands run against the established session with its identity injected:

```erlang
{ok, _} = chappe_rtpengine_session:play_media(Sess, #{file => <<"/prompts/hello.wav">>}),
{ok, _} = chappe_rtpengine_session:play_dtmf(Sess, #{code => 5, duration => 100}),
{ok, _} = chappe_rtpengine_session:start_recording(Sess),
{ok, _} = chappe_rtpengine_session:stop_media(Sess),
%% duck one direction (interpreter style): silence keeps packets
%% flowing as silence, block stops them entirely
{ok, _} = chappe_rtpengine_session:silence_media(Sess, #{party => caller}),
{ok, _} = chappe_rtpengine_session:unsilence_media(Sess, #{party => caller}).
```

Your process (the session owner) receives `{chappe_rtpengine_session, Pid, {node_down, Node}}` when the pinned node stops answering, and `{chappe_rtpengine_session, Pid, {node_restarted, Node}}` when the node came back restarted or replied "unknown call-id": the media session on it is gone, and you decide between re-offering and tearing down.

## DTMF events

To receive caller keypresses (IVR menus, voicemail navigation), open the DTMF listener and point rtpengine's `--dtmf-log-dest` at it:

```erlang
{ok, Port} = chappe_rtpengine_dtmf:open(2225).
%% rtpengine: --dtmf-log-dest=YOUR_HOST:2225
```

Or set `{dtmf_listen, 2225}` in the application environment. Then start sessions with `dtmf => true` and the owner receives each digit:

```erlang
{ok, Sess} = chappe_rtpengine:start_session(#{call_id => CallId, dtmf => true}),
receive
    {chappe_rtpengine_session, Sess, {dtmf, #{digit := Digit}}} -> handle_digit(Digit)
end.
```

`digit` is the ASCII character (`$0`..`$9`, `$*`, `$#`, `$A`..`$D`); the event map also carries `code`, `duration`, `volume`, `source_tag` and the raw JSON object. Without sessions, subscribe directly with `chappe_rtpengine_dtmf:subscribe(CallId)` and receive `{chappe_rtpengine_dtmf, CallId, Event}`.

## Media subscriptions

To tap a call's media (recording taps, listen-in, conference graphs), request a subscription: rtpengine returns an SDP offer for the tapped streams and a to-tag naming the subscription, which you answer with the consumer's SDP:

```erlang
{ok, Sub} = chappe_rtpengine_session:subscribe_request(Sess, #{flags => [all]}),
SubTag = maps:get(<<"to-tag">>, Sub),
OfferedSDP = chappe_rtpengine_ng:sdp(Sub),
{ok, _} = chappe_rtpengine_session:subscribe_answer(Sess, #{to_tag => SubTag, sdp => ConsumerSDP}),
%% later
{ok, _} = chappe_rtpengine_session:unsubscribe(Sess, #{to_tag => SubTag}).
```

Pass `from_tag` instead of `flags => [all]` to tap a single participant. Subscriptions need an rtpengine built with transcoding support; minimal builds reply "Unrecognized command".

## Notes

- One `chappe_rtpengine_client` process per node owns one UDP socket; nodes are added and removed at runtime.
- Design details are in `docs/design/overview.md`, feature list and roadmap in `docs/features.md`.

## License

Apache-2.0
