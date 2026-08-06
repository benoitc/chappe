# Proxy

A proxy forwards a request to one or more destinations without terminating the
dialog. enki forks sequentially or in parallel, relays provisionals, forwards
the first 2xx and cancels the losers, and can record-route so in-dialog requests
(ACK, BYE, re-INVITE) traverse it. Read this to route calls transparently.

## When to use it

- You route to registered contacts or a next hop and want one end-to-end dialog
  (not two), with SDP passthrough.
- You are building a registrar-backed router or an edge that must stay in the
  path for in-dialog requests.

## Forward to a destination

```erlang
ok = chappe_sip:invite(fun(Req, _Res) ->
    chappe_sip:proxy_request(Req, <<"sip:bob@10.0.0.2">>, #{record_route => true})
end).
```

The proxy completes the server transaction itself, so the handler does not send
a response.

## Fork

```erlang
Dests = [<<"sip:bob@10.0.0.2">>, <<"sip:bob@10.0.0.3">>],
chappe_sip:proxy_request(Req, Dests, #{forking => parallel, record_route => true}).
```

`forking` is `sequential` (try in order until a 2xx) or `parallel` (all at once,
first 2xx wins, losers get CANCEL). The best final response is relayed if none
succeed.

## Route to a registered browser

Resolve an AOR to a WebSocket flow and forward over it:

```erlang
{ok, _Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@example.com">>),
chappe_sip:proxy_request(Req, {ws, Flow}, #{record_route => true}).
```

## Record-route and in-dialog

With `record_route => true`, enki inserts one Record-Route carrying a flow
token, so the browser's ACK/BYE/re-INVITE come back through the proxy and are
forwarded to the far end in both directions. A forked second 2xx (a different
To-tag arriving later) is forwarded upstream statelessly.

## Notes

- One Record-Route (single interface); a pre-existing multi-hop Route set is
  forwarded by its next Route or the Request-URI. Strict-router recovery is not
  implemented.
- A WS-to-WS proxied dialog needs two flow tokens (a single token routes one
  direction); use a [B2BUA](b2bua.md) to bridge two browsers.
