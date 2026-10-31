# Run a conference (native or FreeSWITCH)

`chappe_mrf:conference/2` starts a conference process that owns its room,
on one of two backends: `native` (chappe_mix behind rtpengine) or `fs`
(mod_conference on one FreeSWITCH node). The room outlives every caller
until you stop it. Use native for rooms chappe controls sample by sample
(listen, whisper, talker events); use fs when the room should live with
the rest of your FreeSWITCH media.

## When to use it

- Callers dial into a meeting room.
- A supervisor listens to an agent without being heard (native, `relate`).
- A room needs a PIN.

## Start a room and join callers

```erlang
{ok, Conf} = chappe_mrf:conference(<<"sales">>, #{backend => native}),
{ok, Member} = chappe_mrf_conf:join(Conf, B2b, #{name => <<"alice">>}).
```

`B2b` is the handle `connect_caller/3` returned; an endpoint joins the
same way (see below). A second call to
`conference/2` with the same name returns the same process. The process
that started the room gets its events:

```erlang
receive
    {chappe_mrf_conf, Conf, {joined, M, #{name := Name}}} -> {M, Name};
    {chappe_mrf_conf, Conf, {left, M, Reason}} -> {M, Reason};
    {chappe_mrf_conf, Conf, {talking, M, true}} -> M
end.
```

`chappe_mrf_conf:events/2` adds another receiver.

## Control the members

```erlang
ok = chappe_mrf_conf:mute(Conf, Member),
ok = chappe_mrf_conf:deaf(Conf, Member),
ok = chappe_mrf_conf:kick(Conf, Member),
ok = chappe_mrf_conf:lock(Conf),
Members = chappe_mrf_conf:members(Conf).
```

`unmute/2`, `undeaf/2`, `unlock/1` undo them, and `leave/2` hangs a member
up like `kick/2` with the reason `departed`.

## Native rooms

A caller joins through a loopback INVITE: `replace_b/3` swaps its leg for
a chappe_mix leg, and rtpengine stays in front (codecs, SRTP, WebRTC).
When the mixer runs on another rtpengine interface than the caller's
current leg, say so:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"ops">>, #{
    anchor_params => #{b => #{direction => [host, host]}}
}).
```

An endpoint of `create_endpoint/1` joins a native room too: its dialog is
re-INVITEd with an offer from the mixer through rtpengine, so the
FreeSWITCH channel and the room meet in rtpengine. Give the interfaces
between the mixer and the node when they differ:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"ops">>, #{
    endpoint_params => #{offer => #{direction => [host, docker]},
                         answer => #{direction => [docker, host]}}
}),
{ok, Ep} = chappe_mrf:create_endpoint(#{}),
{ok, Member} = chappe_mrf_conf:join(Conf, Ep, #{}).
```

Kicking an endpoint takes it out of the room; its channel stays yours.
An endpoint of `connect_caller/3` already carries a call: join the call
(`B2b`) instead.

Native only:

```erlang
%% the supervisor hears the agent, the agent does not hear the supervisor
ok = chappe_mrf_conf:relate(Conf, Agent, Supervisor, nohear),
%% a prompt to every member, played by rtpengine on each caller's leg
ok = chappe_mrf_conf:play(Conf, <<"/media/beep.wav">>).
```

With `focus => true`, the room serves RFC 4575 conference-info. Register
the SUBSCRIBE handler once:

```erlang
ok = chappe_sip:event_package(<<"conference">>, fun chappe_mrf:focus_subscribe/2).
```

## FreeSWITCH rooms

```erlang
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{
    backend => fs, node => fs1, profile => <<"default">>
}),
{ok, Member} = chappe_mrf_conf:join(Conf, B2b, #{
    pin => <<"1234">>, pin_prompt => <<"/media/pin.wav">>, moderator => true
}).
```

A caller joined from its call is bridged into a new endpoint on the
room's node, enters the PIN (`play_collect`, three tries), then runs the
conference application. Member ids are mod_conference's. An endpoint
already on that node joins as it is: `chappe_mrf_conf:join(Conf, Ep, #{})`.

## Notes

- The room ends with `chappe_mrf_conf:stop/1`, or with the `owner` process
  you gave `conference/2`.
- `play/2` on an fs room plays into the room (`conference <name> play`).
- `relate/4` is native only: `{error, {unsupported, fs}}` on fs.

## Where it lives

- Modules: `chappe_mrf_conf` (API and process), `chappe_mrf_conf_native`,
  `chappe_mrf_conf_fs`; the loopback middleware is in `chappe_mrf`
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl`,
  `chappe_mrf_live_SUITE.erl`
- Lab: `make interop-mrf` (native and FreeSWITCH rooms)
- Design: [overview](../design/overview.md#native-conferences-and-the-loopback-middleware)
