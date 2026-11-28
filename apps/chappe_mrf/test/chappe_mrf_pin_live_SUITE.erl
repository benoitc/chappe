%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% PIN rooms against the real lab (make interop-mrf): pjsua callers
%% (apps/chappe_sip/interop/pjsua/hd.sh, digits as RFC 4733 events with
%% -D) dial a native 16 kHz room that asks a PIN. FreeSWITCH plays the
%% prompt, the 16 kHz band probe, and reads the digits; with the right
%% PIN chappe moves the call into the mixer, the caller keeping its codec,
%% and FreeSWITCH leaves the call. A G.722, an Opus and a PCMU caller get
%% in and are heard both ways with an HD member; three wrong PINs end the
%% call; a call the application's IVR sends with a wrong PIN, or into a
%% full room, stays on its endpoint with working media; a caller that
%% dialed a room locked meanwhile hears the busy tone and its call ends.
%% A caller turned away leaves nothing: no rtpengine call, mixer leg,
%% FreeSWITCH channel or endpoint of its own. The setup is
%% chappe_mrf_live_SUITE's, the callers and the band check
%% chappe_mrf_hd_live_SUITE's.
%% Skipped unless MRF=1 (apps/chappe_mrf/test/e2e.sh) and docker runs.
-module(chappe_mrf_pin_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([native_pin_g722/1, native_pin_opus/1, native_pin_pcmu/1]).
-export([native_pin_wrong/1, b2b_pin_wrong_keeps_call/1]).
-export([handoff_failure_keeps_call/1]).

-define(HD, chappe_mrf_hd_live_SUITE).
-define(UA, chappe_mrf_live_ua).
-define(RTPE, chappe_mrf_live_rtpe).
-define(RATE, 16000).
-define(PIN, "4321").
%% marker tones: what a caller plays to an IVR endpoint, the IVR's play,
%% the wrong-PIN prompt (live suite's pin.wav is 520 Hz)
-define(CALLER_TONE, 700).
-define(PLAYED, 1100).
-define(BAD, 300).

all() ->
    [
        native_pin_g722,
        native_pin_opus,
        native_pin_pcmu,
        native_pin_wrong,
        b2b_pin_wrong_keeps_call,
        handoff_failure_keeps_call
    ].

init_per_suite(Config) ->
    case ?HD:init_per_suite(Config) of
        {skip, _} = Skip ->
            Skip;
        Config1 ->
            Media = ?config(media, Config1),
            _ = ?HD:wav(
                Media,
                "pin-probe.wav",
                chappe_mix_test_tone:band_probe(4000),
                ?RATE
            ),
            ?UA:write_wav(filename:join(Media, "pin-bad.wav"), ?BAD, 2000),
            ?UA:write_wav(filename:join(Media, "ivr-play.wav"), ?PLAYED, 3000),
            Config1
    end.

end_per_suite(Config) ->
    ?HD:end_per_suite(Config).

init_per_testcase(Case, Config) ->
    ?HD:init_per_testcase(Case, Config).

%% a pjsua a failed case left running would hold its name for the next
end_per_testcase(Case, Config) ->
    _ = [
        os:cmd("docker rm -f " ++ container(N) ++ " >/dev/null 2>&1")
     || N <- [a, b]
    ],
    ?HD:end_per_testcase(Case, Config).

%% ---- a caller with the right PIN ----

%% A G.722 caller dials a native 16 kHz room that asks a PIN: it hears
%% the prompt in wideband on FreeSWITCH, sends the PIN (telephone-event/
%% 8000), and is moved into the mixer with its codec; then it and an Opus
%% member hear each other in wideband, and FreeSWITCH has no channel left
%% for it. Its phone offers speex/16000 first, which FreeSWITCH does not
%% take (its codec list) and rtpengine can transcode: the move's re-offer
%% made from the whole offer had rtpengine send it speex, which it does
%% not decode, and it heard nothing in the room (chappe_sip_b2b_replace:
%% kept_sdp/1).
native_pin_g722(Config) ->
    native_pin(
        Config,
        <<"pin-g722">>,
        #{
            codec => "speex/16000,G722",
            answered => <<"G722">>,
            rate => ?RATE,
            te => <<"telephone-event/8000">>
        },
        #{codec => "opus", rate => ?RATE}
    ).

%% The same for an Opus caller, whose digits go out as telephone-event/
%% 48000 through rtpengine to FreeSWITCH, with a G.722 member.
native_pin_opus(Config) ->
    native_pin(
        Config,
        <<"pin-opus">>,
        #{
            codec => "opus",
            answered => <<"opus">>,
            rate => ?RATE,
            te => <<"telephone-event/48000">>
        },
        #{codec => "G722", rate => ?RATE}
    ).

