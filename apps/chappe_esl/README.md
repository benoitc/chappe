# chappe_esl

`chappe_esl` is a FreeSWITCH Event Socket (ESL) client for Erlang/OTP. It speaks
the event socket wire protocol and nothing else: connect inbound to
`mod_event_socket`, or accept outbound dialplan socket connections, then run api
and bgapi commands, execute dialplan applications on channels, and receive
decoded events. It is a leaf library with no runtime dependencies and no SIP or
media concepts.

## What you get

- Inbound connections: connect, authenticate, `api`, `bgapi` with a Job-UUID
  await helper, event subscriptions, and `execute` with event-lock.
- Outbound listener: accept dialplan socket connections and run a handler per
  channel.
- A node registry: register several FreeSWITCH nodes, keep them connected,
  watch their health and load, and pick one per call.
- A streaming frame parser that tolerates arbitrary TCP chunking.
- Event decoding for command/reply, api/response, event-plain, event-json,
  event-xml (raw), disconnect-notice, log/data, and rude-rejection.

## Requirements

- Erlang/OTP 29
- rebar3
- A FreeSWITCH with `mod_event_socket` for live use

## Quick start

```sh
rebar3 compile
rebar3 shell
```

Connect inbound, run a command, subscribe to events:

```erlang
{ok, Conn} = chappe_esl:connect(#{host => {127,0,0,1}, port => 8021,
                                password => <<"ClueCon">>}),
{ok, Status} = chappe_esl:api(Conn, "status"),
ok = chappe_esl:subscribe(Conn, ['CHANNEL_CREATE', 'CHANNEL_HANGUP']),
receive
    {chappe_esl_event, Conn, Event} ->
        io:format("event ~s~n", [chappe_esl_event:name(Event)])
end.
```

Run a background job and wait for its result:

```erlang
{ok, Result} = chappe_esl:bgapi_await(Conn, "originate loopback/wait &park").
```

Execute a dialplan application on a channel:

```erlang
ok = chappe_esl:execute(Conn, Uuid, "playback", "tone_stream://%(2000,4000,440)").
```

## Outbound

Listen for dialplan socket connections and handle each channel with a
`chappe_esl_handler`:

```erlang
-module(my_handler).
-behaviour(chappe_esl_handler).
-export([handle_channel/3]).

handle_channel(Conn, Channel, _Args) ->
    Uuid = chappe_esl_event:header(<<"Unique-ID">>, Channel),
    ok = chappe_esl:execute(Conn, "answer", ""),
    ok = chappe_esl:execute(Conn, "playback", "ivr/ivr-welcome.wav"),
    ok = chappe_esl:execute(Conn, "hangup", "").
```

```erlang
{ok, _Ref} = chappe_esl:start_listener(8084, my_handler, []).
```

## Nodes

Register FreeSWITCH nodes, then pick one per call:

```erlang
ok = chappe_esl:node_add(fs1, #{host => "10.0.0.11", tags => [conference]}),
ok = chappe_esl:node_add(fs2, #{host => "10.0.0.12", tags => [conference]}),
{ok, Name} = chappe_esl:node_select(#{policy => least_sessions}),
{ok, _} = chappe_esl:node_api(Name, "status").
```

See `docs/guides/nodes.md`, `docs/guides/select-node.md`, and
`examples/README.md` (`make demo-esl`) to try it against two FreeSWITCH nodes.

## Events

The controlling process receives:

- `{chappe_esl_event, Conn, Event}` for every subscribed event
- `{chappe_esl_linger, Conn}` on a disconnect notice with Content-Disposition
  `linger` (outbound: the channel hung up, events keep coming)
- `{chappe_esl_disconnect, Conn}` on any other disconnect notice
- `{chappe_esl_log, Conn, Headers, Body}` for log data
- `{chappe_esl_closed, Conn}` when the socket closes, or after a framing error

Read event fields with `chappe_esl_event:name/1`, `chappe_esl_event:header/2`, and
`chappe_esl_event:body/1`. Change the controlling process with
`chappe_esl:set_controlling_process/2`.

## Documentation

Guides live in `docs/`. Build the HTML with `rebar3 ex_doc` and open
`doc/index.html`.

## Tests

```sh
rebar3 eunit    # parser and event decoders, split at every byte boundary
rebar3 ct       # connection, outbound and node suites against an in-process fake
```

Live interop against two real FreeSWITCH nodes is opt-in (`make interop-esl`
from the umbrella root); see `interop/README.md`.

## License

Copyright 2026 Benoit Chesneau. Apache-2.0 (see LICENSE and NOTICE).
