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

## Anchor the media in rtpengine

Add a `media` map to anchor the SDP through rtpengine while the Call-ID is
kept: the offer on the forwarded request, the answer on its 1xx and 2xx, and
the release on the in-dialog BYE. It needs a configured rtpengine backend
(see [Media](media.md)) and `record_route => true`, so the in-dialog
requests come back through the proxy.

```erlang
chappe_sip:proxy_request(Req, <<"sip:bob@10.0.0.2">>,
                         #{record_route => true,
                           media => #{offer_params => #{},
                                      answer_params => #{}}}).
```

`offer_params` and `answer_params` are rtpengine flags for each side. A
failed offer fails the request instead of forwarding it unanchored; a failed
answer relays the response unchanged. Without `media` the proxy forwards
the SDP untouched.

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

## Move on from a dead or slow branch

Timer C restarts with every provisional, so a target that keeps ringing
holds the call. Two timeouts per branch end it sooner:

```erlang
chappe_sip:proxy_request(Req, Dests, #{provisional_timeout => 2000,
                                       final_timeout => 30000}).
```

- `provisional_timeout`: a branch that sent nothing, not even a 100, by
  then is dropped (no CANCEL: RFC 3261 9.1 allows one only after a
  provisional) and counts as a 408. With sequential forking the next
  target is tried.
- `final_timeout`: a branch with no final by then is CANCELled (or dropped
  if it never sent a provisional) and counts as a 408, whatever its
  provisionals did to Timer C.

Both are in ms, off by default, and run next to Timer C: the first to fire
ends the branch.

## Follow redirects

By default a 3xx is a final like any other and may reach the caller. With
`follow_redirects` the proxy recurses on its Contacts (RFC 3261 16.7 step
4):

```erlang
Local = fun(Uri) -> binary:match(Uri, <<"@10.0.0.">>) =/= nomatch end,
chappe_sip:proxy_request(Req, Dests, #{
    follow_redirects => #{max_targets => 5, max_depth => 2, allow => Local}
}).
```

- The Contacts are tried in q order, next in sequential forking, at once in
  parallel forking.
- `max_targets` (default 5, at most 32) caps the targets every 3xx of the
  transaction adds together; `max_depth` (default 2, at most 8) caps how
  many 3xx deep a target may come from.
- `allow` is your policy: a fun of the URI, run in the request worker. A
  URI it refuses, one already in the target set, and a SIP URI for a SIPS
  request are not tried. Without one, only the proxy's own domains are
  followed: the hosts of its listen addresses, its `aliases` and the
  `registrar_domains` it serves.
- The Contacts tried leave the 3xx. A 3xx with Contacts left can still be
  the best final the caller gets; one with none left is not.
- `follow_redirects => true` takes the defaults, own domains included. A
  callee could otherwise 302 the caller to any number; to follow other
  networks, give `allow` your rule, such as
  `allow => fun(_Uri) -> true end` on a trusted core.
- A Contact naming the proxy itself brings the request back in. It counts
  the hops it made through the proxy: its depth starts there, and once back
  it follows no Contact naming the proxy again, so one request reaches at
  most `1 + max_targets` targets however its 3xx chain.

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

With `record_route => true`, chappe_sip inserts a Record-Route carrying flow
tokens, so ACK/BYE/re-INVITE come back through the proxy and are forwarded to
the far end in both directions, whatever their `Require`, including a CANCEL of a re-INVITE in transit.
The token of each WebSocket leg is in the route, so a browser-to-browser
dialog routes both ways.

The route is signed (an HMAC over its address, flow tokens, Call-ID and an
expiry, see `flow_token_secret` and `record_route_ttl_s` in
[Configuration](configuration.md)): a forged or expired route is not ours and
is not relayed.

When the request arrives on one address and leaves from another (two
listen addresses, IPv4 in and IPv6 out, TLS in and UDP out, or the two
sides of a 1:1 NAT), the proxy inserts two Record-Routes (RFC 5658 5): the
address the caller reached first, then the one the callee reaches on top.
Each side's route set starts with an address it can reach, and nothing is
rewritten in the responses. An in-dialog request carrying both of our
Routes has both removed, so it does not spiral through us.

## SIPS and TLS

- The Record-Route is a `sips:` URI (the TLS listener) when the forwarded
  request's Request-URI or top Route is SIPS, and a `sip:` URI otherwise. When
  the two sides differ (TLS in, UDP out), the request is record-routed twice,
  `sips:` for the TLS side, instead of rewriting the Record-Route in the
  responses (RFC 5658 4 and 5).
- A SIPS request is only forwarded to a SIPS target (480 otherwise); a SIP
  request for a SIPS target keeps a `sip:` Request-URI and goes over TLS (RFC
  5630).
- A `sips:` target with `transport=udp` is not tried: the branch counts as a
  480 and nothing is sent (RFC 3261 19.1.1).

## What the proxy does, in detail

- `chappe_sip:proxy_request/3`: a stateful proxy after RFC 3261 section 16.
  Sequential and parallel forking with the Request-URI rewritten to each
  target, a pre-existing Route set honoured (loose and strict next hops,
  strict-router recovery), Timer C per INVITE branch, CANCEL relayed to the
  branches (the downstream 487 or a crossing 2xx goes upstream), loop
  detection (482) that lets spirals through, and the 16.7 best response (6xx
  first, lowest class, retry-able 4xx preferred, challenges and 3xx Contacts
  merged, 503 sent as 500). Every 2xx is forwarded for 64*T1 after the first
  (RFC 6026), also over TCP/TLS, where nta ends the client transaction at
  the first 2xx: the shim's agent callback catches the later ones. Record-Route insertion (sips when the forwarded request is
  SIPS, doubled across addresses or TLS/non-TLS) and in-dialog forwarding
  through it, CANCEL of a transit re-INVITE included.

## Notes

- A 2xx after the first is forwarded over UDP; on TCP or TLS the client
  transaction ends with the first 2xx, so a later fork's 2xx is dropped by
  the stack.
- A record-routed dialog must end within `record_route_ttl_s` (24 h by
  default), after which its route marker is refused.

## Where it lives

- Modules: `chappe_sip_proxy`, `chappe_sip_proxy_rules`,
  `chappe_sip_proxy_redirect` (follow_redirects, the branch timeouts),
  `chappe_sip_proxy_accepted` (the RFC 6026 Accepted state),
  `chappe_sip_proxy_dialog`, `chappe_sip_route`, the stray 2xx path of the
  NIF (`stray_cb`).
- Tests: `chappe_sip_proxy_conf_SUITE`, `chappe_sip_proxy_forking_SUITE`,
  `chappe_sip_proxy_record_route_SUITE`, `chappe_sip_proxy_media_SUITE`,
  `chappe_sip_route_tests`.
- Lab: `make interop-conformance`.
