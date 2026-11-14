# Getting started

`chappe_esl` connects to FreeSWITCH over the event socket. Read this to add it to a
project, open your first connection, and run a command.

## When to use it

- You need to drive FreeSWITCH from Erlang: run api commands, subscribe to
  events, or handle outbound dialplan socket connections.
- You do not want SIP or media logic in the client. chappe_esl is the wire client
  only.

## Get the code

chappe_esl is an app of the chappe umbrella. To work on it or try it, clone
the umbrella and open a shell with every app loaded:

```sh
git clone https://github.com/benoitc/chappe.git
cd chappe
rebar3 shell
```

To use it from your own project, depend on the umbrella repository and
list `chappe_esl` in your application's `applications`:

```erlang
{deps, [
    {chappe_esl, {git_subdir, "https://github.com/benoitc/chappe.git",
                  {branch, "main"}, "apps/chappe_esl"}}
]}.
```

## Connect and run a command

In the shell, open an inbound connection:

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

## Deploy FreeSWITCH nodes

Turn API expansion off on production nodes, in `switch.conf`:

```xml
<configuration name="switch.conf" description="Core Configuration">
  <settings>
    <param name="api-expansion" value="false"/>
  </settings>
</configuration>
```

FreeSWITCH expands `${var}` in every application argument, and with API
expansion on (its default) also `${api(args)}`, so text that reaches an
application can run an API command such as `system`. The typed helpers
refuse text holding `${`; this setting is the defence in depth for raw
`exec` callers and for dialplans. The chappe labs run with it off.

## Next

- [Inbound connections](inbound.md)
- [Outbound connections](outbound.md)
- [Events](events.md)
- [Configuration](../configuration.md): app env and node options

## Where it lives

- Modules: `chappe_esl` (API), `chappe_esl_inbound`, `chappe_esl_conn`
- Tests: `apps/chappe_esl/test/chappe_esl_conn_SUITE.erl`
- Lab: `make interop-esl` (FreeSWITCH in docker, `apps/chappe_esl/interop/`)
