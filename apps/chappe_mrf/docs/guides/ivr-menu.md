# Answer a caller with a menu

`chappe_mrf:connect_caller/3` answers an incoming INVITE by bridging it,
anchored in rtpengine, to a FreeSWITCH node, and gives you the node's
channel as an endpoint. Use it for an IVR, a voicemail or any call where
Erlang decides what the caller hears.

## When to use it

- The caller should hear prompts and press digits before anything else.
- You record or stream the caller's audio.
- You want to move the caller somewhere else afterwards (see
  [Bridge a caller](bridge.md)).

## Connect the caller

Call it from the INVITE handler. The handler then drives the endpoint:

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Ep, B2b} = chappe_mrf:connect_caller(Req, Res, #{}),
    menu(Ep, B2b)
end).
```

chappe_esl picks the node (`node_select/1`, fewest sessions first); the
other up nodes follow on 408, 503 or a transport error. Pass `node => fs1`
to pin one, or `select => #{tags => [ivr]}`.

The call runs in its own process (`chappe_sip_b2b:relay_async/2`), so the
handler is free. The handler owns the endpoint: when it exits, the channel
is killed.

## Play a menu and collect a digit

```erlang
menu(Ep, B2b) ->
    case chappe_mrf:play_collect(Ep, #{file => <<"/media/menu.wav">>,
                                       max => 1, timeout => 8000}) of
        {ok, <<"1">>} -> chappe_mrf:play(Ep, <<"/media/sales.wav">>);
        {ok, <<"9">>} -> chappe_sip_b2b:hangup(B2b, #{});
        {ok, _} -> menu(Ep, B2b)
    end.
```

`play_collect/2` takes `min`, `max`, `tries`, `timeout`, `terminators`,
`invalid_file` and `digit_timeout`; `{ok, <<>>}` means no digit came.

## Record and play back

```erlang
ok = chappe_mrf:record(Ep, <<"/media/msg-42.wav">>, #{max_secs => 30}),
ok = chappe_mrf:play(Ep, <<"/media/msg-42.wav">>).
```

The path is on the FreeSWITCH node. `record_session/2` records both
directions until `record_session_stop/2` or the hangup.

## React to events

The owner gets `{chappe_mrf, Ep, Event}`:

```erlang
receive
    {chappe_mrf, Ep, {dtmf, Digit}} -> Digit;
    {chappe_mrf, Ep, {hangup, Cause}} -> Cause;
    {chappe_mrf, Ep, {node_down, Node}} -> Node
end.
```

The call's events (`{chappe_sip_b2b, Ref, Event}`, `{done, Why}` at the
end) go to the `notify` option, the handler by default.

## Other commands

| function | what it does |
|----------|--------------|
| `send_dtmf/2` | send digits to the caller |
| `set/3` | set a channel variable |
| `api/2` | run an api command on the endpoint's node |
| `execute/3` | run any dialplan application and wait for it |
| `fork_audio_start/3`, `fork_audio_stop/1` | stream the audio to a WebSocket (mod_audio_fork) |
| `modify/2` | `hold`, `unhold`, or a new SDP on an endpoint of `create_endpoint/1` |
| `destroy/1` | hang up and free the endpoint |

## Notes

- `say` and `speak` are not wrapped: run them with `execute/3` where the
  node has the modules.
- A command blocks the process that calls it, not the endpoint: digits
  keep reaching the owner during a long playback.

## Where it lives

- Modules: `chappe_mrf` (API), `chappe_mrf_endpoint` (one per channel),
  `chappe_mrf_esl` (the outbound socket handler); commands run on
  `chappe_esl_call`
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl` (fakes),
  `chappe_mrf_live_SUITE.erl`
- Lab: `make interop-mrf` (`apps/chappe_mrf/interop/`); the demo SBC has an
  IVR on `2000` (`make demo`)
