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
- `execute/3,4` (sendmsg execute with event-lock), `sendmsg/3` (headers only)
  and `sendmsg/4` (headers and a body, Content-Length added).
- `filter/2`, `sendevent/3` and `sendevent/4` (with a body).
- `myevents/2,3` (one channel's events), `nixevent/2` and `noevents/1`.
- A command on a connection that is gone returns `{error, closed}`.
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
- Node registry (`node_add/2`, `node_remove/1`, `nodes/0`, `node_status/1`):
  one supervised connection per FreeSWITCH node, reconnect with exponential
  backoff and jitter, load from HEARTBEAT and channel events, health probes
  (`status`, `show calls count`, `sofia status`), heartbeat timeout. Nodes
  also load from the `nodes` app env.
- Node selection (`node_select/1`) by fewest sessions, most idle CPU or
  weight, skipping nodes that are down, drained (`node_drain/1`) or full,
  filtered by tags.
- `node_api/2` and `node_bgapi/2` on a node's connection; up, down, draining
  and load notices (`node_subscribe/1`) and the node's events
  (`node_events/1`).
- Requirement catalogue in `docs/compliance/requirements.tsv`.

## Roadmap

- Commands without an API yet: `divert_events`, `resume`, `log`, `nolog`,
  `exit`, and `userauth` login. Send them today only by building the bytes
  yourself.
- `bgapi_await/2,3` gaps: it subscribes with `event plain`, which switches the
  connection's event format; it never unsubscribes BACKGROUND_JOB; it cannot
  send a caller-chosen `Job-UUID`.
- TLS event socket connections.
- Structured decoding of event-xml (currently kept raw).
- Automatic reconnect for connections opened with `connect/1` (the node
  registry reconnects its own).
