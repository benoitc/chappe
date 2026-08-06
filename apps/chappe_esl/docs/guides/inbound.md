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

The connecting process becomes the controlling process for events.

## Run api commands

`api/2` blocks and returns the response body:

```erlang
{ok, Body} = chappe_esl:api(Conn, "sofia status"),
{ok, Body2} = chappe_esl:api(Conn, ["uuid_getvar ", Uuid, " state"]).
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

## Execute applications on a channel

`execute/4` sends a dialplan application with event-lock:

```erlang
ok = chappe_esl:execute(Conn, Uuid, "answer", ""),
ok = chappe_esl:execute(Conn, Uuid, "playback", "ivr/ivr-welcome.wav").
```

## Filters and injected events

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
