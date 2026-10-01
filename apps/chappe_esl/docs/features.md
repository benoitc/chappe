# Features

What chappe_esl does today, and what is planned. Use this to see whether a
capability exists before you reach for it.

## Current

- Inbound connect and authenticate against `mod_event_socket`. A refused
  password returns `{error, {auth_failed, ReplyText}}`; an ACL rejection
  (text/rude-rejection) returns `{error, {rejected, Text}}`.
- `api/2,3` (synchronous, returns the response body). A body starting with
  `-ERR` returns `{error, Text}`; no reply within the timeout returns
  `{error, timeout}` without exiting the caller.
- `bgapi/2` (returns a Job-UUID) and `bgapi_await/2,3` (waits for the
  BACKGROUND_JOB result).
- `subscribe/2` and `events/3` (plain, json, xml formats).
- `execute/3,4` (sendmsg execute with event-lock) and `sendmsg/3` (headers only).
- `filter/2` and `sendevent/3` (headers only).
- Event delivery to a controlling process as `{chappe_esl_event, Conn, Event}`,
  with a changeable controlling process. On inbound connections the link moves
  to the new controlling process.
- Log frames delivered as `{chappe_esl_log, Conn, Headers, Body}` when
  FreeSWITCH sends them (there is no `log` command API yet, see Roadmap).
- Per-connection counters via `stats/1`.
- Outbound listener with a per-channel `chappe_esl_handler` behaviour and channel
  data on connect. `linger` is sent after `connect` by default
  (`start_listener/4` with `#{linger => false | Seconds}` to change it). A
  disconnect notice with Content-Disposition `linger` is delivered as
  `{chappe_esl_linger, Conn}`, any other as `{chappe_esl_disconnect, Conn}`.
- Streaming frame parser tolerant of arbitrary TCP chunking. A Content-Length
  that is not a non-negative integer, or a frame over `max_frame_bytes`, closes
  the connection.
- Event decoding: command/reply, api/response, text/event-plain (URL-decoded),
  text/event-json, text/event-xml (raw body), text/disconnect-notice, log/data,
  text/rude-rejection.
- Requirement catalogue in `docs/compliance/requirements.tsv`.

## Roadmap

- Commands without an API yet: `myevents`, `nixevent`, `noevents`,
  `divert_events`, `resume`, `log`, `nolog`, `exit`, and `userauth` login.
  Send them today only by building the bytes yourself.
- Bodies on `sendmsg/3` and `sendevent/3` (both send headers only, no
  Content-Length body).
- `bgapi_await/2,3` gaps: it subscribes with `event plain`, which switches the
  connection's event format; it never unsubscribes BACKGROUND_JOB; it cannot
  send a caller-chosen `Job-UUID`.
- TLS event socket connections.
- Structured decoding of event-xml (currently kept raw).
- Automatic reconnect for inbound connections.
