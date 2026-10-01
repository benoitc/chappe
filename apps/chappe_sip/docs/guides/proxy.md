# Proxy

A proxy forwards a request to one or more targets without terminating the
dialog. chappe_sip forks sequentially or in parallel, relays provisionals,
forwards every 2xx and cancels the losers, picks the best final response when
no branch answers, and can record-route so in-dialog requests (ACK, BYE,
re-INVITE) traverse it. It follows the stateful proxy rules of RFC 3261
section 16 and the 2xx handling of RFC 6026. Read this to route calls
transparently.

## When to use it

- You route to registered contacts or a next hop and want one end-to-end dialog
  (not two), with SDP passthrough.
- You are building a registrar-backed router or an edge that must stay in the
  path for in-dialog requests.

## Forward to a target

```erlang
ok = chappe_sip:handle(<<"INVITE">>, fun(Req, _Res) ->
    chappe_sip:proxy_request(Req, <<"sip:bob@10.0.0.2">>, #{record_route => true})
end, #{proxy => true}).
```

The target becomes the Request-URI of the forwarded request (16.6 step 2). A
target given as `<<"10.0.0.2:5070">>` keeps the user and parameters of the
received Request-URI and replaces its host and port. The proxy completes the
server transaction itself, so the handler does not send a response.

`proxy => true` tells the stack the route proxies: a `Require` is
for the far UAS and passes through, while a `Proxy-Require` tag we do not
support gets 420 (RFC 3261 16.3). Without it the route acts as a UAS and
answers 420 to an unknown `Require` before your handler runs. A proxy route
that also answers some requests itself checks their `Require` on its own.

## Fork

```erlang
Dests = [<<"sip:bob@10.0.0.2">>, <<"sip:bob@10.0.0.3">>],
chappe_sip:proxy_request(Req, Dests, #{forking => parallel, record_route => true}).
```

`forking` is `sequential` (try in order until a 2xx) or `parallel` (all at once,
first 2xx wins, losers get CANCEL).

## Time out a ringing branch

```erlang
chappe_sip:proxy_request(Req, Dests, #{timer_c => 60000}).
```

Each INVITE branch runs Timer C (16.6 step 11), restarted by every provisional
other than 100. When it fires, a branch that sent a provisional is CANCELled
and one that never answered is dropped; either way it counts as a 408. The
default is the `timer_c_ms` setting (185 s; the RFC asks for more than 3
minutes).

## Route to a registered browser

Resolve an AOR to a WebSocket flow and forward over it:

```erlang
{ok, _Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
chappe_sip:proxy_request(Req, {ws, Flow}, #{record_route => true}).
```

## Route to an outbound (RFC 5626) binding

A UA that registered with `+sip.instance` and `reg-id` straight to you over
TCP, TLS or UDP is reached over that flow, not by its Contact address:

```erlang
{ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
chappe_sip:proxy_request(Req, {flow, Uri, Flow}, #{}).
```

The Request-URI becomes the contact `Uri`. A TCP/TLS flow is the connection
the REGISTER came on; a UDP flow is its source address and port.

## What reaches the caller

- Provisionals (but 100 Trying) are relayed as they arrive.
- Every 2xx is forwarded: the first on the server transaction, then, for
  64*T1 (`proxy_accepted_ms`), each 2xx with a new To-tag, from another branch
  or from a fork further downstream (RFC 6026), over UDP, TCP and TLS. A
  retransmission of a 2xx already forwarded is absorbed.
- With no 2xx, the best final once every branch is done (16.7 step 6): a 6xx
  first (it also CANCELs the other branches), else the lowest class, and in
  4xx a 401, 407, 415, 420 or 484. The challenges of every 401 and 407 branch
  are merged into the one relayed, the Contacts of every 3xx too, and a 503
  goes up as a 500.
- The caller's CANCEL goes to every pending branch; the caller gets the 487
  the callee sends, or the 2xx when the callee answered as the CANCEL
  crossed it (16.10).

## Route sets and loops

- A Route naming this proxy is removed (16.4). With a Route left, the top one
  is the next hop and the target only replaces the Request-URI (16.6 steps 6
  and 7); a strict router (no `lr`) gets the Request-URI swapped in.
- Behind a strict router, a Request-URI holding our Record-Route is restored
  from the last Route (16.4).
- The branch of each Via the proxy adds carries a hash of the request as
  received. A request coming back with one of our Vias and the same hash
  looped and gets 482; with another hash it spirals (a new Request-URI) and
  is forwarded again (16.3 step 4).
- Max-Forwards 0 gets 483.

## Record-route and in-dialog

With `record_route => true`, chappe_sip inserts one Record-Route carrying flow
tokens, so ACK/BYE/re-INVITE come back through the proxy and are forwarded to
the far end in both directions, whatever their `Require`, including a CANCEL of a re-INVITE in transit.
The token of each WebSocket leg is in the route, so a browser-to-browser
dialog routes both ways.

The route is signed (an HMAC over its address, flow tokens, Call-ID and an
expiry, see `flow_token_secret` and `record_route_ttl_s` in
[Configuration](configuration.md)): a forged or expired route is not ours and
is not relayed.

## SIPS and TLS

- The Record-Route is a `sips:` URI (the TLS listener) when the forwarded
  request's Request-URI or top Route is SIPS, and a `sip:` URI otherwise. When
  the two sides differ (TLS in, UDP out), the Record-Route in the responses
  going back is rewritten for the upstream side (16.7 step 8).
- A SIPS request is only forwarded to a SIPS target (480 otherwise); a SIP
  request for a SIPS target keeps a `sip:` Request-URI and goes over TLS (RFC
  5630).

## Notes

- One Record-Route per forward (single interface per transport).
- A 2xx after the first is forwarded over UDP; on TCP or TLS the client
  transaction ends with the first 2xx, so a later fork's 2xx is dropped by
  the stack.
- A record-routed dialog must end within `record_route_ttl_s` (24 h by
  default), after which its route marker is refused.
