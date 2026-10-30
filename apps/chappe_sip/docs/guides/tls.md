# TLS

chappe_sip can bind a TLS (`sips`) listener on its own port, in addition to UDP/TCP.
It is a second sofia transport with your certificate and cipher policy, and
it is also what chappe_sip uses for outbound `sips:` requests. Read this to
accept and send SIP over TLS.

## When to use it

- You accept SIP over TLS from peers or trunks on port 5061.
- You send to `sips:` targets (a trunk, a proxy branch) and must check who
  answers.
- You need `sips:` for browsers over `wss://`; the WebSocket listener is
  separate: give it a `wss` option with the same cert dir, or terminate
  `wss` at a load balancer. See [SIP over WebSocket](websocket.md).

## Prepare certificates

`cert_dir` holds the sofia certificate files:

- `agent.pem`: the certificate and its private key, concatenated.
- `cafile.pem`: the CA bundle that signs the peers you accept.

The certificate names your SIP domain in a subjectAltName, as a `URI:sip:`
or a `DNS:` entry (RFC 5922). sofia does not match IP-address entries.

## Enable the listener

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:127.0.0.1:5060">>,
    tls => #{
        contact  => <<"sips:0.0.0.0:5061;transport=tls">>,
        cert_dir => <<"/etc/chappe/certs">>
    }
}).
```

## Verification

- Outbound connections are verified by default (`verify => peer`): the server
  certificate must chain to `cafile.pem` and name the target host in its
  subjectAltName (RFC 5922 7.3). A server that fails gets the connection
  closed and no request.
- Inbound clients are not asked for a certificate unless you set
  `verify_clients => true`; then a client without one `cafile.pem` signs is
  refused (RFC 5922 7.4).
- `verify => none` turns outbound checks off and is refused unless you also
  pass `allow_insecure => true`. Keep that to tests.

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:0.0.0.0:5060">>,
    tls => #{
        contact        => <<"sips:0.0.0.0:5061;transport=tls">>,
        cert_dir       => <<"/etc/chappe/certs">>,
        verify_clients => true
    }
}).
```

## SIPS in dialogs and through the proxy

- A 2xx to a dialog formed over TLS, or with a `sips:` Request-URI, top
  Record-Route or Contact, carries our `sips:` Contact (RFC 3261 12.1.1).
- A request we originate to a `sips:` Request-URI, `proxy` or first
  `route_set` entry carries our `sips:` Contact, and so do the target
  refreshes of the dialog it forms (8.1.1.8, 12.2.1.1). A `sips:`
  Request-URI goes over TLS even through a `sip:` proxy or route (8.1.2).
  See [Originate calls](originate-calls.md).
- A `sips:` URI with `transport=udp` is refused, as a request target and as
  a proxy target (19.1.1).
- The proxy record-routes with its `sips:` address when the forwarded
  request is SIPS, forwards a SIPS request only to a SIPS target, and sends a
  SIP request for a SIPS target over TLS (RFC 5630). See [Proxy](proxy.md).

## Notes

- The TLS contact MUST be a `sips:` URI with `transport=tls`; a `sip:` URI
  excludes tls and start fails with "protocol not supported". The URIs
  chappe_sip puts in messages never carry `transport=tls`.
- The version floor is TLS 1.2 (1.0/1.1 are refused). 1.3 follows the OpenSSL
  default.
- `verify` must be `peer` or `none`, `verify_clients` a boolean; any other
  value fails start with `{error, {tls, _}}` rather than silently weakening
  verification.
- sofia rejects a null cipher list; chappe_sip sends a sane default. Override with
  `ciphers => <<"...">>` and set `passphrase` if the key is encrypted.
- Comma-listed transports share one port, so TLS binds on its own port
  (typically 5061), separate from the UDP/TCP `contact`.

## Where it lives

- Modules: the TLS options of the NIF (`nif_start`), `chappe_sip_engine`
  (`validate_tls/1`), `chappe_sip_route` (sips Record-Route).
- Tests: `chappe_sip_tls_SUITE`.
- Lab: `make interop-conformance`.
