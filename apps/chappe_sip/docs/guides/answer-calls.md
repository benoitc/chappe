# Answer calls (UAS)

You answer an inbound dialog-forming request by creating a UAS dialog. The
dialog is a process that is the source of truth for the call; it delivers
in-dialog events (ACK, re-INVITE, INFO, BYE) to your handler as messages. Read
this to accept calls and handle what happens during them.

## When to use it

- You terminate the call in enki (you are the endpoint), not bridging or
  proxying it elsewhere.
- You want to answer, then react to re-INVITE (hold), INFO, or the peer's BYE.

## Create the dialog

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Dialog} = chappe_sip:create_uas(Req, Res, #{local_sdp => my_answer_sdp()}),
    run(Dialog)
end).
```

`create_uas/3` sends the dialog-forming 2xx (with the local tag, and a Contact
it adds for you) and returns once the leg is up. Opts: `local_sdp`, `status`
(default 200), `reason`, `headers`, `handled_events`, `owner`, `on_owner_exit`.

## Handle in-dialog events

The dialog sends the owner messages. The simplest loop waits for teardown:

```erlang
run(Dialog) ->
    {destroyed, _ReqOrReason} = chappe_sip_dialog:wait(Dialog).
```

To act on events, receive them directly:

```erlang
run(Dialog) ->
    receive
        {chappe_sip_dialog, Dialog, ack, _Req} ->
            run(Dialog);
        {chappe_sip_dialog, Dialog, {auto_answered, info}, _Req} ->
            run(Dialog);
        {chappe_sip_dialog, Dialog, destroy, _} ->
            {destroyed, byed}
    end.
```

Unclaimed in-dialog requests (INFO/UPDATE) are auto-answered 200; a peer BYE
arrives as `destroy`.

## Drive the dialog

```erlang
{ok, RemoteSdp} = chappe_sip_dialog:modify(Dialog, hold),      %% re-INVITE, hold
{ok, RemoteSdp2} = chappe_sip_dialog:modify(Dialog, unhold),
{ok, _Msg} = chappe_sip_dialog:request(Dialog, #{method => <<"INFO">>,
                                           content_type => <<"application/dtmf">>,
                                           body => <<"1">>}),
ok = chappe_sip_dialog:destroy(Dialog).                        %% send BYE
```

## Structured handlers

For anything beyond a trivial loop, use the `chappe_sip_handler` behaviour. It maps
dialog events to callbacks.

```erlang
-module(my_call).
-behaviour(chappe_sip_handler).
-export([init/1, handle_dialog/4, terminate/2]).

init(Req) ->
    {answer, #{local_sdp => answer_for(Req)}, #{started => now_ms()}}.

handle_dialog(ack, _Req, _Res, S)  -> {ok, S};
handle_dialog(info, _Req, Res, S)  -> chappe_sip_res:send(Res, 200), {ok, S};
handle_dialog(_Ev, _Req, _Res, S)  -> {ok, S}.

terminate(_Reason, _S) -> ok.
```

Start it from the method handler:

```erlang
ok = chappe_sip:invite(fun(Req, Res) -> chappe_sip_handler:start(my_call, Req, Res) end).
```

`init/1` returns `{answer, Opts, State}`, `{reject, Status, State}`, or
`{ignore, State}`. A `handle_dialog` callback returns `{ok, State}` or
`{stop, State}` (which sends BYE).

## Notes

- The dialog fsm monitors its owner; if your handler crashes, the dialog is torn
  down (BYE) by default (`on_owner_exit => destroy`).
- A long call is fine: the worker is not bounded by the handler deadline once it
  owns a dialog. See [Configuration](configuration.md).