%% A PCMU caller hears the 16 kHz prompt at 8 kHz (its 1000 and 2500 Hz),
%% sends the PIN at telephone-event/8000 and is moved into the 16 kHz
%% room, where it hears a G.722 member and is heard by it, narrowband.
native_pin_pcmu(Config) ->
    native_pin(
        Config,
        <<"pin-pcmu">>,
        #{
            codec => "PCMU",
            answered => <<"PCMU">>,
            rate => 8000,
            te => <<"telephone-event/8000">>
        },
        #{codec => "G722", rate => ?RATE}
    ).

%% Caller A (codec: the codecs it offers, answered: the one FreeSWITCH
%% answers, rate, te: the telephone-event it offers) dials Room,
%% which asks a PIN, with member B in already. Each plays its own band
%% (the probe at 16 kHz, its narrow tones at 8 kHz) for the whole call
%% and records what it hears: A first the prompt, then nothing while
%% FreeSWITCH waits for the digits, then B once it moved; B nothing, then
%% A.
native_pin(Config, Room, Caller, Member) ->
    Dir = ?config(priv_dir, Config),
    {ok, Conf} = room(Room, #{}),
    ok = answer(Conf, #{pin_prompt => <<"/media/pin-probe.wav">>}),
    B = ?HD:pjsua(
        Config,
        b,
        Member#{play => looped(Dir, b, Member), dur => 40},
        ?HD:target(Config, <<"open">>)
    ),
    {ok, _} = joined(open),
    Base = baseline(Conf),
    A = ?HD:pjsua(
        Config,
        a,
        Caller#{
            play => looped(Dir, a, Caller),
            dur => 30,
            dtmf => [{9, ?PIN}]
        },
        ?HD:target(Config, <<"pin">>)
    ),
    {Joined, Seen} = pin_joined(Base, 40000),
    ct:log("baseline ~p; while the PIN was entered ~p; join ~p", [
        Base, Seen, Joined
    ]),
    ?assertMatch({ok, _}, Joined),
    %% FreeSWITCH had the caller's channel, and has it no more
    ?assertEqual(maps:get(fs1, Base) + 1, maps:get(fs1, Seen)),
    In = settled(Conf, Base#{
        members := 2, legs := 2, rtpe := maps:get(rtpe, Base) + 1
    }),
    ct:log("after the move ~p", [In]),
    [?HD:wait_pjsua(P, 60000) || P <- [A, B]],
    Codecs = maps:get(codecs, In),
    ok = chappe_mrf_conf:stop(Conf),
    LogA = log(Dir, a),
    RecA = ?HD:wav_samples(filename:join(Dir, "a.wav")),
    RecB = ?HD:wav_samples(filename:join(Dir, "b.wav")),
    RateA = maps:get(rate, Caller),
    RateB = maps:get(rate, Member),
    %% A: the prompt, then the room after the move
    {Prompt, Room1} =
        case segments(RecA, RateA) of
            [{P0, _}, {R0, _} | _] -> {P0, R0};
            Segs -> ct:fail({caller_heard, Segs})
        end,
    ct:log("A hears the prompt from ~p ms, the room from ~p ms", [Prompt, Room1]),
    Checks = [
        {prompt, judge(RateA, from(RecA, RateA, Prompt + 500, 2500))},
        {a_to_b, judge(RateA, RateB, ?HD:heard(RecB, RateB, 3))},
        {b_to_a, judge(RateB, RateA, from(RecA, RateA, Room1 + 1000, 3000))}
    ],
    ct:log("~p", [Checks]),
    [?assertEqual({W, ok}, {W, R}) || {W, R} <- Checks],
    %% the caller offered its telephone-event and kept its codec through
    %% the move (no re-INVITE, no other payload type), which rtpengine
    %% receives from it
    ?assert(has(LogA, maps:get(te, Caller)), {offered, maps:get(te, Caller)}),
    ok = kept_codec(LogA, Caller, Codecs).

