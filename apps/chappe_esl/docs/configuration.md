# Configuration

This page lists what you can set in chappe_esl: the application environment,
the options of a node in the registry, and the options of a single
connection, listener or audio fork. Read it when you write a `sys.config` or add a node
and need a default.

## Application environment

| Key | Default | What it does |
|---|---|---|
| `nodes` | `[]` | FreeSWITCH nodes to register at boot: a list of `{Name, Opts}` or a `Name => Opts` map. Empty, the registry does not run until `chappe_esl:node_add/2`. |
| `max_frame_bytes` | `10485760` (10 MiB) | Largest frame a connection buffers. A frame over it closes the connection as a framing error. |

```erlang
%% sys.config
[{chappe_esl, [
    {nodes, [
        {fs1, #{host => "10.0.0.11", tags => [conference]}},
        {fs2, #{host => "10.0.0.12", tags => [conference], weight => 2}}
    ]},
    {max_frame_bytes, 4194304}
]}].
```

## Node options

Passed to `chappe_esl:node_add/2` or listed in `nodes`. Only `host` is
required; a wrong option returns `{error, {bad_option, Key}}`.

| Key | Default | What it does |
|---|---|---|
| `host` | required | Address or name of the node. |
| `port` | `8021` | mod_event_socket port. |
| `password` | `<<"ClueCon">>` | Event socket password. |
| `tags` | `[]` | Labels `node_select/1` filters on. |
| `weight` | `1` | Share for the `weighted` policy. |
| `max_sessions` | `infinity` | Cap on calls; the lower of this and the node's own Max-Sessions applies. |
| `sip_uri` | `undefined` | Where to send SIP to this node (chappe_mrf needs it). |
| `events` | `[]` | Events to subscribe to on top of HEARTBEAT, BACKGROUND_JOB, CHANNEL_CREATE and CHANNEL_HANGUP_COMPLETE. |
| `probes` | `status`, `show calls count`, `sofia status` | api commands run as health probes. |
| `heartbeat_interval_ms` | `20000` | Match FreeSWITCH's `event-heartbeat-interval`; no HEARTBEAT for twice this marks the node down. |
| `probe_interval_ms` | `5000` | Time between probe rounds. |
| `probe_timeout_ms` | `2000` | Time a probe may take. |
| `connect_timeout_ms` | `2000` | Time to connect and authenticate. |
| `backoff_min_ms` | `500` | First reconnect wait. |
| `backoff_max_ms` | `30000` | Longest reconnect wait (doubling with jitter). |

## Connection options

Passed to `chappe_esl:connect/1` for an inbound connection you manage
yourself.

| Key | Default | What it does |
|---|---|---|
| `host`, `port` | required | mod_event_socket address. |
| `password` | `<<"ClueCon">>` | Event socket password. |
| `connect_timeout` | `5000` | Milliseconds to connect and authenticate. |

## Listener options

`chappe_esl:start_listener/3,4` takes a port, a `chappe_esl_handler`
module, its arguments and, with `/4`, a map of options:

| Key | Default | Meaning |
|---|---|---|
| `linger` | `true` | `true` sends `linger` after `connect`, so events after the hangup still arrive; an integer sends `linger <Seconds>`; `false` sends nothing. |
| `ip` | `{127, 0, 0, 1}` | `inet:ip_address()` to listen on; an IPv6 address listens on IPv6. |
| `allow` | unset (any peer) | CIDR networks or addresses (binaries or strings) peers may connect from. A peer outside is closed right after accept and counted as `refused`. An empty list is refused. |
| `backlog` | `128` | Length of the queue of connections not yet accepted. |
| `max_pending` | `64` | Accepted connections that may wait for their channel data at once; a new one past it is closed (`busy`). |
| `first_frame_timeout` | `5000` | Milliseconds an accepted connection has to receive its channel data; then it is closed. |

A bad value returns `{error, {bad_option, Key}}` and nothing listens.
`chappe_esl:listener_stats/1` returns the listener's counters. See
[Outbound connections](guides/outbound.md).

## Audio fork options

`chappe_esl_call:audio_fork_start/3` takes a map:

| Key | Default | Meaning |
|---|---|---|
| `module` | `audio_fork` | `audio_fork` for mod_audio_fork, `audio_stream` for mod_audio_stream. Another value returns `{error, {bad_option, module}}`. |
| `mix` | `mono` | `mono`, `mixed` or `stereo`. |
| `rate` | `16000` | Sample rate in Hz (`8k` and `16k` on the mod_audio_stream command line). |
| `metadata` | none | First text frame sent to the server. |

## Where it lives

- App env: `chappe_esl_sup` (`nodes`), `chappe_esl_parser:new/0`
  (`max_frame_bytes`)
- Node options and defaults: `chappe_esl_node:validate/1`
- Connection options: `chappe_esl_conn`, `chappe_esl_inbound`
- Listener options: `chappe_esl_listener`
- Audio fork options: `chappe_esl_call`
