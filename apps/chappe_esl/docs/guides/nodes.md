# Register and monitor FreeSWITCH nodes

The node registry keeps one connection per FreeSWITCH node, reconnects it when
it drops, and tracks each node's health and load. Read this when your service
drives several FreeSWITCH servers and needs to know which ones are usable.

## When to use it

- You run more than one FreeSWITCH and want each one watched for you.
- You want reconnects, health checks and load figures without writing them.
- You want to be told when a node goes up or down.

For a single connection you manage yourself, use `chappe_esl:connect/1`
instead (see [Inbound](inbound.md)).

## Match the heartbeat interval

FreeSWITCH sends a HEARTBEAT event every `event-heartbeat-interval` seconds
(20 by default). The registry marks a node down when no HEARTBEAT arrives for
twice `heartbeat_interval_ms`, so set the two to the same value. In
`switch.conf.xml`:

```xml
<param name="event-heartbeat-interval" value="5"/>
```

## Add a node

```erlang
ok = chappe_esl:node_add(fs1, #{
    host => "10.0.0.11",
    port => 8021,
    password => <<"ClueCon">>,
    tags => [conference, record],
    weight => 2,
    max_sessions => 400,
    sip_uri => <<"sip:10.0.0.11:5080">>,
    heartbeat_interval_ms => 5000
}).
```

Only `host` is required. A wrong option returns `{error, {bad_option, Key}}`,
and a name already in use returns `{error, already_exists}`.

## Add nodes from the app environment

Nodes listed in the `nodes` env of `chappe_esl` start with the application:

```erlang
{chappe_esl, [
    {nodes, [
        {fs1, #{host => "10.0.0.11", tags => [conference]}},
        {fs2, #{host => "10.0.0.12", tags => [conference]}}
    ]}
]}
```

## Check the state and the load

```erlang
[{fs1, up}, {fs2, down}] = chappe_esl:nodes(),
{ok, #{state := up, load := Load}} = chappe_esl:node_status(fs1),
#{sessions := Sessions, max_sessions := Max, idle_cpu := Idle} = Load.
```

A node is `connecting` on its first attempt, `up` once it is logged in,
subscribed and its probes pass, `draining` when you drained it, and `down`
otherwise. The load map holds `sessions`, `max_sessions`, `sessions_per_sec`,
`idle_cpu` and `uptime_ms` from HEARTBEAT, `calls` from `show calls count`,
and `heartbeat_at` / `probe_at` timestamps in milliseconds.

## Get told about changes

```erlang
ok = chappe_esl:node_subscribe(all),
receive
    {chappe_esl_node, Name, up} -> ok;
    {chappe_esl_node, Name, down} -> ok;
    {chappe_esl_node, Name, draining} -> ok;
    {chappe_esl_node, Name, {load, Load}} -> ok
end.
```

Pass a node name instead of `all` to follow one node. To receive the node's
events (CHANNEL_CREATE, CHANNEL_HANGUP_COMPLETE, BACKGROUND_JOB, HEARTBEAT and
the extra names in its `events` option):

```erlang
ok = chappe_esl:node_events(fs1),
receive
    {chappe_esl_node, fs1, {event, Event}} ->
        chappe_esl_event:name(Event)
end.
```

`node_unsubscribe/1` leaves both.

## Run commands on a node

```erlang
{ok, Status} = chappe_esl:node_api(fs1, "status"),
{ok, JobUuid} = chappe_esl:node_bgapi(fs1, "originate sofia/gw/1000 &park").
```

They run on the node's own connection and return `{error, down}` while it is
not up. The BACKGROUND_JOB result reaches `node_events/1` subscribers.

## Drain and remove

```erlang
ok = chappe_esl:node_drain(fs1),   % stays connected, no longer selected
ok = chappe_esl:node_resume(fs1),
ok = chappe_esl:node_remove(fs1).  % closes the connection
```

## Notes

- Probes run every `probe_interval_ms` (5000): `status`, `show calls count`
  and `sofia status`, each within `probe_timeout_ms` (2000). An `-ERR` or no
  answer marks the node down. Change the list with the `probes` option.
- Reconnects wait between `backoff_min_ms` (500) and `backoff_max_ms`
  (30000), doubling each time, with jitter.
- Without nodes the registry runs no process.
- `all` is reserved for subscriptions; do not name a node `all`.
- Every node option and its default is in [Configuration](../configuration.md).

## Where it lives

- Modules: `chappe_esl_nodes` (registry and notices), `chappe_esl_node` (one per node: connection, backoff, probes, load)
- Tests: `apps/chappe_esl/test/chappe_esl_nodes_SUITE.erl`
- Lab: `make interop-esl` (two FreeSWITCH nodes); `make demo-esl` to watch them from a shell