%% ---- wrong PINs ----

%% Three wrong PINs from a caller that dialed the room: it hears the
%% prompt three times, then pin_fail_prompt, and its call ends. The room
%% is as it was: its member, its mixer legs, rtpengine's calls,
%% FreeSWITCH's channels, chappe_mrf's endpoints.
native_pin_wrong(Config) ->
    Dir = ?config(priv_dir, Config),
    {ok, Conf} = room(<<"pin-wrong">>, #{}),
    ok = answer(Conf, #{
        pin_prompt => <<"/media/pin.wav">>,
        pin_fail_prompt => <<"/media/pin-bad.wav">>
    }),
    B = ?HD:pjsua(
        Config, b, #{codec => "G722", rate => ?RATE, dur => 40}, open(Config)
    ),
    {ok, _} = joined(open),
    Base = settled(Conf, undefined),
    T0 = erlang:monotonic_time(millisecond),
    A = ?HD:pjsua(
        Config,
        a,
        #{
            codec => "G722",
            rate => ?RATE,
            dur => 30,
            dtmf => [{6, "1111"}, {11, "2222"}, {16, "3333"}]
        },
        pin(Config)
    ),
    {Joined, Seen} = pin_joined(Base, 40000),
    Ms = erlang:monotonic_time(millisecond) - T0,
    ct:log("join ~p after ~p ms; while the PIN was entered ~p", [
        Joined, Ms, Seen
    ]),
    ?assertEqual({error, bad_pin}, Joined),
    %% three entries, not three prompts waiting pin_timeout each
    ?assert(Ms < 25000, {bad_pin_after, Ms}),
    Back = settled(Conf, Base),
    ct:log("baseline ~p, after ~p", [Base, Back]),
    [?HD:wait_pjsua(P, 60000) || P <- [A, B]],
    ok = chappe_mrf_conf:stop(Conf),
    ?assert(hung_up(log(Dir, a))),
    RecA = ?HD:wav_samples(filename:join(Dir, "a.wav")),
    ?assert(tone_heard(RecA, ?RATE, ?BAD), no_fail_prompt),
    ?assertEqual(
        3,
        length(segments(RecA, ?RATE, 520)),
        {prompts, segments(RecA, ?RATE, 520)}
    ).

%% Your IVR sends a call it answered (connect_caller/3) to a PIN room
%% naming its endpoint; the caller sends a wrong PIN: join/3 returns
%% {error, bad_pin}, the room is as it was, and the call is still the
%% IVR's: its endpoint plays to the caller and records it.
b2b_pin_wrong_keeps_call(Config) ->
    {ok, Conf} = room(<<"pin-ivr">>, #{}),
    Join = fun(B2b, Ep) ->
        chappe_mrf_conf:join(Conf, B2b, #{
            pin => ?PIN,
            pin_tries => 1,
            pin_prompt => <<"/media/pin.wav">>,
            pin_fail_prompt => <<"/media/pin-bad.wav">>,
            pin_timeout => 8000,
            endpoint => Ep
        })
    end,
    Base = baseline(Conf),
    keeps_call(Config, Conf, Base, Join, [{7, "9999"}], {error, bad_pin}).

