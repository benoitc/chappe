# Design overview

This explains how chappe_esl is built so you can read the code or extend it. Start
here before changing the parser or the connection state machine.

## Scope

chappe_esl speaks the FreeSWITCH Event Socket wire protocol. It has no SIP, media,
or engine concepts and no runtime dependencies beyond kernel and stdlib. Event
JSON is decoded with the OTP `json` module.

## Modules

- `chappe_esl` is the public API. It builds command bytes and delegates to the
  connection process.
- `chappe_esl_parser` is a pure streaming frame decoder. It buffers bytes, splits the
  header block at the blank line, then reads exactly Content-Length body bytes.
  It never throws and returns partial state when a frame is incomplete.
- `chappe_esl_event` classifies a decoded frame by Content-Type and turns event frames
  into an event map with a decoded body.
- `chappe_esl_conn` is one gen_statem per connection that owns the TCP socket. It runs
  the states below, feeds bytes to `chappe_esl_parser`, correlates replies, and
  delivers events.
- `chappe_esl_inbound` opens an inbound connection and waits for authentication.
- `chappe_esl_outbound_sup`, `chappe_esl_listener`, and `chappe_esl_handler` implement the outbound
  listener and its per-channel handler contract.
- `chappe_esl_app` and `chappe_esl_sup` are the OTP application and root supervisor.
- `chappe_esl_nodes` is the node registry: a supervisor, started only when
  nodes exist, that owns the node ETS table and the pg scope for notices.
  `chappe_esl_node` is one gen_statem per FreeSWITCH node; it is the
  controlling process of the node's `chappe_esl_conn`.

## Node states

`chappe_esl_node` runs `connecting`, `up` and `down`, and shows `draining`
for an up node that was drained. A node is up after login, the event
subscription and one passing round of probes. It goes down on a closed
socket, a failed probe, or no HEARTBEAT for twice the heartbeat interval; it
closes the connection and retries after an exponential backoff with jitter.
Probes run in a separate process so a slow node never blocks the node
process. Every change is written to the node's ETS row before the notice is
sent, so a subscriber that reads `node_status/1` on a notice sees the new
state. Readers (`node_status`, `node_select`, `node_api`) read ETS and never
call the node process.

## Connection states

`chappe_esl_conn` uses `state_functions` mode and keeps its state in a `#data{}`
record.

- Inbound: `authenticating` answers the auth/request with the password and waits
  for +OK, then enters `ready`.
- Outbound: `accepting` sends `connect`, reads the channel data, sends
  `linger` (unless disabled; its reply is consumed internally), starts the
  handler process, then enters `ready`.
- `ready` classifies each frame. command/reply and api/response answer the
  oldest unanswered command (FreeSWITCH replies in order, so a FIFO queue
  correlates them). Every text/event-* frame is delivered to the owner process.

## Framing

TCP delivers an arbitrary byte stream. `chappe_esl_parser:feed/2` appends new bytes to
its buffer and peels off every complete frame, keeping trailing partial bytes
for the next call. The parser is the highest-risk component and is tested by
feeding real frames split at every byte boundary.

## Failure handling

Bad input from the socket is logged, never thrown. A closed socket answers every
pending caller with `{error, closed}` and notifies the owner with
`{chappe_esl_closed, Conn}`. A framing error (a Content-Length that is not a
non-negative integer, or a frame over `max_frame_bytes`) is handled the same
way after the frames parsed before it; during authentication it fails
connect with `{protocol_error, Reason}`. A request that times out returns
`{error, timeout}` and keeps its FIFO slot, so its late reply is dropped.
Inbound connections link to the controlling process (the link follows
`set_controlling_process/2`); outbound handlers link to their connection.
A connection that cannot reach FreeSWITCH returns
`{error, {connect_failed, Reason}}` from `connect/1` without killing the
caller, and a command on a connection that is gone returns
`{error, closed}`.
