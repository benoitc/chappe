# Getting started

`chappe_esl` connects to FreeSWITCH over the event socket. Read this to add it to a
project, open your first connection, and run a command.

## When to use it

- You need to drive FreeSWITCH from Erlang: run api commands, subscribe to
  events, or handle outbound dialplan socket connections.
- You do not want SIP or media logic in the client. chappe_esl is the wire client
  only.

## Add the dependency

```erlang
{deps, [
    {chappe_esl, {git, "https://github.com/benoitc/chappe_esl.git", {branch, "main"}}}
]}.
```

## Connect and run a command

Start a shell and open an inbound connection:

```sh
rebar3 shell
```

```erlang
{ok, Conn} = chappe_esl:connect(#{host => {127,0,0,1}, port => 8021,
                                password => <<"ClueCon">>}),
{ok, Body} = chappe_esl:api(Conn, "status").
```

## Subscribe to events

The connecting process receives event messages:

```erlang
ok = chappe_esl:subscribe(Conn, ['CHANNEL_CREATE']),
receive
    {chappe_esl_event, Conn, Event} ->
        io:format("~s~n", [chappe_esl_event:name(Event)])
after 5000 ->
    timeout
end.
```

## Close

```erlang
ok = chappe_esl:close(Conn).
```

## Next

- [Inbound connections](inbound.md)
- [Outbound connections](outbound.md)
- [Events](events.md)