%% The move is refused. A call your IVR sends to a full room gets {error,
%% full} before any PIN is asked, and stays on its endpoint with working
%% media. A caller that dials a room which is locked while chappe answers
%% it to the PIN endpoint hears the busy tone (join_fail_prompt's
%% default) and its call ends, leaving nothing.
handoff_failure_keeps_call(Config) ->
    Dir = ?config(priv_dir, Config),
    {ok, Full} = room(<<"pin-full">>, #{max_members => 1}),
    ok = answer(Full, #{}),
    B = ?HD:pjsua(
        Config, b, #{codec => "PCMU", rate => 8000, dur => 30}, open(Config)
    ),
    {ok, _} = joined(open),
    Base = baseline(Full),
    Join = fun(B2b, Ep) ->
        chappe_mrf_conf:join(Full, B2b, #{pin => ?PIN, endpoint => Ep})
    end,
    keeps_call(Config, Full, Base, Join, [], {error, full}),
    ?HD:wait_pjsua(B, 60000),
    ok = chappe_mrf_conf:stop(Full),
    %% a caller that dialed the room: it is locked once chappe answers the
    %% caller to its PIN endpoint, before the PIN join reaches the room
    {ok, Locked} = room(<<"pin-locked">>, #{}),
    ok = answer(Locked, #{pin_prompt => <<"/media/pin.wav">>}),
    Base2 = settled(Locked, undefined),
    Eps = endpoint_pids(),
    A = ?HD:pjsua(
        Config, a, #{codec => "G722", rate => ?RATE, dur => 20}, pin(Config)
    ),
    ok = new_endpoint(Eps, 20000),
    ok = chappe_mrf_conf:lock(Locked),
    {Joined, _Seen} = pin_joined(Base2, 30000),
    ct:log("join ~p", [Joined]),
    ?assertEqual({error, locked}, Joined),
    Back = settled(Locked, Base2),
    ct:log("baseline ~p, after ~p", [Base2, Back]),
    ?HD:wait_pjsua(A, 60000),
    ok = chappe_mrf_conf:stop(Locked),
    ?assert(hung_up(log(Dir, a))),
    RecA = ?HD:wav_samples(filename:join(Dir, "a.wav")),
    Busy = chappe_mix_test_tone:levels(
        lists:sublist(RecA, 2 * ?RATE), [480, 620], ?RATE
    ),
    ct:log("the caller hears ~p", [Busy]),
    [?assert(L > -40.0, {busy_tone, F, L}) || {F, L} <- Busy].

%% A G.722 caller answered by the IVR (connect_caller/3 on fs1), playing
%% its tone, joins Conf through Join(B2b, Ep) in the IVR, sending Dtmf,
%% which must give Want. Then the IVR records the caller and plays to it:
%% both carry their tone, and the call lasts until the caller hangs up.
%% The room is Base again once the join failed, the caller's channel and
%% call still up.
keeps_call(Config, Conf, Base, Join, Dtmf, Want) ->
    Dir = ?config(priv_dir, Config),
    Test = self(),
    Rec =
        <<"/media/ivr-",
            (integer_to_binary(erlang:unique_integer([positive])))/binary,
            ".wav">>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        case
            chappe_mrf:connect_caller(Req, Res, #{
                node => fs1, anchor_params => ?HD:to_fs()
            })
        of
            {ok, Ep, B2b} ->
                R = Join(B2b, Ep),
                Test ! {ivr_join, R},
                Recorded = chappe_mrf:record(Ep, Rec, #{max_secs => 3}),
                Played = chappe_mrf:play(Ep, <<"/media/ivr-play.wav">>),
                Test ! {ivr, Recorded, Played},
                receive
                    {chappe_mrf, Ep, {hangup, _}} -> ok
                after 60000 -> ok
                end;
            Err ->
                Test ! {ivr_join, Err}
        end
    end),
    Tone = ?HD:wav(Dir, "a-tone.wav", tone(?CALLER_TONE, 4, ?RATE), ?RATE),
    A = ?HD:pjsua(
        Config,
        a,
        #{
            codec => "G722",
            rate => ?RATE,
            play => Tone,
            dur => 25,
            dtmf => Dtmf
        },
        ?HD:target(Config, <<"ivr">>)
    ),
    R =
        receive
            {ivr_join, Got} -> Got
        after 40000 -> ct:fail(no_ivr_join)
        end,
    ct:log("join ~p", [R]),
    ?assertEqual(Want, R),
    %% the room as it was; the caller's channel, endpoint and call are
    %% still up (FreeSWITCH lists a channel a little after it runs)
    Kept = settled(Conf, Base#{
        fs1 := maps:get(fs1, Base) + 1,
        rtpe := maps:get(rtpe, Base) + 1,
        endpoints := maps:get(endpoints, Base) + 1
    }),
    ct:log("baseline ~p, after the join ~p", [Base, Kept]),
    receive
        {ivr, Recorded, Played} ->
            ?assertEqual({ok, ok}, {Recorded, Played})
    after 30000 -> ct:fail(no_ivr_media)
    end,
    ?HD:wait_pjsua(A, 60000),
    Level = ?UA:wav_level(media_path(Config, Rec), ?CALLER_TONE),
    RecA = ?HD:wav_samples(filename:join(Dir, "a.wav")),
    ct:log("the IVR recorded the caller's tone at ~.1f dBFS", [Level]),
    ?assert(Level > -40.0, {recorded, Level}),
    ?assert(tone_heard(RecA, ?RATE, ?PLAYED), no_ivr_play),
    ?assertNot(hung_up(log(Dir, a))).

%% ---- the room and its callers ----

%% a native 16 kHz room, its callers and the mixer on the host
room(Name, Extra) ->
    chappe_mrf:conference(
        Name,
        maps:merge(
            #{
                rate => 16000,
                anchor_params => #{
                    b => #{direction => [<<"host">>, <<"host">>]}
                }
            },
            Extra
        )
    ).

