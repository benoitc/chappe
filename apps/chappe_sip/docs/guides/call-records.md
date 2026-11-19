# Call records (CDR)

`chappe_sip_cdr` sends you one record per INVITE call attempt: when it
started, when it rang, when it was answered, when and why it ended. Read
this when you bill calls, feed a call log or a dashboard, or need to know
that every call your node touched has ended.

## When to use it

- You bill answered calls by duration.
- You keep a call log per account or per trunk.
- You alert on calls that end abnormally (an fsm crash, a lost WebSocket).

## Subscribe

```erlang
init() ->
    ok = chappe_sip_cdr:subscribe(self()),
    loop().

loop() ->
    receive
        {chappe_sip_cdr, attempt, #{id := _Id}} -> loop();
        {chappe_sip_cdr, start, #{id := _Id, answered_at := _At}} -> loop();
        {chappe_sip_cdr, stop, Record} -> store(Record), loop()
    end.
```

Each record comes three times, with the same `id`:

- `attempt`: the INVITE arrived or went out.
- `start`: the call was answered (a 2xx). A call never answered has none.
- `stop`: the attempt or the call is over. Every attempt gets exactly one.

The subscriber is monitored: when it exits it is dropped. With no subscriber
the stack opens no record at all. A subscriber that joins mid-call gets the
calls that start after it.

## What a record holds

| Field | Value |
| --- | --- |
| `id` | a unique hex binary |
| `role` | `uas`, `uac`, `b2b_a`, `b2b_b`, `proxy` |
| `call_id`, `from`, `to`, `request_uri` | from the INVITE |
| `local_tag`, `remote_tag` | the dialog tags, ours and the peer's |
| `transport`, `source` | how an inbound INVITE came, and from where |
| `attempt_at`, `ringing_at`, `answered_at`, `ended_at` | `erlang:system_time(millisecond)`, `undefined` when it did not happen |
| `final_status` | the INVITE's final status (`200`, `486`, ...) |
| `reason` | why it ended (stop only) |
| `link` | for a b2bua leg, the `id` of the other leg |
| `call_ref` | the call's ref, shared by every record of the call ([follow a call](follow-a-call.md)) |
| `related` | the `call_ref` of the call a transfer brought this leg from, else `undefined` |

Billable duration is `ended_at - answered_at`.

## Why a call ended

| `reason` | Meaning |
| --- | --- |
| `{bye, local}` | your side sent the BYE |
| `{bye, remote}` | the peer sent the BYE (or, for a proxy, a BYE passed through) |
| `cancel` | the caller CANCELled before the answer |
| `{final, Status}` | the INVITE got this non-2xx final |
| `timeout` | `create_uac/2` gave up, or an in-dialog request got 408 |
| `no_ack` | the 2xx we sent was never ACKed |
| `session_expired`, `{refresh_failed, S}` | the session timer ended it (RFC 4028) |
| `engine_restart` | the SIP stack went away (`chappe_sip:stop/0`, an engine restart or a degrade) |
| `owner_down` | the process that owned the call exited |
| `flow_lost` | the WebSocket connection of the call closed |
| `unknown` | a proxied call whose end the proxy cannot see |
| `{process_down, Why}` | the process driving the call exited without saying why (a crash, a kill, a supervisor shutdown) |

## Roles

- `uas`: an INVITE your handler answers (`create_uas/3`, or a reject on
  `Res`).
- `uac`: an INVITE you send (`create_uac/2`, `chappe_sip_uac:start/2`).
- `b2b_a` and `b2b_b`: the two legs of `create_b2bua/4`, each naming the
  other in `link`. The A leg's `attempt` still says `uas`: the role is
  known once your handler bridges it.
- `proxy`: an INVITE you pass to `proxy_request/3`. Its `attempt` also says
  `uas`. A record-routed call (`record_route => true`) stops when its BYE
  passes through, or after `record_route_ttl_s` with reason `unknown` when no
  BYE ever does. Without Record-Route the proxy does not see the end of the
  call: the record stops at the answer with reason `unknown`.

## Notes

- The records are kept by one process that monitors whatever drives each
  call (the request worker, the UAC fsm, the dialog fsm). A driver that dies
  before it ended its record (`kill`, a supervisor shutdown) ends it with
  `{process_down, Why}`, so a stop is never lost and never sent twice.
- `chappe_sip_cdr:open_records/0` lists the calls not ended yet.
- Events are plain messages; ship them to your billing store from your
  subscriber, not from a SIP handler.

## Where it lives

- Modules: `chappe_sip_cdr` (fed by the dialog and UAC fsms, the B2BUA and
  the proxy).
- Tests: `chappe_sip_cdr_SUITE`.
- Lab: none.
