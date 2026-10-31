# Register to a carrier

A registration client keeps one of your addresses registered at a remote
registrar: a SIP trunk, a carrier, or an account on an upstream PBX. chappe
sends the REGISTER, answers the digest challenge, refreshes before the
binding expires, and retries when the registrar fails. Read this when a
provider only sends you calls while you are registered with it.

## When to use it

- Your SIP trunk is registration based rather than IP based.
- You connect to an upstream PBX as one of its extensions.
- You need to know, in your app, whether the registration is up.

## Register

Start one registration per binding, under a name of your choice.

```erlang
ok = chappe_sip:register_client(trunk1, #{
    aor => <<"sip:4420711111@sip.carrier.example">>,
    auth => #{user => <<"4420711111">>, pass => <<"s3cret">>},
    expires => 600
}).
```

The options:

| Option | Default | What it does |
|---|---|---|
| `aor` | required | The address-of-record, used in From and To. |
| `registrar` | the AOR's domain | The Request-URI of the REGISTER. |
| `auth` | none | `#{user, pass, realm}`, or a list of them, one per realm. |
| `expires` | `3600` | The expiry you ask for, in seconds. |
| `contact` | our contact with the AOR's user | The Contact URI to bind. |
| `proxy`, `route_set`, `headers` | none | As for `chappe_sip_uac`: an outbound proxy, a preloaded route set, extra headers. |
| `retry_min_ms`, `retry_max_ms` | `1000`, `300000` | Bounds of the exponential backoff after a failure. |

`{error, bad_aor}` means the AOR does not parse; `{error, already_started}`
that the name is taken.

## Check where it stands

```erlang
{ok, #{status := registered, expires_in := Left}} =
    chappe_sip:register_status(trunk1).
```

The status is `registering`, `registered`, `failed` or `expired`. The map
also gives the expiry the registrar `granted`, the `last_status` received,
the `failures` in a row, and the `aor`, `registrar` and `contact`.

## Be told when it changes

```erlang
ok = chappe_sip:register_subscribe(self()),
receive
    {chappe_sip_regc, trunk1, failed} -> alert(trunk1);
    {chappe_sip_regc, trunk1, registered} -> ok
end.
```

The events are `registered` (a 2xx after a start, a failure or an expiry),
`failed` (a REGISTER failed) and `expired` (the binding ran out with no
successful refresh). Your process gets them for every registration until it
exits.

## Remove the binding

```erlang
ok = chappe_sip:unregister_client(trunk1).
```

This sends a REGISTER with `Expires: 0` and stops the process.

## Load registrations at boot

Put them in the `registrations` setting of `chappe_sip`, as a map of name to
options (or a list of option maps, each with a `name`). They go out once
`chappe_sip:start/1` has brought the stack up:

```erlang
{chappe_sip, [
    {registrations, #{
        trunk1 => #{aor => <<"sip:4420711111@sip.carrier.example">>,
                    auth => #{user => <<"4420711111">>, pass => <<"s3cret">>}}
    }}
]}
```

## Notes

- Every REGISTER of a registration shares one Call-ID and counts up its CSeq
  (RFC 3261 10.2.4).
- A 423 is retried at once with the `Min-Expires` it names. A 503 with
  `Retry-After` waits that long before the backoff applies.
- The refresh reuses the last challenge, so a registrar that challenges every
  REGISTER costs one round trip, not two.
- On application stop, registrations are removed before the stack goes down
  (their supervisor stops first).
- The registrations gauge `chappe_sip_registrations{status}` is in
  [Metrics](metrics.md).

## Where it lives

- Modules: `chappe_sip` (`register_client/2`, `unregister_client/1`,
  `register_status/1`, `register_subscribe/1`), `chappe_sip_regc` (one
  gen_statem per registration), `chappe_sip_regc_sup`.
- Tests: `chappe_sip_regc_SUITE`.
- Lab: none.
