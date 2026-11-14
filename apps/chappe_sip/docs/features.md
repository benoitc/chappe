# Features

What chappe_sip does today, one line per capability, each linking to the
guide that shows how to use it. Use it to check whether a capability exists
before you build it. The behaviour in detail is in each guide; the protocol
coverage, row by row, is in the [compliance matrix](compliance.md).

## Signalling core

| Capability | Guide |
|---|---|
| Embedded SIP engine (sofia-sip nta) over a plain-C NIF, supervised by the app | [Engine design](design/engine.md) |
| UDP, TCP and several listen addresses per transport | [Deployment](guides/deployment.md) |
| TLS listener, RFC 5922 verification, SIPS in dialogs and through the proxy | [TLS](guides/tls.md) |
| SIP over WebSocket (RFC 7118), WSS, keepalive, the WebRTC gateway | [WebSocket](guides/websocket.md) |
| Request handlers by method, middleware, the `chappe_sip_handler` behaviour | [Answer calls](guides/answer-calls.md) |
| Answer calls (UAS), in-dialog operations, hold, early dialogs, Reason | [Answer calls](guides/answer-calls.md) |
| Place calls and out-of-dialog requests (UAC), digest retry, redirects, route sets, 3PCC | [Originate calls](guides/originate-calls.md) |
| Replaces (RFC 3891), dialog lookup | [Answer calls](guides/answer-calls.md#match-an-invite-with-replaces) |
| Reliable provisionals (PRACK, RFC 3262) | [Reliable provisionals](guides/reliable-provisionals.md) |
| Session timers (RFC 4028) | [Session timers](guides/session-timers.md) |
| Digest authentication, both sides (MD5, SHA-256) | [Authentication](guides/authentication.md) |
| One `call_ref` per call, on every leg, call record and capture packet, found from any node | [Follow a call](guides/follow-a-call.md) |
| Request locals, handed from a middleware to the handler | [Answer calls](guides/answer-calls.md#pass-data-from-a-middleware-to-the-handler) |
| Dialog events (hold, unhold, refresh, in-dialog PUBLISH) and a stream of every dialog's state | [Answer calls](guides/answer-calls.md#watch-every-dialogs-state) |
| Start options: SIP timers, outbound proxy or preloaded route, TCP keep-alive, UDP MTU, aliases | [Configuration reference](configuration.md#start-options-of-the-native-stack) |
| A public address behind 1:1 NAT, the local one to local networks | [Deployment](guides/deployment.md#run-behind-11-nat) |

## B2BUA, proxy and edge

| Capability | Guide |
|---|---|
| B2BUA: bridge, header rules, privacy service, Timer C, early media | [B2BUA](guides/b2bua.md) |
| B2BUA events of the B leg (request sent, provisionals, early dialogs), `a_headers`, redirects on the B leg, funs for the B offer and for auth | [B2BUA](guides/b2bua.md#watch-the-b-leg-ring) |
| B2BUA re-INVITE and UPDATE relay, SDP hook, late offer, hold events | [Handle re-INVITE in a B2BUA](guides/b2bua-reinvite.md) |
| B2BUA parallel forking, serial targets, per-branch flow, headers and anchor flags, the answering branch, `pass_failure` hunting under one To-tag | [Fork and hunt](guides/b2bua-forking.md) |
| B2BUA hangup, in-dialog requests, INFO relay, `replace_b`, `relay_async`, `set_owner` | [Call control](guides/b2bua-call-control.md) |
| Peers monitored by OPTIONS, peer groups with failover, direct or anchored media per call | [Run an SBC](guides/sbc.md) |
| Stateful forking proxy (RFC 3261 16), Record-Route, in-dialog forwarding | [Proxy](guides/proxy.md) |
| Proxy redirects followed (bounded), provisional and final timeouts per branch, double Record-Route (RFC 5658) | [Proxy](guides/proxy.md#follow-redirects) |
| Guard: rules on any header, ACL and rate limits, an action per transport, silent drop with an engine blocklist | [Protect the edge](guides/protect-the-edge.md) |

## Registration

| Capability | Guide |
|---|---|
| Registrar and location store, Path, outbound flows (RFC 5626), NAT, the flow of each binding | [Registrar](guides/registrar.md) |
| Outbound registration to a carrier or PBX | [Register to a carrier](guides/register-to-a-carrier.md) |

## Events and transfer

| Capability | Guide |
|---|---|
| SUBSCRIBE/NOTIFY, both sides, event package routing (RFC 6665) | [Subscriptions](guides/subscriptions.md) |
| PUBLISH, presence (RFC 3856), message waiting (RFC 3842) | [Presence](guides/presence.md) |
| REFER, both sides (RFC 3515, RFC 7647) | [REFER](guides/refer.md) |
| B2BUA transfers, blind and attended, under a policy or decided by the app, on calls to FreeSWITCH too | [REFER](guides/refer.md#transfer-a-b2bua-call) |
| Conference focus and conference state (RFC 4579, RFC 4575) | [Conference focus](guides/conference-focus.md) |

## Media

| Capability | Guide |
|---|---|
| Media facade: anchor, tap, SIPREC, duck, play, record, DTMF on rtpengine | [Media](guides/media.md) |
| SIPREC client (RFC 7866) for anchored calls and native rooms, and a recording server | [SIPREC](guides/siprec.md) |
| Conferences on chappe_mix, rtpengine in front for WebRTC and transcoding | [Media](guides/media.md#run-a-conference-chappe_mix) |
| Media-anchoring proxy | [Proxy](guides/proxy.md) |

## Operations

| Capability | Guide |
|---|---|
| Configuration and limits | [Configuration reference](configuration.md) |
| Release, systemd, engine restart and the hang policy, security defaults | [Deployment](guides/deployment.md) |
| Call records (CDR) | [Call records](guides/call-records.md) |
| SIP capture to Homer (HEP) | [Capture](guides/capture.md) |
| Prometheus metrics, with an optional built-in listener | [Metrics](guides/metrics.md) |
| Interop and conformance labs | [Interop testing](guides/interop-testing.md) |

## Planned

- A remote-app model (apps outside the SIP node's VM, in the spirit of
  drachtio's control socket): a [draft design](design/remote-app.md),
  not implemented; its status is recorded in
  [decision 0008](../../../docs/decisions/0008-remote-app-model.md).

## Non-goals

- A media plane. chappe_sip moves SIP signalling and controls media engines
  through `chappe_sip_media`, but RTP never flows through the SIP processes:
  it stays in rtpengine and in the chappe_mix conference processes.