%% Every INVITE joins Conf from its INVITE: to sip:pin@ with a PIN (?PIN,
%% Extra's prompts, its endpoint on fs1), to anything else without one.
%% {joined, pin | open, Result} comes back.
answer(Conf, Extra) ->
    Test = self(),
    PinOpts = maps:merge(
        #{
            pin => ?PIN,
            pin_timeout => 10000,
            pin_endpoint => #{node => fs1, anchor_params => ?HD:to_fs()}
        },
        Extra
    ),
    chappe_sip:invite(fun(Req, Res) ->
        {Way, Opts} =
            case binary:match(chappe_sip_req:uri(Req), <<"sip:pin@">>) of
                nomatch -> {open, #{}};
                _ -> {pin, PinOpts}
            end,
        Test ! {joined, Way, chappe_mrf_conf:join(Conf, {call, Req, Res}, Opts)}
    end).

pin(Config) -> ?HD:target(Config, <<"pin">>).

open(Config) -> ?HD:target(Config, <<"open">>).

joined(Way) ->
    receive
        {joined, Way, R} -> R
    after 40000 -> ct:fail({no_join, Way})
    end.

%% Wait for the PIN caller's join, sampling the counts meanwhile:
%% {Result, the counts while fs1 ran the most channels}.
pin_joined(Base, Ms) ->
    pin_joined(Base, Base, Ms).

pin_joined(Base, Seen, Ms) when Ms =< 0 ->
    ct:fail({no_pin_join, Base, Seen});
pin_joined(Base, Seen, Ms) ->
    receive
        {joined, pin, R} -> {R, Seen}
    after 250 ->
        Now = counts(),
        case maps:get(fs1, Now) > maps:get(fs1, Seen) of
            true -> pin_joined(Base, maps:merge(Seen, Now), Ms - 250);
            false -> pin_joined(Base, Seen, Ms - 250)
        end
    end.

%% what a caller plays for the whole call: the probe at 16 kHz, its
%% narrow band tones at 8 kHz
looped(Dir, Name, #{rate := ?RATE}) ->
    ?HD:wav(
        Dir,
        atom_to_list(Name) ++ "-play.wav",
        chappe_mix_test_tone:band_probe(8000),
        ?RATE
    );
looped(Dir, Name, #{rate := 8000}) ->
    ?HD:wav(Dir, atom_to_list(Name) ++ "-play.wav", ?HD:narrow_tones(8), 8000).

tone(Freq, Secs, Rate) ->
    chappe_mix_test_tone:tone(Freq, 5000, Secs * Rate, Rate).

%% ---- what is left ----

%% What the room and the lab hold: rtpengine's calls, the room's mixer
%% legs and members, fs1's channels, chappe_mrf's endpoints, and the
%% codec rtpengine reports for each side of each call.
baseline(Conf) ->
    #{name := Name} = chappe_mrf_conf:info(Conf),
    (counts())#{
        legs => chappe_mrf_faults:mix_legs(<<"mrf-", Name/binary>>),
        members => length(chappe_mrf_conf:members(Conf))
    }.

counts() ->
    {ok, Calls} = chappe_rtpengine:list(?RTPE),
    #{
        rtpe => length(Calls),
        codecs => codecs(Calls),
        fs1 => channels(fs1),
        endpoints => length(endpoint_pids())
    }.

%% The counts once they match Want (but the codecs), or have held for 2
%% s with Want undefined; Want not reached in 20 s fails.
settled(Conf, Want) ->
    settled(Conf, Want, baseline(Conf), 0, 40).

settled(_Conf, undefined, Counts, 4, _N) ->
    Counts;
settled(_Conf, Want, Counts, _Same, 0) ->
    ct:fail({not_settled, Want, Counts});
settled(Conf, Want, Counts, Same, N) ->
    case Want =/= undefined andalso same(Counts, Want) of
        true ->
            Counts;
        false ->
            timer:sleep(500),
            case baseline(Conf) of
                Next when Want =:= undefined ->
                    Same1 =
                        case same(Next, Counts) of
                            true -> Same + 1;
                            false -> 0
                        end,
                    settled(Conf, Want, Next, Same1, N - 1);
                Next ->
                    settled(Conf, Want, Next, 0, N - 1)
            end
    end.

same(A, B) ->
    maps:without([codecs], A) =:= maps:without([codecs], B).

%% the channels a node runs
channels(Node) ->
    {ok, Out} = chappe_esl:node_api(Node, <<"show channels count">>),
    {match, [N]} = re:run(
        Out, <<"([0-9]+) total">>, [{capture, all_but_first, binary}]
    ),
    binary_to_integer(N).

endpoint_pids() ->
    [
        P
     || {_, P, _, _} <- supervisor:which_children(chappe_mrf_ep_sup),
        is_pid(P)
    ].

%% an endpoint not in Eps appears (connect_caller/3 starts it before it
%% calls the node)
new_endpoint(_Eps, Ms) when Ms =< 0 ->
    ct:fail(no_pin_endpoint);
new_endpoint(Eps, Ms) ->
    case endpoint_pids() -- Eps of
        [] ->
            timer:sleep(5),
            new_endpoint(Eps, Ms - 5);
        [_ | _] ->
            ok
    end.

%% #{Tag => Codec}: what rtpengine reports for each side of Calls, the
%% codec of the media it receives most on
codecs(Calls) ->
    maps:from_list([
        {Tag, Codec}
     || Id <- Calls,
        {ok, #{<<"tags">> := Tags}} <- [
            chappe_rtpengine:query(?RTPE, #{call_id => Id})
        ],
        Tag := #{<<"medias">> := [#{<<"codec">> := Codec} | _]} <- Tags
    ]).

%% ---- the caller's codec ----

%% The caller kept the codec it was answered with on FreeSWITCH: one
%% stream, of that codec, started once (no re-INVITE reached it), no
%% packet of another payload type received, and rtpengine receiving that
%% codec from it (the side of the call under the caller's From tag).
kept_codec(Log, #{answered := Answered}, Codecs) ->
    Updated = re:run(Log, <<"Audio updated, stream #0: ([^ ]+) ">>, [
        global, {capture, all_but_first, binary}
    ]),
    {match, [Tag]} = re:run(
        Log, <<"From: <[^>]*>;tag=([^\\s;]+)">>, [
            {capture, all_but_first, binary}
        ]
    ),
    Want = string:uppercase(Answered),
    Pts = re:run(Log, <<"RX pt=([0-9]+)">>, [
        global, {capture, all_but_first, binary}
    ]),
    {match, Maps} = re:run(
        Log, <<"(m=audio[^\\r\\n]*|a=rtpmap:[^\\r\\n]*)">>, [
            global, {capture, all_but_first, binary}
        ]
    ),
    ct:log(
        "streams ~p; received ~p; rtpengine ~p (the caller's tag ~s)~n"
        "SDP lines ~p",
        [
            Updated, Pts, Codecs, Tag, Maps
        ]
    ),
    ?assertMatch({match, [[_]]}, Updated),
    {match, [[Got]]} = Updated,
    ?assertEqual(Want, string:uppercase(Got)),
    ?assertMatch(
        nomatch, re:run(Log, <<"RX [0-9]+ bytes Request msg INVITE">>)
    ),
    ?assertMatch(nomatch, re:run(Log, <<"badpt=-?[1-9]">>)),
    #{Tag := Side} = Codecs,
    ?assertEqual(Want, string:uppercase(hd(binary:split(Side, <<"/">>)))),
    ok.

%% ---- what a caller heard ----

%% Whether the far end ended the call of the pjsua of Log: it was
%% disconnected before its own duration ran out. A BYE of another call (a
%% previous case's, retransmitted to this port) is answered 481 and does
%% not count.
hung_up(Log) ->
    has(Log, <<"Call 0 is DISCONNECTED">>) andalso
        not has(Log, <<"has been exceeded for call 0">>).

%% the pjsua log of Name
log(Dir, Name) ->
    {ok, Bin} = file:read_file(filename:join(Dir, container(Name) ++ ".log")),
    Bin.

%% the container of pjsua Name, as chappe_mrf_hd_live_SUITE names it
container(Name) ->
    os:getenv("MRF_PJSUA_NAME", "chappe-hd") ++ "-" ++ atom_to_list(Name).

has(Bin, Part) ->
    binary:match(Bin, Part) =/= nomatch.

%% The probe (or its narrow band, at 8 kHz) sent at RateIn, heard at Rate:
%% the whole band both at 16 kHz, else 1000 and 2500 Hz above -40 dBFS.
judge(Rate, Samples) ->
    judge(?RATE, Rate, Samples).

judge(_RateIn, _Rate, []) ->
    {error, nothing_heard};
judge(?RATE, ?RATE, Samples) ->
    Cal = chappe_mix_test_tone:band_calibrate(
        chappe_mix_test_tone:band_probe(2000)
    ),
    chappe_mix_test_tone:band_shape(Samples, Cal);
judge(_RateIn, Rate, Samples) ->
    Lv = chappe_mix_test_tone:levels(Samples, [1000, 2500], Rate),
    case [{F, L} || {F, L} <- Lv, L =< -40.0] of
        [] -> ok;
        Low -> {error, {low, Low}}
    end.

%% Len ms of Rec (at Rate) from From ms
from(Rec, Rate, From, Len) ->
    lists:sublist(Rec, From * Rate div 1000 + 1, Len * Rate div 1000).

%% whether Freq is above -35 dBFS in some 200 ms of Rec
tone_heard(Rec, Rate, Freq) ->
    segments(Rec, Rate, Freq) =/= [].

%% where the 1000 Hz tone is in Rec: [{FromMs, ToMs}], 200 ms windows
%% above -35 dBFS, gaps under 1 s merged
segments(Rec, Rate) ->
    segments(Rec, Rate, 1000).

segments(Rec, Rate, Freq) ->
    On = [
        begin
            [{_, L}] = chappe_mix_test_tone:levels(W, [Freq], Rate),
            L > -35.0
        end
     || W <- chappe_mix_test_tone:windows(Rec, Rate div 5)
    ],
    merge(runs(On, 0, []), []).

runs([], _I, Acc) ->
    lists:reverse(Acc);
runs([true | T], I, [{F, I} | Acc]) ->
    runs(T, I + 1, [{F, I + 1} | Acc]);
runs([true | T], I, Acc) ->
    runs(T, I + 1, [{I, I + 1} | Acc]);
runs([false | T], I, Acc) ->
    runs(T, I + 1, Acc).

merge([], Acc) ->
    [{F * 200, T * 200} || {F, T} <- lists:reverse(Acc)];
merge([{F2, T2} | Rest], [{F1, T1} | Acc]) when F2 - T1 < 5 ->
    merge(Rest, [{F1, T2} | Acc]);
merge([R | Rest], Acc) ->
    merge(Rest, [R | Acc]).

media_path(Config, <<"/media/", File/binary>>) ->
    filename:join(?config(media, Config), binary_to_list(File)).
