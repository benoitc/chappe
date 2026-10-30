# chappe_sip documentation

This is the index of the chappe_sip documentation: every guide, every design
page and the references. Start with [getting started](guides/getting-started.md)
if you are new, check [features](features.md) to see whether a capability
exists, and read the [design overview](design/overview.md) before you change
the code. Documentation that spans the apps (concepts, architecture,
decisions, contributing) is in the [umbrella docs](../../../docs/README.md).

## Start

- [Getting started](guides/getting-started.md): build from the umbrella,
  start the stack and answer your first call.
- [Features](features.md): what chappe_sip does today, one line per
  capability, with the guide for each.

## Calls

- [Answer calls (UAS)](guides/answer-calls.md): `create_uas/3`, the
  `chappe_sip_handler` behaviour, in-dialog operations, Replaces.
- [Originate calls (UAC)](guides/originate-calls.md): place calls and send
  out-of-dialog requests.
- [Reliable provisionals (PRACK)](guides/reliable-provisionals.md): 100rel
  on the UAS and the UAC.
- [Session timers](guides/session-timers.md): RFC 4028 refresh and expiry.
- [Authentication](guides/authentication.md): digest as a UAC, on a
  registrar, and on any inbound request.

## B2BUA, proxy and edge

- [B2BUA](guides/b2bua.md): bridge an inbound call to a new one.
- [Handle re-INVITE in a B2BUA](guides/b2bua-reinvite.md): offers, the SDP
  hook, anchoring and hold events.
- [Fork and hunt with the B2BUA](guides/b2bua-forking.md): parallel forks,
  serial targets, `pass_failure`.
- [Control a live B2BUA call](guides/b2bua-call-control.md): hangup,
  in-dialog requests, `replace_b`, `relay_async`, `set_owner`.
- [Run an SBC](guides/sbc.md): monitored peers, failover, direct or anchored
  media per call.
- [Proxy](guides/proxy.md): forking, record-routing, media anchoring.
- [Protect the edge](guides/protect-the-edge.md): the guard middleware.

## Transports

- [SIP over WebSocket and the WebRTC gateway](guides/websocket.md).
- [TLS](guides/tls.md): a `sips` listener on its own port.

## Registration

- [Registrar](guides/registrar.md): the location store, Path, outbound
  flows.
- [Register to a carrier](guides/register-to-a-carrier.md): outbound
  registrations.

## Events and transfer

- [Subscriptions (SUBSCRIBE/NOTIFY)](guides/subscriptions.md): both sides
  of RFC 6665, event package routing.
- [Presence and message waiting](guides/presence.md): PUBLISH, presence,
  MWI.
- [REFER (call transfer)](guides/refer.md): both sides.
- [Conference focus](guides/conference-focus.md): `isfocus` and RFC 4575
  conference state.

## Media

- [Put media under a call](guides/media.md): rtpengine anchoring, taps,
  SIPREC, ducking, conferences on chappe_mix.

## Operations

- [Configuration and limits](guides/configuration.md): how to set values,
  and the ones that matter first.
- [Configuration reference](configuration.md): every setting and its
  default.
- [Deployment](guides/deployment.md): the release, systemd, the hang
  policy, security defaults.
- [Call records (CDR)](guides/call-records.md).
- [SIP capture (HEP)](guides/capture.md).
- [Metrics](guides/metrics.md): Prometheus.
- [Interop testing](guides/interop-testing.md): the JsSIP, conformance and
  SBC labs.

## Design

- [Overview](design/overview.md): supervision, the layers of `src/`, entry
  points, public and internal modules, tests by area.
- [Engine](design/engine.md): the sofia-sip NIF, the event contract, the
  threads, the risky regions.
- [B2BUA](design/b2bua.md): the subsystem, the relay loop, ownership,
  `replace_b`.
- [WebSocket transport](design/ws-transport.md): the Erlang transaction
  layer and what keeps it in step with nta.
- [Media](design/media.md): the boundary with the media engines and
  capability routing.
- [Remote apps](design/remote-app.md): a draft, not implemented.

## Compliance and history

- [Compliance matrix](compliance.md): every RFC requirement row and the
  tests that prove it (generated).
- [Compliance catalogue](compliance/README.md): how rows and claims work
  here.
- [Plan history](history/plan.md): the milestone log of the original port.
- [AGENTS.md](../AGENTS.md): notes for AI coding agents.
