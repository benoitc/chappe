%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Opt-in interop suite against two live FreeSWITCH nodes. It runs only when
%% FS_HOST is set, otherwise every case is skipped. interop/docker-compose.yml
%% brings up fs1 and fs2 with ESL published on 18021 and 18022:
%%
%%   FS_HOST=127.0.0.1 FS_PORT=18021 FS2_PORT=18022 FS_PASSWORD=ClueCon \
%%   FS_COMPOSE="docker compose -p chappe-esl -f apps/chappe_esl/interop/docker-compose.yml" \
%%     rebar3 ct --dir apps/chappe_esl/test --suite chappe_esl_live_SUITE
%%
%% `make interop-esl' does all of it. The `conn' group drives one connection
%% to fs1. The `nodes' group registers both nodes; it needs FS2_PORT, and its
%% stop/start case needs FS_COMPOSE (the compose command line) to stop and
%% start fs1. The `call' group drives a channel with chappe_esl_call: fs1
%% calls fs2's socket-<port> extension, which connects back to a listener
%% here (ESL_SOCKET_PORT, 18084); it needs ESL_MEDIA_DIR, the directory both
%% nodes mount as /media, for its prompt and recordings.
-module(chappe_esl_live_SUITE).
-behaviour(chappe_esl_handler).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([status/1, reloadxml/1, originate_and_events/1, conference/1]).
-export([nodes_up_with_load/1, sessions_rise/1, stop_and_restart/1]).
-export([
    call_playback/1, call_digits/1, call_dtmf_event/1, call_record/1,
    call_owner_death/1, call_timeout_breaks/1, call_paths_with_spaces/1,
    call_audio_fork/1, call_audio_stream/1, call_linger_notice/1,
    call_playback_results/1, call_events_and_variables/1,
    call_fork_controls/1, call_stream_controls/1, call_say_speak/1,
    call_detect/1
]).
-export([handle_channel/3]).

-define(CALL_CASES, [
    call_playback,
    call_digits,
    call_dtmf_event,
    call_record,
    call_owner_death,
    call_timeout_breaks,
    call_paths_with_spaces,
    call_audio_fork,
    call_audio_stream,
    call_linger_notice,
    call_playback_results,
    call_events_and_variables,
    call_fork_controls,
    call_stream_controls,
    call_say_speak,
    call_detect
]).

all() ->
    [{group, conn}, {group, call}, {group, nodes}].

groups() ->
    [
        {conn, [], [status, reloadxml, originate_and_events, conference]},
        {call, [], ?CALL_CASES},
        {nodes, [sequence], [nodes_up_with_load, sessions_rise, stop_and_restart]}
    ].

