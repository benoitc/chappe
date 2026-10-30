# SIP over WebSocket and the WebRTC gateway

chappe_sip terminates SIP-over-WebSocket (RFC 7118) with an Erlang transport built on
livery, so browsers (JsSIP) register and call through the same TU logic as UDP
peers. Bridge a browser to a UDP/TCP peer as a proxy or a B2BUA. Read this to
put a WebRTC front end on your SIP network.

## When to use it

- You serve browser softphones (JsSIP, SIP.js) over `wss://` and bridge them to
  a carrier or PBX over UDP.
- You want registrations and calls from browsers handled in-process, no separate
  WebSocket gateway.

## Enable the WS listener

Add a `ws` option to `chappe_sip:start/1`. The listener requires the `sip`
subprotocol: a client that does not offer it is refused at the upgrade.

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:127.0.0.1:5060">>,
    ws      => #{port => 8080}
}),
ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})).
```

livery starts lazily, only when a `ws` or `wss` listener is configured.

## Serve wss:// directly

Add a `wss` option with the cert dir you use for SIP TLS (`agent.pem` holds the
certificate and key), or `certfile` and `keyfile`:

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:127.0.0.1:5060">>,
    ws      => #{port => 8080},
    wss     => #{port => 8443, cert_dir => <<"/etc/chappe/tls">>}
}).
```

Requests chappe sends to a browser on a WSS connection carry a `WSS` Via. To
terminate TLS at a load balancer instead, configure `ws` only and point the
balancer at that port.

## Keep connections alive

The server pings each connection every `ws_ping_interval_ms` (30 s). A
connection with no inbound traffic for `ws_idle_timeout_ms` (600 s) is closed;
a live browser answers the pings, so only a dead one is reaped. A client's
CRLFCRLF keepalive gets a CRLF back (RFC 5626).

```erlang
application:set_env(chappe_sip, ws_ping_interval_ms, 20000),
application:set_env(chappe_sip, ws_idle_timeout_ms, 120000).
```

## Bridge browser to UDP (B2BUA)

Resolve the registered browser's flow and originate the B leg over it:

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
    {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}),
    chappe_sip_b2b:relay(Legs)
