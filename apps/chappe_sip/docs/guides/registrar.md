# Registrar

The registrar is a location store: it records REGISTER bindings (AOR to contact,
with expiry) and lets your routing logic resolve an address of record to its
current contacts. chappe_sip ships a ready-made REGISTER handler backed by it. Read
this to accept registrations and route to registered users.

## When to use it

- You accept REGISTER from UAs and route calls to wherever they last registered.
- You bridge or proxy to a registered WebSocket browser, or to an RFC 5626
  outbound UA (you need its flow).

## Accept registrations

```erlang
{ok, _} = application:ensure_all_started(chappe_sip),
ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5060">>}),
Auth = #{realm  => <<"example.com">>,
         secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                      (_)           -> error
                  end},
ok = chappe_sip:handle(<<"REGISTER">>, chappe_sip:registrar(#{auth => Auth}),
                       #{option_tags => [<<"path">>, <<"outbound">>]}).
```

`chappe_sip:registrar/1` follows RFC 3261 10.3: the AOR is the To URI in
canonical form (host case-insensitive, parameters dropped), Contacts may be
comma-joined and each takes its own `expires`, a Contact matches its binding
by the 19.1.4 URI rules, the CSeq check is per binding, `expires=0` removes a
binding, and `Contact: *` with `Expires: 0` clears the AOR. The 200 lists every
binding with its `expires` (and `q`), and a `Date`. The `option_tags` route
option lets a REGISTER list `path` and `outbound` in `Require` (RFC 3261 10.3
step 2); without it such a REGISTER gets 420.

## Require authentication

A registrar needs an `auth` option: `chappe_sip:registrar(#{})` raises
`error({registrar, auth_required})`, since an open registrar lets anyone
overwrite another user's bindings. The map form runs digest authentication
before any binding is written:

```erlang
Auth = #{realm  => <<"example.com">>,
         domain => <<"example.com">>,
         secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                      (_)           -> error
                  end},
ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})).
```

On a closed test network you may opt out explicitly:

```erlang
ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})).
```

The handler challenges an unauthenticated REGISTER with 401 and a stateless
nonce, verifies the digest response, and binds the authenticated username to
the AOR: its user part must be that user and its host one of `domain` (a
binary or a list; the realm when you give none), else the REGISTER gets 403.
A replayed response gets a fresh challenge with `stale=true`, a digest `uri`
other than the Request-URI gets 400. `secret` returns `{ok, Password}`,
`{ha1, HA1}` (a precomputed `MD5(user:realm:password)`), or `error` for an
unknown user. For a custom policy pass a `fun((Req) -> ok |
{reject, Status} | {reject, Status, Headers})` instead of the map. A
registrar never answers 6xx (RFC 3261 10.3): a policy that rejects with one
sends 403.

## Serve some domains only

By default the registrar keeps bindings for any domain. List yours to answer
404 to a REGISTER for another one (its Request-URI or its To):

```erlang
ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth,
                                                domains => [<<"example.com">>]})).
```

The `registrar_domains` setting does the same for every registrar.

## Resolve an AOR

```erlang
[Contact | _] = chappe_sip:location(<<"sip:alice@example.com">>),          %% contact URIs, highest q first
{ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@example.com">>),   %% first + transport flow
[#{contact := Uri, path := Path} | _] = chappe_sip:bindings(<<"sip:alice@example.com">>).
```

`location/1` lists the contacts the highest `q` first (no `q` counts as 1.0).
`bindings/1` gives each binding as a map: `contact`, `expires`, `q`, `flow`,
`path`, `instance`, `reg_id`, `params`, `callid`, `cseq`, `received`,
`transport` and `send_flow`. `send_flow` is the flow to reach that binding
over, worked out the way `location_flow/1` does it for the first binding (its
RFC 5626 flow, or the address its REGISTER came from when the device is
behind a NAT; `undefined` means send to the contact). Use it to fork a call to
every device of a user:

```erlang
Dests = [{Contact, #{flow => Flow}}
         || #{contact := Contact, send_flow := Flow}
                <- chappe_sip:bindings(<<"sip:alice@example.com">>)],
{ok, Legs} = chappe_sip:create_b2bua(Req, Res, {parallel, Dests}, #{}).
```

