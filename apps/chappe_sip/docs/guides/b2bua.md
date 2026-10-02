# B2BUA

A back-to-back user agent terminates the inbound call and originates a fresh
one, so chappe_sip sits in the middle of two independent dialogs. It relays
provisionals (with early media), the answer, re-INVITEs and UPDATEs, and BYE
between the legs, and can rewrite headers and SDP. Read this to bridge a
caller to a callee under your control.

## When to use it

- You need to control both dialogs (record media, rewrite SDP/headers, insert an
  IVR, re-target) rather than transparently proxying.
- You bridge across transports (a WebSocket browser to a UDP peer). See
  [SIP over WebSocket](websocket.md).

## Bridge a call

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    Callee = <<"sip:bob@10.0.0.2">>,
    case chappe_sip:create_b2bua(Req, Res, Callee, #{}) of
        {ok, Legs}      -> chappe_sip_b2b:relay(Legs);
        {error, Reason} -> chappe_sip_res:send(Res, 500), {error, Reason}
    end
end).
```

`create_b2bua/4` originates the B leg, relays provisionals to the caller (with a
shared To-tag and their body), bridges the 2xx SDP, and returns the two legs.
`chappe_sip_b2b:relay/1` carries the call until either leg is torn down, then
destroys the other.

Both legs hand re-INVITE and UPDATE to their owner, so run `relay/1,2` (or
answer those events yourself) for as long as the call lasts.

## Options

```erlang
chappe_sip:create_b2bua(Req, Res, Callee, #{
    proxy_request_headers  => {all, [<<"route">>]},  %% copy headers A -> B
    proxy_response_headers => [<<"X-Account">>],     %% copy B's 2xx -> A's 2xx
    pass_failure           => true,                  %% relay a B failure to A
    session_expires        => 1800,                  %% a session timer per leg
    timer_c                => 60000,                 %% how long B may ring (ms)
    flow                   => Flow,                  %% originate B over a WS flow
    privacy                => true                   %% act as a privacy service
}).
```

`proxy_request_headers` and `proxy_response_headers` take
`list | all | {all, Exclude}`. `all` never copies the dialog headers,
`Session-Expires`/`Min-SE`, and, from B's 2xx, `Require`, `Supported`,
`Allow` and `RSeq`: those belong to one leg. A `Privacy: none` from A always
reaches B unchanged, whatever you copy (RFC 3323 4.2). Set `flow` (from
`chappe_sip:location_flow/1`) to send the B leg to a registered WebSocket UA.

## Act as a privacy service

Set `privacy => true` when your b2bua is the privacy service of RFC 3323 for
its callers. It reads the `Privacy` header of A's INVITE:

- `none`: nothing is removed, and the header reaches B unchanged.
- `user` or `header`: Subject, Call-Info, Organization, User-Agent, Reply-To
  and In-Reply-To stay off the B leg, even with
  `proxy_request_headers => all`. The b2bua already gives B its own From,
  Contact, Via and Call-ID.
- `id`: P-Asserted-Identity and P-Preferred-Identity stay off the B leg.
- `session`: the b2bua cannot anonymize media on its own. If you do it (for
  example through rtpengine and `local_sdp_b`), say so with
  `privacy => #{session => true}`.
- `critical` with a level it cannot apply (`session` without that flag, or a
  token it does not know): A gets a 500 whose reason phrase names the levels,
  such as `Privacy Failure: session not supported`, B is never called, and
  `create_b2bua/4` returns `{error, {privacy, [<<"session">>]}}`.

```erlang
case chappe_sip:create_b2bua(Req, Res, Callee, #{privacy => true}) of
    {ok, Legs} -> chappe_sip_b2b:relay(Legs);
    {error, _} -> ok
end.
```

## How long B may ring

B rings as long as it keeps sending provisionals: each one other than 100
restarts Timer C on the B leg (RFC 3261 16.7). When Timer C fires, B is
CANCELled and the caller gets a 408. `timer_c` sets it per call; the default
is the `timer_c_ms` setting (185 s). The handler deadline does not apply
while B rings: the worker owns the call from the moment the B leg is sent.

## Rewrite the SDP that crosses

```erlang
chappe_sip_b2b:relay(Legs, #{
    rewrite_sdp => fun(From, Sdp) -> anchor(From, Sdp) end
}).
```

`From` is the leg (`a` or `b`) the offer or answer came from. Use it to run
the SDP through a media anchor such as rtpengine before the other leg sees it.

## What crosses the legs

- A re-INVITE or UPDATE with a new offer goes to the other leg; its answer
  comes back in the 2xx. A failure (a 488, a 491 on glare) comes back as is.
- A re-INVITE or UPDATE with no offer, or with the SDP already in force (the
  same `o=` line), is a session refresh: its own leg answers it.
- A reliable 1xx from B (100rel, RFC 3262) is PRACKed on the B leg. The
  caller gets a reliable 1xx when it asked for 100rel, and the 2xx waits for
  its PRACK when that 1xx carried SDP.
- The `Reason` of a BYE or CANCEL (RFC 3326) goes out on the other leg's BYE
  or CANCEL.

## Notes

- Each leg negotiates and refreshes its own session timer (RFC 4028): see
  [Session timers](session-timers.md).
- A crash of either dialog fsm tears the call down (the relay monitors both).
- Server-initiated BYE reaches a WebSocket B leg over its flow automatically.
