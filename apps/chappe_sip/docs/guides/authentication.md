# Authentication

chappe_sip does SIP digest authentication (RFC 2617, RFC 7616 and RFC 8760:
MD5, MD5-sess, SHA-256 and SHA-256-sess with `qop=auth`) in Erlang, both as
the client (a UAC retries automatically on a challenge) and as the server (you
challenge a request and verify the response). Read this to authenticate
outbound requests, protect REGISTER, or challenge any inbound request.

## When to use it

- You call a proxy or registrar that challenges with 401 or 407.
- You run a registrar and want only authenticated UAs to write bindings.
- You want to challenge an inbound request (INVITE, MESSAGE, ...) before your
  handler runs.

## Authenticate outbound requests (UAC)

Pass `auth`; chappe_sip parses the challenges and resends with credentials.

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@example.com">>,
                               #{auth => #{user => <<"alice">>,
                                           pass => <<"secret">>}}).
```

The same option works for `chappe_sip:request/2` (OPTIONS, MESSAGE, ...).
When a proxy and the callee each want their own credentials, give a list;
an entry with `realm` answers only that realm, one without answers any:

```erlang
Auth = [#{realm => <<"proxy.example.com">>, user => <<"alice">>, pass => <<"p1">>},
        #{user => <<"alice">>, pass => <<"p2">>}],
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@example.com">>, #{auth => Auth}).
```

What the UAC does with a 401 or 407:

- It answers each Digest challenge it can, one per realm, in `Authorization`
  for a 401 and `Proxy-Authorization` for a 407, and keeps answering the
  realms of earlier rounds: a 407 then a 401 ends with both headers.
- Of several challenges for one realm it takes the strongest algorithm it
  supports (SHA-256 before MD5), the topmost on a tie. A challenge it does
  not understand (another algorithm, Basic) is ignored.
- A new challenge for a realm it already answered means the credentials were
  refused, and you get the 401/407 as `{error, #chappe_sip_error{}}`, unless
  it says `stale=true`: then only the nonce expired, and the request goes
  again with the new one.
- Each request sent with one nonce counts (`nc=00000001`, `00000002`, ...),
  so a retry after a 420 or 422 reuses the nonce with a fresh response.
- The 2xx ACK carries the INVITE's credentials. A 3xx to another scheme,
  host or port drops them.

## Protect REGISTER (registrar)

The ready-made REGISTER handler takes an `auth` option. See
[Registrar](registrar.md#require-authentication) for the full story.

```erlang
Auth = #{realm  => <<"example.com">>,
         domain => <<"example.com">>,
         secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                      (_)           -> error
                  end},
ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})).
```

## Challenge any inbound request (UAS)

Use the digest primitives in a handler: challenge when the credentials are
missing or wrong, re-challenge with `stale` when the nonce expired or was
replayed.

```erlang
Realm  = <<"example.com">>,
Secret = fun(<<"alice">>) -> {ok, <<"secret">>};
            (_)           -> error
         end,
Challenge = fun(Res, Stale) ->
    Hdrs = [{<<"WWW-Authenticate">>, V}
            || V <- chappe_sip_digest:challenges(Realm, #{stale => Stale})],
    chappe_sip_res:send(Res, 401, #{headers => Hdrs})
end,
ok = chappe_sip:invite(fun(Req, Res) ->
    Args = #{method        => chappe_sip_req:method(Req),
             authorization => chappe_sip_req:get(<<"authorization">>, Req),
             request_uri   => chappe_sip_req:uri(Req),
             realm         => Realm,
             secret        => Secret},
    case chappe_sip_digest:verify(Args) of
        {ok, _User}           -> your_handler(Req, Res);
        stale                 -> Challenge(Res, true);
        {error, uri_mismatch} -> chappe_sip_res:send(Res, 400);
        {error, _}            -> Challenge(Res, false)
    end
end).
```

`challenges/2` returns one value per algorithm, SHA-256 then MD5, all with
the same nonce (RFC 8760); put each in its own header. Pass
`#{algorithms => [<<"MD5">>]}` for a single MD5 challenge, which is what
`challenge/1,2` build.

## The digest primitives

| Function | Side | Does |
| --- | --- | --- |
| `chappe_sip_hdr:auth/1` | both | Parse any digest header into `#{scheme, params}`. |
| `chappe_sip_digest:select/1` | client | Keep the strongest supported challenge per realm. |
| `chappe_sip_digest:credentials/1` | client | Build an `Authorization` value from a parsed challenge; `nc` counts the requests sent with its nonce. |
| `chappe_sip_digest:challenges/2` | server | Build `WWW-Authenticate` values, one per algorithm, with a stateless nonce. |
| `chappe_sip_digest:challenge/1,2` | server | One MD5 `WWW-Authenticate` value (`/2` sets `stale=true`). |
| `chappe_sip_digest:verify/1` | server | Verify an `Authorization`; returns `{ok, User} \| stale \| {error, Reason}`. |

`verify/1` takes:

- `secret`: returns `{ok, Password}`, `{ha1, HA1}` (a precomputed hex
  `H(user:realm:password)` of the hash the client answers with, so you need
  not store plaintext), or `error` for an unknown user.
- `request_uri` (optional): the digest `uri` must name it, else
  `{error, uri_mismatch}`.
- `algorithms` (optional): the ones accepted, SHA-256 and MD5 by default.
- `qop` (optional, default `true`): our challenge offered `qop=auth`, so an
  answer without it (`{error, qop_missing}`) or with another qop
  (`{error, unsupported_qop}`) is refused. Pass `false` only if you
  challenged without qop.

## Notes

- `auth-int` is not implemented: a challenge offering only it is refused, not
  downgraded.
- An MD5 challenge without `qop` is answered in the RFC 2069 form, for older
  servers; a SHA-256 one without `qop` gets `qop=auth` (RFC 8760).
- The server nonce is a stateless HMAC over a timestamp, valid for 5 minutes.
  An expired nonce returns `stale`, so the client re-authenticates without
  prompting the user.
- The server remembers the highest nonce count it accepted per nonce
  (`chappe_sip_digest_nc`, swept as nonces expire, at most 200000 nonces): a
  replayed response, or one with a lower count, returns `stale`.
- The registrar binds the authenticated username to the AOR: its user part
  must be the user and its host one of `domain` (the realm when you give no
  `domain`), else the REGISTER is refused 403. A digest `uri` that is not the
  Request-URI gets 400.
