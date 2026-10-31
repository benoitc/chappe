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
- `chappe_esl_call` is typed call control: one process per channel that
  owns a connection, runs dialplan applications and waits for their end,
  and turns the channel's events into messages for its owner.
- `chappe_esl_exec` is the wire side of `chappe_esl_call`: the `sendmsg`
  execute with an `Event-UUID`, the wait for its completion, `uuid_break`,
  and the quoting of arguments FreeSWITCH splits on spaces.

## Supervision

```
chappe_esl_sup (one_for_one)
|-- chappe_esl_outbound_sup     handler pool for accepted outbound sockets
|-- {chappe_esl_listener, Ref}  one per start_listener/3, added at run time
`-- chappe_esl_nodes            node registry, only when nodes exist
    `-- chappe_esl_node         one per FreeSWITCH node
```

Inbound connections from `chappe_esl:connect/1` are not supervised: each
`chappe_esl_conn` is linked to its controlling process. Call processes
(`chappe_esl_call:start/1,2`) are started by their owner, not by a
supervisor.

## One connection FSM for both directions

Inbound (you dial FreeSWITCH on 8021) and outbound (the dialplan `socket`
application dials you) differ only in how a connection starts. After the
handshake, both read the same frames, correlate replies the same way and
deliver the same events. So one module, `chappe_esl_conn`, runs both: the
start state is `authenticating` for inbound and `accepting` for outbound,
and both converge on `ready` (see "Connection states" below). Plan finding
M15 keeps a split by mode as an option if one side grows.

## Call control: why two modules

`chappe_esl_call` and `chappe_esl_exec` together implement one idea:
"run this application on this channel and tell me when it is done". The
split is by size and by caller, not by concept (plan finding M14):

- `chappe_esl_exec` holds the stateless wire steps. `exec/5` runs in the
  connection's controlling process and waits there for the
  `CHANNEL_EXECUTE_COMPLETE` whose `Application-UUID` matches the
  `Event-UUID` it sent, so a completion is matched to its own request even
  when several are in flight.
- `chappe_esl_call` is the process: it becomes the controlling process of
  the connection, subscribes to the channel's events (`myevents` outbound,
  a `Unique-ID` filter inbound), keeps the requests waiting on completions,
  and sends its owner `{chappe_esl_call, Call, Msg}`: `{dtmf, Digit}`,
  `{hangup, Cause}`, `{complete, App, Event}`, `{event, Event}`, `closed`.

When the owner dies before the channel hangs up, the call process stops the
audio forks and session recordings it started, kills the channel with
`uuid_kill` and closes the connection. Read both modules together when you
change how a command completes.

## The node registry

`chappe_esl_nodes` owns a named ETS table, `chappe_esl_nodes`, created in
its `init/1` so it lives as long as the registry. Each `chappe_esl_node`
writes its own row; `node_status/1`, `node_select/1` and `node_api/2` read
it without calling the node process. Notices (`{chappe_esl_node, Name,
up | down | draining | {load, Load}}`, and `{event, Event}` for event
subscribers) go through a `pg` scope (`chappe_esl_nodes_pg`) whose groups
are keyed by node name (or `all`), so a subscription does not depend on
the node process that sends to it. The registry starts with the
`nodes` app env, or on the first `chappe_esl:node_add/2`.

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

## Why it takes no SIP dependency

chappe_esl is a leaf app: it depends on nothing else in the umbrella and is
published on its own. The rule and its reasons are recorded in
[decision 0003](../../../../docs/decisions/0003-leaf-apps.md). Settings are
listed in [Configuration](../configuration.md).

## Where it lives

- Code: `apps/chappe_esl/src/`
- Tests: eunit `chappe_esl_parser_tests` (frames split at every byte),
  `chappe_esl_event_tests`; suites `chappe_esl_conn_SUITE`,
  `_outbound_SUITE`, `_call_SUITE`, `_nodes_SUITE` against
  `chappe_esl_fake_server`
- Lab: `make interop-esl` (`chappe_esl_live_SUITE` against FreeSWITCH in
  docker, `apps/chappe_esl/interop/`); `make demo-esl` for two monitored
  nodes
