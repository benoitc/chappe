# Outbound connections

An outbound connection is FreeSWITCH connecting to your listener from the
dialplan socket application. Use it to handle a specific channel in its own
Erlang process.

## When to use it

- Your dialplan hands a channel to Erlang with `<action application="socket"
  data="host:port async full"/>`.
- You want one handler process per channel with the channel data in hand.

## Write a handler

Implement the `chappe_esl_handler` behaviour. `handle_channel/3` runs in its own
process with the connection and the initial channel data event:

```erlang
-module(my_handler).
-behaviour(chappe_esl_handler).
-export([handle_channel/3]).

handle_channel(Conn, Channel, _Args) ->
    Uuid = chappe_esl_event:header(<<"Unique-ID">>, Channel),
    ok = chappe_esl:execute(Conn, "answer", ""),
    ok = chappe_esl:execute(Conn, "playback", "ivr/ivr-welcome.wav"),
    ok = chappe_esl:execute(Conn, "hangup", "NORMAL_CLEARING").
```

Applications run on the current channel, so `execute/3` needs no UUID.

## Start the listener

Start the application, then the listener:

```erlang
{ok, _} = application:ensure_all_started(chappe_esl),
{ok, _Ref} = chappe_esl:start_listener(8084, my_handler, []).
```

The third argument is passed to `handle_channel/3` as `Args`.

## Receive events on the channel

Subscribe to the channel's own events and receive them in the handler process:

```erlang
handle_channel(Conn, _Channel, _Args) ->
    ok = chappe_esl:subscribe(Conn, ['CHANNEL_HANGUP']),
    ok = chappe_esl:execute(Conn, "answer", ""),
    receive
        {chappe_esl_event, Conn, Event} ->
            io:format("hangup ~s~n", [chappe_esl_event:name(Event)])
    after 30000 ->
        timeout
    end.
```

## Hand the channel to a call process

To play, collect digits and record with each application awaited, start a
`chappe_esl_call` in the handler. See [Control a call](call-control.md).

## Linger after hangup

Each connection sends `linger` right after `connect`, so FreeSWITCH keeps the
socket open after hangup and the final channel events still arrive. The
handler then receives `{chappe_esl_linger, Conn}` at hangup, the remaining
events, `{chappe_esl_disconnect, Conn}` on the final notice, and
`{chappe_esl_closed, Conn}` when the socket closes.

Change it per listener with `start_listener/4`:

```erlang
{ok, _} = chappe_esl:start_listener(8084, my_handler, [], #{linger => 30}),
{ok, _} = chappe_esl:start_listener(8085, my_handler, [], #{linger => false}).
```

`true` (default) sends `linger`, an integer sends `linger <Seconds>`, `false`
sends nothing.

## Stop the listener

```erlang
ok = chappe_esl:stop_listener(8084).
```

## Where it lives

- Modules: `chappe_esl_listener` (accepts sockets), `chappe_esl_outbound_sup` (handler pool), `chappe_esl_handler` (the behaviour you implement), `chappe_esl_conn` (`accepting` state)
- Tests: `apps/chappe_esl/test/chappe_esl_outbound_SUITE.erl`
- Lab: `make interop-esl`
