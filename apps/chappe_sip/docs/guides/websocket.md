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

Add a `ws` option to `chappe_sip:start/1`. The listener negotiates the `sip`
subprotocol and disables the idle close for long-lived registrations.

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:127.0.0.1:5060">>,
    ws      => #{port => 8443}
}),
ok = chappe_sip:register(chappe_sip:registrar()).
```

livery starts lazily, only when a `ws` listener is configured. Terminate TLS for
`wss://` at your load balancer, or run livery behind one.

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

- Proxy: one transparent dialog, SDP passthrough, record-route with a flow token.
  A WS-to-WS proxied dialog (two browsers) needs two flow tokens.
- B2BUA: two dialogs; handles WS-to-WS cleanly (a browser-to-browser call).

## Notes

- Restrict browser origins with `ws_allowed_origins` (a list of binary
  Origins); a request from any other Origin is refused with 403 at the upgrade.
  The default (empty) allows any origin. Terminate `wss://` and authenticate at
  your edge or with a REGISTER auth hook (see [Registrar](registrar.md)).
- A browser is reachable only over its flow; its `.invalid` Contact is not
  routable. Always resolve the flow with `chappe_sip:location_flow/1`.
- Via `received`/`rport` are stamped from the client peer.
- Media (RTP/SRTP, ICE) is peer-to-peer or orchestrated by your app; chappe_sip carries
  the WebRTC SDP unchanged.
- Verified against real JsSIP (register and a WebRTC call). See
  [Interop testing](interop-testing.md).
