# Nodes, health and transports

This guide covers running against one or several rtpengine nodes: health checking, load-based selection, call pinning, restart detection, address changes, and the TCP and WebSocket transports. You need it when you deploy more than one rtpengine, or when you want to react to a node going away.

## Add and remove nodes

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "192.168.1.10",
    port => 2223,
    timeout => 1000,          % per attempt, milliseconds
    attempts => 3,            % total attempts before {error, timeout}
    health_interval => 5000,  % ms between health pings
    down_after => 2           % consecutive failures before down
}),
ok = chappe_rtpengine:remove_node(rtpe1).
```

Each node gets one client process and one socket. Requests carry unique cookies; over UDP the identical datagram is retransmitted per attempt, which is safe because rtpengine serves duplicates from its reply cache.

A UDP request larger than `max_datagram` (default 65507 bytes, the IPv4 payload limit) returns `{error, too_large}` without being sent, and so does one the kernel refuses as too big. Lower it to your path MTU budget if you want large offers refused early, and use the TCP or WebSocket transport for bodies that do not fit:

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{host => "192.168.1.10", port => 2223,
                                       max_datagram => 8000}).
```

## Follow a node that moves

If you address a UDP node by name, the client looks the name up when the node is added, then again every `resolve_interval_ms` and after `resolve_after_timeouts` requests in a row time out. When the address changes, requests go to the new one, including retransmits of requests already in flight.

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "rtpengine.internal",
    port => 2223,
    resolve_interval_ms => 30000,   % default 60000; infinity turns it off
    resolve_after_timeouts => 2     % default 2
}),
#{address_changes := _} = chappe_rtpengine:stats(rtpe1).
```

To resolve through something other than inet (a service registry, a test fixture), pass a resolver fun:

```erlang
Resolver = fun(_Host) -> {ok, {10, 0, 0, 7}} end,
ok = chappe_rtpengine:add_node(rtpe1, #{host => <<"rtpe1">>, port => 2223,
                                       resolver => Resolver}).
```

Notes:

- The lookup runs in a helper process, so a slow resolver never delays replies. A lookup that fails keeps the current address.
- A host given as an IP address is never re-resolved.
- The name must resolve when you add the node: a UDP node whose name does not resolve fails `add_node/2`.
- If the new address is in another family (IPv4 to IPv6), the client opens a new socket; a reply still on its way to the old one is lost and the request retransmits.
- TCP and WebSocket nodes do not use these options: they resolve on every connect.

## Select a node per call

```erlang
{ok, Node} = chappe_rtpengine:select_node(),
[#{name := _, status := _, generation := _, in_flight := _, pinned := _} | _] =
    chappe_rtpengine:list_nodes().
```

Selection returns the healthy node with the least load (in-flight requests plus pinned calls). Media sessions do this for you and pin the call; to pin manually use `chappe_rtpengine_pool:pin(CallId)` and `chappe_rtpengine_pool:unpin(CallId)`.

## React to node events

```erlang
ok = chappe_rtpengine_pool:subscribe(),
receive
    {chappe_rtpengine_pool, {node_down, Node}} -> ...;
    {chappe_rtpengine_pool, {node_up, Node, Generation}} -> ...
end.
```

A node goes down after `down_after` consecutive failures (health pings and request timeouts both count) and comes back on the next successful ping. Every recovery bumps the node's generation.

Notes:

- rtpengine loses all sessions on restart while answering health pings as if nothing happened. A generation bump is your only signal that calls pinned before the flap lost their media. Sessions handle this for you and notify their owners; see the sessions guide.
- The pool never re-offers on its own: a new offer needs SDP that only signalling can produce.

## NG over TCP

If your SDP bodies outgrow safe datagram sizes (ICE candidate lists, many m-lines), point the node at rtpengine's `--listen-tcp-ng` listener:

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "192.168.1.10",
    port => 2224,
    transport => tcp
}).
```

The API is identical. Nothing is retransmitted (the transport is reliable), timeouts still bound every request, and a broken connection fails in-flight requests with `{error, closed}` and reconnects in the background. Requests made while disconnected return `{error, {send_failed, not_connected}}`.

Notes:

- The host name is resolved on every connect attempt, so a node that moves to a new address is found on reconnect, and a name that does not resolve yet is retried like a refused connection (`add_node/2` succeeds; requests fail with `not_connected` until it resolves).
- A reply stream that announces a message over 4 MiB, or sends a cookie over 256 bytes, or bytes that are not bencode, drops the connection and reconnects.

## NG over WebSocket

To drive an rtpengine across a firewall or over 443, point the node at its HTTP interface (`--listen-http` or `--listen-https`). The NG channel rides a WebSocket negotiating the `ng.rtpengine.com` subprotocol; a server that does not grant it never becomes connected.

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "rtpengine.example.net",
    port => 443,
    transport => wss,
    path => <<"/">>,
    tls_opts => [{verify, verify_peer}]
}).
```

Use `transport => ws` for a plain `--listen-http` listener; `path` defaults to `/` and `tls_opts` (any `ssl:tls_client_option()`) only apply to `wss`. Replies are accepted in binary or text frames. Reliability semantics match TCP: nothing is retransmitted, timeouts bound every request, broken connections fail in-flight requests with `{error, closed}` and reconnect in the background.

## Inspect a node

```erlang
#{sent := _, replies := _, retransmits := _, timeouts := _, reconnects := _} =
    chappe_rtpengine:stats(rtpe1),
#{status := up, generation := 1} = chappe_rtpengine_pool:node_info(rtpe1).
```

Ask the daemon what it runs:

```erlang
{ok, CallIds} = chappe_rtpengine:list(rtpe1, #{limit => 100}),
{ok, #{<<"currentstatistics">> := #{<<"sessionstotal">> := N}}} =
    chappe_rtpengine:statistics(rtpe1).
```

`list/1` returns 32 call-ids at most, the daemon's default. Over UDP a large
`limit` can make a reply too big for one datagram: use TCP or WebSocket.

All node options and their defaults are in [Configuration](../configuration.md).

## Where it lives

- Modules: `chappe_rtpengine_pool` (registry, health, selection), `chappe_rtpengine_client` (transport), `chappe_rtpengine_resolve` (host lookup), `chappe_rtpengine_ws_handler` (WebSocket)
- Tests: `apps/chappe_rtpengine/test/chappe_rtpengine_pool_SUITE.erl`, `chappe_rtpengine_client_SUITE.erl`
- Lab: `make interop` (UDP, TCP and WebSocket against rtpengine in docker)
