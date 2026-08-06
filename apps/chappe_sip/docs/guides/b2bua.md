# B2BUA

A back-to-back user agent terminates the inbound call and originates a fresh
one, so enki sits in the middle of two independent dialogs. It relays
provisionals, the answer, ACKs, and BYE between the legs, and can rewrite
headers. Read this to bridge a caller to a callee under your control.

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
shared To-tag), bridges the 2xx SDP, and returns the two legs. `chappe_sip_b2b:relay/1`
blocks until either leg is torn down, then destroys the other.

## Options

```erlang
chappe_sip:create_b2bua(Req, Res, Callee, #{
    proxy_request_headers => {all, [<<"route">>]},   %% copy headers A -> B
    pass_failure          => true,                   %% relay a B failure to A
    flow                  => Flow                     %% originate B over a WS flow
}).
```

`proxy_request_headers` is `list | all | {all, Exclude}`. Set `flow` (from
`chappe_sip:location_flow/1`) to send the B leg to a registered WebSocket UA.

## Notes

- CANCEL from the caller while B rings is relayed to B.
- A crash of either dialog fsm tears the call down (the relay monitors both).
- Server-initiated BYE reaches a WebSocket B leg over its flow automatically.
