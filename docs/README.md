# Documentation map

This page lists every document in the repository, by who you are and by the
question you have. Use it when the root [README](../README.md) is not enough
and you want the one page that answers your question. User guides live with
their app, because each app is published on its own; pages that span apps
live here in `docs/`.

## Start here

- New to chappe: [README](../README.md), then [Concepts](concepts.md), then
  [Architecture](architecture.md).
- Want to see it work: [the demo SBC](../demo/sbc/README.md) (`make demo`).
- Want to build a service: [Getting started with chappe_sip](../apps/chappe_sip/docs/guides/getting-started.md).
- Want to change the code: [CONTRIBUTING](../CONTRIBUTING.md), then
  [Navigation](navigation.md).
- Porting a drachtio app: [drachtio parity](drachtio-parity.md), then the
  [drachtio mapping](../apps/chappe_mrf/docs/drachtio-mapping.md).

## By reader

### You build a voice service on chappe

| App | Index | Guides |
|---|---|---|
| chappe_sip | [docs index](../apps/chappe_sip/docs/README.md), [README](../apps/chappe_sip/README.md) | [getting started](../apps/chappe_sip/docs/guides/getting-started.md), [answer calls](../apps/chappe_sip/docs/guides/answer-calls.md), [originate calls](../apps/chappe_sip/docs/guides/originate-calls.md), [B2BUA](../apps/chappe_sip/docs/guides/b2bua.md), [B2BUA re-INVITE](../apps/chappe_sip/docs/guides/b2bua-reinvite.md), [B2BUA forking](../apps/chappe_sip/docs/guides/b2bua-forking.md), [B2BUA call control](../apps/chappe_sip/docs/guides/b2bua-call-control.md), [SBC](../apps/chappe_sip/docs/guides/sbc.md), [proxy](../apps/chappe_sip/docs/guides/proxy.md), [registrar](../apps/chappe_sip/docs/guides/registrar.md), [register to a carrier](../apps/chappe_sip/docs/guides/register-to-a-carrier.md), [authentication](../apps/chappe_sip/docs/guides/authentication.md), [protect the edge](../apps/chappe_sip/docs/guides/protect-the-edge.md), [WebSocket](../apps/chappe_sip/docs/guides/websocket.md), [TLS](../apps/chappe_sip/docs/guides/tls.md), [reliable provisionals](../apps/chappe_sip/docs/guides/reliable-provisionals.md), [session timers](../apps/chappe_sip/docs/guides/session-timers.md), [subscriptions](../apps/chappe_sip/docs/guides/subscriptions.md), [presence](../apps/chappe_sip/docs/guides/presence.md), [REFER](../apps/chappe_sip/docs/guides/refer.md), [conference focus](../apps/chappe_sip/docs/guides/conference-focus.md), [media](../apps/chappe_sip/docs/guides/media.md), [call records](../apps/chappe_sip/docs/guides/call-records.md), [capture](../apps/chappe_sip/docs/guides/capture.md), [metrics](../apps/chappe_sip/docs/guides/metrics.md), [configuration](../apps/chappe_sip/docs/guides/configuration.md), [deployment](../apps/chappe_sip/docs/guides/deployment.md), [interop testing](../apps/chappe_sip/docs/guides/interop-testing.md) |
| chappe_rtpengine | [README](../apps/chappe_rtpengine/README.md) | [getting started](../apps/chappe_rtpengine/docs/guides/getting-started.md), [sessions](../apps/chappe_rtpengine/docs/guides/sessions.md), [nodes](../apps/chappe_rtpengine/docs/guides/nodes.md), [media features](../apps/chappe_rtpengine/docs/guides/media-features.md), [subscriptions](../apps/chappe_rtpengine/docs/guides/subscriptions.md), [testing](../apps/chappe_rtpengine/docs/guides/testing.md) |
| chappe_mix | [README](../apps/chappe_mix/README.md) | [run a conference](../apps/chappe_mix/docs/guides/conference.md) |
| chappe_esl | [README](../apps/chappe_esl/README.md) | [getting started](../apps/chappe_esl/docs/guides/getting-started.md), [inbound](../apps/chappe_esl/docs/guides/inbound.md), [outbound](../apps/chappe_esl/docs/guides/outbound.md), [events](../apps/chappe_esl/docs/guides/events.md), [call control](../apps/chappe_esl/docs/guides/call-control.md), [nodes](../apps/chappe_esl/docs/guides/nodes.md), [select a node](../apps/chappe_esl/docs/guides/select-node.md), [testing](../apps/chappe_esl/docs/guides/testing.md) |
| chappe_audio | [README](../apps/chappe_audio/README.md) | [take audio from a fork](../apps/chappe_audio/docs/guides/fork.md), [record a call](../apps/chappe_audio/docs/guides/record.md) |
| chappe_mrf | [README](../apps/chappe_mrf/README.md), [features](../apps/chappe_mrf/docs/features.md) | [IVR menu](../apps/chappe_mrf/docs/guides/ivr-menu.md), [bridge](../apps/chappe_mrf/docs/guides/bridge.md), [conference](../apps/chappe_mrf/docs/guides/conference.md), [drachtio mapping](../apps/chappe_mrf/docs/drachtio-mapping.md) |

