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

## Tunables

| Key | Default | What it does |
| --- | --- | --- |
| `max_message_size` | `262144` | Cap on either direction of the NIF/WS boundary, and the largest message sofia accepts. A `max_message_size` passed to `chappe_sip:start/1` overrides it. |
| `max_request_workers` | `10000` | Concurrent inbound request workers; excess is shed 503. |
| `max_dialogs` | `100000` | Dialog ceiling. |
| `max_uac_transactions` | `100000` | Outgoing transaction ceiling. |
| `handler_deadline_ms` | `30000` | Bounds a handler's pre-dialog phase; disarmed once the worker owns a dialog, forks, or sends an INVITE (a b2bua B leg). Expiry answers 500. |
| `timer_c_ms` | `185000` | Timer C of a proxy or b2bua INVITE branch: how long it may ring, restarted by each provisional. On expiry the branch is CANCELled and counts as a 408. The RFC asks for more than 3 minutes. |
| `proxy_accepted_ms` | `32000` | How long (64*T1) the proxy keeps forwarding new 2xx after the first (RFC 6026). |
| `non_invite_deadline_ms` | `30000` | The same for a non-INVITE request (SUBSCRIBE, REFER, MESSAGE...), capped by `handler_deadline_ms`: its client gives up after 32 s. |
| `health_interval_ms` | `5000` | Engine health-check period. |
| `health_miss_limit` | `3` | Missed health ticks before the engine is declared hung. |
| `engine_failure_action` | `halt` | `halt` (heart/systemd restarts the node) or `degrade` (SIP down, node up). |
| `engine_start_retries` | `10` | Start retries while a previous engine tears down. |
| `ws_idle_timeout_ms` | `600000` | A WS connection with no inbound traffic for this long is closed. |
| `ws_ping_interval_ms` | `30000` | The server pings each WS connection this often (`infinity`: never); the pongs keep a live connection under the idle timeout. |
| `ws_client_txn_timeout_ms` | `64000` | Timer B/F of a WS client transaction (no sofia timers over WS). |
| `ws_timer_c_ms` | `180000` | Timer C: a WS client INVITE with a provisional but no final is CANCELed after this; each provisional restarts it. |
| `ws_ack_timeout_ms` | `32000` | Timer H: how long a WS INVITE final waits for its ACK; an unACKed 2xx is then BYEd. |
| `ws_server_txn_timeout_ms` | `180000` | A WS request the app never answers gets 408 (INVITE) or 500 after this. |
| `max_ws_connections` | `10000` | Concurrent WS connections; a further connect is refused and closed. |
| `ws_transport_max_mailbox` | `10000` | Inbound WS frames are dropped while the transport mailbox is this deep. |
| `ws_allowed_origins` | `[]` | Allowed browser Origins for the WS upgrade. Empty allows any; a non-empty list of binaries rejects everything else with 403. |
| `registrar_default_expires` | `3600` | REGISTER expiry when the request gives none. |
| `registrar_max_expires` | `86400` | Upper clamp on REGISTER expiry. |
| `registrar_min_expires` | `60` | Lower bound on a non-zero REGISTER expiry under an hour; a shorter one is refused 423 Interval Too Brief with `Min-Expires`. 0 disables it. |
| `registrar_domains` | `any` | Domains the registrar keeps bindings for: `any`, or a list of binaries. A REGISTER whose Request-URI or To names another domain gets 404. |
| `registrar_flow_timer` | `120` | `Flow-Timer` (s) in the 2xx to a REGISTER that sets up an RFC 5626 outbound flow over a direct connection. |
| `supported_option_tags` | `[<<"100rel">>, <<"replaces">>, <<"timer">>, <<"tdialog">>, <<"norefersub">>]` | Option tags a request may list in `Require` without a 420. Add `<<"siprec">>` on a recording server; a single route adds its own with `chappe_sip:handle/3`. |
| `session_expires` | `undefined` | Session timer interval (s) to ask for (RFC 4028); undefined never asks, a peer request is still honored. |
| `session_min_se` | `90` | Smallest session interval accepted; a shorter one with `Supported: timer` gets 422 with `Min-SE`. |
| `session_refresher` | `uac` | Who refreshes when chappe_sip, as UAS, picks (`uac` or `uas`). |
| `registrar_max_aors` | `100000` | Distinct AORs the location store holds; a new AOR past this is rejected 503. |
| `registrar_max_bindings_per_aor` | `10` | Contacts bound to one AOR; a REGISTER exceeding this is rejected 403. |
| `media` | `#{}` | Media backends for `chappe_sip_media`, used when `chappe_sip:start/1` gets no `media` option: `rtpengine => #{nodes => [...]}` and `mix => #{ip => _, advertise => _}`. Empty starts nothing. See `docs/design/media.md`. |
| `flow_token_secret` | (random) | Secret keying the Record-Route marker/flow-token HMAC. Unset generates a per-node random secret at boot; set a stable shared value only if record-routed dialogs must survive a restart or span a cluster. A configured value shorter than 16 bytes stops the application from starting. |
| `record_route_ttl_s` | `86400` | Lifetime of a Record-Route marker, signed into it. A dialog record-routed through the proxy must end within it; a marker past it is refused. |

## Notes

- `handler_deadline_ms` bounds only a handler that has not yet created a dialog
  or forked. Long calls are not affected.
- Set `engine_mod` to `chappe_sip_engine_fake` for pure-Erlang tests (no NIF).
