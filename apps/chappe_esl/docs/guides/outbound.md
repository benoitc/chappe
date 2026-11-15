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

## Listen where FreeSWITCH can reach you

The listener binds `127.0.0.1` by default. Anything that connects to it gets
a handler process and drives a channel, and the outbound protocol has no
authentication, so the listener does not open to the network unless you ask.
When FreeSWITCH runs on the same host, the default is all you need.

When FreeSWITCH runs on another host, bind the interface it reaches you on
and list the addresses it connects from in `allow`:

```erlang
{ok, _} = chappe_esl:start_listener(8084, my_handler, [], #{
    ip => {10, 0, 0, 5},
    allow => [<<"10.0.0.0/24">>, "10.0.1.7"]
}).
```

`allow` takes CIDR networks or bare addresses, as binaries or strings, IPv4
or IPv6. The listener checks each peer right after accept: a peer outside
the list is closed before any byte is read or any process started, and
counted as `refused`. Without `allow`, every peer that reaches `ip` is taken.

Keep a firewall rule in front of the port too, letting in only your
FreeSWITCH hosts: `allow` closes the connection after the TCP handshake, a
firewall drops it before.

An IPv6 address (an 8-tuple) listens on IPv6; an IPv4 peer arriving on it
as an IPv4-mapped address matches the IPv4 networks of `allow`.

## Bound connections that do not speak

A connection counts as pending from accept until it sends its channel data.
Two options bound them:

| Option | Default | What happens past it |
|---|---|---|
| `max_pending` | `64` | A new connection is closed at once and counted as `busy`. |
| `first_frame_timeout` | `5000` | The connection is closed and counted in `first_frame_timeouts`. |

FreeSWITCH answers `connect` at once, so the defaults only matter when
something else holds connections open. `backlog` (128) is the queue of
connections not yet accepted; raise it when many calls arrive at once.

```erlang
{ok, _} = chappe_esl:start_listener(8084, my_handler, [], #{
    max_pending => 256,
    first_frame_timeout => 2000,
    backlog => 256
}).
```

Read the counters with `listener_stats/1`:

```erlang
#{accepted := _, refused := _, busy := _,
  first_frame_timeouts := _, pending := _} = chappe_esl:listener_stats(8084).
```

A bad `ip`, `allow`, `backlog`, `max_pending`, `first_frame_timeout` or
`linger` returns `{error, {bad_option, Key}}` and nothing listens.

## Stop the listener

```erlang
ok = chappe_esl:stop_listener(8084).
```

## Where it lives

- Modules: `chappe_esl_listener` (accepts sockets, checks `allow`), `chappe_esl_cidr` (the networks of `allow`), `chappe_esl_outbound_sup` (handler pool), `chappe_esl_handler` (the behaviour you implement), `chappe_esl_conn` (`accepting` state)
- Tests: `apps/chappe_esl/test/chappe_esl_outbound_SUITE.erl`
- Lab: `make interop-esl`