Configuration reference per app:
[chappe_sip](../apps/chappe_sip/docs/configuration.md),
[chappe_rtpengine](../apps/chappe_rtpengine/docs/configuration.md),
[chappe_mix](../apps/chappe_mix/docs/configuration.md),
[chappe_esl](../apps/chappe_esl/docs/configuration.md),
[chappe_audio](../apps/chappe_audio/docs/configuration.md),
[chappe_mrf](../apps/chappe_mrf/docs/configuration.md).

What each app can do today: the `docs/features.md` of
[chappe_sip](../apps/chappe_sip/docs/features.md),
[chappe_rtpengine](../apps/chappe_rtpengine/docs/features.md),
[chappe_mix](../apps/chappe_mix/docs/features.md),
[chappe_esl](../apps/chappe_esl/docs/features.md),
[chappe_mrf](../apps/chappe_mrf/docs/features.md). What changed:
[CHANGELOG](../CHANGELOG.md).

### You want to understand the system

- [Concepts](concepts.md): the mental model and the glossary.
- [Architecture](architecture.md): the apps, supervision, the five main
  flows.
- [Decisions](decisions/README.md): why each boundary exists.
- [Navigation](navigation.md): concept to module to test.
- Design per app:
  - chappe_sip: [overview](../apps/chappe_sip/docs/design/overview.md),
    [engine](../apps/chappe_sip/docs/design/engine.md),
    [media](../apps/chappe_sip/docs/design/media.md),
    [B2BUA](../apps/chappe_sip/docs/design/b2bua.md),
    [WebSocket transport](../apps/chappe_sip/docs/design/ws-transport.md),
    [remote apps (draft)](../apps/chappe_sip/docs/design/remote-app.md)
  - chappe_rtpengine: [overview](../apps/chappe_rtpengine/docs/design/overview.md)
  - chappe_mix: [overview](../apps/chappe_mix/docs/design/overview.md),
    with its evidence in [PERF.md](../apps/chappe_mix/test/audit/PERF.md)
    and [ATTEMPTS.md](../apps/chappe_mix/test/audit/ATTEMPTS.md)
  - chappe_esl: [overview](../apps/chappe_esl/docs/design/overview.md)
  - chappe_audio: [overview](../apps/chappe_audio/docs/design/overview.md)
  - chappe_mrf: [overview](../apps/chappe_mrf/docs/design/overview.md)

### You contribute to chappe