init_per_suite(Config) ->
    case os:getenv("FS_HOST") of
        false ->
            {skip, "FS_HOST not set; live FreeSWITCH interop disabled"};
        Host ->
            Port = list_to_integer(os:getenv("FS_PORT", "18021")),
            Password = list_to_binary(os:getenv("FS_PASSWORD", "ClueCon")),
            {ok, _} = application:ensure_all_started(chappe_esl),
            [{fs, #{host => Host, port => Port, password => Password}} | Config]
    end.

end_per_suite(_Config) ->
    _ = application:stop(chappe_esl),
    ok.

init_per_group(nodes, Config) ->
    case os:getenv("FS2_PORT") of
        false ->
            {skip, "FS2_PORT not set; node registry interop disabled"};
        P2 ->
            Fs = ?config(fs, Config),
            Fs2 = Fs#{port => list_to_integer(P2)},
            ok = chappe_esl:node_add(fs1, node_opts(Fs, [a])),
            ok = chappe_esl:node_add(fs2, node_opts(Fs2, [b])),
            Config
    end;
init_per_group(call, Config) ->
    case os:getenv("ESL_MEDIA_DIR") of
        false ->
            {skip, "ESL_MEDIA_DIR not set; call control interop disabled"};
        Dir ->
            ok = write_wav(filename:join(Dir, "prompt.wav"), 1),
            ok = write_wav(filename:join(Dir, "prompt two.wav"), 1),
            %% mod_say_en's number files, under the lab's sound_prefix
            Digits = filename:join([Dir, "sounds", "digits"]),
            ok = filelib:ensure_path(Digits),
            [
                ok = write_wav(filename:join(Digits, integer_to_list(N) ++ ".wav"), 1)
             || N <- lists:seq(0, 19) ++ lists:seq(20, 90, 10)
            ],
            Port = list_to_integer(os:getenv("ESL_SOCKET_PORT", "18084")),
            [{media_dir, Dir}, {socket_port, Port} | Config]
    end;
init_per_group(_Group, Config) ->
    Config.

end_per_group(nodes, _Config) ->
    _ = chappe_esl:node_remove(fs1),
    _ = chappe_esl:node_remove(fs2),
    ok;
end_per_group(_Group, _Config) ->
    ok.

%% The connection is opened per test case: its controlling process is the
%% process that connects, and init_per_suite's exits before any case runs.
%% Node notices go to the case process, so it subscribes itself.
init_per_testcase(Case, Config) when
    Case =:= nodes_up_with_load; Case =:= sessions_rise; Case =:= stop_and_restart
->
    ok = chappe_esl:node_subscribe(all),
    Config;
init_per_testcase(Case, Config0) ->
    case connect_case(Config0) of
        {skip, _} = Skip ->
            Skip;
        Config ->
            case lists:member(Case, ?CALL_CASES) of
                true -> start_socket(Config);
                false -> Config
            end
    end.

connect_case(Config) ->
    case chappe_esl:connect(?config(fs, Config)) of
        {ok, Conn} ->
            [{conn, Conn} | Config];
        {error, Reason} ->
            %% FS_REQUIRED=1 (the CI job): a FreeSWITCH that cannot be
            %% reached fails the run instead of skipping every case
            case os:getenv("FS_REQUIRED") of
                "1" -> ct:fail({connect_failed, Reason});
                _ -> {skip, {connect_failed, Reason}}
            end
    end.

end_per_testcase(Case, Config) ->
    case lists:member(Case, ?CALL_CASES) of
        true ->
            _ = chappe_esl:stop_listener(?config(socket_port, Config)),
            _ = chappe_esl:api(
                ?config(conn, Config), ["uuid_kill ", ?config(a_uuid, Config)]
            );
        false ->
            ok
    end,
    case ?config(conn, Config) of
        undefined ->
            ok;
        Conn ->
            try
                chappe_esl:close(Conn)
            catch
                _:_ -> ok
            end
    end,
    ok.

%% conn group

status(Config) ->
    Conn = ?config(conn, Config),
    {ok, Body} = chappe_esl:api(Conn, "status"),
    ?assert(binary:match(Body, <<"UP">>) =/= nomatch).

reloadxml(Config) ->
    Conn = ?config(conn, Config),
    ?assertMatch({ok, _}, chappe_esl:bgapi_await(Conn, "reloadxml", 15000)).

%% A call from fs1 to fs2's park extension: fs1 reports the new channel and
%% its hangup.
originate_and_events(Config) ->
    Conn = ?config(conn, Config),
    ok = chappe_esl:subscribe(Conn, ['CHANNEL_CREATE', 'CHANNEL_HANGUP']),
    {ok, Reply} = chappe_esl:bgapi_await(
        Conn, "originate sofia/esl/sip:park@fs2:5080 &park", 15000
    ),
    Uuid = originate_uuid(Reply),
    ?assertNotEqual(undefined, Uuid),
    ok = expect_event(Conn, <<"CHANNEL_CREATE">>, 15000),
    {ok, _} = chappe_esl:api(Conn, ["uuid_kill ", Uuid]),
    ok = expect_event(Conn, <<"CHANNEL_HANGUP">>, 15000).

conference(Config) ->
    Conn = ?config(conn, Config),
    {ok, _} = chappe_esl:bgapi_await(
        Conn,
        "originate sofia/esl/sip:park@fs2:5080 &conference(esltest)",
        15000
    ),
    {ok, List} = chappe_esl:api(Conn, "conference esltest list"),
    ?assert(is_binary(List)),
    {ok, _} = chappe_esl:api(Conn, "conference esltest hup all").

%% call group

%% The outbound handler gives the connection to the case, which starts the
%% call process, then returns.
handle_channel(Conn, _Channel, TestPid) ->
    TestPid ! {live_conn, Conn, self()},
    receive
        started -> ok
    after 15000 -> ok
    end.

%% req: ESL-34 ESL-35
call_playback(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    {ok, Ev} = chappe_esl_call:playback(Call, "/media/prompt.wav"),
    ?assertEqual(
        <<"FILE PLAYED">>,
        chappe_esl_event:header(<<"Application-Response">>, Ev)
    ),
    {ok, Missing} = chappe_esl_call:playback(Call, "/media/missing.wav"),
    ?assertNotEqual(
        <<"FILE PLAYED">>,
        chappe_esl_event:header(<<"Application-Response">>, Missing)
    ),
    ok = chappe_esl_call:hangup(Call),
    ?assertMatch({hangup, _}, call_msg(Call, hangup)).

%% fs1 sends RFC 2833 digits on its leg while fs2 runs play_and_get_digits.
%% req: ESL-37
call_digits(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    send_dtmf_later(Config, "12#", 1500),
    ?assertEqual(
        {ok, <<"12">>},
        chappe_esl_call:play_and_get_digits(Call, #{
            file => <<"/media/prompt.wav">>, max => 4, timeout => 8000
        })
    ).

%% req: ESL-38
call_dtmf_event(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    send_dtmf_later(Config, "5", 500),
    ?assertEqual({dtmf, <<"5">>}, call_msg(Call, dtmf)).

%% req: ESL-37
call_record(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    Name = "rec-" ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, _} = chappe_esl_call:record(Call, "/media/" ++ Name ++ ".wav", #{
        max_secs => 2
    }),
    ok = chappe_esl_call:record_session(Call, "/media/" ++ Name ++ "-s.wav"),
    {ok, _} = chappe_esl_call:playback(Call, "/media/prompt.wav"),
    ok = chappe_esl_call:record_session_stop(
        Call, "/media/" ++ Name ++ "-s.wav"
    ),
    Dir = ?config(media_dir, Config),
    lists:foreach(
        fun(F) ->
            Path = filename:join(Dir, Name ++ F),
            ok = wait(fun() -> filelib:file_size(Path) > 44 end, 100)
        end,
        [".wav", "-s.wav"]
    ).

%% The owner dies: the call kills the channel, and fs1's leg hangs up.
%% req: ESL-39
call_owner_death(Config) ->
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    Call = live_call(Config, Owner),
    ok = chappe_esl_call:answer(Call),
    ok = chappe_esl_call:record_session(Call, "/media/owner-death.wav"),
    Conn = ?config(conn, Config),
    ok = chappe_esl:subscribe(Conn, ['CHANNEL_HANGUP']),
    Mon = monitor(process, Call),
    exit(Owner, kill),
    receive
        {'DOWN', Mon, process, Call, _} -> ok
    after 10000 -> ct:fail(call_not_stopped)
    end,
    ok = expect_event(Conn, <<"CHANNEL_HANGUP">>, 15000).

%% A timed out playback is broken: the next one plays at once, and the late
%% completion does not reach the owner.
%% req: ESL-35
call_timeout_breaks(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:playback(
            Call, "tone_stream://%(20000,0,440)", #{timeout => 500}
        )
    ),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Ev} = chappe_esl_call:playback(Call, "/media/prompt.wav"),
    ?assertEqual(
        <<"FILE PLAYED">>,
        chappe_esl_event:header(<<"Application-Response">>, Ev)
    ),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 5000),
    receive
        {chappe_esl_call, Call, {complete, _, _} = Leak} ->
            ct:fail({leaked, Leak})
    after 500 ->
        ok
    end.

%% Paths with a space play, record and prompt digit collection.
%% req: ESL-37
call_paths_with_spaces(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    {ok, Ev} = chappe_esl_call:playback(Call, "/media/prompt two.wav"),
    ?assertEqual(
        <<"FILE PLAYED">>,
        chappe_esl_event:header(<<"Application-Response">>, Ev)
    ),
    send_dtmf_later(Config, "7#", 1500),
    ?assertEqual(
        {ok, <<"7">>},
        chappe_esl_call:play_and_get_digits(Call, #{
            file => <<"/media/prompt two.wav">>, max => 2, timeout => 8000
        })
    ),
    Name = "rec " ++ integer_to_list(erlang:unique_integer([positive])),
    {ok, _} = chappe_esl_call:record(Call, "/media/" ++ Name ++ ".wav", #{
        max_secs => 1
    }),
    ok = chappe_esl_call:record_session(Call, "/media/" ++ Name ++ " s.wav"),
    {ok, _} = chappe_esl_call:playback(Call, "/media/prompt.wav"),
    ok = chappe_esl_call:record_session_stop(
        Call, "/media/" ++ Name ++ " s.wav"
    ),
    Dir = ?config(media_dir, Config),
    lists:foreach(
        fun(F) ->
            Path = filename:join(Dir, Name ++ F),
            ok = wait(fun() -> filelib:file_size(Path) > 44 end, 100)
        end,
        [".wav", " s.wav"]
    ).

