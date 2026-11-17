# 0002: One process per call

This record explains why every inbound request, dialog and outbound
transaction in chappe_sip is a process of its own, and why your handler may
block for the life of a call. Read it before you add an API that takes an
`owner` or a `notify` process, or before you move call state into a shared
server.

## Status

Accepted (the maintainer's decision, 2026-11-17).

## Context

What the repository shows:

- "A call is a process": each inbound out-of-dialog request runs in its own
  `chappe_sip_request_worker`, each dialog is a `chappe_sip_dialog_fsm`, and
  each outbound transaction a `chappe_sip_uac_fsm`
  (`apps/chappe_sip/docs/design/overview.md`, line 32, and the moduledoc of
  `apps/chappe_sip/src/conn/chappe_sip_request_worker.erl`).
- A worker that exits without a final response makes the engine answer 500
  (same moduledoc).
- Dialogs, media sessions, mixer rooms, rtpengine sessions and chappe_mrf
  endpoints are bound to an owner process and end when it dies (moduledocs
  of `chappe_sip_dialog`, `chappe_rtpengine_session`, `chappe_mix`,
  `chappe_mrf`).
- The leaf apps follow the same shape: one rtpengine session per call
  (`chappe_rtpengine_session_sup`), one mixer process per room
  (`chappe_mix_conf_sup`), one `chappe_esl_call` per FreeSWITCH channel.

## Decision

A call, and each of its parts, is an Erlang process. The application's code
runs in the request worker and owns what it creates. Ownership is explicit:
the `owner` receives events and takes the resource down with it, a `notify`
process only receives events.

## Consequences

- A crash ends one call, not the stack.
- Handlers are plain sequential code that can block (a `receive`,
  `chappe_sip_dialog:wait/1`) without holding anything else up.
- Handing a call to another process means moving ownership
  (`chappe_sip_dialog:set_owner/2`, `chappe_sip_b2b:relay_async/2`).
- The cap on concurrent requests is a process count
  (`max_request_workers`), answered with 503 when reached.

## Open questions

None.
