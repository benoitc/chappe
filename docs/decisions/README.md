# Decisions

These records explain why a boundary in chappe is where it is, and what
moving it would cost. Read the one that covers a boundary before you change
it, or when a rule in `AGENTS.md` or `CONTRIBUTING.md` looks arbitrary.

Each record has a status, the context, the decision, its consequences and
the questions still open. A record marked "Proposed, to confirm by the
maintainer" states only what the repository shows; its reason is still a
question for the maintainer.

| # | Decision | Status |
|---|---|---|
| [0001](0001-sofia-nta-nif.md) | SIP transactions in sofia-sip nta through a NIF | Proposed, to confirm by the maintainer |
| [0002](0002-one-process-per-call.md) | One process per call | Proposed, to confirm by the maintainer |
| [0003](0003-leaf-apps.md) | Leaf apps take no SIP dependency | Accepted as a rule (`AGENTS.md`); reason to confirm by the maintainer |
| [0004](0004-rtpengine-external.md) | rtpengine stays an external daemon | Proposed, to confirm by the maintainer |
| [0005](0005-chappe-mix.md) | chappe_mix exists next to FreeSWITCH conferences | Proposed, to confirm by the maintainer |
| [0006](0006-mrf-orchestration-app.md) | chappe_mrf is an orchestration app | Accepted as a rule (`AGENTS.md`); reason to confirm by the maintainer |
| [0007](0007-ws-transaction-layer.md) | WebSocket has its own Erlang transaction layer | Proposed, to confirm by the maintainer |
| [0008](0008-remote-app-model.md) | The remote-app model | Open: the repository contradicts itself |

## Add a record

1. Copy the shape of an existing record: Status, Context, Decision,
   Consequences, Open questions.
2. Number it after the last one, and add it to the table above.
3. Cite a path for every fact. A reason you cannot cite is an open question.

## Read this next

- [Architecture](../architecture.md): the boundaries these records defend.
