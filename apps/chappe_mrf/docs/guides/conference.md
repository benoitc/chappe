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

## Add, remove or refer a party by REFER

A REFER to the room's URI asks it to bring a party in, with `method=BYE`
in the Refer-To to remove one, or with `method=REFER` to have a party
REFERred to the conference (RFC 4579 5.5, 5.11, 5.7). Give the room a
policy and route REFERs to it:

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

The room answers a REFER only after its own checks and the policy, in
this order:

1. the room owns its name (cluster lease), else 503;
2. the request: a target FreeSWITCH would read as dial-string syntax
   (`, | [ ] { } < > ' $ \`, `:_:`, spaces) is refused 403 before the
   policy runs, as are removal and `method=REFER` in a room without
   `focus => true`, a `method=REFER` whose own Refer-To is not a plain
   reference to this room's URI (no method, no headers), and a party that
   is the room itself: each could make the room REFER or call itself in a
   loop;
3. the policy (below): `false` is 403, `{reject, Code}` is Code;
4. the room's state, only once the policy said yes: for a removal the
   member it names (none is 404, more than one 485), and room for one
   more, for an add or a refer (a locked room 403, a full one 486, the
   parties being dialed counting as members, the rule `join/3` follows).

Then the REFER gets 200, with the conference URI and `isfocus` as Contact
in a focus room, and NOTIFY 100, and the room carries it out:

- An added party is dialed: on native an endpoint of the pool joins the
  mixer out of sight, then bridges to it; on fs mod_conference dials it
  into the room. The INVITE carries the Refer-To's Replaces (5.10), the
  REFER's Referred-By (its URI only), and in a focus room the room's name
  as its Contact user and `isfocus` (5.5; the Contact's host is the
  FreeSWITCH node). The party is no member, and nothing it plays reaches
  the room, until it answered; then it joins as
  `{joined, Member, #{uri := Target}}` and the referrer hears 200. A
  party that does not answer gives its status (486, 603, 480), 408 after
  `dial_timeout`, and the room stays as it was.
- `method=BYE` removes the member whose endpoint entity
  (`<conference URI>;member=Id`, as the roster shows it) the Refer-To is,
  else the one member with that address-of-record; it leaves `kicked`.
  Only this room's members are looked at.
- `method=REFER` makes the focus REFER the party to the conference URI,
  as the focus; the referrer's final status is the party's answer to that
  REFER. The party then calls in like anyone (its PIN, if `join/3` asks
  one).
- A REFER repeated from the same dialog (or the same Call-ID and From
  tag) for the same target dials nobody again: it hears the first one's
  outcome. Adding a member already in answers 200 at once.
- When the room ends, the REFERs still under way get a final NOTIFY 487
  and their dials are given up.

The policy runs in the room process and gets the same keys for every
action, `undefined` where one does not apply, so a clause can match any
of them; one that crashes (no clause for the action, say) refuses the
REFER 403 and the room goes on. It sees `chappe_sip_focus:refer_info/2`'s
map plus the room's view:

| Key | What it is |
|---|---|
| `action` | `add`, `remove` or `refer` |
| `target` | the Refer-To URI, without its method |
| `referrer` | the REFER's From, what its dialog or your digest vouches for |
| `referred_by` | the REFER's Referred-By: only claimed, never grant on it alone |
| `member` | the referrer's member id: its dialog with the room, or the one its Target-Dialog names (RFC 4538); else `undefined` |
| `target_dialog`, `origin` | the dialog a Target-Dialog names, and who sent the REFER |
| `replaces`, `nested` | the Refer-To's Replaces, and for `refer` the Refer-To it carries |
| `dial` | add: the dial string the room would run |
| `removes` | remove: the member it names, or `undefined` |

Decide on where the call goes (`dial`), not only on who asks: that is what
a toll-fraud REFER aims at. A party a REFER dials out never enters a PIN;
one that calls in, referred or not, goes through `join/3` and its options.

For the referrer to hear the party's 180 and 183, give the node those
events: the room follows the dialed leg on the node's event connection,
marked with the `chappe_dial` channel variables. Put `CUSTOM` last: the
event command reads every name after it as a subclass.

```erlang
ok = chappe_esl:node_add(fs1, #{
    host => "10.0.0.5", port => 8021,
    events => [<<"CHANNEL_PROGRESS">>, <<"CHANNEL_PROGRESS_MEDIA">>,
               <<"CUSTOM">>, <<"conference::maintenance">>]
}).
```

A dial-out waits for the party's answer (`ignore_early_media`): what it
plays before that reaches neither the room nor the referrer, who hears
its 183 only.

The roster of a focus room has each participant as a user under the
address-of-record it called from (anonymous when it asked for privacy),
one endpoint `<conference URI>;member=Id` per member, `dialed-out` for a
party a REFER brought in and `referred` by the Referred-By an incoming
INVITE carried. A member that leaves shows `disconnected` (`departed`, or
`booted` when removed) before it is deleted.

Parties a room dials out stay FreeSWITCH calls: give the profile that
dials them `disable-transfer` (mod_sofia) so a REFER on such a call is
refused rather than carried out by FreeSWITCH, out of the room's sight.

A caller the room answers itself (`join/3` with `{call, Req, Res}`) gets
the conference URI with `isfocus` as its Contact in a `focus => true` room
(RFC 4579 4.2), and the room takes the REFERs in its dialog:

- in a focus room a REFER is to the focus, decided as one to the room's
  URI with that member as `member`: add, remove or refer, as above;
- in a room without `focus => true` it is an RFC 3515 transfer of that
  member (and `method=BYE` is refused 403). The member's call carries it
  out (`transfer => notify`, `chappe_sip_b2b_transfer`) once the policy
  says yes, with `action => transfer`, `member`, and the call's `kind`
  (`blind`, or `attended` with the Refer-To's Replaces, RFC 5589): the
  target takes the member's place on its call, shown as
  `{left, Member, transferred}` then `{joined, Member, #{uri := Target}}`.

A caller whose INVITE carries Replaces (RFC 3891) naming a member's call
in this room takes that member's place (RFC 4579 5.9): it joins, then the
member it replaces is hung up and leaves with reason `replaced`. RFC
3891 8 accepts a replacement only from an authenticated and authorized
peer: authenticate the INVITE before you call `join/3`. The room then
allows the member itself (its From has the member's address-of-record)
and a caller that member referred (Referred-By naming it); your
`refer_policy` may allow more, given `action => replace`, `member` (the
member it would replace), `target` (that member's URI), `referrer` (the
caller's From) and `referred_by`:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{
    focus => true,
    refer_policy => fun
        (#{action := replace, referrer := R}) -> is_moderator(R);
        (#{action := add}) -> true;
        (_) -> false
    end
}).
```

Anyone else gets 403, a Replaces naming no call 481, a call of no member
of this room 403, and a second caller replacing a member another one is
replacing 603; the room does not change. The roster shows a caller whose
INVITE had Referred-By as `referred` by that URI.

A call you answered yourself (`connect_caller/3`) carries the Contact you
gave it: for a focus room pass
`contact_params => #{a => chappe_sip_focus:contact_params()}` and
`requests => [refer]`, then hand the room each
`{chappe_sip_b2b, Ref, {request, a, refer, Req, Res}}` with `b2b_event/2`;
for a room without focus pass `transfer => notify` and hand it each
`{chappe_sip_b2b, Ref, {refer, Info}}` and
`{chappe_sip_b2b, Ref, {transferred, Leg, Info}}`. Parties dialed in come
from FreeSWITCH, with the room's name and `isfocus` in its Contact in a
focus room.

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
chappe_cluster configured (chappe_mrf starts it at boot), and a room name has
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
  node end with it. The handoff takes at most `drain_ms` (5000): a member
  whose move is not done by then is hung up, a clean BYE, and is in no
  room after. Moves started any other way (`transfer/3`, a lost lease)
  are never cut: a room that ends while one runs leaves the member's
  call to the move.
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
  `chappe_mrf_conf_fs`, `chappe_mrf_conf_refer` (REFER: the decision),
  `chappe_mrf_conf_refer_dial` (the dial-outs and the nested REFER),
  `chappe_mrf_conf_refer_member` (a member's REFER, transfer and Replaces),
  `chappe_mrf_conf_refer_op` (repeated REFERs); the loopback middleware is
  in `chappe_mrf`
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl`,
  `chappe_mrf_live_SUITE.erl`, `chappe_mrf_cluster_SUITE.erl` (rooms on
  three peer nodes)
- Lab: `make interop-mrf` (native and FreeSWITCH rooms)
- Design: [overview](../design/overview.md#native-conferences-and-the-loopback-middleware)
