# 0001: SIP transactions in sofia-sip nta through a NIF

This record explains why chappe_sip runs sofia-sip's `nta` inside the VM for
UDP, TCP and TLS instead of a transaction layer written in Erlang. Read it
before you touch `apps/chappe_sip/c_src/` or propose to replace the engine.

## Status

Accepted.

## Context

What the repository shows:

- The engine is sofia-sip's nta compiled into
  `priv/lib/chappe_sip_engine_nif.so` behind a plain-C shim with no dialog,
  proxy or offer/answer logic
  ([engine.md](../../apps/chappe_sip/docs/design/engine.md), "Shape").
- The app describes itself as "drachtio ported to Erlang on sofia-sip"
  (`apps/chappe_sip/src/chappe_sip.app.src`), and the overview as
  "drachtio's model on the BEAM"
  (`apps/chappe_sip/docs/design/overview.md`). drachtio-server is built on
  sofia-sip.
- sofia-sip is vendored at a pinned version, as upstream ships it, and
  linked (`AGENTS.md`, `NOTICE`).
- Several nta settings are changed so that Erlang owns merge detection,
  CANCEL handling for proxied INVITEs and stray 2xx routing (`engine.md`,
  "nta settings that differ from a plain UA").
- A full transaction layer in Erlang is possible: the WebSocket transport
  already runs one ([0007](0007-ws-transaction-layer.md)), and performance
  is not what rules it out.

## Decision

Transactions, timers, retransmissions and transports for UDP, TCP and TLS
are sofia-sip's nta, run on one engine thread inside the VM. Everything
above the transaction layer is Erlang. One process, `chappe_sip_engine`,
talks to the NIF.

nta is kept for what it brings without a rewrite:

- the transports: UDP, TCP and TLS connection handling, and RFC 5626
  keepalives and flows;
- RFC 3263 server resolution, with failover between the targets it finds;
- two decades of interop maturity with real SIP equipment.

## Consequences

- A crash in C takes the VM down. That is the cost of the decision, so the
  NIF is held to the safety rules and the tooling in
  [engine.md](../../apps/chappe_sip/docs/design/engine.md) ("Safety rules",
  "How to check"): checked sizes, no silent failure, every argument checked
  at the boundary, a hardened build, and the sanitizers. Every call into it
  is enqueue-only except `start/2` and `stop/1`, which are dirty IO NIFs.
- Building chappe_sip needs a C toolchain, autotools and OpenSSL. Pure
  Erlang work uses the fake engine (`SKIP_ENGINE_BUILD=1`,
  `chappe_sip_engine_fake`).
- We build our own sofia. The vendored tree stays as upstream ships it;
  the fixes we need go as patches in `apps/chappe_sip/c_src/sofia-patches`,
  each with an upstream ticket and a repro, applied to a copy of the tree at
  build time (see its README). A patch is dropped once upstream takes the
  fix.
- The LGPL-2.1 of sofia-sip applies to the vendored copy and to the patches;
  the library we link is a modified sofia-sip, which the LGPL permits
  (`NOTICE`).
- WebSocket is not carried by nta, so a second transaction layer exists in
  Erlang and must stay in step with it
  ([0007](0007-ws-transaction-layer.md)).
- Moving sofia into a separate OS process stays in reserve, if the in-VM
  boundary ever proves impossible to make safe.

## Open questions

None.