%% mod_audio_fork streams the channel to a websocket here: the metadata
%% arrives first as text, then binary audio, and the stop closes it.
%% req: ESL-37
call_audio_fork(Config) ->
    fork_to_sink(Config, #{}).

%% The same through mod_audio_stream, selected with the module option.
%% req: ESL-37
call_audio_stream(Config) ->
    fork_to_sink(Config, #{module => audio_stream}).

fork_to_sink(Config, Opts) ->
    WsPort = ?config(socket_port, Config) + 1,
    Sink = ws_sink(WsPort, self()),
    try
        Call = live_call(Config, self()),
        ok = chappe_esl_call:answer(Call),
        Url = "ws://host.docker.internal:" ++ integer_to_list(WsPort),
        Meta = <<"{\"call\": \"lab one\"}">>,
        ok = chappe_esl_call:audio_fork_start(Call, Url, Opts#{
            mix => mono, rate => 8000, metadata => Meta
        }),
        ?assertMatch({ws, connected, _}, ws_msg()),
        ?assertEqual({ws, text, Meta}, ws_msg()),
        ?assertEqual({ws, binary}, ws_msg()),
        timer:sleep(500),
        ok = chappe_esl_call:audio_fork_stop(Call),
        {ws, closed, Frames} = ws_msg(),
        ct:pal("fork sent ~p binary frames", [Frames]),
        ?assert(Frames > 1)
    after
        exit(Sink, kill)
    end.

%% A playback reports how long it played, an offset and a time limit
%% shorten it, and digit collection returns the terminator and the entry
%% the regexp refused.
%% req: ESL-37
call_playback_results(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    {ok, Ev} = chappe_esl_call:playback(Call, "/media/prompt.wav"),
    Ms = binary_to_integer(
        chappe_esl_event:header(<<"variable_playback_ms">>, Ev)
    ),
    ?assert(Ms > 800 andalso Ms < 1500),
    {ok, Off} = chappe_esl_call:playback(Call, "/media/prompt.wav", #{
        offset => 4000
    }),
    OffMs = binary_to_integer(
        chappe_esl_event:header(<<"variable_playback_ms">>, Off)
    ),
    ?assert(OffMs < Ms),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Lim} = chappe_esl_call:playback(
        Call, "tone_stream://%(20000,0,350)", #{limit_secs => 2}
    ),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:pal("limited playback: ~p ms, ~s", [
        Took, chappe_esl_event:header(<<"Application-Response">>, Lim)
    ]),
    ?assert(Took < 5000),
    send_dtmf_later(Config, "34#", 1000),
    ?assertEqual(
        {ok, #{digits => <<>>, terminator => <<"#">>, invalid => <<"34">>}},
        chappe_esl_call:play_and_get_digits(Call, #{
            file => <<"silence_stream://250">>,
            max => 4,
            timeout => 6000,
            regexp => <<"^9$">>,
            result => full
        })
    ).

