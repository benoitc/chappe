# Configuration

This page lists what you can set in chappe_mrf: one application environment
key, the options of `connect_caller/3` and `create_endpoint/1`, and the
conference options. Read it when you wire chappe_mrf into a release or tune
a call or a room.

chappe_mrf also needs chappe_sip started with rtpengine (and chappe_mix for
native rooms) under `media`, and FreeSWITCH nodes in chappe_esl
(`chappe_esl:node_add/2` or the `nodes` env of chappe_esl). Each node needs
the `mrf` dialplan extension shown in the [README](../README.md).

## Application environment

| Key | Default | What it does |
|---|---|---|
| `esl_port` | unset | Port of the outbound socket listener FreeSWITCH connects back to. Set, the listener starts with the application. |
| `esl_ip` | `{127, 0, 0, 1}` | Address the listener binds. Set it to the interface FreeSWITCH reaches you on when FreeSWITCH runs on another host. |
| `esl_allow` | unset (any peer) | CIDR networks or addresses (strings or binaries) FreeSWITCH connects from. A peer outside is closed right after accept. |
| `shared_dir` | unset | `#{freeswitch => Dir, local => Dir}`: the folder FreeSWITCH records into, as the node and as this host see it. Recordings asked with `store => default` must be in it; unset, both paths are the same. |

```erlang
%% sys.config
[{chappe_mrf, [
    {esl_port, 8084},
    {esl_ip, {10, 0, 0, 5}},
    {esl_allow, ["10.0.0.8", "10.0.0.9"]}
]}].
```

The same at run time, after `chappe_sip:start/1` (it also installs the
loopback INVITE middleware native rooms need):

```erlang
ok = chappe_mrf:start(#{
    esl_port => 8084,
    esl_ip => {10, 0, 0, 5},
    esl_allow => [<<"10.0.0.8">>, <<"10.0.0.9">>]
}).
```

The listener binds 127.0.0.1 by default: the outbound socket has no
authentication, so it does not open to the network unless you say so. Keep
a firewall rule that lets only your FreeSWITCH hosts reach the port too. A
bad `esl_ip` or `esl_allow` returns `{error, {bad_option, ip | allow}}`.

When a listener started by chappe_mrf already runs on `esl_port` (from the
app env, or an earlier `start/1`), `start/1` keeps it only if you ask for
the same `esl_ip` and `esl_allow`. Otherwise it returns
`{error, {listener_running, RunningOpts}}` and the running listener stays
as it is: stop it with `chappe_mrf:stop_listener/0`, then start again.
See [Outbound connections](../../chappe_esl/docs/guides/outbound.md).

## Record options

`record/3`, `record_session/3` and `chappe_mrf_conf:record/3` take, beside
FreeSWITCH's own options:

| Key | Default | What it does |
|---|---|---|
| `store` | unset | `default` adopts the finished file into the recording store (chappe_audio). `record/3` then returns `{ok, Id}`; a session recording, once FreeSWITCH closed it (RECORD_STOP), sends the owner `{recorded, Id}`, and a room's (on mod_conference's stop-recording) the room's listeners `{recorded, Path, {ok, Id}}`. The file is taken in by a job of the store, never in the endpoint or the room. |
| `ref` | the endpoint's call_ref (else its id); the room's name | The call_ref the recording is filed under. |
| `parties` | `[]` | Who is on the call, for the sidecar. |

See [Record a call](../../chappe_audio/docs/guides/record.md).

## connect_caller/3 options

| Key | Default | What it does |
|---|---|---|
| `owner` | the caller | Gets the endpoint's events. |
| `notify` | the owner | Gets the call's `{chappe_sip_b2b, Ref, Event}`. |
| `node` | none | Use this chappe_esl node only, no failover. |
| `select` | `#{}` | `chappe_esl:node_select/1` options for the first node; other up nodes follow. |
| `targets` | none | `[{Node, SipUri}]` to try, bypassing chappe_esl. |
| `user` | `<<"mrf">>` | User of the INVITE to the node (the dialplan extension). |
| `attach_timeout` | `10000` | Milliseconds to wait for the outbound socket. |
| `relay` | `#{}` | Options of `chappe_sip_b2b:relay_async/2`. |
| `media` | `anchor` | Media mode of the B2BUA. Any other `chappe_sip_b2b:create_b2bua/4` option passes through too. |
| `b_headers` | `[]` | Extra headers on the INVITE; `X-Chappe-Call` is added. |

## create_endpoint/1 options

`owner`, `node`, `select`, `targets`, `user` and `attach_timeout` as above,
and:

| Key | Default | What it does |
|---|---|---|
| `sdp` | `chappe_mrf:inactive_sdp()` | The offer to the node. |
| `headers` | `[]` | Extra headers; `X-Chappe-Call` is added. |
| `timeout` | `32000` | Milliseconds for the INVITE. |

## Conference options

Passed to `chappe_mrf:conference/2`.

| Key | Backend | Default | What it does |
|---|---|---|---|
| `backend` | both | `native` | `native` (chappe_mix) or `fs` (mod_conference). |
| `owner` | both | none | The conference stops when it exits; unset, it runs until `chappe_mrf_conf:stop/1`. |
| `notify` | both | the caller | Gets `{chappe_mrf_conf, Conf, Event}`. |
| `anchor_params` | native | `#{}` | rtpengine flags (`#{a, b => map()}`) for a caller moved into the mixer. |
| `endpoint_params` | native | `#{}` | rtpengine flags between the mixer and an endpoint's node (`#{offer, answer => map()}`). |
| `focus` | native | `false` | `true` serves RFC 4575 conference-info. |
| `entity` | native | `sip:Name@<this node>` | Conference URI of the focus. |
| `node` | fs | `chappe_esl:node_select/1` | The node that holds the room. |
| `select` | fs | `#{}` | Options for that selection. |
| `profile` | fs | `<<"default">>` | mod_conference profile. |
| `bridge` | fs | `#{}` | `chappe_mrf:bridge/3` options for a caller joined from a call. |
| `join_timeout` | fs | `15000` | Milliseconds a member may take to appear in the room. |
| `refer_policy` | both | none | `fun(Info) -> boolean() \| {reject, Code}` for a REFER to the room; unset, REFERs are refused 403. |
| `dial` | both | `sofia/<dial_profile>/<target>` | `fun(Target) -> iodata()`: the dial string of a party a REFER adds. |
| `dial_profile` | both | `<<"external">>` | The sofia profile of the default dial string. |
| `dial_timeout` | both | `30000` | Milliseconds the added party has to answer. |
| `dial_endpoint` | native | `#{}` | `create_endpoint/1` options (`node`, `select`, `targets`) of the endpoint that dials it. |

Join options (`chappe_mrf_conf:join/3`): `name`, `mute`, `deaf`,
`moderator`, `uri` (who the member is, for a REFER's `method=BYE`); on fs
also `pin`, `pin_prompt` (default
`silence_stream://250`), `pin_tries` (`3`) and `flags`.

## Where it lives

- App env: `chappe_mrf_app:start/2`
- Call and endpoint options: `chappe_mrf:connect_caller/3`,
  `chappe_mrf:create_endpoint/1`
- Conference options: `chappe_mrf_conf:start/2`, `chappe_mrf_conf.hrl`
