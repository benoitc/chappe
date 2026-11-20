# Configuration reference

Every application setting of chappe_sip, with its default and what it does.
Use it when you tune limits or turn a feature on from `sys.config`. Values
are read with `chappe_sip_config:get/1`, which falls back to the defaults
in `src/chappe_sip_config.erl`; `registrations` and `metrics` are read
directly from the application env. How to set them, and which ones matter
first, is in the [configuration guide](guides/configuration.md).

Listen addresses are not settings: they are the `contact` (one URI, a
contact map with `public` and `local_nets` for 1:1 NAT, or a list) and the
TLS `contact` of `chappe_sip:start/1`. See
[Deployment](guides/deployment.md#run-behind-11-nat).

## Start options of the native stack

These are options of `chappe_sip:start/1`, not application settings. Each
is checked before the stack starts: a value out of bounds or of the wrong
shape fails the start with `{error, {Key, Value}}`.

```erlang
ok = chappe_sip:start(#{
    contact => <<"sip:10.0.0.5:5060">>,
    sip_timers => #{t1 => 500, t2 => 4000, t4 => 5000},
    outbound_route => <<"sip:proxy.example.com;transport=tcp">>,
    tcp_keepalive_ms => 30000,
    udp_mtu => 1300,
    aliases => [<<"sbc.example.com">>]
}).
```

| Key | Default | What it does |
| --- | --- | --- |
| `sip_timers` | `#{t1 => 500, t2 => 4000, t4 => 5000}` | RFC 3261 timers in ms, for UDP, TCP and TLS transactions (WebSocket ones use the `ws_*` settings below). `t1` 10 to 60000, `t2` 10 to 600000 and never below `t1`, `t4` 10 to 600000. Timers B, F, H and J follow `t1` (64*T1). The first UDP retransmission comes after `t1` (sofia patch 0005). |
| `outbound_proxy` | none | Next hop only: a `sip:` or `sips:` URI every request with no route of its own goes to, with no Route header added (a UAC request with no `proxy` option, an in-dialog request with no route set). A proxied request keeps its own next hop. |
| `outbound_route` | none | A `sip:` or `sips:` URI preloaded as the one Route of every request with no proxy, flow or route set of its own (RFC 3261 8.1.2 recommends this form); `;lr` is added when missing. The proxy then sees a Route naming it. Not with `outbound_proxy`. |
| `tcp_keepalive_ms` | off | Sends a CRLFCRLF ping (RFC 5626 4.4.1) on every TCP connection idle this long, 1000 to 3600000. TCP only: TLS connections and UDP get no ping (see the note below the table). |
| `udp_mtu` | `1300` | A request larger than this goes over TCP instead of UDP (RFC 3261 18.1.1), 576 to 65535. |
| `aliases` | `[]` | Up to 16 other names of this node (a DNS name, or a `sip:`/`sips:` URI with an optional port). A Route naming one is ours, as a listen address is; a name with no port matches the port of each listen address. |

Keep-alive and TLS: sofia's TLS transport has no connection timer, and a
ping cannot be added in a contained way. A CRLFCRLF on a TLS connection has
to go through `SSL_write`, and sofia's `tls_write` keeps the buffer of a
write that would block and asserts that the next write passes the same
buffer. A ping that blocks on a connection whose peer stopped reading would
make the next SIP message fail that assertion. For TLS flows, rely on the
client's keep-alives (RFC 5626 4.4.1 makes the UA send them, at the
`registrar_flow_timer` interval) and on the registrar's expiry.

## Engine

| Key | Default | What it does |
| --- | --- | --- |
| `engine_mod` | `chappe_sip_nif` | The engine backend. `chappe_sip_engine_fake` runs the stack with no NIF, for pure-Erlang tests. |
| `health_interval_ms` | `5000` | Engine health-check period. |
| `health_miss_limit` | `3` | Missed health ticks before the engine is declared hung. |
| `engine_failure_action` | `halt` | `halt` (heart/systemd restarts the node) or `degrade` (SIP down, node up). |
| `engine_start_retries` | `10` | Start retries while a previous engine tears down. |
| `hep` | `undefined` | HEPv3 capture server used when `chappe_sip:start/1` gets no `hep` option: `#{host => _, port => _, capture_id => _}`. See [SIP capture](guides/capture.md). |

## Limits

