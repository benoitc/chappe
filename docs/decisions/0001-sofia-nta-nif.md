# 0001: SIP transactions in sofia-sip nta through a NIF

This record explains why chappe_sip runs sofia-sip's `nta` inside the VM for
UDP, TCP and TLS instead of a transaction layer written in Erlang. Read it
before you touch `apps/chappe_sip/c_src/` or propose to replace the engine.

## Status

Proposed, to confirm by the maintainer.

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
- sofia-sip is vendored at a pinned version, kept unmodified and linked
  (`AGENTS.md`, `NOTICE`).
- Several nta settings are changed so that Erlang owns merge detection,
  CANCEL handling for proxied INVITEs and stray 2xx routing (`engine.md`,
  "nta settings that differ from a plain UA").

## Decision

Transactions, timers, retransmissions and transports for UDP, TCP and TLS
are sofia-sip's nta, run on one engine thread inside the VM. Everything
above the transaction layer is Erlang. One process, `chappe_sip_engine`,
talks to the NIF.

## Consequences

- A crash in C takes the VM down. The NIF is kept small, checked under
  AddressSanitizer (`make asan`), and every call into it is enqueue-only
  except `start/2` and `stop/1`, which are dirty IO NIFs.
- Building chappe_sip needs a C toolchain, autotools and OpenSSL. Pure
  Erlang work uses the fake engine (`SKIP_ENGINE_BUILD=1`,
  `chappe_sip_engine_fake`).
- The LGPL-2.1 of sofia-sip applies to the vendored copy.
- WebSocket is not carried by nta, so a second transaction layer exists in
  Erlang and must stay in step with it
  ([0007](0007-ws-transaction-layer.md)).

## Open questions

- Why not a pure-Erlang transaction layer: maturity, RFC coverage,
  performance?
