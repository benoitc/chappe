# Events

FreeSWITCH events arrive as messages to the controlling process. Read this to
subscribe, read event fields, and route events to another process.

## When to use it

- You need channel state, DTMF, background job results, or any FreeSWITCH event.
- You want to move event handling to a dedicated process.

## Subscribe

Choose a format and an event list. `subscribe/2` uses the plain format:

```erlang
ok = chappe_esl:subscribe(Conn, ['CHANNEL_CREATE', 'CHANNEL_ANSWER']),
ok = chappe_esl:events(Conn, json, ['ALL']).
```

## Receive messages

The controlling process receives:

- `{chappe_esl_event, Conn, Event}` for every subscribed event
- `{chappe_esl_linger, Conn}` on a disconnect notice with Content-Disposition
  `linger` (outbound: the channel hung up, events keep coming)
- `{chappe_esl_disconnect, Conn}` on any other disconnect notice
- `{chappe_esl_log, Conn, Headers, Body}` for log data
- `{chappe_esl_closed, Conn}` when the socket closes, or after a framing error

```erlang
receive
    {chappe_esl_event, Conn, Event} ->
        handle(Event);
    {chappe_esl_closed, Conn} ->
        reconnect()
end.
```

## Read event fields

```erlang
Name = chappe_esl_event:name(Event),
Uuid = chappe_esl_event:header(<<"Unique-ID">>, Event),
Body = chappe_esl_event:body(Event),
All  = chappe_esl_event:headers(Event).
```

Plain event values are URL-decoded for you. JSON events decode with the OTP
`json` module; XML events keep the raw body.

## Route events elsewhere

Move delivery to another process:

```erlang
ok = chappe_esl:set_controlling_process(Conn, Pid).
```

From then on `Pid` receives the event messages. On an inbound connection the
link moves too: the old controlling process is unlinked and `Pid` is linked,
so the connection closes when `Pid` exits.

## Where it lives

- Modules: `chappe_esl_event` (decoding and field access), `chappe_esl_conn` (delivery to the controlling process)
- Tests: `apps/chappe_esl/test/chappe_esl_event_tests.erl`, `chappe_esl_conn_SUITE.erl`
- Lab: `make interop-esl`
