# Answer a caller with a menu

`chappe_mrf:connect_caller/3` answers an incoming INVITE by bridging it,
anchored in rtpengine, to a FreeSWITCH node, and gives you the node's
channel as an endpoint. Use it for an IVR, a voicemail or any call where
Erlang decides what the caller hears.

## When to use it

- The caller should hear prompts and press digits before anything else.
- You record or stream the caller's audio.
- You want to move the caller somewhere else afterwards (see
  [Bridge a caller](bridge.md)).

## Connect the caller

Call it from the INVITE handler. The handler then drives the endpoint:

```erlang
ok = chappe_sip:invite(fun(Req, Res) ->
    {ok, Ep, B2b} = chappe_mrf:connect_caller(Req, Res, #{}),
    menu(Ep, B2b)
end).
```

chappe_esl picks the node (`node_select/1`, fewest sessions first); the
other up nodes follow on 408, 503 or a transport error. Pass `node => fs1`
to pin one, or `select => #{tags => [ivr]}`.

The call runs in its own process (`chappe_sip_b2b:relay_async/2`), so the
handler is free. The handler owns the endpoint: when it exits, the channel
is killed.

## Play a menu and collect a digit

```erlang
menu(Ep, B2b) ->
    case chappe_mrf:play_collect(Ep, #{file => <<"/media/menu.wav">>,
                                       max => 1, timeout => 8000}) of
        {ok, <<"1">>} -> chappe_mrf:play(Ep, <<"/media/sales.wav">>);
        {ok, <<"9">>} -> chappe_sip_b2b:hangup(B2b, #{});
        {ok, _} -> menu(Ep, B2b)
    end.
```

`play_collect/2` takes `min`, `max`, `tries`, `timeout`, `terminators`,
`invalid_file` and `digit_timeout`; `{ok, <<>>}` means no digit came. With
`result => full` you also get the terminator pressed and the last entry
the `regexp` refused:

```erlang
{ok, #{digits := Pin, terminator := <<"#">>, invalid := <<>>}} =
    chappe_mrf:play_collect(Ep, #{file => <<"/media/pin.wav">>, max => 6,
                                  regexp => <<"\\d{4,6}">>, result => full}).
```

## Know how a prompt played

`play/3` returns `{error, not_found}` for a file the node cannot find.
`play_info/3` also tells you how long it played:

```erlang
{ok, #{ms := Ms, response := <<"FILE PLAYED">>}} =
    chappe_mrf:play_info(Ep, <<"/media/news.wav">>, #{offset => 8000 * 30,
                                                      limit_secs => 20}).
```

`offset` starts that many samples into the file (30 s of an 8 kHz file
here); `limit_secs` (2 or more) stops it after that many seconds.

## Record and play back

```erlang
ok = chappe_mrf:record(Ep, <<"/media/msg-42.wav">>, #{max_secs => 30}),
ok = chappe_mrf:play(Ep, <<"/media/msg-42.wav">>).
```

The path is on the FreeSWITCH node. `record_session/2` records both
directions until `record_session_stop/2` or the hangup.

## React to events

The owner gets `{chappe_mrf, Ep, Event}`:

```erlang
receive
    {chappe_mrf, Ep, {dtmf, Digit}} -> Digit;
    {chappe_mrf, Ep, {hangup, Cause}} -> Cause;
    {chappe_mrf, Ep, {node_down, Node}} -> Node
end.
```

Ask for more with `events` when you connect the caller or create the
endpoint:

```erlang
{ok, Ep, B2b} = chappe_mrf:connect_caller(Req, Res, #{
    events => [playback_start, playback_stop,
               {custom, <<"mod_audio_fork::connect">>},
               {channel, <<"CHANNEL_BRIDGE">>}]
}),
receive
    {chappe_mrf, Ep, {playback_start, File}} -> File;
    {chappe_mrf, Ep, {playback_stop, File, <<"done">>}} -> File;
    {chappe_mrf, Ep, {custom, Subclass, Ev}} -> {Subclass, Ev};
    {chappe_mrf, Ep, {channel, Name, Ev}} -> {Name, Ev}
end.
```

The call's events (`{chappe_sip_b2b, Ref, Event}`, `{done, Why}` at the
end) go to the `notify` option, the handler by default.

## Other commands

| function | what it does |
|----------|--------------|
| `send_dtmf/2` | send digits to the caller |
| `set/3`, `set/2` | set a channel variable, or a map of them (multiset) |
| `export/3` | set a variable on the channel and the channel it is bridged to |
| `var/2`, `vars/1` | read one variable (`undefined` when unset), or all of them |
| `mute/2`, `unmute/2` | mute what the caller says (`read`) or hears (`write`) |
| `api/2` | run an api command on the endpoint's node |
| `execute/3` | run any dialplan application and wait for it |
| `execute/4` | the same with options; `wait => false` returns `{ok, AppUuid}` at once and the owner gets `{chappe_mrf, Ep, {complete, App, Ev}}` |
| `fork_audio_start/3`, `fork_audio_stop/1` | stream the audio to a WebSocket (mod_audio_fork, or `module => audio_stream`); `bugname` names one of several forks, `mix => stereo` puts the caller left and the node right |
| `fork_audio_pause/1,2`, `fork_audio_resume/1,2` | stop and restart the audio of the forks (all, or `#{bugname => B}`), the WebSocket stays open |
| `fork_audio_send_text/2,3` | send a text frame to the fork's server |
| `modify/2` | `hold`, `unhold`, or a new SDP on an endpoint of `create_endpoint/1` |
| `destroy/1` | hang up and free the endpoint |

## Say numbers and speak text

`say/3` reads a number, a date or digits with the node's mod_say module
(mod_say_en for English) and its sound files. `speak/3` runs a text to
speech module: mod_flite in the lab, a vendor module in production.

```erlang
ok = chappe_mrf:say(Ep, <<"42">>, #{type => number}),
ok = chappe_mrf:say(Ep, integer_to_binary(erlang:system_time(second)),
                    #{type => current_time}),
ok = chappe_mrf:say(Ep, <<"1234">>, #{type => number, method => iterated}),
ok = chappe_mrf:speak(Ep, <<"Your call is important to us">>,
                      #{engine => <<"flite">>, voice => <<"kal">>}).
```

`say/3` takes `language` (`<<"en">>`), `type`, `method` (`pronounced`,
`iterated`, `counted`) and `gender`. The sound files come from the
channel's `sound_prefix`. `speak/3` without `engine` and `voice` uses the
channel's `tts_engine` and `tts_voice`.

## Notes

- A command blocks the process that calls it, not the endpoint: digits
  keep reaching the owner during a long playback.

## Where it lives

- Modules: `chappe_mrf` (API), `chappe_mrf_endpoint` (one per channel),
  `chappe_mrf_esl` (the outbound socket handler); commands run on
  `chappe_esl_call`
- Tests: `apps/chappe_mrf/test/chappe_mrf_SUITE.erl` (fakes),
  `chappe_mrf_live_SUITE.erl`
- Lab: `make interop-mrf` (`apps/chappe_mrf/interop/`); the demo SBC has an
  IVR on `2000` (`make demo`)
