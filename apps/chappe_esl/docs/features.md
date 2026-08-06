# Features

What chappe_esl does today, and what is planned. Use this to see whether a
capability exists before you reach for it.

## Current

- Inbound connect and authenticate against `mod_event_socket`.
- `api/2,3` (synchronous, returns the response body).
- `bgapi/2` (returns a Job-UUID) and `bgapi_await/2,3` (waits for the
  BACKGROUND_JOB result).
- `subscribe/2` and `events/3` (plain, json, xml formats).
- `execute/3,4` (sendmsg execute with event-lock) and `sendmsg/3`.
- `filter/2` and `sendevent/3`.
- Event delivery to a controlling process as `{chappe_esl_event, Conn, Event}`, with a
  changeable controlling process.
- Per-connection counters via `stats/1`.
- Outbound listener with a per-channel `chappe_esl_handler` behaviour, plus linger via
  the handler lifecycle and channel data on connect.
- Streaming frame parser tolerant of arbitrary TCP chunking.
- Event decoding: command/reply, api/response, text/event-plain (URL-decoded),
  text/event-json, text/event-xml (raw body), text/disconnect-notice, log/data.

## Roadmap

- TLS event socket connections.
- Structured decoding of event-xml (currently kept raw).
- Automatic reconnect for inbound connections.
