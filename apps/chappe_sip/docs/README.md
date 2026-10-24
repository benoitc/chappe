# chappe_sip documentation

Start here.

- [Features](features.md): what chappe_sip does today, what is opt-in, what
  is planned.

## Guides

- [Getting started](guides/getting-started.md): embed the stack in an Erlang
  release and answer your first call.
- [Answer calls (UAS)](guides/answer-calls.md): `chappe_sip:create_uas`, the
  `chappe_sip_handler` behaviour, and in-dialog operations.
- [Originate calls (UAC)](guides/originate-calls.md): place calls and send
  out-of-dialog requests with `chappe_sip:create_uac` / `chappe_sip:request`.
- [B2BUA](guides/b2bua.md): bridge an inbound call to a new one.
- [Handle re-INVITE in a B2BUA](guides/b2bua-reinvite.md): what the relay does
  with each offer, the SDP hook, anchoring and hold events.
- [Run an SBC](guides/sbc.md): OPTIONS-monitored peers, peer groups with
  failover, direct or anchored media per call.
- [Proxy](guides/proxy.md): forking, first-2xx-wins, and record-routed
  in-dialog forwarding.
- [Registrar](guides/registrar.md): the AOR-to-contact location store.
- [Authentication](guides/authentication.md): SIP digest auth as a UAC, on a
  registrar, and challenging any inbound request.
- [SIP over WebSocket and the WebRTC gateway](guides/websocket.md): register
  browsers (JsSIP) and bridge them to UDP/TCP peers.
- [TLS](guides/tls.md): a `sips` listener on its own port.
- [Reliable provisionals (PRACK)](guides/reliable-provisionals.md): 100rel on
  the UAS and the UAC.
- [Subscriptions (SUBSCRIBE/NOTIFY)](guides/subscriptions.md): accept a
  SUBSCRIBE, send NOTIFYs, and handle refresh, unsubscribe, and expiry;
  route SUBSCRIBEs by event package; subscribe to another node's state.
- [Session timers](guides/session-timers.md): RFC 4028 refresh and expiry
  on the calls you answer and place.
- [REFER (call transfer)](guides/refer.md): accept a REFER and report the
  transfer, or send one and follow its progress.
- [Conference focus](guides/conference-focus.md): the `isfocus` Contact and
  RFC 4575 conference state for a conference you run.
- [Call records (CDR)](guides/call-records.md): one attempt, start and stop
  per INVITE call, with a normalized end reason.
- [Presence and message waiting](guides/presence.md): PUBLISH, a presence
  agent, a message-waiting notifier, and the client side of each.
- [Configuration and limits](guides/configuration.md): the tunables in
  `chappe_sip_config`.
- [Deployment](guides/deployment.md): build the release and run it under
  systemd with the engine hang policy.
- [SIP capture (HEP)](guides/capture.md): send a copy of every message to
  Homer.
- [Interop testing](guides/interop-testing.md): the opt-in JsSIP and Kamailio
  interop track.

## Architecture

- [Overview](design/overview.md): the layers and the supervision tree.
- [Engine](design/engine.md): the sofia-sip NIF shim and the stack thread.
- [Media](design/media.md): the media facade, rtpengine anchoring and
  conferences on chappe_mix.

## Development

- [AGENTS.md](../AGENTS.md): module layout and the required checks
  (`compile`, `eunit`, `ct`, `lint`, `xref`, `dialyzer`).
