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

The room keeps answering while an endpoint joins. The media setup and
the re-INVITE, which may take up to 75 seconds on a slow node, run in a
helper of the room, so `info/1`, mute, kick, other joins and REFERs are
not held behind it. Your `join/3` returns once the endpoint is in. An
endpoint joins a room once: joining it again while it is a member, or
while its join runs, returns `{error, already_member}` or
`{error, already_joining}`.

A join that fails returns its error at once and leaves nothing behind:
no mixer leg, no rtpengine session, and the room counts it no more
against `max_members`. The room and its members go on. An endpoint whose
node already answered the room's re-INVITE when its join failed is hung
up, since the media it was moved to is gone; its owner gets
`{chappe_mrf, Ep, {hangup, Cause}}`. The same goes for an endpoint whose
join's helper died, or whose join timed out, with the re-INVITE out: its
BYE waits for that re-INVITE to end. A join that timed out before its
re-INVITE went out sends none, and the endpoint keeps its media. A
join, a call's or an endpoint's, may take `join_timeout` milliseconds
(95000 by default and at most), then it fails. Any other value than 1 to 95000 makes `conference/2`
return `{error, {bad_option, join_timeout}}`:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"ops">>, #{join_timeout => 10000}),
case chappe_mrf_conf:join(Conf, B2b, #{}) of
    {ok, Member} -> Member;
    {error, timeout} -> retry_later;
    {error, badarg} -> not_a_call_or_endpoint
end.
```

### Run an HD (16 kHz) native room

Callers on G.722 or Opus keep their band when the room mixes at 16 kHz.
Give the room its rate when you start it:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"hd">>, #{rate => 16000}),
{ok, Member} = chappe_mrf_conf:join(Conf, B2b, #{}).
```

- The chappe_mix room mixes L16 at 16000, and rtpengine transcodes every
  member to it and back: the room lays
  `chappe_sip_media:mixer_params(16000, mixer)` under your `b` anchor
  params and `mixer_params(16000, endpoint)` under your endpoint `offer`
  params. Your own keys win, and inside `codec` key by key: a `codec` map
  of yours (`strip`, say) adds to the room's `mask` and `transcode`, and
  your `transcode` replaces the room's.
- rtpengine needs the L16 codec: the labs test 26.3.1.4, 11.5.1.18
  (Ubuntu 24.04) has none, and upstream tags have it from 13.4.1.1 (not
  tested here).
- A PCMU member is heard, and hears the room, through 8 kHz; the others
  keep their band.
- Give the room's prompts as 16 kHz files. `chappe_mrf_conf:play/2` has
  rtpengine play the file on each member's leg in the member's codec: a
  G.722 or Opus member hears it in wideband, a PCMU member at 8 kHz. An
  8 kHz file is narrowband for everyone. The same holds for an fs room on
  a 16 kHz profile, and for an IVR endpoint's `chappe_mrf:play/2`.
- Run rtpengine with `--audio-player=play-media` (`audio-player =
  play-media` in its config file) for room prompts. rtpengine then mixes
  the prompt with the room's audio while it plays. Without it, a G.722 or
  Opus member hears the prompt garbled.
- The rate is fixed: `rate` is 8000 (default) or 16000, anything else is
  `{error, {bad_option, rate}}`. `conference/2` on a room that runs
  returns it at its own rate or with no `rate`; another rate is
  `{error, {rate_mismatch, RoomRate}}`.
- SIPREC of a 16 kHz room is refused for now
  (`{error, {unsupported, {rate, 16000}}}`).
- The FreeSWITCH equivalent is an fs room with a 16 kHz profile
  (`profile => <<"wideband">>` in the labs); an fs room refuses `rate`
  with `{error, {unsupported, rate}}`.

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
- A `pin` has the caller enter it first, on either backend: see
  [Ask callers for a PIN](#ask-callers-for-a-pin).

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
room's node, enters the PIN (`play_collect`, three tries; see
[Ask callers for a PIN](#ask-callers-for-a-pin)), then runs the
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

## Ask callers for a PIN

A join with `pin` has the caller enter a PIN on a FreeSWITCH endpoint
before it gets in. Use it for a room only some callers may enter. On fs
the caller is already on the room's node. On native the caller enters it
on an IVR endpoint and the call then moves into the mixer: FreeSWITCH
plays the prompt and reads the digits, and leaves the call once it is in
the room.

### A caller that dials the room

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Conf} = chappe_mrf:conference(<<"board">>, #{rate => 16000}),
    chappe_mrf_conf:join(Conf, {call, Req, Res}, #{
        pin => <<"4321">>,
        pin_prompt => <<"/media/pin.wav">>,
        pin_fail_prompt => <<"/media/bad-pin.wav">>,
        pin_endpoint => #{select => #{tags => [ivr]}}
    })
end).
```

1. On native, chappe answers the caller to a FreeSWITCH endpoint
   (`connect_caller/3` with `pin_endpoint`'s options).
2. The endpoint plays `pin_prompt` and reads the digits, `pin_tries`
   times at most.
3. With the right PIN the call moves into the mixer, the caller seeing no
   re-INVITE, and the endpoint's channel is hung up. `join/3` returns
   `{ok, Member}`.
4. After the last wrong entry the caller hears `pin_fail_prompt` and the
   call ends: `{error, bad_pin}`.
5. When the caller does not get in for another reason (the room filled or
   was locked meanwhile, the move into the mixer fails, the deadline), it
   hears `join_fail_prompt`, a busy tone by default, and the call ends:
   `join/3` returns that error.

### A call your IVR sends to the room

Name the endpoint the call is on:

```erlang
{ok, Ep, B2b} = chappe_mrf:connect_caller(Req, Res, #{}),
%% your menu runs on Ep, then:
case chappe_mrf_conf:join(Conf, B2b, #{pin => <<"4321">>, endpoint => Ep}) of
    {ok, Member} -> {in, Member};
    {error, bad_pin} -> chappe_mrf:play(Ep, <<"/media/try-later.wav">>)
end.
```

- With the right PIN the call moves into the room and `Ep`'s channel is
  hung up: you get `{chappe_mrf, Ep, {hangup, Cause}}`.
- A wrong PIN returns `{error, bad_pin}` and the call stays on `Ep`,
  yours to drive: play, collect, hang up. No `pin_fail_prompt` plays.
- A move that fails after the PIN leaves the call on `Ep` too.
- Without `endpoint` a native room refuses the join with
  `{error, {bad_option, endpoint}}`. An fs room ignores it: it bridges the
  call into an endpoint of its own, and a wrong PIN ends the call.

### PIN options

| Option | Default | What it does |
|---|---|---|
| `pin` | none | The PIN: digits and `*`, as a binary (it keeps leading zeros) or an integer. |
| `pin_prompt` | `silence_stream://250` | The file that asks for it. |
| `pin_tries` | `3` | How many entries the caller has. |
| `pin_timeout` | `5000` | Milliseconds FreeSWITCH waits for one entry. |
| `pin_fail_prompt` | none | Played after the last wrong entry, before the call ends, where the room made the endpoint. |
| `join_fail_prompt` | a busy tone (`tone_stream://%(500,500,480,620);loops=3`) | native, `{call, Req, Res}`: played when the caller does not get in for any other reason than a wrong PIN, before the call ends. |
| `pin_endpoint` | the node chappe_esl picks | native, `{call, Req, Res}`: the `connect_caller/3` options (`node`, `select`, `targets`, `user`, `attach_timeout`, `anchor_params`) of the endpoint the caller enters the PIN on. |
| `endpoint` | none | native, a call: the endpoint the call is on. |

A value of the wrong kind is refused before anything starts:
`{error, {bad_option, Key}}`.

Notes:

- The digits are read outside the room process: the room answers its
  other requests while a caller types.
- A native room's `join_timeout` covers the PIN and the move. A caller
  still typing at the deadline gets `{error, timeout}`: it hears
  `join_fail_prompt` and the call ends, or it stays on `Ep` when your IVR
  sent it.
- A caller that dialed the room is answered on FreeSWITCH, so its codec
  is negotiated there first; the move to the mixer reuses the call's
  rtpengine session.

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
- One operation holds at most `refer_attach_max` REFERs while it runs (16
  by default): the first, its repeats, and REFERs from other origins for
  the same party. Each keeps a subscription, and its dialog when it came
  in one, so past the cap a REFER gets 503 before it is accepted, and
  nothing is kept. A REFER the room took while the operation was
  starting, its first REFERs accepted but not attached yet, may pass the
  count: it is accepted, then hears NOTIFY 503 at once. Once the
  operation is done, a repeat hears its outcome at once.
- When the room ends, the REFERs still under way get a final NOTIFY 487
  and their dials are given up.

Set the cap on one operation's REFERs with `refer_attach_max`; a value
that is no positive integer makes `conference/2` return
`{error, {bad_option, refer_attach_max}}`:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{
    focus => true,
    refer_policy => fun(_) -> true end,
    refer_attach_max => 4
}).
```

The policy runs in the room process and gets the same keys for every
action, `undefined` where one does not apply, so a clause can match any
of them; one that crashes (no clause for the action, say) refuses the
REFER 403 and the room goes on. It sees `chappe_sip_focus:refer_info/2`'s
map plus the room's view:

| Key | What it is |
|---|---|
| `action` | `add`, `remove`, `refer`, or `transfer` (a member of a room without focus transferring itself, below) |
| `target` | the Refer-To URI, without its method |
| `referrer` | the REFER's From, what its dialog or your digest vouches for |
| `referred_by` | the REFER's Referred-By, as the referrer claims it: the room checks nothing of it, so do not grant a REFER on it alone |
| `member` | the referrer's member id: its dialog with the room, or the one its Target-Dialog names (RFC 4538); else `undefined` |
| `target_dialog`, `origin` | the dialog a Target-Dialog names, and who sent the REFER |
| `replaces`, `nested` | the Refer-To's Replaces, and for `refer` the Refer-To it carries |
| `dial` | add: the dial string the room would run, made by your `dial` fun when you gave one (one that crashes refuses the REFER 403) |
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

On native, the node bridges the party from the room's endpoint, and
FreeSWITCH would offer it only the codec that endpoint speaks (G.722 in a
16 kHz room, PCMU in an 8 kHz one). So the default dial string offers the
party every codec of the lab as its leg's `absolute_codec_string`, in the
order of the room's rate:

| Room | Offered to the party |
|---|---|
| native, 16 kHz | `OPUS,G722,PCMU,PCMA` |
| native, 8 kHz | `PCMU,PCMA,G722,OPUS` (a G.711 party needs no transcoding) |
| fs | nothing added: FreeSWITCH offers the profile's codecs |

The `dial` value your `refer_policy` sees starts with that block
(`[^^:absolute_codec_string=OPUS,G722,PCMU,PCMA]sofia/external/...`).
Change the list with `dial_codecs`, or keep FreeSWITCH's own choice on
native too with `dial_codecs => inherit`:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"hd">>, #{
    rate => 16000,
    focus => true,
    dial_codecs => <<"G722,PCMU">>
}).
```

A `dial` fun of your own builds the whole dial string: put the codecs in
it yourself (`[^^:absolute_codec_string=...]` before `sofia/...`).
`chappe_mrf:dial_codecs(Opts)` gives the default list for the room's
options (`inherit` on fs):

```erlang
Opts = #{rate => 16000, focus => true},
Codecs = chappe_mrf:dial_codecs(Opts),    %% <<"OPUS,G722,PCMU,PCMA">>
Dial = fun(<<"sip:", Bare/binary>>) ->
    [<<"[^^:absolute_codec_string=">>, Codecs, <<"]sofia/carrier/">>, Bare]
end,
{ok, Conf} = chappe_mrf:conference(<<"hd">>, Opts#{dial => Dial}).
```

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
member it replaces is hung up and leaves with reason `replaced`. Who may
do so is a separate decision from a REFER's: the room never asks your
`refer_policy`, so a policy that lets every REFER in, or lets members
REFER, lets nobody replace anyone.

Without a `replaces_policy` the room allows:

- the member itself: the caller's From has the member's
  address-of-record (another device of the same user);
- a caller the member referred: its Referred-By names the member (an
  attended transfer into the room).

An anonymous caller (`anonymous.invalid`, or the user `anonymous`) never
passes this default: every anonymous caller shares one
address-of-record. This rests on what the INVITE carries, and the room
authenticates none of it: the caller must name the member's dialog with
the room in its Replaces (its Call-ID and both tags, which only a party
to that dialog or one it told knows) and the member in its From or
Referred-By. On a network you do not trust, authenticate the INVITE
(digest, RFC 3891 8) in your handler before you call `join/3`, and
tighten with `replaces_policy`:

```erlang
{ok, Conf} = chappe_mrf:conference(<<"board">>, #{
    focus => true,
    replaces_policy => fun(#{caller := C, replaced_aor := Aor}) ->
        is_moderator(C) orelse C =:= Aor
    end
}).
```

Once you give it, the policy alone decides: `true` lets the caller
replace the member, anything else refuses it 403, and a policy that
crashes refuses it too (logged; the room goes on). It runs in the room
process and gets these keys, `undefined` where one is unknown:

| Key | What it is |
|---|---|
| `caller` | the URI of the INVITE's From |
| `referred_by` | the URI of its Referred-By, as the caller claims it |
| `request` | the INVITE (`chappe_sip_req`), for what your handler or middleware attached to it |
| `replaced` | the member id the Replaces names |
| `replaced_aor` | that member's address-of-record |

Whatever decides, a Replaces naming no call gets 481, a call of no
member of this room 403, and a second caller replacing a member another
one is replacing 603; the room does not change. The member stays held
for the first caller only while its join runs: a join that fails or
raises, a caller that dies, or 95 seconds, release it. A transfer of the
member's call releases it too. A caller whose join gets in after that is
too late: the member stays, the late call is hung up and leaves with
reason `expired` (the roster shows it `booted`), and its `join/3`
returns `{error, expired}`. A member that hung up before the caller got
in leaves its place to it: that call stays. The roster shows a caller
whose INVITE had Referred-By as `referred` by that URI.

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
  `chappe_mrf_conf_native_ep` (an endpoint's media in a native room),
  `chappe_mrf_conf_fs`, `chappe_mrf_conf_pin` (the PIN, on both
  backends), `chappe_mrf_conf_refer` (REFER: the decision),
  `chappe_mrf_conf_refer_dial` (the dial-outs and the nested REFER),
  `chappe_mrf_conf_refer_member` (a member's REFER, transfer and Replaces),
  `chappe_mrf_conf_refer_op` (repeated REFERs); the loopback middleware is
  in `chappe_mrf`
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl`,
  `chappe_mrf_live_SUITE.erl`, `chappe_mrf_hd_live_SUITE.erl` (HD rooms with
  pjsua callers), `chappe_mrf_cluster_SUITE.erl` (rooms on
  three peer nodes)
- Lab: `make interop-mrf` (native and FreeSWITCH rooms)
- Design: [overview](../design/overview.md#native-conferences-and-the-loopback-middleware)