| Key | Default | What it does |
| --- | --- | --- |
| `max_message_size` | `262144` | Cap on either direction of the NIF/WS boundary, and the largest message sofia accepts. A `max_message_size` passed to `chappe_sip:start/1` overrides it. |
| `max_request_workers` | `10000` | Concurrent inbound request workers; excess is shed 503. |
| `max_dialogs` | `100000` | Dialog ceiling. |
| `max_uac_transactions` | `100000` | Outgoing transaction ceiling. |
| `handler_deadline_ms` | `30000` | Bounds a handler's pre-dialog phase; disarmed once the worker owns a dialog, forks, or sends an INVITE (a b2bua B leg). Expiry answers 500. |
| `non_invite_deadline_ms` | `30000` | The same for a non-INVITE request (SUBSCRIBE, REFER, MESSAGE...), capped by `handler_deadline_ms`: its client gives up after 32 s. |

## Proxy and B2BUA

| Key | Default | What it does |
| --- | --- | --- |
| `timer_c_ms` | `185000` | Timer C of a proxy or b2bua INVITE branch: how long it may ring, restarted by each provisional. On expiry the branch is CANCELled and counts as a 408. The RFC asks for more than 3 minutes. |
| `proxy_accepted_ms` | 64*T1 (`32000`) | How long (Timer M) the proxy keeps forwarding new 2xx after the first (RFC 6026 7.2). Unset, it follows the T1 of `sip_timers`. |
| `record_route_ttl_s` | `86400` | Lifetime of a Record-Route marker, signed into it. A dialog record-routed through the proxy must end within it; a marker past it is refused. |
| `flow_token_secret` | (random) | Secret keying the Record-Route marker/flow-token HMAC. Unset generates a per-node random secret at boot; set a stable shared value only if record-routed dialogs must survive a restart or span a cluster. A configured value shorter than 16 bytes stops the application from starting. |
| `supported_option_tags` | `[<<"100rel">>, <<"replaces">>, <<"timer">>, <<"tdialog">>, <<"norefersub">>]` | Option tags a request may list in `Require` without a 420. Add `<<"siprec">>` on a recording server; a single route adds its own with `chappe_sip:handle/3`. |

## SIPREC

| Key | Default | What it does |
| --- | --- | --- |
| `siprec_srs` | `undefined` | The recording server URI `chappe_sip_siprec:start/3` uses when given `default`. |
| `siprec_max_per_call` | `2` | Recordings one call may have at once; one more is refused with `{error, too_many}`. |
| `siprec_answer_timeout_ms` | `10000` | How long a recording server may take to answer the INVITE or a re-INVITE. Past it the INVITE is cancelled, or the session ended with a BYE, and the owner gets `stopped` with reason `{srs, timeout}`. |
| `siprec_store` | `chappe_audio_store` | The store a recording server writes each stream to with `store => default` (`chappe_sip_siprec_srs:serve/3`): a module with `open/2`, `write/2` and `close/2`, as `chappe_audio_store` of the chappe_audio app has them. |
| `siprec_rtp_ports` | `undefined` | The UDP ports a recording server's receivers bind, `{Min, Max}`: each stream takes a free port in the range (an even port and the one above it, for its RTCP, when the client does not offer `a=rtcp-mux`), and a stream that finds none is refused with port 0. Set it when the server runs behind a NAT or in a container that publishes only those ports. `undefined` binds any port; the `rtp_ports` option of `chappe_sip_siprec_srs:serve/3` overrides it. |

## WebSocket

| Key | Default | What it does |
| --- | --- | --- |
| `ws_idle_timeout_ms` | `600000` | A WS connection with no inbound traffic for this long is closed. |
| `ws_ping_interval_ms` | `30000` | The server pings each WS connection this often (`infinity`: never); the pongs keep a live connection under the idle timeout. |
| `ws_client_txn_timeout_ms` | `64000` | Timer B/F of a WS client transaction (no sofia timers over WS). |
| `ws_timer_c_ms` | `180000` | Timer C: a WS client INVITE with a provisional but no final is CANCELed after this; each provisional restarts it. |
| `ws_ack_timeout_ms` | 64*T1 (`32000`) | Timer H: how long a WS INVITE final waits for its ACK; an unACKed 2xx is then BYEd. Unset, it follows the T1 of `sip_timers`. |
| `ws_server_txn_timeout_ms` | `180000` | A WS request the app never answers gets 408 (INVITE) or 500 after this. |
| `ws_progress_ms` | `60000` | A ringing WS INVITE sends its last non-100 provisional again this often until the final (RFC 3261 13.3.1.1); `infinity`: never. |
| `max_ws_connections` | `10000` | Concurrent WS connections; a further connect is refused and closed. |
| `ws_transport_max_mailbox` | `10000` | Inbound WS frames are dropped while the transport mailbox is this deep. |
| `ws_allowed_origins` | `[]` | Allowed browser Origins for the WS upgrade. Empty allows any; a non-empty list of binaries rejects everything else with 403. |

