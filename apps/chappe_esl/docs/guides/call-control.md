# Control a call

`chappe_esl_call` drives one FreeSWITCH channel: it runs dialplan
applications and waits for each to finish, collects digits, records, and
tells you about DTMF and the hangup. You need it when Erlang decides what
happens on a call (an IVR, a voicemail, a media bridge) instead of the XML
dialplan.

## When to use it

- Your dialplan hands a channel to Erlang with `socket <host>:<port> async
  full`, and you want to play, collect and record on it.
- You hold an inbound connection and a channel uuid, and want to drive that
  channel.
- You need to know when an application finished, not only that FreeSWITCH
  accepted it.

## Start a call process from an outbound handler

Start the listener as in [Outbound connections](outbound.md), then start a
call process in the handler:

```erlang
-module(my_ivr).
-behaviour(chappe_esl_handler).
-export([handle_channel/3]).

handle_channel(Conn, _Channel, _Args) ->
    {ok, Call} = chappe_esl_call:start(Conn, #{}),
    ok = chappe_esl_call:answer(Call),
    {ok, _} = chappe_esl_call:playback(Call, "/sounds/welcome.wav"),
    ok = chappe_esl_call:hangup(Call).
```

The call process becomes the connection's controlling process and sends
`myevents`. The handler process is its owner: it receives the call's
messages, and the call is cleaned up when it exits.

To let another process own the call, pass it and return from the handler:

```erlang
handle_channel(Conn, _Channel, Owner) ->
    {ok, Call} = chappe_esl_call:start(Conn, #{owner => Owner}),
    Owner ! {new_call, Call},
    ok.
```

The connection stays open after the handler returns, because it now follows
the call process.

## Start a call process on an inbound connection

Pass the channel uuid:

```erlang
{ok, Conn} = chappe_esl:connect(#{host => "fs1", port => 8021}),
{ok, Call} = chappe_esl_call:start(Conn, #{uuid => Uuid}).
```

The call sets a `Unique-ID` filter and subscribes to every event, so use one
connection per call.

## Run an application and wait for it

```erlang
{ok, Event} = chappe_esl_call:exec(Call, "playback", "/sounds/menu.wav"),
<<"FILE PLAYED">> =
    chappe_esl_event:header(<<"Application-Response">>, Event).
```

`exec/4` takes options:

```erlang
{error, timeout} =
    chappe_esl_call:exec(Call, "park", "", #{timeout => 5000}),
{ok, AppUuid} =
    chappe_esl_call:exec(Call, "playback", "/sounds/hold.wav", #{wait => false}).
```

With `wait => false` the completion arrives later as
`{chappe_esl_call, Call, {complete, <<"playback">>, Event}}`. When the caller
and the owner are different processes, it can reach the owner before the caller
gets its `{ok, AppUuid}`.

## Collect digits

```erlang
{ok, Digits} = chappe_esl_call:play_and_get_digits(Call, #{
    file => <<"/sounds/enter-pin.wav">>,
    min => 4,
    max => 4,
    tries => 3,
    timeout => 5000,
    terminators => <<"#">>
}).
```

`Digits` is `<<>>` when the caller entered nothing.

## Record

Record the caller for at most 30 seconds:

```erlang
{ok, _} = chappe_esl_call:record(Call, "/recordings/msg.wav", #{max_secs => 30}).
```

Record the whole session in the background:

```erlang
ok = chappe_esl_call:record_session(Call, "/recordings/call.wav"),
%% ...
ok = chappe_esl_call:record_session_stop(Call, "/recordings/call.wav").
```

## Other helpers

```erlang
ok = chappe_esl_call:set(Call, "language", "fr"),
ok = chappe_esl_call:export(Call, "account", "42"),
ok = chappe_esl_call:send_dtmf(Call, "1234#"),
{ok, _AppUuid} = chappe_esl_call:conference(Call, "sales", #{flags => [moderator]}),
ok = chappe_esl_call:audio_fork_start(Call, "wss://asr.example/ws", #{mix => mono, rate => 16000}),
ok = chappe_esl_call:audio_fork_stop(Call),
{ok, _} = chappe_esl_call:api(Call, "uuid_getvar " ++ Uuid ++ " language"),
ok = chappe_esl_call:hangup(Call, "USER_BUSY").
```

`conference/3` returns once FreeSWITCH accepted the command; its completion
arrives when the member leaves.

## Fork the audio to a websocket

`audio_fork_start/3` sends the channel audio to a websocket server, for
example a speech recognizer. It speaks mod_audio_fork by default. If your
node runs mod_audio_stream instead, pass `module => audio_stream`:

```erlang
ok = chappe_esl_call:audio_fork_start(Call, "wss://asr.example/ws", #{
    module => audio_stream,
    mix => mono,
    rate => 16000,
    metadata => <<"{\"call\": \"42\"}">>
}),
%% ...
ok = chappe_esl_call:audio_fork_stop(Call).
```

| Option | Default | Meaning |
|---|---|---|
| `module` | `audio_fork` | `audio_fork` sends `uuid_audio_fork`, `audio_stream` sends `uuid_audio_stream`. |
| `mix` | `mono` | `mono` (caller only), `mixed` (both in one channel) or `stereo` (one channel each). |
| `rate` | `16000` | Sample rate in Hz. For mod_audio_stream, 8000 and 16000 are sent as `8k` and `16k`. |
| `metadata` | none | Text sent to the server as the first frame. |
| `bugname` | `audio_fork` | mod_audio_fork only: the fork's name, so one channel runs several. mod_audio_stream has one fork per channel and refuses it. |

The call remembers which module and bug name started each fork:
`audio_fork_stop/1` and the cleanup when the owner dies send each its stop.
Any other `module` returns `{error, {bad_option, module}}`.

