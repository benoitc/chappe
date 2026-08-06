# Registrar

The registrar is a location store: it records REGISTER bindings (AOR to contact,
with expiry) and lets your routing logic resolve an address of record to its
current contacts. enki ships a ready-made REGISTER handler backed by it. Read
this to accept registrations and route to registered users.

## When to use it

- You accept REGISTER from UAs and route calls to wherever they last registered.
- You bridge or proxy to a registered WebSocket browser (you need its flow).

## Accept registrations

```erlang
{ok, _} = application:ensure_all_started(chappe_sip),
ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5060">>}),
ok = chappe_sip:register(chappe_sip:registrar()).
```

`chappe_sip:registrar/0` records the request's contacts (per-contact and header
`Expires`, `expires=0` removal, `Contact: *` clear, CSeq reorder rejection,
periodic sweep) and answers 200 with the live bindings.

## Require authentication

`chappe_sip:registrar/0` accepts any REGISTER, which is fine on a closed network but
lets anyone overwrite another user's bindings on a public edge. Pass an `auth`
option to require digest authentication before any binding is written:

```erlang
Auth = #{realm  => <<"example.com">>,
         secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                      (_)           -> error
                  end},
ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})).
```

The handler challenges an unauthenticated REGISTER with 401 and a stateless
nonce, verifies the digest response, and binds the authenticated username to
the AOR user-part (a REGISTER for a different AOR gets 403). `secret` returns
`{ok, Password}`, `{ha1, HA1}` (a precomputed `MD5(user:realm:password)`), or
`error` for an unknown user. For a custom policy pass a `fun((Req) -> ok |
{reject, Status} | {reject, Status, Headers})` instead of the map.

## Resolve an AOR

```erlang
[Contact | _] = chappe_sip:location(<<"sip:alice@example.com">>),          %% contact URIs
{ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@example.com">>).   %% first + transport flow
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

## Notes

- A WebSocket UA is reachable only over its flow; use `location_flow/1` and pass
  `{ws, Flow}` (proxy) or `#{flow => Flow}` (b2bua). See
  [SIP over WebSocket](websocket.md).
- A WS binding is dropped when its connection closes (RFC 5626). UDP bindings
  persist until their `Expires`.
- Default and maximum expiry are `registrar_default_expires` /
  `registrar_max_expires` in [Configuration](configuration.md).
