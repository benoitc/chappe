# Getting started

`chappe_sip` is a SIP server you embed in an Erlang release. It runs the
signaling stack (sofia-sip's transaction layer, behind a C NIF) in-process, and
you write the call logic in Erlang against the `chappe_sip` API. Read this to bring
the stack up and answer your first call.

## When to use it

- You want a UAS, UAC, B2BUA, proxy, or registrar driven by Erlang, with no
  separate signaling daemon.
- You are comfortable orchestrating media (RTP) yourself; chappe_sip moves signaling
  only (see the non-goals in [Features](../features.md)).

## Build

The default build compiles the C engine (sofia-sip static + the NIF). It needs
a C toolchain, autotools, pkg-config, and OpenSSL.

```bash
rebar3 compile
```

Pure-Erlang work (no engine) runs against the fake backend:

```bash
SKIP_ENGINE_BUILD=1 rebar3 compile
```

## Start the stack

`contact` is the SIP URI chappe_sip binds and advertises. Use the address you want to
listen on.

```erlang
{ok, _} = application:ensure_all_started(chappe_sip),
ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5060">>}).
```

Stop it with `chappe_sip:stop()`.

## Answer OPTIONS

Register a handler per method. A handler is a `fun(Req, Res)` that runs in its
own worker process; answer with `chappe_sip_res:send/2,3`.

```erlang
ok = chappe_sip:options(fun(_Req, Res) ->
    chappe_sip_res:send(Res, 200, #{headers => [{<<"Allow">>, <<"INVITE,ACK,BYE,OPTIONS">>}]})
end).
```

## Answer an INVITE (echo the offer)

Create a UAS dialog to accept a call. `local_sdp` is your answer body.

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    Offer = chappe_sip_req:body(Req),
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{local_sdp => Offer}),
    %% block until the caller hangs up (or destroy it yourself)
    {destroyed, _} = chappe_sip_dialog:wait(Dialog)
end).
```

## Next

- [Answer calls (UAS)](answer-calls.md) for dialogs, in-dialog requests, and the
  `chappe_sip_handler` behaviour.
- [Originate calls (UAC)](originate-calls.md) to place calls.
- [Configuration and limits](configuration.md) for the worker cap and deadlines.

## Notes

- Handlers block for the life of the call ("a call is a process"). Do the work
  in the handler; it does not need to return until the call ends.
- Exiting a handler without a final response makes the engine answer 500.
