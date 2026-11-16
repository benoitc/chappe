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
same way (see below). On a native room, a caller you have not answered yet
joins from its INVITE handler (see [Answer a caller into the room](#answer-a-caller-into-the-room)). A second call to
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

### Record a native room

A native room is recorded through SIPREC: its mix goes to the recording
server you name, as one participant, until `stop_record/1` or the room's
end.

```erlang
ok = chappe_mrf_conf:record(Conf, <<"sip:srs@recorder.example.com">>,
                            #{ref => CallRef}),
ok = chappe_mrf_conf:stop_record(Conf).
```

`ref` is the recording's `call_ref` (default the room's name). Point it at
chappe's own recording server (`chappe_sip_siprec_srs:serve/3` with
`store => default`) to land the mix in the recording store, then find it
with `chappe_audio_store:find(CallRef)`.

### Answer a caller into the room

A caller whose INVITE you have not answered joins straight from its handler.
On native the room's mixer answers it through rtpengine, with no placeholder
leg first; on fs chappe answers it and bridges it to an endpoint on the
room's node.

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Conf} = chappe_mrf:conference(<<"ops">>, #{}),
    {ok, _Member} = chappe_mrf_conf:join(Conf, {call, Req, Res}, #{name => <<"bob">>})
end).
```

- Call it in the INVITE's request worker; it returns once the caller is in.
- The call then runs in a process of its own (`chappe_sip_b2b:relay_async/2`),
  so the handler may return. The caller hanging up is a `left` event.
- On fs the join's `pin`, `pin_prompt` and `pin_tries` apply as for a
  `B2b`.

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

Room flags, a size limit and recording:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{
    backend => fs, node => fs1, max_members => 10,
    room_flags => [<<"wait-mod">>, <<"audio-always">>]
}),
ok = chappe_mrf_conf:record(Conf, <<"/recordings/board.wav">>),
%% ...
ok = chappe_mrf_conf:stop_record(Conf).
```

`max_members` works on both backends: past it `join/3` returns
`{error, full}`. The recording is a file the node writes.

## Room events

Besides `joined`, `left` and `talking`, the receivers get:

```erlang
receive
    {chappe_mrf_conf, Conf, {muted, Member, true}} -> muted;
    {chappe_mrf_conf, Conf, {dtmf, Member, Digit}} -> Digit;           %% fs
    {chappe_mrf_conf, Conf, {play_done, Member, File}} -> File;        %% fs, play/3
    {chappe_mrf_conf, Conf, {play_done, File}} -> File;                %% fs, play/2
    {chappe_mrf_conf, Conf, lost} -> stop_sending_callers()            %% cluster
end.
```

`{play_done, File}` concerns the whole room, so it comes from the node's
events: add them when you register the node,
`chappe_esl:node_add(fs1, #{..., events => [<<"CUSTOM">>, <<"conference::maintenance">>]})`.

## Move a member to another room

```erlang
{ok, NewId} = chappe_mrf_conf:transfer(Lobby, Member, Board).
```

Both rooms use the same backend. On fs they are on one node and
mod_conference moves the channel; on native the member's call moves to the
other mixer through rtpengine, without a re-INVITE. The member leaves the
first room with reason `transferred`. An endpoint you joined to a native
room cannot move this way (`{error, {unsupported, endpoint_member}}`).

## Add or remove a party by REFER

A REFER to the room's URI asks it to bring a party in, or, with
`method=BYE` in the Refer-To, to remove one (RFC 4579 5.5, 5.11). Give the
room a policy and route REFERs to it:

```erlang
ok = chappe_sip:refer(fun chappe_mrf:focus_refer/2),
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{
    focus => true,
    refer_policy => fun(#{action := _, referrer := R}) -> is_moderator(R) end,
    dial_endpoint => #{select => #{}},
    dial_profile => <<"carrier">>
}),
{ok, M} = chappe_mrf_conf:join(Conf, B2b, #{uri => <<"sip:alice@example.com">>}).
```

- An added party is dialed into the room: on native an endpoint of the
  pool joins the mixer and bridges to it, on fs mod_conference dials it
  into the room. In a `focus => true` room (native or fs) that INVITE
  carries the room's name as its Contact user and `isfocus` (RFC 4579
  5.5); the Contact's host is the FreeSWITCH node that holds the call. It joins as `{joined, Member, #{uri := Target}}`, and the
  referrer gets NOTIFY 200 once it answers (408 after `dial_timeout`, or
  the party's status).
- `method=BYE` removes the member whose `uri` matches (the join's `uri`,
  or a dialed party's); 404 when none does. Only a `focus => true` room
  removes: any other room refuses it 403, whatever its policy says.
- Without `refer_policy` every REFER is refused 403. The policy sees
  `#{action, target, referrer, referred_by}`, and for an add the dial
  string it would run as `dial`; `referred_by` is only claimed, never
  grant on it alone. Decide on where the call goes (`dial`), not only on
  who asks: that is what a toll-fraud REFER aims at.
- A target URI with anything FreeSWITCH reads as dial-string syntax
  (`, | [ ] { } < > ' $ \`, `:_:`, spaces) is refused 403 before the
  policy runs: only letters, digits and `- . _ ~ ! * + = ; @ : %` pass.

A caller the room answers itself (`join/3` with `{call, Req, Res}`) gets
the conference URI with `isfocus` as its Contact in a `focus => true` room
(RFC 4579 4.2), and the room takes the REFERs in its dialog:

- in a focus room a REFER is to the focus: its Refer-To party is dialed
  in, with the Refer-To's Replaces on that INVITE (5.10), or with
  `method=BYE` the member it names is removed (5.11);
- in a room without `focus => true` it is an RFC 3515 transfer (and
  `method=BYE` is refused 403): the target takes the member's place on
  its call, shown as
  `{left, Member, transferred}` then `{joined, Member, #{uri := Target}}`.

The room's `refer_policy` decides each. A call you answered yourself
(`connect_caller/3`) carries the Contact you gave it: pass
`contact_params => #{a => chappe_sip_focus:contact_params()}` there for a
focus room, and `requests => [refer]`, then hand the room each
`{chappe_sip_b2b, Ref, {request, a, refer, Req, Res}}` with `b2b_event/2`.
Parties dialed in come from FreeSWITCH, with the room's name and
`isfocus` in its Contact in a focus room.

A member's own REFER on a call with `transfer => auto` is carried out by
its B2BUA: the target takes the member's place. Hand the room the call's
event from your notify process:

```erlang
receive
    {chappe_sip_b2b, _Ref, {transferred, _Leg, _Info}} = Ev ->
        ok = chappe_mrf_conf:b2b_event(Conf, Ev)
end.
```

The room shows `{left, Member, transferred}`, then
`{joined, Member, #{uri := Target}}`.

## Run rooms on a cluster

On one node, a room name names one room. On several nodes, two callers
dialing the same room on two nodes would land in two rooms. Set the
chappe_mrf setting `cluster => chappe_cluster` on every node, with
chappe_cluster configured (it starts on first use), and a room name has
one owner in the region:

```erlang
%% sys.config, on every node
{chappe_mrf, [{cluster, chappe_cluster}]}
```

```erlang
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{}),
{ok, Member} = chappe_mrf_conf:join(Conf, B2b, #{}).
```

- `conference/2` starts the room's process waiting, claims the lease
  `{chappe_mrf_conf, Name}` for it, then hands the lease over. Only then
  does the room register its name and take members. On another node,
  `conference/2` returns the pid of the room that holds the lease, found
  in the node's replica with no write to the region, and `join/3` works
  on it from there. A start that finds the room still waiting for its
  lease gets it once it runs.
- The claim runs in the process that calls `conference/2` and waits at
  most `claim_timeout` (1000 ms), so rooms opening at once never wait on
  each other.
- A clean stop of the room's node (`init:stop/0`, `docker stop`, stopping
  chappe_mrf) hands the room off first: the room gives its lease back, a
  room of the same name opens on a live node, and the members whose calls
  run on other nodes move there, with a short gap in the audio and no
  re-INVITE to the caller. The members whose calls run on the stopping
  node end with it. The handoff takes at most `drain_ms` (5000).
- When the owner node crashes (or is killed, or cut off), its members'
  calls on other nodes stay up, without the room's audio, until they hang
  up. `conference/2` returns `{error, {owner_unreachable, Node}}` until
  the lease runs out (within the cluster's `lease_ms`), then opens the
  room on a live node; new callers land there.
- When the region takes the lease back while the node runs (it lost its
  quorum, or paused), the room gets `lost`: it takes no new member
  (`{error, lost}`), sends `{chappe_mrf_conf, Conf, lost}` to its
  receivers and frees the name on its node. It then moves its members to
  the room that owns the name next, as soon as the region lets one open
  (on the majority side, or here once the quorum is back), trying for
  `rehome_ms` (30000), and stops when its last member leaves.
- A join, a REFER and a recording start check `chappe_cluster:valid/1`
  first; an fs join checks it before it bridges or answers the caller.
- fs rooms do not move: the conference lives in FreeSWITCH, and each
  member is a channel driven through the event socket the stopping node
  holds, which hangs the channel up when it closes. A clean stop gives
  the name back at once, so the next caller opens the room on a live
  node.

Without a quorum, `conference/2` does not open a room. It returns the
room the local replica names when this node reaches it, else `{error,
no_quorum}`: play a prompt or send the call elsewhere. The reason is that
the majority side can claim the name while the minority cannot. A room
opened without a lease on the minority would take members while the
majority's room takes others, and the two halves of the call would not
hear each other, with nothing to tell them. Refusing keeps one room per
name whenever a quorum exists, and calls already in a room are not
touched.

## Notes

- The room ends with `chappe_mrf_conf:stop/1`, or with the `owner` process
  you gave `conference/2`.
- `play/2` on an fs room plays into the room (`conference <name> play`).
- `relate/4` is native only: `{error, {unsupported, fs}}` on fs.

## Where it lives

- Modules: `chappe_mrf_conf` (API and process), `chappe_mrf_conf_native`,
  `chappe_mrf_conf_fs`; the loopback middleware is in `chappe_mrf`
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl`,
  `chappe_mrf_live_SUITE.erl`, `chappe_mrf_cluster_SUITE.erl` (rooms on
  three peer nodes)
- Lab: `make interop-mrf` (native and FreeSWITCH rooms)
- Design: [overview](../design/overview.md#native-conferences-and-the-loopback-middleware)
