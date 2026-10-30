# 0008: The remote-app model

This record is about serving applications that run outside the SIP node's
VM (on other Erlang nodes, or in any language over a control socket, as
drachtio does). The repository says three different things about it. Read
this before you plan work on the route table, `chappe_sip_res`, dialog
ownership, or a control protocol.

## Status

Open. The repository contradicts itself; the maintainer has to say which
statement holds.

## Context

The three statements:

| Where | Says | Date |
|---|---|---|
| [`apps/chappe_sip/docs/plan.md`](../../apps/chappe_sip/docs/plan.md), M15 | "Dropped: the original external control-protocol M15 (re-adds the process boundary the design removed)." | closed 2026-07-15 |
| [`apps/chappe_sip/docs/design/remote-app.md`](../../apps/chappe_sip/docs/design/remote-app.md) | Titled "(draft)", "No code exists for it yet". Its "Decisions" section, "Recorded on 2026-10-03 after review", says the phases ship in order (Phase 0 in-node groundwork, then a control socket, outbound connect, an Erlang distribution client) and that remote clients are separate hex packages. Seven open questions remain. | 2026-10-03 |
| [`apps/chappe_sip/docs/features.md`](../../apps/chappe_sip/docs/features.md), "Planned" | "Multi-app / outbound connection model ... We embed the stack in the node, so a remote-app split and outbound cloud-scaling are not available yet." | undated |

The plan dropped a control protocol on the grounds of the process boundary;
the later draft records a decision to build one; the feature tracker lists
it as planned. None of the three links the others. No code for it exists in
`apps/chappe_sip/src/`.

## Decision

None recorded here. Until the maintainer answers, treat the in-node model
as the only supported one: applications run in the SIP node's VM and
register handlers with `chappe_sip:handle/2,3`.

## Consequences

- Whichever answer holds, the other two documents need a line pointing here.
- If the draft holds, its Phase 0 (route match rules, the proxy form of
  `chappe_sip_res`, dialog orphaning and `attach/2`, opaque handles) changes
  public APIs in chappe_sip and needs its own plan.
- If the plan's "dropped" holds, `remote-app.md` should be marked rejected
  and the "Planned" entry removed.

## Open questions

- Which is true now? Keep as draft, mark rejected, or delete?
