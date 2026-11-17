# 0013: Calls are found across nodes through `call_ref` on pg, not owned

This record explains why a call is found from any node of a cluster by its
`call_ref` through `pg`, and why that needs no lease or consensus, unlike
the resources of [0010](0010-cluster-ownership.md). Read it before you make
something findable across nodes, or before you put a call into
chappe_cluster.

## Status

Accepted. It records the code as merged.

## Context

What the repository shows:

- A call gets one `call_ref`, an opaque binary made when its first request
  arrives (`chappe_sip_call:new_ref/0`, 12 random bytes in hex) or given by
  the app, carried on every leg as `X-Chappe-Call` (moduledoc of
  `apps/chappe_sip/src/core/chappe_sip_call.erl`).
- A process that serves the call (the B2BUA, a dialog, the rtpengine
  session, a SIPREC recording) joins the pg group `{chappe_sip_call, Ref}`
  of the `chappe_sip` scope while it does, and a node-local table keeps the
  handle it serves under (`chappe_sip_call:join/3,4`). The scope is started
  by `chappe_sip_sup` (child `chappe_sip_pg`), so it lives and stops with
  the app.
- `chappe_sip_call:lookup/1,2` reads the group's member nodes, asks each
  for its local handles (`erpc:call/5`, 5 s), and leaves out a node that
  does not answer. `chappe_sip:calls/1` is the public form.
- A lookup can be briefly stale: a process that just ended may still be
  listed, and its handle then answers `{error, noproc}`; a process that just
  joined on another node may not be listed yet
  ([follow-a-call.md](../../apps/chappe_sip/docs/guides/follow-a-call.md),
  "Notes"; `lookup/2`).
- [0010](0010-cluster-ownership.md): "`pg` is eventually consistent: it
  finds things, it cannot make one of them the only one."
- The same shape finds chappe_audio streams (its own `chappe_audio` scope,
  `chappe_audio:streams/1`) and message-waiting subscribers
  (`chappe_sip_mwi`, the `chappe_sip_mwi` group).

## Decision

- A call is found, not owned. Its processes join a pg group named after
  its `call_ref`, and any node asks the members' nodes for their handles.
- Each part of a call keeps the owner it already has, a local process
  ([0002](0002-one-process-per-call.md)). Nothing in the cluster decides
  which node serves a call.
- A lookup may be stale for a moment; callers treat a handle that answers
  `{error, noproc}` as gone.

## Consequences

- Finding a call needs no chappe_cluster and works on any connected nodes,
  with or without the `cluster` setting.
- A lookup costs one remote call per node that serves the call, bounded by
  5 s each. The guide offers it to find a call again from an operator
  console, another node, or a billing or capture search
  ([follow-a-call.md](../../apps/chappe_sip/docs/guides/follow-a-call.md)).
- Something that must exist once in the cluster (a room, a binding, a
  singleton job) goes through chappe_cluster
  ([0010](0010-cluster-ownership.md)), not through pg.

## Open questions

None.
