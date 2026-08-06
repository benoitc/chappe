# Configuration and limits

Every tunable lives in `chappe_sip_config` with a default, read from the
`chappe_sip` application environment. Set them in `sys.config` (or with
`application:set_env/3` before `chappe_sip:start/1`). Read this to size the server and
tune its safety limits.

## When to use it

- You cap concurrency, adjust timeouts, or change the engine failure policy.
- You raise the registrar expiry or the message-size limit.

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

## Tunables

| Key | Default | What it does |
| --- | --- | --- |
| `max_message_size` | `262144` | Cap on either direction of the NIF/WS boundary. |
| `max_request_workers` | `10000` | Concurrent inbound request workers; excess is shed 503. |
| `max_dialogs` | `100000` | Dialog ceiling. |
| `max_uac_transactions` | `100000` | Outgoing transaction ceiling. |
| `handler_deadline_ms` | `30000` | Bounds a handler's pre-dialog phase; disarmed once the worker owns a dialog or forks. Expiry answers 500. |
| `health_interval_ms` | `5000` | Engine health-check period. |
| `health_miss_limit` | `3` | Missed health ticks before the engine is declared hung. |
| `engine_failure_action` | `halt` | `halt` (heart/systemd restarts the node) or `degrade` (SIP down, node up). |
| `engine_start_retries` | `10` | Start retries while a previous engine tears down. |
| `ws_idle_timeout_ms` | `600000` | Idle WS connections are closed (clients keepalive per RFC 7118). |
| `ws_client_txn_timeout_ms` | `64000` | WS UAC transaction timeout (no sofia Timer B/F over WS). |
| `ws_server_txn_timeout_ms` | `180000` | WS server transaction reaper. |
| `max_ws_connections` | `10000` | Concurrent WS connections; a further connect is refused and closed. |
| `ws_transport_max_mailbox` | `10000` | Inbound WS frames are dropped while the transport mailbox is this deep. |
| `ws_allowed_origins` | `[]` | Allowed browser Origins for the WS upgrade. Empty allows any; a non-empty list of binaries rejects everything else with 403. |
| `registrar_default_expires` | `3600` | REGISTER expiry when the request gives none. |
| `registrar_max_expires` | `86400` | Upper clamp on REGISTER expiry. |
| `registrar_min_expires` | `0` | Lower bound on a non-zero REGISTER expiry; a shorter one is refused 423 Interval Too Brief. 0 disables it. |
| `registrar_max_aors` | `100000` | Distinct AORs the location store holds; a new AOR past this is rejected 503. |
| `registrar_max_bindings_per_aor` | `10` | Contacts bound to one AOR; a REGISTER exceeding this is rejected 403. |
| `flow_token_secret` | (random) | Secret keying the Record-Route marker/flow-token HMAC. Unset generates a per-node random secret at boot; set a stable shared value only if record-routed dialogs must survive a restart or span a cluster. |

## Notes

- `handler_deadline_ms` bounds only a handler that has not yet created a dialog
  or forked. Long calls are not affected.
- Set `engine_mod` to `chappe_sip_engine_fake` for pure-Erlang tests (no NIF).