Pause, resume, talk to the server or stop one fork. The last argument
names the forks (`#{}` for all of them, `#{bugname => B}`, `#{module => M}`):

```erlang
ok = chappe_esl_call:audio_fork_pause(Call, #{bugname => <<"asr">>}),
ok = chappe_esl_call:audio_fork_resume(Call, #{}),
ok = chappe_esl_call:audio_fork_send_text(Call, <<"{\"type\": \"mark\"}">>, #{}),
ok = chappe_esl_call:audio_fork_stop(Call, #{bugname => <<"asr">>}).
```

Pause keeps the WebSocket open and stops the audio. With no fork running
that the selection names, they return `{error, not_forking}`.

## Receive the call's messages

The owner receives:

```erlang
receive
    {chappe_esl_call, Call, {dtmf, Digit}} -> Digit;
    {chappe_esl_call, Call, {hangup, Cause}} -> Cause;
    {chappe_esl_call, Call, {complete, App, Event}} -> {App, Event};
    {chappe_esl_call, Call, {event, Event}} -> chappe_esl_event:name(Event);
    {chappe_esl_call, Call, linger} -> final_events_follow;
    {chappe_esl_call, Call, disconnect} -> nothing_more_coming;
    {chappe_esl_call, Call, closed} -> closed
end.
```

`linger` means the channel hung up, the final events still follow and the
socket stays open. `disconnect` means FreeSWITCH sends nothing more on this
connection. Neither ends a request in flight or the call process: `closed`
does, and it is the only message that says the process stopped. Ignore the
first two if you have no use for them, but do not crash on them.

Start the call with `ref => Ref` (an opaque binary, such as your call's
correlation id) and every message carries it as a fourth element,
`{chappe_esl_call, Call, Msg, Ref}`; `chappe_esl_call:ref/1` returns it.

## Run a slow command

`api/2` returns when FreeSWITCH answers, 10 seconds at most. The call process
does not wait with you: your exec timeouts fire, other callers get answers, and
if your process dies the forks stop and the channel is killed.

FreeSWITCH still runs a synchronous `api` on the thread that sends this
connection's events, so a slow one holds back the hangup, DTMF and completions
on the node until it returns. If you need them during a slow command, send it
with `bgapi`, on the connection you gave `start/2`:

```erlang
{ok, _JobUuid} = chappe_esl:bgapi(Conn, ["uuid_broadcast ", Uuid, " /sounds/hold.wav aleg"]).
```

It returns once FreeSWITCH took the command, without its result. If you need the
result, run the command on another connection: `chappe_esl:node_api/2`, or
`chappe_esl:bgapi_await/2` on a connection of your own.

## Without a call process

If your process already controls a connection, `exec/5` waits for one
completion in place. Subscribe to the channel's events first (here an
outbound connection, so the uuid can be `undefined`):

```erlang
ok = chappe_esl:myevents(Conn, plain),
{ok, Event} = chappe_esl_call:exec(Conn, undefined, "answer", "", #{}).
```

Other messages that arrive meanwhile stay in your mailbox.

## Notes

- Applications run one after the other (`event-lock`). A request queued
  behind a long one waits for it; its timeout counts from when you sent it.
- A timeout stops the application with `uuid_break`: at once when it is
  running, or as soon as it starts when it is still queued. Its late
  completion is dropped. `uuid_break` stops media (playback, prompts,
  record); an application that plays nothing, such as `park`, keeps running.
- With `exec/5`, a timed out application that is running gets `uuid_break`;
  one still queued gets `uuid_break <uuid> all`, which also flushes the
  applications queued behind it. Its late completion stays a plain event in
  your mailbox.
- Requests in flight end with `{error, hangup}` at the hangup and
  `{error, closed}` when the connection goes. Later requests return
  `{error, hangup}`.
- When the owner exits before the hangup, the call stops the audio forks
  (with `uuid_audio_fork` or `uuid_audio_stream`, as they were started) and
  session recordings it started, sends `uuid_kill`, and closes the
  connection. Start it with `cleanup => false` to skip this. `stop/1` closes
  the connection and leaves the channel alone.
- An argument longer than 1024 bytes, or with a line break, is sent in the
  sendmsg body.
- Paths and arguments may contain spaces and quotes: the helpers quote and
  escape them where FreeSWITCH splits arguments (record, record_session,
  play_and_get_digits, uuid_record, the fork metadata). With `exec/3,4` you
  pass the argument string as FreeSWITCH reads it.
- `audio_fork_start/3` needs mod_audio_fork, or mod_audio_stream with
  `module => audio_stream`, on the node. Each module allows one fork per
  channel (mod_audio_fork through its default bug name, `audio_fork`).
- Use mod_audio_stream v1.1.0 or newer: earlier versions compare the
  websocket upgrade response headers case-sensitively, so a server sending
  lowercase names fails with "WebSocket upgrade failed" and gets no audio.
- A fork you start with `api/2` instead is not tracked: stop it yourself.
- A fork counts as started as soon as you ask, so an owner dying before
  FreeSWITCH answers still stops it. A refused start takes it back, unless a
  fork of that module was already running.
- Requests from one process run in the order you make them. Requests made at
  the same time from several processes have no set order on the wire.

## Where it lives

- Modules: `chappe_esl_call` (the call process and typed helpers), `chappe_esl_exec` (the execute and its completion wait); why there are two is in the [design overview](../design/overview.md#call-control-why-two-modules)
- Tests: `apps/chappe_esl/test/chappe_esl_call_SUITE.erl`
- Lab: `make interop-esl` (`chappe_esl_live_SUITE`); chappe_mrf drives it in `make interop-mrf`
