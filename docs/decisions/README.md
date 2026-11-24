# Decisions

These records explain why a boundary in chappe is where it is, and what
moving it would cost. Read the one that covers a boundary before you change
it, or when a rule in `AGENTS.md` or `CONTRIBUTING.md` looks arbitrary.

Each record has a status, the context, the decision, its consequences and
the questions still open. A reason the repository does not give is listed
under Open questions, never written as a fact.

A date is the day of the maintainer's decision. "Records the code" means
the record writes down a boundary the merged code already holds.

| # | Decision | Status |
|---|---|---|
| [0001](0001-sofia-nta-nif.md) | SIP transactions in sofia-sip nta through a NIF | Accepted |
| [0002](0002-one-process-per-call.md) | One process per call | Accepted (2026-11-17) |
| [0003](0003-leaf-apps.md) | Leaf apps take no SIP dependency | Accepted (2026-11-17) |
| [0004](0004-rtpengine-external.md) | rtpengine stays an external daemon | Accepted (2026-11-17) |
| [0005](0005-chappe-mix.md) | chappe_mix exists next to FreeSWITCH conferences | Accepted (2026-11-17) |
| [0006](0006-mrf-orchestration-app.md) | chappe_mrf is an orchestration app | Accepted (2026-11-17) |
| [0007](0007-ws-transaction-layer.md) | WebSocket has its own Erlang transaction layer | Accepted (2026-11-17) |
| [0008](0008-remote-app-model.md) | The remote-app model | Planned (2026-11-17) |
| [0009](0009-srtp-in-erlang.md) | SRTP is decrypted in Erlang where chappe receives media itself | Accepted (2026-11-14) |
| [0010](0010-cluster-ownership.md) | One Ra group per region owns what needs one owner | Accepted (2026-11-15) |
| [0011](0011-chappe-audio-leaf.md) | chappe_audio is a leaf app with a store behaviour, and takes in recorded RTP | Accepted, records the code |
| [0012](0012-siprec-srs.md) | A SIPREC recording server: SIP in chappe_sip, audio in chappe_audio | Accepted (2026-11-17) |
| [0013](0013-call-ref-lookup.md) | Calls are found across nodes through `call_ref` on pg, not owned | Accepted, records the code |
| [0014](0014-optional-siblings.md) | chappe_cluster and chappe_audio are optional siblings | Accepted, records the code |
| [0015](0015-location-behaviour.md) | Registrar bindings sit behind a location behaviour; cross-node calls go through the edge node | Accepted (2026-11-17) |
| [0016](0016-security-defaults.md) | Security defaults | Accepted, records the code |
| [0017](0017-chappe-mix-16khz-l16.md) | A chappe_mix room runs at 8 or 16 kHz, on L16 at 16 kHz | Accepted (2026-11-24) |

## Add a record

1. Copy the shape of an existing record: Status, Context, Decision,
   Consequences, Open questions.
2. Number it after the last one, and add it to the table above.
3. Cite a path for every fact. A reason you cannot cite is an open question.

## Read this next

- [Architecture](../architecture.md): the boundaries these records defend.