%% A PLAYBACK_START and PLAYBACK_STOP asked for with subscribe/2 reach the
%% owner; variables are set, read and dumped; uuid_audio mutes and unmutes.
%% req: ESL-34 ESL-37
call_events_and_variables(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    ok = chappe_esl_call:subscribe(Call, [<<"PLAYBACK_START">>, 'PLAYBACK_STOP']),
    {ok, _} = chappe_esl_call:playback(Call, "/media/prompt.wav"),
    ?assertEqual(<<"PLAYBACK_START">>, event_named(Call, <<"PLAYBACK_START">>)),
    ?assertEqual(<<"PLAYBACK_STOP">>, event_named(Call, <<"PLAYBACK_STOP">>)),
    ok = chappe_esl_call:multiset(Call, #{
        <<"chappe_a">> => <<"one two">>, <<"chappe_b">> => <<"x|y">>
    }),
    ?assertEqual({ok, <<"one two">>}, chappe_esl_call:getvar(Call, <<"chappe_a">>)),
    ?assertEqual({ok, undefined}, chappe_esl_call:getvar(Call, <<"chappe_none">>)),
    {ok, Vars} = chappe_esl_call:dump(Call),
    ?assertMatch(#{<<"chappe_b">> := <<"x|y">>}, Vars),
    ok = chappe_esl_call:mute(Call, read),
    ok = chappe_esl_call:unmute(Call, read),
    ok = chappe_esl_call:hangup(Call).

%% Two named mod_audio_fork forks on one channel, one mono and one stereo:
%% the stereo one carries twice the bytes; pause stops the audio of one
%% fork, resume brings it back, send_text reaches its server.
%% req: ESL-37
call_fork_controls(Config) ->
    Base = ?config(socket_port, Config),
    Mono = ws_sink(Base + 1, self()),
    Stereo = ws_sink(Base + 2, self()),
    try
        Call = live_call(Config, self()),
        ok = chappe_esl_call:answer(Call),
        Url = fun(P) -> "ws://host.docker.internal:" ++ integer_to_list(P) end,
        ok = chappe_esl_call:audio_fork_start(Call, Url(Base + 1), #{
            bugname => <<"mono">>, mix => mono, rate => 8000
        }),
        ok = chappe_esl_call:audio_fork_start(Call, Url(Base + 2), #{
            bugname => <<"stereo">>, mix => stereo, rate => 8000
        }),
        %% the channel writes too while we measure: a stereo bug sends a
        %% frame when it has both directions
        {ok, _} = chappe_esl_call:exec(
            Call, "playback", "tone_stream://%(20000,0,600)", #{wait => false}
        ),
        timer:sleep(500),
        flush_audio(),
        timer:sleep(2000),
        Bytes = audio_bytes(),
        ct:pal("2 s of audio: mono ~p, stereo ~p", [
            maps:get(Mono, Bytes, 0), maps:get(Stereo, Bytes, 0)
        ]),
        Ratio = maps:get(Stereo, Bytes, 0) / max(1, maps:get(Mono, Bytes, 0)),
        ?assert(Ratio > 1.7 andalso Ratio < 2.3),
        ok = chappe_esl_call:audio_fork_pause(Call, #{bugname => <<"stereo">>}),
        timer:sleep(500),
        flush_audio(),
        timer:sleep(1500),
        Paused = audio_bytes(),
        ct:pal("paused: ~p", [Paused]),
        ?assertEqual(0, maps:get(Stereo, Paused, 0)),
        ?assert(maps:get(Mono, Paused, 0) > 0),
        ok = chappe_esl_call:audio_fork_resume(Call, #{bugname => <<"stereo">>}),
        timer:sleep(1500),
        ?assert(maps:get(Stereo, audio_bytes(), 0) > 0),
        ok = chappe_esl_call:audio_fork_send_text(
            Call, <<"{\"type\": \"mark\"}">>, #{bugname => <<"mono">>}
        ),
        ?assertEqual({ws, text, <<"{\"type\": \"mark\"}">>}, ws_text()),
        ok = chappe_esl_call:audio_fork_stop(Call)
    after
        exit(Mono, kill),
        exit(Stereo, kill)
    end.

%% mod_audio_stream takes pause, resume and send_text too.
%% req: ESL-37
call_stream_controls(Config) ->
    Port = ?config(socket_port, Config) + 1,
    Sink = ws_sink(Port, self()),
    try
        Call = live_call(Config, self()),
        ok = chappe_esl_call:answer(Call),
        Url = "ws://host.docker.internal:" ++ integer_to_list(Port),
        ok = chappe_esl_call:audio_fork_start(Call, Url, #{
            module => audio_stream, mix => mono, rate => 8000
        }),
        ?assertMatch({ws, connected, _}, ws_msg()),
        timer:sleep(1000),
        ok = chappe_esl_call:audio_fork_pause(Call, #{}),
        timer:sleep(500),
        flush_audio(),
        timer:sleep(1500),
        ?assertEqual(0, maps:get(Sink, audio_bytes(), 0)),
        ok = chappe_esl_call:audio_fork_resume(Call, #{}),
        timer:sleep(1500),
        ?assert(maps:get(Sink, audio_bytes(), 0) > 0),
        ok = chappe_esl_call:audio_fork_send_text(Call, <<"hello there">>, #{}),
        ?assertEqual({ws, text, <<"hello there">>}, ws_text()),
        ok = chappe_esl_call:audio_fork_stop(Call)
    after
        exit(Sink, kill)
    end.

%% mod_say_en plays the sound files of a number (seen as PLAYBACK_START
%% events), mod_flite speaks text for as long as it takes to say it.
%% req: ESL-37
call_say_speak(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    ok = chappe_esl_call:subscribe(Call, [<<"PLAYBACK_START">>]),
    S0 = erlang:monotonic_time(millisecond),
    ok = chappe_esl_call:say(Call, <<"42">>, #{type => number}),
    Said = erlang:monotonic_time(millisecond) - S0,
    Played = played_files(),
    ct:pal("say 42 played ~p in ~p ms", [Played, Said]),
    %% mod_say_en picks forty and two, then plays both one-second files
    ?assertEqual([<<"file_string://digits/40.wav!digits/2.wav">>], Played),
    ?assert(Said > 1800),
    {ok, <<"true", _/binary>>} = chappe_esl_call:api(Call, "module_exists mod_flite"),
    T0 = erlang:monotonic_time(millisecond),
    ok = chappe_esl_call:speak(Call, <<"Thank you for calling the chappe lab">>, #{
        engine => <<"flite">>, voice => <<"kal">>
    }),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:pal("speak took ~p ms", [Took]),
    ?assert(Took > 1000).

%% mod_spandsp hears fs1's 440 Hz tone with the lab's chappe_440
%% descriptor, and a CNG fax tone fs1 starts sending.
%% req: ESL-37 ESL-38
call_detect(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    ok = chappe_esl_call:detect_tones(Call, <<"chappe_440">>),
    ?assertEqual({tone, <<"TONE_440">>}, call_msg(Call, tone)),
    ok = chappe_esl_call:stop_detect_tones(Call),
    ok = chappe_esl_call:detect_fax(Call, #{}),
    Conn = ?config(conn, Config),
    {ok, _} = chappe_esl:api(Conn, [
        "uuid_broadcast ", ?config(a_uuid, Config),
        " tone_stream://%(500,3000,1100);loops=4 aleg"
    ]),
    ?assertEqual({fax, detected}, call_msg(Call, fax)),
    ?assertEqual(
        {error, <<"-ERR failed to start tone detector">>},
        chappe_esl_call:detect_tones(Call, <<"no_such_descriptor">>)
    ).

event_named(Call, Name) ->
    receive
        {chappe_esl_call, Call, {event, Ev}} ->
            case chappe_esl_event:name(Ev) of
                Name -> Name;
                _ -> event_named(Call, Name)
            end
    after 10000 -> ct:fail({no_event, Name})
    end.

%% the PLAYBACK_START files until none comes for a second
played_files() ->
    receive
        {chappe_esl_call, _, {event, Ev}} ->
            case chappe_esl_event:name(Ev) of
                <<"PLAYBACK_START">> ->
                    [chappe_esl_event:header(<<"Playback-File-Path">>, Ev) | played_files()];
                _ ->
                    played_files()
            end
    after 1000 -> []
    end.

flush_audio() ->
    receive
        {ws_audio, _, _} -> flush_audio()
    after 0 -> ok
    end.

%% bytes per sink received since the last flush
audio_bytes() ->
    audio_bytes(#{}).

audio_bytes(Acc) ->
    receive
        {ws_audio, Sink, N} -> audio_bytes(Acc#{Sink => maps:get(Sink, Acc, 0) + N})
    after 0 -> Acc
    end.

ws_text() ->
    receive
        {ws, text, _} = Msg -> Msg
    after 10000 -> ct:fail(no_ws_text)
    end.

%% After the hangup a real node tells the owner the socket lingers.
%% req: ESL-38
call_linger_notice(Config) ->
    Call = live_call(Config, self()),
    ok = chappe_esl_call:answer(Call),
    ok = chappe_esl_call:hangup(Call),
    ok = expect_linger(Call),
    ok = chappe_esl_call:stop(Call).

expect_linger(Call) ->
    receive
        {chappe_esl_call, Call, linger} -> ok;
        {chappe_esl_call, Call, closed} -> ct:fail(closed_before_linger)
    after 10000 ->
        ct:fail(no_linger)
    end.

%% nodes group

%% Both nodes come up and report their load from HEARTBEAT and the probes.
%% req: ESL-24 ESL-25 ESL-27
nodes_up_with_load(_Config) ->
    ok = wait_up([fs1, fs2]),
    lists:foreach(
        fun(Name) ->
            Load = wait_load(Name, fun(L) ->
                maps:is_key(heartbeat_at, L) andalso maps:is_key(calls, L)
            end),
            ct:pal("~p load ~p", [Name, Load]),
            ?assertMatch(#{max_sessions := 200, idle_cpu := _}, Load)
        end,
        [fs1, fs2]
    ),
    ?assertMatch({ok, _}, chappe_esl:node_select(#{})),
    ?assertEqual({ok, fs2}, chappe_esl:node_select(#{tags => [b]})).

%% A call from fs1 to fs2 raises both session counts; fs2's CHANNEL_CREATE
%% carries the X-Chappe-Call header of the INVITE, which is how a caller
%% ties a FreeSWITCH uuid to its own call. Selection then prefers the idle
%% one, and the counts fall back after hangup.
%% req: ESL-25 ESL-29 ESL-31 ESL-33
sessions_rise(_Config) ->
    ok = chappe_esl:node_events(fs2),
    CallId = integer_to_binary(erlang:unique_integer([positive])),
    {ok, _Job} = chappe_esl:node_bgapi(fs1, [
        "originate {sip_h_X-Chappe-Call=",
        CallId,
        "}sofia/esl/sip:park@fs2:5080 &park"
    ]),
    Uuid = wait_call(CallId),
    ct:pal("X-Chappe-Call ~s is fs2 channel ~s", [CallId, Uuid]),
    ok = wait_load(fs1, fun(L) -> maps:get(sessions, L, 0) >= 1 end, ok),
    ok = wait_load(fs2, fun(L) -> maps:get(sessions, L, 0) >= 1 end, ok),
    {ok, _} = chappe_esl:node_api(fs2, ["uuid_kill ", Uuid]),
    ok = wait_load(fs1, fun(L) -> maps:get(sessions, L, 1) =:= 0 end, ok).

%% fs1 stops: it goes down and selection returns fs2; it starts again: up.
%% req: ESL-24 ESL-31
stop_and_restart(_Config) ->
    case os:getenv("FS_COMPOSE") of
        false ->
            {skip, "FS_COMPOSE not set"};
        Compose ->
            ok = wait_up([fs1, fs2]),
            flush(),
            compose(Compose, "stop fs1"),
            ok = expect_state(fs1, down, 30000),
            ?assertEqual({ok, fs2}, chappe_esl:node_select(#{})),
            ?assertEqual({error, down}, chappe_esl:node_api(fs1, "status")),
            compose(Compose, "start fs1"),
            ok = expect_state(fs1, up, 60000),
            %% up means the probes passed, so the node answers at once
            ok = wait(
                fun() ->
                    case chappe_esl:node_api(fs1, "status") of
                        {ok, <<"UP", _/binary>>} -> true;
                        _ -> false
                    end
                end,
                600
            ),
            ok = wait_up([fs1, fs2])
    end.

%% helpers

start_socket(Config) ->
    Port = ?config(socket_port, Config),
    {ok, _} = chappe_esl:start_listener(Port, ?MODULE, self()),
    Config ++ [{a_uuid, new_uuid()}].

%% fs1 calls fs2's socket extension and keeps playing a tone (so its RTP
%% carries the DTMF it is asked to send); fs2's channel connects here.
live_call(Config, Owner) ->
    Conn = ?config(conn, Config),
    AUuid = ?config(a_uuid, Config),
    Port = integer_to_list(?config(socket_port, Config)),
    {ok, _} = chappe_esl:bgapi(Conn, [
        "originate {origination_uuid=",
        AUuid,
        "}sofia/esl/sip:socket-",
        Port,
        "@fs2:5080 &endless_playback(tone_stream://%(1000,0,440))"
    ]),
    receive
        {live_conn, OConn, Handler} ->
            {ok, Call} = chappe_esl_call:start(OConn, #{owner => Owner}),
            Handler ! started,
            Call
    after 15000 ->
        ct:fail(no_socket_connection)
    end.

send_dtmf_later(Config, Digits, Ms) ->
    Conn = ?config(conn, Config),
    AUuid = ?config(a_uuid, Config),
    spawn(fun() ->
        timer:sleep(Ms),
        {ok, _} = chappe_esl:api(Conn, ["uuid_send_dtmf ", AUuid, " ", Digits])
    end).

%% The next call message of the given kind, skipping the others.
call_msg(Call, Kind) ->
    receive
        {chappe_esl_call, Call, Msg} when element(1, Msg) =:= Kind -> Msg
    after 15000 ->
        ct:fail({no_call_msg, Kind})
    end.

new_uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = rand:bytes(16),
    iolist_to_binary(
        io_lib:format(
            "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E]
        )
    ).

%% A minimal websocket server for the fork modules: it accepts one client
%% (echoing the audio.drachtio.org subprotocol), then reports
%% {ws, connected, Request}, {ws, text, Payload}, {ws, binary} for the first
%% binary frame, and {ws, closed, BinaryFrames} on a close frame or the end
%% of the connection. Every binary frame is also {ws_audio, Sink, Bytes}.
ws_sink(Port, TestPid) ->
    {ok, L} = gen_tcp:listen(Port, [
        binary, {packet, raw}, {active, false}, {reuseaddr, true}
    ]),
    Pid = spawn(fun() ->
        receive
            go -> ws_accept(L, TestPid)
        end
    end),
    ok = gen_tcp:controlling_process(L, Pid),
    Pid ! go,
    Pid.

ws_accept(L, TestPid) ->
    {ok, S} = gen_tcp:accept(L, 30000),
    Req = ws_request(S, <<>>),
    Key = ws_header(<<"sec-websocket-key">>, Req),
    Accept = base64:encode(
        crypto:hash(sha, <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)
    ),
    Proto =
        case ws_header(<<"sec-websocket-protocol">>, Req) of
            <<>> ->
                [];
            P ->
                First = string:trim(hd(binary:split(P, <<",">>))),
                [<<"sec-websocket-protocol: ">>, First, <<"\r\n">>]
        end,
    ok = gen_tcp:send(S, [
        %% lowercase names, as livery sends them: mod_audio_stream before
        %% v1.1.0 fails the upgrade on them
        <<"HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n">>,
        <<"connection: Upgrade\r\nsec-websocket-accept: ">>,
        Accept,
        <<"\r\n">>,
        Proto,
        <<"\r\n">>
    ]),
    TestPid ! {ws, connected, Req},
    ws_loop(S, TestPid, <<>>, 0).

ws_request(S, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, _] ->
            Head;
        [_] ->
            {ok, Data} = gen_tcp:recv(S, 0, 10000),
            ws_request(S, <<Acc/binary, Data/binary>>)
    end.

ws_header(Name, Req) ->
    Lines = binary:split(Req, <<"\r\n">>, [global]),
    Values = [
        string:trim(V)
     || Line <- Lines,
        [K, V] <- [binary:split(Line, <<":">>)],
        string:lowercase(K) =:= Name
    ],
    case Values of
        [V1 | _] -> V1;
        [] -> <<>>
    end.

ws_loop(S, TestPid, Buf, N) ->
    case ws_frame(Buf) of
        {1, Payload, Rest} ->
            TestPid ! {ws, text, Payload},
            ws_loop(S, TestPid, Rest, N);
        {2, Payload, Rest} when N =:= 0 ->
            TestPid ! {ws, binary},
            TestPid ! {ws_audio, self(), byte_size(Payload)},
            ws_loop(S, TestPid, Rest, 1);
        {2, Payload, Rest} ->
            TestPid ! {ws_audio, self(), byte_size(Payload)},
            ws_loop(S, TestPid, Rest, N + 1);
        {8, _Payload, _Rest} ->
            _ = gen_tcp:send(S, <<1:1, 0:3, 8:4, 0:1, 0:7>>),
            TestPid ! {ws, closed, N},
            gen_tcp:close(S);
        {_Op, _Payload, Rest} ->
            ws_loop(S, TestPid, Rest, N);
        more ->
            case gen_tcp:recv(S, 0, 30000) of
                {ok, Data} ->
                    ws_loop(S, TestPid, <<Buf/binary, Data/binary>>, N);
                {error, _} ->
                    TestPid ! {ws, closed, N}
            end
    end.

%% One client frame (always masked), unmasked.
ws_frame(<<_Fin:1, _:3, Op:4, 1:1, Len0:7, Rest0/binary>>) ->
    case {Len0, Rest0} of
        {126, <<Len:16, R/binary>>} -> ws_payload(Op, Len, R);
        {127, <<Len:64, R/binary>>} -> ws_payload(Op, Len, R);
        {Len, R} when Len < 126 -> ws_payload(Op, Len, R);
        _ -> more
    end;
ws_frame(_) ->
    more.

ws_payload(Op, Len, Bin) ->
    case Bin of
        <<Mask:4/binary, Masked:Len/binary, Rest/binary>> ->
            {Op, unmask(Masked, Mask), Rest};
        _ ->
            more
    end.

unmask(Data, Mask) ->
    Size = byte_size(Data),
    <<Key:Size/binary, _/binary>> = binary:copy(Mask, Size div 4 + 1),
    crypto:exor(Data, Key).

ws_msg() ->
    receive
        {ws, _, _} = Msg -> Msg;
        {ws, _} = Msg -> Msg
    after 15000 ->
        ct:fail(no_ws_message)
    end.

%% A Secs long 440 Hz tone, 8 kHz 16-bit mono.
write_wav(Path, Secs) ->
    Rate = 8000,
    Samples = <<
        <<(round(8000 * math:sin(2 * math:pi() * 440 * I / Rate))):16/little-signed>>
     || I <- lists:seq(0, Rate * Secs - 1)
    >>,
    Size = byte_size(Samples),
    Header =
        <<"RIFF", (36 + Size):32/little, "WAVE", "fmt ", 16:32/little,
            1:16/little, 1:16/little, Rate:32/little, (Rate * 2):32/little,
            2:16/little, 16:16/little, "data", Size:32/little>>,
    file:write_file(Path, [Header, Samples]).

node_opts(#{host := Host, port := Port, password := Password}, Tags) ->
    #{
        host => Host,
        port => Port,
        password => Password,
        tags => Tags,
        heartbeat_interval_ms => 1000,
        probe_interval_ms => 1000,
        probe_timeout_ms => 3000,
        backoff_min_ms => 200,
        backoff_max_ms => 2000
    }.

compose(Compose, Args) ->
    Out = os:cmd(Compose ++ " " ++ Args ++ " 2>&1"),
    ct:pal("~s ~s: ~s", [Compose, Args, Out]).

wait_up(Names) ->
    wait(
        fun() ->
            lists:all(
                fun(N) ->
                    case chappe_esl:node_status(N) of
                        {ok, #{state := up}} -> true;
                        _ -> false
                    end
                end,
                Names
            )
        end,
        300
    ).

wait_load(Name, Pred) ->
    receive
        {chappe_esl_node, Name, {load, Load}} ->
            case Pred(Load) of
                true -> Load;
                false -> wait_load(Name, Pred)
            end
    after 15000 ->
        ct:fail({no_load, Name})
    end.

wait_load(Name, Pred, ok) ->
    wait(
        fun() ->
            {ok, #{load := L}} = chappe_esl:node_status(Name),
            Pred(L)
        end,
        300
    ).

%% The fs2 channel created for our X-Chappe-Call.
wait_call(CallId) ->
    receive
        {chappe_esl_node, fs2, {event, Ev}} ->
            case
                {
                    chappe_esl_event:name(Ev),
                    chappe_esl_event:header(<<"variable_sip_h_X-Chappe-Call">>, Ev)
                }
            of
                {<<"CHANNEL_CREATE">>, CallId} ->
                    chappe_esl_event:header(<<"Unique-ID">>, Ev);
                _ ->
                    wait_call(CallId)
            end
    after 15000 ->
        ct:fail({no_channel, CallId})
    end.

expect_state(Name, State, Timeout) ->
    receive
        {chappe_esl_node, Name, State} -> ok
    after Timeout ->
        ct:fail({no_state, Name, State})
    end.

wait(_Fun, 0) ->
    ct:fail(wait_timeout);
wait(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait(Fun, N - 1)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

originate_uuid(Reply) ->
    case binary:split(string:trim(Reply), <<" ">>) of
        [<<"+OK">>, Uuid | _] -> Uuid;
        _ -> undefined
    end.

expect_event(Conn, Name, Timeout) ->
    receive
        {chappe_esl_event, Conn, Event} ->
            case chappe_esl_event:name(Event) of
                Name -> ok;
                _Other -> expect_event(Conn, Name, Timeout)
            end
    after Timeout ->
        {error, {no_event, Name}}
    end.