Use the contact as a proxy destination, or route to it in a b2bua:

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    case chappe_sip:location(<<"sip:bob@example.com">>) of
        []        -> chappe_sip_res:send(Res, 404);   %% not registered
        [Uri | _] -> chappe_sip:proxy_request(Req, Uri, #{record_route => true})
    end
end).
```

## Route through the edge proxy (Path, RFC 3327)

An edge proxy that puts itself in a `Path` on the REGISTER must also be on the
way back. The registrar stores the Path with the binding and echoes it in the
200. Send the request with one `Route` header per element, in order:

```erlang
[#{contact := Uri, path := Path} | _] = chappe_sip:bindings(<<"sip:bob@example.com">>),
{ok, Legs} = chappe_sip:create_b2bua(Req, Res, Uri,
                                     #{headers => [{<<"Route">>, P} || P <- Path]}).
```

A REGISTER carrying a Path without `Supported: path` gets 420 with
`Unsupported: path` (the RFC 3327 5.3 recommended policy).

## Outbound flows (RFC 5626)

A Contact with `+sip.instance` and `reg-id` is bound per flow: one binding per
(instance, reg-id), next to any plain binding of the AOR. When the UA lists
`outbound` in `Supported`, the 200 carries `Require: outbound`, and a
`Flow-Timer` (`registrar_flow_timer`) when we are its first hop. Past the first
hop the reg-id counts only when the first Path URI has `ob`; otherwise the
REGISTER gets 439 (the UA asked for outbound) or the reg-id is ignored. A
reg-id with two non-zero Contacts is a 400. When a WebSocket flow drops, only
its bindings go.

An outbound binding registered straight to you (a single Via) is tied to the
flow the REGISTER came on: its TCP/TLS connection (`{conn, Id}`), or its UDP
source address and port (`{udp, Ip, Port}`). Reach the UA over it:

```erlang
{ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@example.com">>),
chappe_sip:proxy_request(Req, {flow, Uri, Flow}, #{}).
```

When that TCP/TLS connection closes, its bindings go (RFC 5626 7). A
re-registration over another connection moves the binding to it.

## Run the registrar on a cluster

With `cluster => chappe_cluster`, every node of a region shares one location
store: a REGISTER taken on one node is found on every other, and a call from
any node reaches the device. You need it when your devices register to
several nodes behind one name (DNS, a load balancer) and any node may place a
call to them. Start chappe_cluster on each node first (see the chappe_cluster
guide, `docs/guides/cluster.md`), then:

```erlang
[{chappe_sip, [
    {cluster, chappe_cluster},
    %% the same on every node: edge routes stay valid across restarts
    {flow_token_secret, <<"a-shared-secret-of-16-bytes-or-more">>}
]}].
```

Put chappe_cluster in your release next to chappe_sip (it is not a
dependency, so nothing pulls it in): a node set to `cluster => chappe_cluster`
without it refuses to start with `{cluster, {chappe_cluster_not_installed,
_}}`.

Route a call with `location_target/1`, which gives the right target from any
node:

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    case chappe_sip:location_target(<<"sip:bob@example.com">>) of
        {ok, Target} -> chappe_sip:proxy_request(Req, Target, #{});
        {error, not_found} -> chappe_sip_res:send(Res, 480)
    end
end).
```

For a b2bua, give each binding its route set:

```erlang
Dests = [{C, #{flow => F, route_set => Path}}
         || #{contact := C, send_flow := F, path := Path}
                <- chappe_sip:bindings(<<"sip:bob@example.com">>)],
{ok, Legs} = chappe_sip:create_b2bua(Req, Res, {parallel, Dests}, #{}).
```

What happens:

- Each binding records the node that took its REGISTER (`node`). A device
  reached over that node's connection (an RFC 5626 flow, a WebSocket, a UDP
  source behind a NAT) also gets an edge route (`edge`): that node's address
  and a token naming the flow, under a MAC.
- On another node, `bindings/1` puts the edge route first in `path`, and
  `target` is `{route, Contact, Path}`. The request goes to the edge node,
  which forwards it over the connection it holds and record-routes the
  dialog (RFC 5626 5.3), so the rest of the call goes the same way.
- The flow is gone at the edge node (the connection closed under the
  request): it answers 430 Flow Failed (RFC 5626 5.3) and drops the
  bindings of that flow. Without a quorum it retries the removal every
  second until the region takes it. Any other failure to forward (the
  node busy, its WebSocket transport restarting) is a 500, and the binding
  stays.
- A device whose contact is reachable as it is has no edge route: any node
  sends to it directly.
- The edge node stops: a UDP binding is reached at its address from the
  node that calls (a NAT that filters by source may drop it). A TCP, TLS or
  WebSocket binding is left out of `bindings/1`: the device is unreachable
  until it registers again on a live node.
- Keep-alives (`qualify_interval_ms`) go from the node that holds each
  binding. Expired bindings are deleted by one node of the region, a
  chappe_cluster singleton that moves when its node stops.
- Without a quorum (two of three nodes down) a REGISTER gets 503 with
  `Retry-After` (`registrar_retry_after`) after at most
  `registrar_cluster_timeout_ms`. Bindings already stored keep their
  expiry, and calls to them still go through: lookups read the node's own
  replica.

Notes:

- Why 503 rather than a binding kept on one node: a 200 says the binding
  is stored (RFC 3261 10.3 step 8). A binding only one node knows would be
  missing from every other node, and merging it later, after the majority
  took REGISTERs for the same AOR, would break the CSeq ordering of 10.3. A
  device told 503 keeps its current binding and retries after
  `Retry-After` (RFC 3261 21.5.4), and decision 0010's rule holds: no call
  stops, only the registration waits.
- Two nodes taking REGISTERs for one AOR at once never lose one: each write
  is a compare-and-swap on the AOR's value, retried on a conflict.
- An AOR's bindings must fit chappe_cluster's `max_value_bytes` (a REGISTER
  past it gets 403), and the region's `max_keys` bounds the AORs (503 past
  it). `registrar_max_aors` applies to a single node only.
- An edge route names a connection of one boot of its node: after that
  node restarts, its TCP, TLS and WebSocket bindings are unreachable until
  the devices register again. Set the same `flow_token_secret` on every
  node so UDP edge routes survive a restart.
- A route that names a connection or a WebSocket (an edge route, or the
  Record-Route of a dialog through one) is accepted only by the node and
  boot that made it, even with a shared `flow_token_secret`: on another
  node, or after a restart, that id may be another device's connection.

## Registrar behaviour in detail

- Registrar (RFC 3261 10.3): `chappe_sip:registrar/1` is a ready REGISTER
  handler backed by a persistent AOR to contact store. The AOR is the
  canonical To URI (host case-insensitive, parameters dropped, escapes
  undone); comma-joined Contacts each take their own `expires`; a Contact
  matches its binding by the 19.1.4 URI rules; the CSeq check is per binding
  and a failing REGISTER writes nothing (one the store could not apply in
  time gets 500 and is never applied); `expires=0` removal, `Contact: *`
  clear, 423 with `Min-Expires` below `registrar_min_expires` (60), 404
  outside `registrar_domains`, never a 6xx (an auth policy's 6xx goes out
  as 403); the 200 lists every binding with `expires` and `q`, and a
  `Date`. A UA registering directly gets its keep-alives answered: STUN
  Binding on UDP, CRLF pong on TCP, TLS and WS (RFC 5626 5.4). `chappe_sip:location/1` resolves an AOR the highest q
  first and `chappe_sip:bindings/1` gives each binding with its Path. Path
  (RFC 3327) is stored and echoed (420 without `Supported: path`). Outbound
  (RFC 5626): one binding per (instance, reg-id) flow, `Require: outbound` and
  `Flow-Timer` in the 200, 439 past a first hop without an `ob` Path. A WS
  binding is purged when its connection drops (the flow is the only path to
  the UA), so a browser that disconnects is deregistered; only that flow's
  binding goes. An outbound binding registered directly over TCP/TLS is tied
  to its connection (`{conn, Id}`, from the request meta `conn`) and purged
  when it closes; over UDP to its source address and port. A request reaches
  it over that flow (`proxy_request/3` with `{flow, Uri, Flow}`, or the
  `flow` option of a UAC or b2bua).

## Notes

- A WebSocket UA is reachable only over its flow; use `location_flow/1` and pass
  `{ws, Flow}` (proxy) or `#{flow => Flow}` (b2bua). See
  [SIP over WebSocket](websocket.md).
- A WS binding is dropped when its connection closes (RFC 5626). UDP bindings
  persist until their `Expires`.
- Default, maximum and minimum expiry are `registrar_default_expires`,
  `registrar_max_expires` and `registrar_min_expires` (60: a shorter non-zero
  expiry under an hour gets 423 with `Min-Expires`) in
  [Configuration](configuration.md).
- Each REGISTER is applied on its own, in arrival order. One the store
  cannot apply within 5 s gets 500 and is never applied later.
- A UA that registers directly gets its keep-alives answered (RFC 5626
  5.4): a STUN Binding request on the UDP port, a CRLFCRLF ping on TCP, TLS
  and WebSocket with a CRLF pong.
- A plain binding (no reg-id) over TCP or TLS is not tied to its
  connection: it stays until its `Expires`. A UDP flow has no failure
  detection (no STUN keepalive), so it also lasts until `Expires`.

## Where it lives

- Modules: `chappe_sip_registrar`, `chappe_sip_registry`,
  `chappe_sip_registry_keeper`, `chappe_sip_location` (the store backends
  `chappe_sip_location_ets` and `chappe_sip_location_cluster`),
  `chappe_sip_registry_sweep` (the cluster sweep), `chappe_sip_qualify`,
  `chappe_sip_route` (flows and edge routes), `chappe_sip_proxy_dialog` (the
  edge forward).
- Tests: `chappe_sip_registrar_SUITE`, `chappe_sip_registrar_cluster_SUITE`
  (three peer nodes), `chappe_sip_digest_SUITE`, `chappe_sip_route_tests`.
- Lab: `make interop-conformance`.