## Registrar

| Key | Default | What it does |
| --- | --- | --- |
| `registrar_default_expires` | `3600` | REGISTER expiry when the request gives none. |
| `registrar_max_expires` | `86400` | Upper clamp on REGISTER expiry. |
| `registrar_min_expires` | `60` | Lower bound on a non-zero REGISTER expiry under an hour; a shorter one is refused 423 Interval Too Brief with `Min-Expires`. 0 disables it. |
| `registrar_domains` | `any` | Domains the registrar keeps bindings for: `any`, or a list of binaries. A REGISTER whose Request-URI or To names another domain gets 404. |
| `registrar_flow_timer` | `120` | `Flow-Timer` (s) in the 2xx to a REGISTER that sets up an RFC 5626 outbound flow over a direct connection. |
| `registrar_max_aors` | `100000` | Distinct AORs the location store holds; a new AOR past this is rejected 503. |
| `registrar_max_bindings_per_aor` | `10` | Contacts bound to one AOR; a REGISTER exceeding this is rejected 403. |
| `registrar_sweep_ms` | `30000` | How often expired bindings are deleted from the location store; lookups skip them meanwhile. |
| `cluster` | `none` | `none`: the location store is this node's. `chappe_cluster`: it is the region's KV, shared by every node (chappe_sip starts chappe_cluster at boot, before its own processes; a release without it is refused with `{cluster, {chappe_cluster_not_installed, _}}`, and any other value with `{cluster, {badarg, Value}}`); see the registrar guide, "Run the registrar on a cluster". It also lets a peer be pinged from one node (`probe => singleton`, [Run an SBC](guides/sbc.md#ping-a-peer-from-one-node-of-a-cluster)). |
| `registrar_cluster_timeout_ms` | `1000` | On a cluster, how long a REGISTER waits for the region's quorum before it gets 503. |
| `wall_clock` | `{hlc, physical_clock, []}` | The wall clock (`{M, F, A}` returning ms) of the node's hybrid logical clock, when chappe_cluster does not run one. Message-waiting updates are ordered by it. |
| `hlc_max_offset_ms` | `10000` | How far (ms) a stamp from another node may move that clock past its wall clock. |
| `registrar_retry_after` | `5` | On a cluster, the `Retry-After` (s) of the 503 a REGISTER gets without a quorum. |

## Event state compositor (PUBLISH)

| Key | Default | What it does |
| --- | --- | --- |
| `esc_max_publications` | `100000` | Live publications the ESC holds in all; a new one past this is rejected 503 with `Retry-After`. Refreshes and modifies of a live publication are still taken. |
| `esc_max_publications_per_resource` | `16` | Live publications for one resource, across its packages; a new one past this is rejected 503 with `Retry-After`. |
| `esc_max_body_size` | `65536` | Bytes of one PUBLISH body; a larger one is rejected 413 and nothing is stored. |

## Session timers

| Key | Default | What it does |
| --- | --- | --- |
| `session_expires` | `undefined` | Session timer interval (s) to ask for (RFC 4028); undefined never asks, a peer request is still honored. |
| `session_min_se` | `90` | Smallest session interval accepted; a shorter one with `Supported: timer` gets 422 with `Min-SE`. |
| `session_refresher` | `uac` | Who refreshes when chappe_sip, as UAS, picks (`uac` or `uas`). |

## Features started at boot

| Key | Default | What it does |
| --- | --- | --- |
| `media` | `#{}` | Media backends for `chappe_sip_media`, used when `chappe_sip:start/1` gets no `media` option: `rtpengine => #{nodes => [...]}` and `mix => #{ip => _, advertise => _}`. Empty starts nothing. See [Media](guides/media.md). |
| `peers` | `[]` | OPTIONS-monitored peers added at start: a list of `{Name, Opts}` or a map `Name => Opts`. See [Run an SBC](guides/sbc.md). |
| `registrations` | `#{}` | Outbound registrations started once `chappe_sip:start/1` has brought the stack up: a map `Name => Opts`, or a list of option maps with a `name`. See [Register to a carrier](guides/register-to-a-carrier.md). |
| `metrics` | `true` | `false` records no metrics; `#{port => P, ip => Ip}` also serves `GET /metrics` on that port (127.0.0.1 by default). See [Metrics](guides/metrics.md). |
