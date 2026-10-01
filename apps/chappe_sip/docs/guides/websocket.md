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
