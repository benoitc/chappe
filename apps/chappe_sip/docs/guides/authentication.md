# Authentication

enki does SIP digest authentication (RFC 2617/7118, MD5 with `qop=auth`) in
Erlang, both as the client (a UAC retries automatically on a challenge) and as
the server (you challenge a request and verify the response). Read this to
authenticate outbound requests, protect REGISTER, or challenge any inbound
request.

## When to use it

- You call a proxy or registrar that challenges with 401 or 407.
- You run a registrar and want only authenticated UAs to write bindings.
- You want to challenge an inbound request (INVITE, MESSAGE, ...) before your
  handler runs.

## Authenticate outbound requests (UAC)

Pass `auth`; enki parses the challenge and resends with credentials.

```erlang
{ok, Dialog} = chappe_sip:create_uac(<<"sip:bob@example.com">>,
                               #{auth => #{user => <<"alice">>,
                                           pass => <<"secret">>}}).
```

The same option works for `chappe_sip:request/2` (OPTIONS, MESSAGE, ...). enki retries
once, using `Authorization` for a 401 and `Proxy-Authorization` for a 407.

## Protect REGISTER (registrar)

The ready-made REGISTER handler takes an `auth` option. See
[Registrar](registrar.md#require-authentication) for the full story.

```erlang
Auth = #{realm  => <<"example.com">>,
         secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                      (_)           -> error
                  end},
ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})).
```

## Challenge any inbound request (UAS)

Use the digest primitives in a handler: challenge when there are no
credentials, verify when there are.

```erlang
Realm  = <<"example.com">>,
Secret = fun(<<"alice">>) -> {ok, <<"secret">>};
            (_)           -> error
         end,
ok = chappe_sip:invite(fun(Req, Res) ->
    case chappe_sip_req:get(<<"authorization">>, Req) of
        undefined ->
            Chal = chappe_sip_digest:challenge(Realm),
            chappe_sip_res:send(Res, 401,
                          #{headers => [{<<"WWW-Authenticate">>, Chal}]});
        Auth ->
            case chappe_sip_digest:verify(#{method        => chappe_sip_req:method(Req),
                                      authorization => Auth,
                                      realm         => Realm,
                                      secret        => Secret}) of
                {ok, _User} ->
                    your_handler(Req, Res);
                stale ->
                    Fresh = chappe_sip_digest:challenge(Realm, true),
                    chappe_sip_res:send(Res, 401,
                                  #{headers => [{<<"WWW-Authenticate">>, Fresh}]});
                {error, _} ->
                    chappe_sip_res:send(Res, 403)
            end
    end
end).
```

## The digest primitives

| Function | Side | Does |
| --- | --- | --- |
| `chappe_sip_hdr:auth/1` | both | Parse any digest header into `#{scheme, params}`. |
| `chappe_sip_digest:credentials/1` | client | Build an `Authorization` value from a parsed challenge. |
| `chappe_sip_digest:challenge/1,2` | server | Build a `WWW-Authenticate` value with a stateless nonce (`/2` sets `stale=true`). |
| `chappe_sip_digest:verify/1` | server | Verify an `Authorization`; returns `{ok, User} \| stale \| {error, Reason}`. |

`secret` returns `{ok, Password}`, `{ha1, HA1}` (a precomputed
`MD5(user:realm:password)`, so you need not store plaintext), or `error` for an
unknown user.

## Notes

- MD5 with `qop=auth` only. SHA-256 and `auth-int` are refused with an error,
  not downgraded to a weaker form.
- The server nonce is a stateless HMAC over a coarse timestamp (no server-side
  store), valid for 5 minutes. An expired nonce returns `stale`, so the client
  re-authenticates without prompting the user.
- The UAC does not replay credentials across a cross-authority (3xx) redirect.
- The registrar binds the authenticated username to the AOR user-part: a
  REGISTER for a different AOR is refused 403.