end).
```

This works in both directions: a UDP caller reaches the browser, and a browser
caller reaches a UDP callee. In-dialog ACK/BYE/re-INVITE traverse the WS<->UDP
dialog.

## Bridge as a proxy

```erlang
ok = chappe_sip:invite(fun(Req, _Res) ->
    {ok, _Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
    chappe_sip:proxy_request(Req, {ws, Flow}, #{record_route => true})
end).
```

## Proxy vs B2BUA over WS

- Proxy: one transparent dialog, SDP passthrough, record-route with a flow
  token per WS leg, so a WS-to-WS proxied dialog (two browsers) routes both
  ways.
- B2BUA: two dialogs; handles WS-to-WS cleanly (a browser-to-browser call).

## How the WebSocket transport behaves

- SIP-over-WebSocket (RFC 7118) via livery (`ws => #{port}` in
  `chappe_sip:start/1`, and `wss => #{port, cert_dir}` for secure WebSocket
  with the `agent.pem` of the SIP TLS cert dir): an Erlang WS transport
  bridges frames to the shared transaction-user logic, so UAS/registrar/etc.
  work over WS. The engine multiplexes each operation to the sofia NIF or the
  WS transport by handle. The `sip` subprotocol is required (a client that
  does not offer it is refused); text and binary frames are accepted, and a
  message that is not valid UTF-8 goes out in a binary frame. Requests over
  WSS carry a `WSS` Via. livery starts lazily, only when a WS listener is
  configured. To terminate TLS at a load balancer instead, point it at the
  plain `ws` port.
- WS transactions follow the RFC 3261 rules for a reliable transport: no
  retransmissions, a retransmitted request gets the last response again, a
  non-2xx INVITE final waits for its ACK (Timer H), Timer B/F bound a client
  transaction, Timer C (180 s) CANCELs an INVITE stuck after a provisional,
  a CANCEL waits for a provisional, and a non-2xx final is ACKed with the
  INVITE's branch. A CANCEL of an unanswered INVITE gets the 487, a 2xx
  never ACKed within 64*T1 is BYEd, reliable provisionals (100rel) carry
  RSeq and are matched to their PRACK, and dialog-forming responses carry
  the request's Record-Route. An INVITE left ringing sends its last non-100
  provisional again every `ws_progress_ms` (60 s) until the final, as nta
  does on UDP, TCP and TLS (RFC 3261 13.3.1.1).
- Via `received` is stamped when the sent-by is not the client address (a
  WS client's `.invalid` host always is); `rport` is filled in only when the
  client asked with a bare `rport` (RFC 3581).
- Keepalive: a CRLFCRLF ping gets a CRLF pong on WS and, through sofia, on
  TCP/TLS (RFC 5626 4.4.1). The server pings each WS connection every
  `ws_ping_interval_ms` (30 s); a connection with no inbound traffic for
  `ws_idle_timeout_ms` (600 s) is closed, so only a client that stopped
  answering is reaped.
- WebRTC gateway: bridge a browser (WS) and a UDP/TCP peer in both
  directions, as a proxy (`chappe_sip:proxy_request` to a `{ws, Flow}` target,
  Record-Route with a flow token so in-dialog ACK/BYE/re-INVITE traverse) or
  a B2BUA (`chappe_sip:create_b2bua` with a `flow` opt). Resolve a registered
  browser with `chappe_sip:location_flow/1`. A real JsSIP-to-JsSIP WebRTC call
  completes through the b2bua over WS (verified in the interop track). A
  WS-to-WS proxied dialog carries a flow token per leg, so both directions
  route; the tokens are trusted-gateway scoped.
- Dialog-forming 2xx responses carry a Contact (RFC 3261 12.1.1), and a
  UAC-built request over WS (e.g. a 2xx ACK) gets a Via from the transport, so
  strict clients (JsSIP) build the dialog and accept in-dialog requests.

## Behaviour changes

- A closed WebSocket connection ends the dialogs bound to it: owners get
  `destroy` with reason `flow_lost`.

## Notes

- Restrict browser origins with `ws_allowed_origins` (a list of binary
  Origins); a request from any other Origin is refused with 403 at the upgrade.
  The default (empty) allows any origin. Terminate `wss://` and authenticate at
  your edge or with a REGISTER auth hook (see [Registrar](registrar.md)).
- A browser is reachable only over its flow; its `.invalid` Contact is not
  routable. Always resolve the flow with `chappe_sip:location_flow/1`.
- Via `received` is stamped from the client peer, and `rport` when the client
  asked with a bare `rport` (RFC 3581).
- WS is a reliable transport: nothing is retransmitted. Timer B/F (64 s) and
  Timer C (180 s, `ws_timer_c_ms`) bound requests sent to a browser; a 2xx a
  browser never ACKs is BYEd after `ws_ack_timeout_ms` (32 s); a request your
  app never answers gets 408 (INVITE) or 500 after `ws_server_txn_timeout_ms`.
- An INVITE your app leaves ringing sends its last non-100 provisional again
  every `ws_progress_ms` (60 s) until you send the final, so a proxy between
  the browser and chappe does not cancel it (RFC 3261 13.3.1.1). nta does the
  same on UDP, TCP and TLS. `infinity` turns it off.
- Reliable provisionals work over WS: `chappe_sip_res:send_reliable/2` adds RSeq
  and `chappe_sip_res:await_prack/2` gets the PRACK, as on UDP.
- A message larger than `max_message_size` closes the connection (1009) when
  it comes in and is refused with `{error, too_large}` when it would go out.
  A message that is not valid UTF-8 goes out in a binary frame.
- If the WS transport process restarts, every WS connection closes and its
  binding is dropped; browsers reconnect and register again.
- Media (RTP/SRTP, ICE) is peer-to-peer or orchestrated by your app; chappe_sip carries
  the WebRTC SDP unchanged.
- Verified against real JsSIP (register and a WebRTC call). See
  [Interop testing](interop-testing.md).

## Where it lives

- Modules: `chappe_sip_ws_listener`, `chappe_sip_ws_conn`,
  `chappe_sip_ws_transport`, `chappe_sip_ws`; design in
  [ws-transport](../design/ws-transport.md).
- Tests: `chappe_sip_websocket_SUITE`, `chappe_sip_ws_conf_SUITE`,
  `chappe_sip_webrtc_gateway_SUITE`.
- Lab: `make interop` (JsSIP, `apps/chappe_sip/interop`).
