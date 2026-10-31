# Inbound connections

An inbound connection is your client connecting to FreeSWITCH's
`mod_event_socket`. Use it to run commands, launch background jobs, and drive
channels from Erlang.

## When to use it

- You control FreeSWITCH from an external Erlang process.
- You want synchronous api results, background jobs, or event subscriptions.

## Connect and authenticate

```erlang
{ok, Conn} = chappe_esl:connect(#{
    host => {127,0,0,1},
    port => 8021,
    password => <<"ClueCon">>,
    connect_timeout => 5000
}).
```

The connecting process becomes the controlling process for events and is
linked to the connection.

Connect fails with a tagged error:

```erlang
{error, {auth_failed, <<"-ERR invalid">>}} = chappe_esl:connect(BadPassword),
{error, {rejected, <<"Access Denied, go away.">>}} = chappe_esl:connect(DeniedByAcl).
```

## Run api commands

`api/2` blocks and returns the response body:

```erlang
{ok, Body} = chappe_esl:api(Conn, "sofia status"),
{ok, Body2} = chappe_esl:api(Conn, ["uuid_getvar ", Uuid, " state"]).
```

A `-ERR` body comes back as an error, and a slow command as a timeout (the
default is 10 s; the caller does not exit):

```erlang
{error, <<"-ERR nope Command not found!">>} = chappe_esl:api(Conn, "nope"),
{error, timeout} = chappe_esl:api(Conn, "sofia status", 100).
```

## Run background jobs

`bgapi/2` returns a Job-UUID and the result arrives later as a BACKGROUND_JOB
event:

```erlang
{ok, JobId} = chappe_esl:bgapi(Conn, "originate loopback/wait &park").
```

`bgapi_await/2,3` subscribes, sends the job, and waits for its result. Call it
from the controlling process:

```erlang
{ok, Result} = chappe_esl:bgapi_await(Conn, "reloadxml", 15000).
```

It subscribes with `event plain BACKGROUND_JOB`, which switches the
connection's event format to plain, and leaves that subscription in place.

## Execute applications on a channel

`execute/4` sends a dialplan application with event-lock:

```erlang
ok = chappe_esl:execute(Conn, Uuid, "answer", ""),
ok = chappe_esl:execute(Conn, Uuid, "playback", "ivr/ivr-welcome.wav").
```

## Filters and injected events

Both send headers only; a body is not supported yet.

```erlang
ok = chappe_esl:filter(Conn, "Event-Name CHANNEL_ANSWER"),
ok = chappe_esl:sendevent(Conn, "NOTIFY", [
    {<<"profile">>, <<"internal">>},
    {<<"content-type">>, <<"application/simple-message-summary">>}
]).
```

## Close

```erlang
ok = chappe_esl:close(Conn).
```

## Where it lives

- Modules: `chappe_esl` (API), `chappe_esl_inbound` (connect helper), `chappe_esl_conn` (the connection FSM), `chappe_esl_parser`
- Tests: `apps/chappe_esl/test/chappe_esl_conn_SUITE.erl`, `chappe_esl_parser_tests.erl`
- Lab: `make interop-esl`
