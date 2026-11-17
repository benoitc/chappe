# 0008: The remote-app model

This record is about serving applications that run outside the SIP node's
VM (on other Erlang nodes, or in any language over a control socket, as
drachtio does). Read this before you plan work on the route table,
`chappe_sip_res`, dialog ownership, or a control protocol.

## Status

Planned (the maintainer's decision, 2026-11-17).

## Context

The repository said three different things about it:

| Where | Says | Date |
|---|---|---|
| [`apps/chappe_sip/docs/history/plan.md`](../../apps/chappe_sip/docs/history/plan.md), M15 | "Dropped: the original external control-protocol M15 (re-adds the process boundary the design removed)." | closed 2026-07-15 |
| [`apps/chappe_sip/docs/design/remote-app.md`](../../apps/chappe_sip/docs/design/remote-app.md) | Titled "(draft)", "No code exists for it yet". Its "Decisions" section, "Recorded on 2026-10-03 after review", says the phases ship in order and that remote clients are separate hex packages. | 2026-10-03 |
| [`apps/chappe_sip/docs/features.md`](../../apps/chappe_sip/docs/features.md), "Planned" | A remote-app model, "a draft design, not implemented". | undated |

No code for it exists in `apps/chappe_sip/src/`. Applications run in the SIP
node's VM and register handlers with `chappe_sip:handle/2,3`.

## Decision

- [`remote-app.md`](../../apps/chappe_sip/docs/design/remote-app.md) is the
  plan. Its phases ship in the order of its "Recommendation":
  1. Phase 0, in-node groundwork: the route table with match rules, the
     proxy form of `chappe_sip_res`, dialog orphaning and `attach/2`,
     opaque handles;
  2. Phase 1, a control socket that apps connect in to;
  3. Phase 2, outbound connect;
  4. Phase 3, an Erlang distribution client.
- Until Phase 0 ships, the in-node model is the only supported one: you
  register your handlers with `chappe_sip:handle/2,3` in the SIP node.
- The 2026-07 "Dropped" in `history/plan.md` is superseded by this record.
  The history page stays as it was written.

## Consequences

- `remote-app.md` and the "Planned" entry of
  [`features.md`](../../apps/chappe_sip/docs/features.md) each point to this
  record.
- Phase 0 changes public APIs of chappe_sip (route match rules,
  `chappe_sip_res`, dialog ownership), so it gets its own phase plan before
  any code.
- Remote clients are separate hex packages, not modules of chappe_sip
  (`remote-app.md`, "Decisions").

## Open questions

- The seven open questions left in `remote-app.md` ("Open questions", 3 to
  9: orphaned dialogs, owner epoch fencing in-node, media exposed
  remotely, middleware, shared secrets across SIP nodes, pooled outbound
  connections, CDR, HEP and presence on the socket). Each is settled in
  the plan of the phase it belongs to.
