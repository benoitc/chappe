# Configuration

This page lists what you can set in chappe_rtpengine: the application
environment, which only concerns the DTMF listener, and the options of each
node you add. Read it when you write a `sys.config` or call
`chappe_rtpengine:add_node/2` and need a default.

## Application environment

| Key | Default | What it does |
|---|---|---|
| `dtmf_listen` | unset | UDP port of the DTMF listener, opened at boot. Point rtpengine's `--dtmf-log-dest` at it. Unset, the listener stays closed until `chappe_rtpengine_dtmf:open/1,2`. |
| `dtmf_ip` | any | Local address the boot-time listener binds. |
| `dtmf_allowed_sources` | any | List of source IPs whose datagrams are taken; others are dropped and counted. |

```erlang
%% sys.config
[{chappe_rtpengine, [
    {dtmf_listen, 2225},
    {dtmf_ip, {10, 0, 0, 5}},
    {dtmf_allowed_sources, [{10, 0, 0, 7}]}
]}].
```

The same at run time:

```erlang
{ok, Port} = chappe_rtpengine_dtmf:open(2225, #{
    ip => {10, 0, 0, 5},
    allowed_sources => [{10, 0, 0, 7}]
}).
```

Nodes are not read from the environment: add them with `add_node/2`. When
you use rtpengine through chappe_sip, the nodes go under
`media => #{rtpengine => #{nodes => [...]}}` in `chappe_sip:start/1`.

## Node options

Passed to `chappe_rtpengine:add_node/2`. Only `host` and `port` are
required.

| Key | Default | What it does |
|---|---|---|
| `host` | required | Address or name of the node. A name is resolved again on every TCP connect, and for UDP every `resolve_interval_ms`. |
| `port` | required | NG port (`--listen-ng`, `--listen-tcp-ng`, or the HTTP port for ws/wss). |
| `transport` | `udp` | `udp`, `tcp`, `ws` or `wss`. |
| `path` | `/` | HTTP path of the WebSocket. |
| `tls_opts` | `[]` | `ssl` client options for `wss`. |
| `timeout` | `1000` | Milliseconds per attempt. |
| `attempts` | `3` | Attempts before `{error, timeout}`. UDP retransmits; TCP and WebSocket only use the deadline. |
| `max_datagram` | `65507` | Largest UDP request; larger ones return `{error, too_large}` unsent. |
| `resolve_interval_ms` | `60000` | UDP: how often a host name is resolved again (`infinity` disables). |
| `resolve_after_timeouts` | `2` | UDP: resolve again after this many timeouts in a row. |
| `resolver` | inet | Fun from host to `{ok, Ip} \| {error, Reason}`, for custom lookups and tests. |
| `health_interval` | `5000` | Milliseconds between health pings. |
| `down_after` | `2` | Consecutive failures before the node is marked down. |

```erlang
ok = chappe_rtpengine:add_node(rtpe1, #{
    host => "rtpe1.example.net",
    port => 2223,
    timeout => 500,
    attempts => 4,
    health_interval => 2000
}).
```

## Session options

Passed to `chappe_rtpengine:start_session/1`.

| Key | Default | What it does |
|---|---|---|
| `call_id` | required | The call's Call-ID. |
| `node` | pool-selected | Pin the session to this node. |
| `dtmf` | `false` | `true`: the owner gets `{chappe_rtpengine_session, Pid, {dtmf, Event}}`. |

## Where it lives

- App env: `chappe_rtpengine_dtmf:init/1`
- Node options: `chappe_rtpengine_client` (`opts()` type and `init/1`),
  `chappe_rtpengine_pool:add_node/2`
- Session options: `chappe_rtpengine_session:init/1`
