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

```erlang
%% sys.config
[{chappe_mrf, [{esl_port, 8084}]}].
```

The same at run time, after `chappe_sip:start/1` (it also installs the
loopback INVITE middleware native rooms need):

```erlang
ok = chappe_mrf:start(#{esl_port => 8084}).
```

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

Join options (`chappe_mrf_conf:join/3`): `name`, `mute`, `deaf`,
`moderator`; on fs also `pin`, `pin_prompt` (default
`silence_stream://250`), `pin_tries` (`3`) and `flags`.

## Where it lives

- App env: `chappe_mrf_app:start/2`
- Call and endpoint options: `chappe_mrf:connect_caller/3`,
  `chappe_mrf:create_endpoint/1`
- Conference options: `chappe_mrf_conf:start/2`, `chappe_mrf_conf.hrl`
