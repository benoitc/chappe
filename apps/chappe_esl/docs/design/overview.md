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

## Connection states

`chappe_esl_conn` uses `state_functions` mode and keeps its state in a `#data{}`
record.

- Inbound: `authenticating` answers the auth/request with the password and waits
  for +OK, then enters `ready`.
- Outbound: `accepting` sends `connect`, reads the channel data, starts the
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
`{chappe_esl_closed, Conn}`. Inbound connections link to the connecting process;
outbound handlers link to their connection.
