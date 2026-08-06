# TLS

chappe_sip can bind a TLS (`sips`) listener on its own port, in addition to UDP/TCP.
It is a second sofia transport with your certificate and cipher policy. Read
this to accept `sips:` traffic.

## When to use it

- You accept SIP over TLS from peers or trunks on port 5061.
- You need `sips:` for browsers over `wss://`; note the WebSocket listener is
  separate (terminate `wss` at a load balancer). See
  [SIP over WebSocket](websocket.md).

## Prepare certificates

`cert_dir` holds the sofia certificate files:

- `agent.pem`: the certificate and its private key, concatenated.
- `cafile.pem`: the CA bundle for peer verification.

## Enable the listener

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:127.0.0.1:5060">>,
    tls => #{
        contact => <<"sips:0.0.0.0:5061;transport=tls">>,
        cert_dir => <<"/etc/chappe/certs">>,
        verify   => none            %% or `peer' to require a client cert
    }
}).
```

## Notes

- The TLS contact MUST be a `sips:` URI with `transport=tls`; a `sip:` URI
  excludes tls and start fails with "protocol not supported".
- The version floor is TLS 1.2 (1.0/1.1 are disabled). 1.3 follows the OpenSSL
  default.
- `verify` must be `none` or `peer`; any other value fails start with
  `{error, {tls, {bad_verify, _}}}` rather than silently disabling
  verification. `peer` requires each client to present a certificate that
  `cafile.pem` validates.
- sofia rejects a null cipher list; chappe_sip sends a sane default. Override with
  `ciphers => <<"...">>` and set `passphrase` if the key is encrypted.
- Comma-listed transports share one port, so TLS binds on its own port
  (typically 5061), separate from the UDP/TCP `contact`.
