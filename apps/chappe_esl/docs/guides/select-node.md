# Pick a node for a call

`chappe_esl:node_select/1` returns the registered FreeSWITCH node a new call
should go to. Read this when you send calls to a pool of FreeSWITCH nodes and
need to choose one per call, then find that call again on the node.

## When to use it

- You place calls on one of several FreeSWITCH nodes.
- You want to skip nodes that are down, drained or full.
- You need nodes with a given capability (tags).

Register the nodes first (see [Register and monitor FreeSWITCH
nodes](nodes.md)).

## Select a node

```erlang
case chappe_esl:node_select(#{policy => least_sessions, tags => [conference]}) of
    {ok, Name} -> place_call(Name);
    {error, none_up} -> reject_call()
end.
```

Only nodes that are `up`, not draining, below their session limit and carrying
every tag asked for are candidates.

## Choose a policy

- `least_sessions` (the default): the fewest sessions.
- `idle_cpu`: the most idle CPU from the last HEARTBEAT.
- `weighted`: a random node in proportion to its `weight`. A weight of 0
  is never picked.

```erlang
{ok, Name} = chappe_esl:node_select(#{policy => weighted}).
```

## Send the call to the node

Keep the node's SIP address in its `sip_uri` option and read it back:

```erlang
{ok, #{sip_uri := Uri}} = chappe_esl:node_status(Name).
```

If the node refuses the call (503, timeout), select again: a node that keeps
failing goes down and drops out of the candidates.

## Find the call on the node

Put a header of your own on the INVITE, for example `X-Chappe-Call: <id>`.
FreeSWITCH copies it into the channel variables, so the CHANNEL_CREATE event
of the new channel carries it as `variable_sip_h_X-Chappe-Call`, next to the
channel's `Unique-ID`:

```erlang
ok = chappe_esl:node_events(Name),
receive
    {chappe_esl_node, Name, {event, Ev}} ->
        case chappe_esl_event:name(Ev) of
            <<"CHANNEL_CREATE">> ->
                CallId = chappe_esl_event:header(<<"variable_sip_h_X-Chappe-Call">>, Ev),
                Uuid = chappe_esl_event:header(<<"Unique-ID">>, Ev),
                link_call(CallId, Uuid);
            _ ->
                ok
        end
end.
```

From then on drive the channel with `chappe_esl:node_api(Name, ["uuid_kill ",
Uuid])` and the other `uuid_*` commands.

## Notes

- The session count moves on CHANNEL_CREATE and CHANNEL_HANGUP_COMPLETE, and
  is corrected by each HEARTBEAT and probe, so back-to-back selections see the
  calls just placed.
- A node is full at the lower of its `max_sessions` option and the
  Max-Sessions it reports.
- Ties go to the first node name in Erlang term order.

## Where it lives

- Modules: `chappe_esl` (`node_select/1`), `chappe_esl_nodes` (the selection over the ETS rows)
- Tests: `apps/chappe_esl/test/chappe_esl_nodes_SUITE.erl`
- Lab: `make interop-esl`; chappe_mrf picks nodes this way in `make interop-mrf`
