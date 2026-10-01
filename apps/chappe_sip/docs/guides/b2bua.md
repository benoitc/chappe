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
    flow                   => Flow                   %% originate B over a WS flow
}).
```

`proxy_request_headers` and `proxy_response_headers` take
`list | all | {all, Exclude}`. `all` never copies the dialog headers,
`Session-Expires`/`Min-SE`, and, from B's 2xx, `Require`, `Supported`,
`Allow` and `RSeq`: those belong to one leg. A `Privacy: none` from A always
reaches B unchanged, whatever you copy (RFC 3323 4.2). Set `flow` (from
`chappe_sip:location_flow/1`) to send the B leg to a registered WebSocket UA.

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
