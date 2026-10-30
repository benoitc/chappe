# Protect the edge

`chappe_sip_guard` is a middleware that turns requests away before any
handler runs: SIP scanners by User-Agent, sources outside an allow list or
inside a deny list, and sources sending faster than a rate. With the `drop`
action it answers nothing and has the engine discard that source's next
requests before they cost a transaction. Read this when your node is
reachable from the internet.

## When to use it

- Scanners (`friendly-scanner`, `sipvicious`) probe your public port.
- Only known networks (your carriers, your offices) may send you requests.
- One source floods you with REGISTER or INVITE.

## Add the guard

Build it with `chappe_sip_guard:new/1` and install it with `chappe_sip:use/1`
before your handlers.

```erlang
ok = chappe_sip:use(chappe_sip_guard:new(#{
    user_agents => [<<"friendly-scanner">>, <<"^sipvicious">>],
    deny => [<<"192.0.2.0/24">>],
    rate => #{rate => 20, burst => 40},
    action => 403
})).
```

The checks run in this order: User-Agent, then source address, then rate.
The first one that fails turns the request away.

| Option | Default | What it does |
|---|---|---|
| `user_agents` | `[]` | Regexes, matched caseless against the User-Agent. |
| `allow` | none | CIDRs. When set, only these sources pass. |
| `deny` | `[]` | CIDRs. These sources are turned away. |
| `rate` | none | `#{rate := PerSecond, burst => N}`: a token bucket per source address. `burst` defaults to twice the rate. |
| `action` | `403` | `403`, `503`, or `drop`. |
| `block_ms` | `30000` | With `drop`: how long the engine then discards every request from that source. `0` blocks nothing. |

## Guard one method only

`chappe_sip:use/2` takes a method, so you can rate-limit REGISTER harder than
the rest:

```erlang
ok = chappe_sip:use(<<"REGISTER">>,
                    chappe_sip_guard:new(#{rate => #{rate => 2, burst => 5},
                                           action => drop})).
```

## Drop silently

With `action => drop`, the request that tripped the guard gets no response,
and its source goes on the engine's blocklist for `block_ms`. The engine then
discards that source's requests before nta creates a server transaction, so
a flood from it costs almost nothing. This works on UDP, TCP and TLS. Over
WebSocket each request still reaches the guard.

```erlang
ok = chappe_sip:use(chappe_sip_guard:new(#{
    allow => [<<"203.0.113.0/24">>, <<"10.0.0.0/8">>],
    action => drop,
    block_ms => 60000
})).
```

## Notes

- The source is the transport peer (`chappe_sip_req:source_ip/1`), not the
  Via, which a client can forge.
- A request whose source is unknown passes `deny` and `rate`, and fails a
  non-empty `allow`.
- Each block counts in the `chappe_sip_guard_blocked_total{reason}` metric
  (`user_agent`, `source`, `rate`); see [Metrics](metrics.md).
- `chappe_sip_engine:stats/0` returns `#{incoming, discarded}`: the server
  transactions held and the requests the blocklist discarded.
- On UDP, TCP and TLS, nta has no silent discard: a dropped request's
  retransmissions are absorbed without a 100 Trying, and once the client has
  given up (64*T1) a 408 ends the transaction (never sent for a non-INVITE,
  RFC 4320).
- The blocklist lives in the NIF and outlives an engine restart.

## Where it lives

- Modules: `chappe_sip_guard` (the policy), `chappe_sip_engine`
  (`discard/1`, `block_source/2`), the C blocklist in
  `c_src/chappe_sip_engine_nif.c` (`blk_put`, `request_in`), and
  `chappe_sip_net` (CIDR parsing).
- Tests: `chappe_sip_guard_SUITE`.
- Lab: none.