- [CONTRIBUTING](../CONTRIBUTING.md): checks, conventions, PRs.
- [If you want to change something](#if-you-want-to-change-something):
  one workflow per task.
- [Plans](plans/): maintainer plans such as
  [documentation and maintainability](plans/documentation-and-maintainability.md).
- AI agents: [AGENTS.md](../AGENTS.md).

## By question

| I want to... | Read |
|---|---|
| answer calls | [answer calls](../apps/chappe_sip/docs/guides/answer-calls.md) |
| place calls | [originate calls](../apps/chappe_sip/docs/guides/originate-calls.md) |
| bridge two calls, or build an SBC | [B2BUA](../apps/chappe_sip/docs/guides/b2bua.md), [SBC](../apps/chappe_sip/docs/guides/sbc.md) |
| ring several phones at once | [B2BUA forking](../apps/chappe_sip/docs/guides/b2bua-forking.md) |
| hang up, transfer or move a live call | [B2BUA call control](../apps/chappe_sip/docs/guides/b2bua-call-control.md) |
| anchor media, record, play, fork audio | [media](../apps/chappe_sip/docs/guides/media.md), [chappe_rtpengine sessions](../apps/chappe_rtpengine/docs/guides/sessions.md) |
| record a call, find a recording | [record a call](../apps/chappe_audio/docs/guides/record.md) |
| get a call's audio into Erlang | [take audio from a fork](../apps/chappe_audio/docs/guides/fork.md), [chappe_mix taps](../apps/chappe_mix/docs/guides/conference.md#tap-a-party-or-the-room) |
| run a conference | [chappe_mix conference](../apps/chappe_mix/docs/guides/conference.md), [chappe_mrf conference](../apps/chappe_mrf/docs/guides/conference.md) |
| build an IVR on FreeSWITCH | [IVR menu](../apps/chappe_mrf/docs/guides/ivr-menu.md) |
| drive FreeSWITCH directly | [chappe_esl getting started](../apps/chappe_esl/docs/guides/getting-started.md) |
| register phones | [registrar](../apps/chappe_sip/docs/guides/registrar.md) |
| register to a carrier | [register to a carrier](../apps/chappe_sip/docs/guides/register-to-a-carrier.md) |
| keep scanners and floods out | [protect the edge](../apps/chappe_sip/docs/guides/protect-the-edge.md) |
| serve browsers | [WebSocket](../apps/chappe_sip/docs/guides/websocket.md) |
| watch the system | [metrics](../apps/chappe_sip/docs/guides/metrics.md), [call records](../apps/chappe_sip/docs/guides/call-records.md), [capture](../apps/chappe_sip/docs/guides/capture.md) |
| know what a word means | [Concepts](concepts.md) |
| find the code for a feature | [Navigation](navigation.md) |
| know why it is built this way | [Decisions](decisions/README.md) |

## If you want to change something

| Task | Workflow |
|---|---|
| Run the checks and the labs | [labs](contributing/labs.md) |
| Follow a call through the system | [debug a call](contributing/debug-a-call.md) |
| Change B2BUA behaviour | [change the B2BUA](contributing/change-b2bua.md) |
| Add a SIP feature or header | [add a SIP feature](contributing/add-sip-feature.md) |
| Add an event package | [add an event package](contributing/add-event-package.md) |
| Add a media backend or capability | [add a media backend](contributing/add-media-backend.md) |
| Add a chappe_mrf conference backend | [add a conference backend](contributing/add-mrf-conference-backend.md) |
| Add an app to the umbrella | [add an app](contributing/add-app.md) |
| Add tests or a fake | [add tests](contributing/add-tests.md) |
| Add an interop lab | [add an interop lab](contributing/add-interop-lab.md) |
| Add or update a compliance row | [compliance](contributing/compliance.md) |
| Write or change a guide | [write a guide](contributing/write-a-guide.md) |
| Change the C engine | [change the C engine](contributing/change-c-engine.md) |
| Extend the public API | [extend the public API](contributing/extend-public-api.md) |

Compliance matrices, generated by `make compliance`:
[chappe_sip](../apps/chappe_sip/docs/compliance.md),
[chappe_rtpengine](../apps/chappe_rtpengine/docs/compliance.md),
[chappe_mix](../apps/chappe_mix/docs/compliance.md),
[chappe_esl](../apps/chappe_esl/docs/compliance.md),
[chappe_mrf](../apps/chappe_mrf/docs/compliance.md).

Labs: [chappe_sip interop](../apps/chappe_sip/interop/README.md),
[chappe_rtpengine interop](../apps/chappe_rtpengine/interop/README.md),
[chappe_esl interop](../apps/chappe_esl/interop/README.md),
[chappe_mix bench](../apps/chappe_mix/bench/README.md).
