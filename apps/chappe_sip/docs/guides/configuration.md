# Configuration and limits

Every tunable lives in `chappe_sip_config` with a default, read from the
`chappe_sip` application environment. Set them in `sys.config` (or with
`application:set_env/3` before `chappe_sip:start/1`). Read this to size the server and
tune its safety limits.

## When to use it

- You cap concurrency, adjust timeouts, or change the engine failure policy.
- You raise the registrar expiry or the message-size limit.
- You accept an extension in `Require` (SIPREC, a custom tag).

## Set values

```erlang
%% sys.config
[
  {chappe_sip, [
    {max_request_workers, 5000},
    {handler_deadline_ms, 60000},
    {engine_failure_action, degrade}
  ]}
].
```

## Find a setting

Every key, its default and what it does is in the
[configuration reference](../configuration.md). The ones you are most likely
to change:

- `max_request_workers`, `max_dialogs`, `max_uac_transactions`: the
  ceilings of a busy node.
- `handler_deadline_ms`: how long a handler may take before it creates a
  dialog or forks.
- `engine_failure_action`: `halt` (the default) or `degrade`; see
  [Deployment](deployment.md).
- `timer_c_ms`: how long a proxy or B2BUA branch may ring.
- `registrar_domains` and `registrar_min_expires` on a registrar.

## Limits and overload

- Bounded request workers (503 shed past the cap), per-request handler
  deadline (500 on expiry), and a message-size cap on both directions of
  the NIF boundary, all on WS too (a WS-only node answers them without a
  native engine). Over WS a message past `max_message_size` closes the
  connection with 1009 inbound, checked by the ws parser on each frame and
  reassembled message before it is buffered, and is refused
  (`{error, too_large}`) outbound. All tunable in `chappe_sip_config`.

## Notes

- `handler_deadline_ms` bounds only a handler that has not yet created a dialog
  or forked. Long calls are not affected.
- Listen addresses are not settings: they are the `contact` (one URI or a
  list) and TLS `contact` of `chappe_sip:start/1`. See
  [Deployment](deployment.md) for several addresses.
- Set `engine_mod` to `chappe_sip_engine_fake` for pure-Erlang tests (no NIF).

## Where it lives

- Modules: `chappe_sip_config` (every default); the [configuration
  reference](../configuration.md).
- Tests: each feature's suite.
- Lab: none.
