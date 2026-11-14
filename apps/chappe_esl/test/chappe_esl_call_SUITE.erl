%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_esl_call against the fake FreeSWITCH: as an outbound client
%% connecting to a listener (the dialplan socket application) and as an
%% inbound event socket with a channel.
-module(chappe_esl_call_SUITE).
-behaviour(chappe_esl_handler).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    outbound_subscribes/1,
    exec_matches_its_completion/1,
    exec_timeout/1,
    timeout_breaks_running/1,
    timeout_breaks_queued/1,
    raw_timeout_breaks/1,
    args_with_spaces/1,
    raw_exec_interleaved/1,
    raw_exec_long_arg/1,
    inbound_call/1,
    play_and_get_digits/1,
    play_and_get_digits_full/1,
    playback_options/1,
    subscribe_events/1,
    variables_and_audio/1,
    fork_commands/1,
    dtmf_and_hangup/1,
    helpers/1,
    audio_stream_commands/1,
    owner_death_cleanup/1,
    owner_death_after_hangup/1,
    owner_death_audio_stream/1,
    connection_closed/1,
    stop_leaves_channel/1,
    api_held_hangup/1,
    api_held_dtmf/1,
    api_held_exec_timeout/1,
    api_held_exec_sent/1,
    api_held_past_send_limit/1,
    api_held_owner_death/1,
    api_held_fork_stop_owner_death/1,
    api_held_replies_in_order/1,
    api_held_connection_closed/1,
    api_helper_killed/1,
    api_helper_quiet/1,
    fork_start_failed/1,
    fork_start_failed_while_running/1,
    call_linger_then_disconnect/1,
    call_disconnect_only/1
]).
-export([handle_channel/3]).
-export([log/2]).

-define(UUID, <<"fake-uuid-1">>).

all() ->
    [
        outbound_subscribes,
        exec_matches_its_completion,
        exec_timeout,
        timeout_breaks_running,
        timeout_breaks_queued,
        raw_timeout_breaks,
        args_with_spaces,
        raw_exec_interleaved,
        raw_exec_long_arg,
        inbound_call,
        play_and_get_digits,
        play_and_get_digits_full,
        playback_options,
        subscribe_events,
        variables_and_audio,
        fork_commands,
        dtmf_and_hangup,
        helpers,
        audio_stream_commands,
        owner_death_cleanup,
        owner_death_after_hangup,
        owner_death_audio_stream,
        connection_closed,
        stop_leaves_channel,
        api_held_hangup,
        api_held_dtmf,
        api_held_exec_timeout,
        api_held_exec_sent,
        api_held_past_send_limit,
        api_held_owner_death,
        api_held_fork_stop_owner_death,
        api_held_replies_in_order,
        api_held_connection_closed,
        api_helper_killed,
        api_helper_quiet,
        fork_start_failed,
        fork_start_failed_while_running,
        call_linger_then_disconnect,
        call_disconnect_only
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_esl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_esl),
    ok.

%% The handler hands the connection to a call process owned by the test
%% (or the owner it was given) and returns: the connection follows the call
%% process, not the handler.
handle_channel(Conn, _Channel, {TestPid, Owner}) ->
    TestPid ! {call, chappe_esl_call:start(Conn, #{owner => Owner})},
    ok.

%% req: ESL-34
outbound_subscribes(_Config) ->
    {Call, _Fake} = outbound(#{}),
    ?assertMatch(<<"connect", _/binary>>, next_block()),
    ?assertMatch(<<"linger", _/binary>>, next_block()),
    ?assertMatch(<<"myevents plain", _/binary>>, next_block()),
    ?assertEqual(?UUID, chappe_esl_call:uuid(Call)).

%% Two executes in flight, the slow one sent first, plus a completion no
%% request waits for: each request gets its own completion, the stray one
%% reaches the owner.
%% req: ESL-35
exec_matches_its_completion(_Config) ->
    Apps = #{<<"playback">> => #{delay => 300, response => <<"FILE PLAYED">>}},
    {Call, Fake} = outbound(#{apps => Apps}),
    Self = self(),
    spawn(fun() -> Self ! {pb, chappe_esl_call:playback(Call, "a.wav")} end),
    _ = block_with(<<"execute-app-name: playback">>),
    ok = chappe_esl_fake_server:inject(
        Fake,
        chappe_esl_fake_server:plain_event(<<"CHANNEL_EXECUTE_COMPLETE">>, [
            {<<"Unique-ID">>, ?UUID},
            {<<"Application">>, <<"park">>},
            {<<"Application-UUID">>, <<"stray">>}
        ])
    ),
    ?assertEqual(ok, chappe_esl_call:answer(Call)),
    ?assertMatch({complete, <<"park">>, _}, owner_msg_skip_events(Call)),
    receive
        {pb, {ok, Ev}} ->
            ?assertEqual(<<"playback">>, hdr(<<"Application">>, Ev)),
            ?assertEqual(
                <<"FILE PLAYED">>, hdr(<<"Application-Response">>, Ev)
            )
    after 5000 ->
        ct:fail(no_playback_result)
    end.

%% req: ESL-35
exec_timeout(_Config) ->
    {Call, _Fake} = outbound(#{apps => #{<<"park">> => silent}}),
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:exec(Call, "park", "", #{timeout => 200})
    ),
    ?assertEqual(ok, chappe_esl_call:answer(Call)).

%% A timed out application that is running is broken with uuid_break, and
%% its late completion does not reach the owner.
%% req: ESL-35
timeout_breaks_running(_Config) ->
    {Call, _Fake} = outbound(#{apps => #{<<"playback">> => #{delay => 500}}}),
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:exec(Call, "playback", "long.wav", #{timeout => 200})
    ),
    ?assertEqual(
        <<"api uuid_break fake-uuid-1">>, block_with(<<"uuid_break">>)
    ),
    no_completion(Call, 700).

%% A timed out application still queued is broken once it starts.
%% req: ESL-35
timeout_breaks_queued(_Config) ->
    Spec = #{execute_delay => 500, delay => 700},
    {Call, _Fake} = outbound(#{apps => #{<<"playback">> => Spec}}),
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:exec(Call, "playback", "long.wav", #{timeout => 100})
    ),
    receive
        {fake_server, _, <<"api uuid_break", _/binary>> = Early} ->
            ct:fail({broken_before_start, Early})
    after 200 ->
        ok
    end,
    ?assertEqual(
        <<"api uuid_break fake-uuid-1">>, block_with(<<"uuid_break">>)
    ),
    no_completion(Call, 700).

%% exec/5 breaks a running application, and flushes the queue when its
%% application has not started yet.
%% req: ESL-35
raw_timeout_breaks(_Config) ->
    Apps = #{
        <<"park">> => #{delay => silent},
        <<"playback">> => #{execute_delay => 5000, delay => silent}
    },
    {ok, Fake, Port} = chappe_esl_fake_server:start(#{
        channel => <<"in-1">>, apps => Apps
    }),
    {ok, Conn} = chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port}),
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:exec(Conn, <<"in-1">>, "park", "", #{timeout => 100})
    ),
    ?assertEqual(<<"api uuid_break in-1">>, block_with(<<"uuid_break">>)),
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:exec(Conn, <<"in-1">>, "playback", "x", #{
            timeout => 100
        })
    ),
    ?assertEqual(<<"api uuid_break in-1 all">>, block_with(<<"uuid_break">>)),
    ok = chappe_esl:close(Conn),
    ok = chappe_esl_fake_server:stop(Fake).

%% Arguments FreeSWITCH splits on spaces are quoted and escaped; playback and
%% stop_record_session take the path as is.
%% req: ESL-37
args_with_spaces(_Config) ->
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{}, Owner),
    {ok, _} = chappe_esl_call:record(Call, "/r/my msg.wav", #{max_secs => 5}),
    expect_app(<<"record">>, <<"'/r/my msg.wav' 5">>),
    {ok, _} = chappe_esl_call:record(Call, "/r/it's\\x.wav", #{}),
    expect_app(<<"record">>, <<"/r/it\\'s\\\\x.wav">>),
    {ok, _} = chappe_esl_call:play_and_get_digits(Call, #{
        file => "/s/enter pin.wav", regexp => <<"\\d+">>
    }),
    expect_app(
        <<"play_and_get_digits">>,
        <<"1 1 1 5000 # '/s/enter pin.wav' silence_stream://250 chappe_digits ",
            "\\\\d+ 5000">>
    ),
    {ok, _} = chappe_esl_call:playback(Call, "/s/hello world.wav"),
    expect_app(<<"playback">>, <<"/s/hello world.wav">>),
    ok = chappe_esl_call:record_session(Call, "/r/whole call.wav"),
    expect_app(<<"record_session">>, <<"'/r/whole call.wav'">>),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{
        metadata => <<"{\"a\": 1}">>
    }),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 start ws://x mono 16000 audio_fork ",
            "'{\"a\": 1}'">>,
        block_with(<<"uuid_audio_fork">>)
    ),
    flush_blocks(),
    exit(Owner, kill),
    _ = block_with(<<"uuid_audio_fork fake-uuid-1 stop">>),
    ?assertEqual(
        <<"api uuid_record fake-uuid-1 stop '/r/whole call.wav'">>,
        block_with(<<"uuid_record">>)
    ).

%% exec/5 from the controlling process of an inbound connection: messages
%% that are not its completion stay in the mailbox, in order.
%% req: ESL-35
raw_exec_interleaved(_Config) ->
    Apps = #{<<"playback">> => #{delay => 100}, <<"park">> => silent},
    {ok, Fake, Port} = chappe_esl_fake_server:start(#{
        channel => <<"in-1">>, apps => Apps
    }),
    {ok, Conn} = chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port}),
    Stray = chappe_esl_fake_server:plain_event(<<"CHANNEL_EXECUTE_COMPLETE">>, [
        {<<"Application-UUID">>, <<"other">>}
    ]),
    ok = chappe_esl_fake_server:inject(Fake, Stray),
    {ok, Ev} = chappe_esl_call:exec(Conn, <<"in-1">>, "playback", "b.wav", #{}),
    ?assertEqual(<<"b.wav">>, hdr(<<"Application-Data">>, Ev)),
    receive
        {chappe_esl_event, Conn, E1} ->
            ?assertEqual(<<"other">>, hdr(<<"Application-UUID">>, E1))
    after 1000 ->
        ct:fail(stray_lost)
    end,
    receive
        {chappe_esl_event, Conn, E2} ->
            ?assertEqual(<<"CHANNEL_EXECUTE">>, chappe_esl_event:name(E2))
    after 1000 ->
        ct:fail(execute_event_lost)
    end,
    ?assertEqual(
        {error, timeout},
        chappe_esl_call:exec(Conn, <<"in-1">>, "park", "", #{timeout => 100})
    ),
    ?assertMatch(
        {ok, <<_:36/binary>>},
        chappe_esl_call:exec(Conn, <<"in-1">>, "park", "", #{wait => false})
    ),
    ok = chappe_esl:close(Conn),
    ok = chappe_esl_fake_server:stop(Fake).

%% An argument with a line break travels as a text/plain body.
%% req: ESL-36
raw_exec_long_arg(_Config) ->
    {ok, Fake, Port} = chappe_esl_fake_server:start(#{channel => <<"in-1">>}),
    {ok, Conn} = chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port}),
    Arg = <<"line one\nline two">>,
    {ok, Ev} = chappe_esl_call:exec(Conn, <<"in-1">>, "speak", Arg, #{}),
    ?assertEqual(<<"speak">>, hdr(<<"Application">>, Ev)),
    Block = block_with(<<"execute-app-name: speak">>),
    ?assert(contains(Block, <<"Content-Type: text/plain">>)),
    ?assert(contains(Block, <<"\n\nline one\nline two">>)),
    ?assertNot(contains(Block, <<"execute-app-arg">>)),
    ok = chappe_esl:close(Conn),
    ok = chappe_esl_fake_server:stop(Fake).

%% Over an inbound connection the call filters on the channel uuid and
%% subscribes to every event.
%% req: ESL-34
inbound_call(_Config) ->
    {ok, Fake, Port} = chappe_esl_fake_server:start(#{channel => <<"in-1">>}),
    {ok, Conn} = chappe_esl:connect(#{host => {127, 0, 0, 1}, port => Port}),
    ?assertEqual(
        {error, {missing_option, uuid}}, chappe_esl_call:start(Conn, #{})
    ),
    {ok, Call} = chappe_esl_call:start(Conn, #{uuid => <<"in-1">>}),
    _ = block_with(<<"filter Unique-ID in-1">>),
    _ = block_with(<<"event plain ALL">>),
    ?assertEqual(ok, chappe_esl_call:answer(Call)),
    ?assert(contains(block_with(<<"answer">>), <<"sendmsg in-1">>)),
    ?assertEqual({ok, <<"+OK">>}, chappe_esl_call:api(Call, "status")),
    ok = chappe_esl_call:stop(Call),
    ok = chappe_esl_fake_server:stop(Fake).

%% req: ESL-37
play_and_get_digits(_Config) ->
    Vars = [{<<"variable_chappe_digits">>, <<"1234">>}],
    {Call, _Fake} = outbound(#{
        apps => #{<<"play_and_get_digits">> => #{vars => Vars}}
    }),
    ?assertEqual(
        {ok, <<"1234">>},
        chappe_esl_call:play_and_get_digits(Call, #{
            file => <<"prompt.wav">>, max => 4, tries => 3
        })
    ),
    Block = block_with(<<"play_and_get_digits">>),
    ?assert(
        contains(
            Block,
            <<"execute-app-arg: 1 4 3 5000 # prompt.wav silence_stream://250 ",
                "chappe_digits [0-9*#]+ 5000">>
        )
    ),
    %% nothing entered: no variable on the completion
    {Call2, _} = outbound(#{}),
    ?assertEqual(
        {ok, <<>>},
        chappe_esl_call:play_and_get_digits(Call2, #{file => <<"p.wav">>})
    ).

%% result => full also reads the terminator and the refused entry.
%% req: ESL-37
play_and_get_digits_full(_Config) ->
    Vars = [
        {<<"variable_pin">>, <<"42">>},
        {<<"variable_read_terminator_used">>, <<"#">>},
        {<<"variable_pin_invalid">>, <<"9">>}
    ],
    {Call, _Fake} = outbound(#{
        apps => #{<<"play_and_get_digits">> => #{vars => Vars}}
    }),
    ?assertEqual(
        {ok, #{digits => <<"42">>, terminator => <<"#">>, invalid => <<"9">>}},
        chappe_esl_call:play_and_get_digits(Call, #{
            file => <<"p.wav">>, var => <<"pin">>, result => full
        })
    ),
    {Call2, _} = outbound(#{}),
    ?assertEqual(
        {ok, #{digits => <<>>, terminator => <<>>, invalid => <<>>}},
        chappe_esl_call:play_and_get_digits(Call2, #{
            file => <<"p.wav">>, result => full
        })
    ).

%% Named forks: the bug name goes after the rate (before the metadata) and
%% after each verb; pause, resume and send_text reach the forks the
%% selection names, in each module's grammar; a stopped fork is no longer
%% tracked; the owner's death stops each fork still running by its name.
%% req: ESL-37 ESL-39
fork_commands(_Config) ->
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{}, Owner),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://a", #{
        bugname => <<"left">>, mix => stereo, rate => 8000
    }),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 start ws://a stereo 8000 left">>,
        block_with(<<"uuid_audio_fork">>)
    ),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://b", #{
        bugname => <<"right">>, metadata => <<"{\"a\": 1}">>
    }),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 start ws://b mono 16000 right ",
            "'{\"a\": 1}'">>,
        block_with(<<"uuid_audio_fork">>)
    ),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://c", #{
        module => audio_stream
    }),
    _ = block_with(<<"uuid_audio_stream">>),
    ok = chappe_esl_call:audio_fork_pause(Call, #{bugname => <<"left">>}),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 pause left">>,
        block_with(<<"pause">>)
    ),
    ok = chappe_esl_call:audio_fork_resume(Call, #{module => audio_stream}),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 resume">>,
        block_with(<<"resume">>)
    ),
    ok = chappe_esl_call:audio_fork_send_text(Call, "hi there", #{}),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 send_text left 'hi there'">>,
        block_with(<<"send_text">>)
    ),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 send_text right 'hi there'">>,
        block_with(<<"send_text">>)
    ),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 send_text 'hi there'">>,
        block_with(<<"send_text">>)
    ),
    ok = chappe_esl_call:audio_fork_stop(Call, #{bugname => <<"right">>}),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 stop right">>,
        block_with(<<"stop">>)
    ),
    ?assertEqual(
        {error, not_forking},
        chappe_esl_call:audio_fork_pause(Call, #{bugname => <<"right">>})
    ),
    [
        ?assertEqual(Err, chappe_esl_call:audio_fork_start(Call, "ws://d", O))
     || {Err, O} <- [
            {{error, {bad_option, bugname}}, #{
                module => audio_stream, bugname => <<"x">>
            }},
            {{error, {bad_option, bugname}}, #{bugname => <<"a b">>}},
            {{error, {bad_option, bugname}}, #{bugname => <<"a'b">>}}
        ]
    ],
    ?assertEqual(
        {error, {bad_option, text}},
        chappe_esl_call:audio_fork_send_text(Call, <<"a\nb">>, #{})
    ),
    ?assertEqual(
        {error, {bad_option, select}},
        chappe_esl_call:audio_fork_pause(Call, all)
    ),
    exit(Owner, kill),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 stop left">>,
        block_with(<<"stop">>)
    ),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 stop">>,
        block_with(<<"stop">>)
    ),
    ?assertMatch(<<"api uuid_kill fake-uuid-1", _/binary>>, block_with(<<"uuid_kill">>)).

%% multiset picks a delimiter no value contains; getvar and dump read the
%% channel over api; mute and unmute use uuid_audio. Bad input is refused
%% before anything is sent.
%% req: ESL-37
variables_and_audio(_Config) ->
    Dump = <<"{\"Unique-ID\": \"fake-uuid-1\", \"variable_a\": \"1\", ",
        "\"variable_b\": \"x|y\"}">>,
    {Call, _Fake} = outbound(#{
        api => #{
            <<"uuid_getvar fake-uuid-1 a">> => <<"1">>,
            <<"uuid_getvar fake-uuid-1 nope">> => <<"_undef_">>,
            <<"uuid_dump fake-uuid-1 json">> => Dump
        }
    }),
    ok = chappe_esl_call:multiset(Call, #{<<"a">> => <<"1">>, "b" => "x y"}),
    expect_app(<<"multiset">>, <<"^^|a=1|b=x y">>),
    ok = chappe_esl_call:multiset(Call, #{<<"b">> => <<"x|y">>}),
    expect_app(<<"multiset">>, <<"^^~b=x|y">>),
    ok = chappe_esl_call:multiset(Call, #{}),
    [
        ?assertEqual(
            {error, {bad_option, vars}}, chappe_esl_call:multiset(Call, V)
        )
     || V <- [
            #{<<"a=b">> => <<"1">>},
            #{<<"a b">> => <<"1">>},
            #{<<"a">> => <<"1\n2">>},
            #{<<"a">> => <<"|~^;#!">>},
            nope
        ]
    ],
    ?assertEqual({ok, <<"1">>}, chappe_esl_call:getvar(Call, <<"a">>)),
    ?assertEqual({ok, undefined}, chappe_esl_call:getvar(Call, "nope")),
    ?assertEqual(
        {error, {bad_option, var}}, chappe_esl_call:getvar(Call, <<"a b">>)
    ),
    ?assertEqual(
        {ok, #{<<"a">> => <<"1">>, <<"b">> => <<"x|y">>}},
        chappe_esl_call:dump(Call)
    ),
    ok = chappe_esl_call:mute(Call, read),
    ?assertEqual(
        <<"api uuid_audio fake-uuid-1 start read mute 1">>,
        block_with(<<"uuid_audio">>)
    ),
    ok = chappe_esl_call:unmute(Call, write),
    ?assertEqual(
        <<"api uuid_audio fake-uuid-1 start write mute 0">>,
        block_with(<<"uuid_audio">>)
    ),
    ?assertEqual(
        {error, {bad_option, direction}}, chappe_esl_call:mute(Call, both)
    ).

%% subscribe/2 adds events with CUSTOM and its subclasses last, and
%% refuses words that would break the command.
%% req: ESL-34
subscribe_events(_Config) ->
    {Call, _Fake} = outbound(#{}),
    ok = chappe_esl_call:subscribe(Call, [
        {custom, <<"a::b">>}, 'PLAYBACK_START', <<"DETECTED_TONE">>
    ]),
    ?assertEqual(
        <<"event plain PLAYBACK_START DETECTED_TONE CUSTOM a::b">>,
        block_with(<<"event plain">>)
    ),
    ok = chappe_esl_call:subscribe(Call, []),
    [
        ?assertEqual(
            {error, {bad_option, events}}, chappe_esl_call:subscribe(Call, E)
        )
     || E <- [[<<"A B">>], [{custom, <<"x\ny">>}], [<<"CUSTOM">>], [<<>>], [1]]
    ].

%% offset seeks with File@@Samples; limit_secs sets playback_timeout_sec
%% around the playback and clears it after; bad values are refused before
%% anything is sent.
%% req: ESL-37
playback_options(_Config) ->
    {Call, _Fake} = outbound(#{}),
    {ok, _} = chappe_esl_call:playback(Call, "a.wav", #{offset => 8000}),
    expect_app(<<"playback">>, <<"a.wav@@8000">>),
    {ok, _} = chappe_esl_call:playback(Call, "b.wav", #{limit_secs => 3}),
    expect_app(
        <<"multiset">>,
        <<"playback_timeout_sec=3 playback_timeout_as_success=true">>
    ),
    expect_app(<<"playback">>, <<"b.wav">>),
    expect_app(<<"unset">>, <<"playback_timeout_sec">>),
    [
        ?assertEqual(
            {error, {bad_option, K}}, chappe_esl_call:playback(Call, "c", O)
        )
     || {K, O} <- [
            {offset, #{offset => -1}},
            {offset, #{offset => <<"1">>}},
            {limit_secs, #{limit_secs => 1}},
            {limit_secs, #{limit_secs => 2.5}}
        ]
    ].

%% req: ESL-38
dtmf_and_hangup(_Config) ->
    {Call, Fake} = outbound(#{apps => #{<<"park">> => silent}}),
    ok = chappe_esl_fake_server:dtmf(Fake, <<"5">>),
    ?assertEqual({dtmf, <<"5">>}, owner_msg(Call)),
    Self = self(),
    spawn(fun() -> Self ! {park, chappe_esl_call:exec(Call, "park", "")} end),
    _ = block_with(<<"execute-app-name: park">>),
    ?assertMatch({event, _}, owner_msg(Call)),
    ok = chappe_esl_fake_server:hangup(Fake, <<"NORMAL_CLEARING">>),
    ?assertEqual({hangup, <<"NORMAL_CLEARING">>}, owner_msg(Call)),
    {event, Ev} = owner_msg(Call),
    ?assertEqual(<<"CHANNEL_HANGUP_COMPLETE">>, chappe_esl_event:name(Ev)),
    receive
        {park, Result} -> ?assertEqual({error, hangup}, Result)
    after 5000 ->
        ct:fail(park_not_released)
    end,
    ?assertEqual({error, hangup}, chappe_esl_call:answer(Call)),
    ?assertEqual(ok, chappe_esl_call:hangup(Call)).

%% Each helper sends the application and argument FreeSWITCH expects.
%% req: ESL-37
helpers(_Config) ->
    {Call, _Fake} = outbound(#{}),
    ok = chappe_esl_call:set(Call, "a", "1"),
    expect_app(<<"set">>, <<"a=1">>),
    ok = chappe_esl_call:export(Call, "b", "2"),
    expect_app(<<"export">>, <<"b=2">>),
    ok = chappe_esl_call:send_dtmf(Call, "12#"),
    expect_app(<<"send_dtmf">>, <<"12#">>),
    {ok, _} = chappe_esl_call:record(Call, "/tmp/r.wav", #{max_secs => 5}),
    expect_app(<<"record">>, <<"/tmp/r.wav 5">>),
    ok = chappe_esl_call:record_session(Call, "/tmp/s.wav"),
    expect_app(<<"record_session">>, <<"/tmp/s.wav">>),
    ok = chappe_esl_call:record_session_stop(Call, "/tmp/s.wav"),
    expect_app(<<"stop_record_session">>, <<"/tmp/s.wav">>),
    {ok, AppUuid} = chappe_esl_call:conference(Call, "room1", #{
        flags => [mute, moderator]
    }),
    expect_app(<<"conference">>, <<"room1@default+flags{mute|moderator}">>),
    {complete, <<"conference">>, Ev} = owner_msg_skip_events(Call),
    ?assertEqual(AppUuid, hdr(<<"Application-UUID">>, Ev)),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x/y", #{
        mix => stereo, rate => 8000, metadata => <<"{}">>
    }),
    ?assertMatch(
        <<"api uuid_audio_fork fake-uuid-1 start ws://x/y stereo 8000 audio_fork {}">>,
        block_with(<<"uuid_audio_fork">>)
    ),
    ok = chappe_esl_call:audio_fork_stop(Call),
    ?assertMatch(
        <<"api uuid_audio_fork fake-uuid-1 stop">>,
        block_with(<<"uuid_audio_fork">>)
    ),
    ok = chappe_esl_call:hangup(Call, "USER_BUSY"),
    expect_app(<<"hangup">>, <<"USER_BUSY">>).

%% module => audio_stream speaks mod_audio_stream: 8000 and 16000 as 8k and
%% 16k, metadata right after the rate, and its own stop. module =>
%% audio_fork is the default grammar; another module is refused.
%% req: ESL-37
audio_stream_commands(_Config) ->
    {Call, _Fake} = outbound(#{}),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x/y", #{
        module => audio_stream, mix => stereo, rate => 8000, metadata => <<"{}">>
    }),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 start ws://x/y stereo 8k {}">>,
        block_with(<<"uuid_audio_stream">>)
    ),
    ok = chappe_esl_call:audio_fork_stop(Call),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 stop">>,
        block_with(<<"uuid_audio_stream">>)
    ),
    ok = chappe_esl_call:audio_fork_start(Call, "wss://a", #{
        module => audio_stream, metadata => <<"{\"a\": 1}">>
    }),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 start wss://a mono 16k ",
            "'{\"a\": 1}'">>,
        block_with(<<"uuid_audio_stream">>)
    ),
    ok = chappe_esl_call:audio_fork_start(Call, "wss://b", #{
        module => audio_stream, rate => 24000
    }),
    ?assertEqual(
        <<"api uuid_audio_stream fake-uuid-1 start wss://b mono 24000">>,
        block_with(<<"uuid_audio_stream">>)
    ),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://c", #{
        module => audio_fork
    }),
    ?assertEqual(
        <<"api uuid_audio_fork fake-uuid-1 start ws://c mono 16000">>,
        block_with(<<"uuid_audio_fork">>)
    ),
    ?assertEqual(
        {error, {bad_option, module}},
        chappe_esl_call:audio_fork_start(Call, "ws://d", #{module => fork})
    ).

%% The owner dies: the fork and the session recording stop, then the
%% channel is killed, and the call process and connection end.
%% req: ESL-39
owner_death_cleanup(_Config) ->
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{}, Owner),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{}),
    ok = chappe_esl_call:record_session(Call, "/tmp/s1.wav"),
    ok = chappe_esl_call:record_session(Call, "/tmp/s2.wav"),
    flush_blocks(),
    Mon = monitor(process, Call),
    exit(Owner, kill),
    ?assertEqual(
        [
            <<"api uuid_audio_fork fake-uuid-1 stop">>,
            <<"api uuid_record fake-uuid-1 stop /tmp/s1.wav">>,
            <<"api uuid_record fake-uuid-1 stop /tmp/s2.wav">>,
            <<"api uuid_kill fake-uuid-1">>
        ],
        [next_block() || _ <- lists:seq(1, 4)]
    ),
    receive
        {'DOWN', Mon, process, Call, normal} -> ok
    after 5000 ->
        ct:fail(call_not_stopped)
    end.

%% A mod_audio_stream fork is stopped with its own command before the kill.
%% req: ESL-39
owner_death_audio_stream(_Config) ->
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{}, Owner),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{
        module => audio_stream
    }),
    flush_blocks(),
    exit(Owner, kill),
    ?assertEqual(
        [
            <<"api uuid_audio_stream fake-uuid-1 stop">>,
            <<"api uuid_kill fake-uuid-1">>
        ],
        [next_block() || _ <- lists:seq(1, 2)]
    ).

%% After the hangup there is nothing left to kill.
%% req: ESL-39
owner_death_after_hangup(_Config) ->
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, Fake} = outbound(#{}, Owner),
    ok = chappe_esl_fake_server:hangup(Fake, <<"NORMAL_CLEARING">>),
    %% the call has seen the hangup once a later request is refused
    ok = wait(fun() -> chappe_esl_call:answer(Call) =:= {error, hangup} end),
    flush_blocks(),
    Mon = monitor(process, Call),
    exit(Owner, kill),
    receive
        {'DOWN', Mon, process, Call, normal} -> ok
    after 5000 ->
        ct:fail(call_not_stopped)
    end,
    receive
        {fake_server, _, Block} -> ct:fail({unexpected, Block})
    after 200 ->
        ok
    end.

%% req: ESL-38
connection_closed(_Config) ->
    {Call, Fake} = outbound(#{apps => #{<<"park">> => silent}}),
    Self = self(),
    spawn(fun() -> Self ! {park, chappe_esl_call:exec(Call, "park", "")} end),
    _ = block_with(<<"execute-app-name: park">>),
    ok = chappe_esl_fake_server:drop(Fake),
    ?assertEqual(closed, owner_msg_skip_events(Call)),
    receive
        {park, Result} -> ?assertEqual({error, closed}, Result)
    after 5000 ->
        ct:fail(park_not_released)
    end,
    ?assertEqual({error, closed}, chappe_esl_call:answer(Call)).

%% stop/1 releases the channel: no cleanup commands.
stop_leaves_channel(_Config) ->
    {Call, _Fake} = outbound(#{}),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{}),
    flush_blocks(),
    ok = chappe_esl_call:stop(Call),
    ?assertNot(is_process_alive(Call)),
    receive
        {fake_server, _, Block} -> ct:fail({unexpected, Block})
    after 200 ->
        ok
    end.

%% While an api reply is withheld the call process still handles events:
%% this is about the process, the fake sends events a real node would hold
%% back during a synchronous api.
%% req: ESL-38
api_held_hangup(_Config) ->
    {Call, Fake} = outbound(#{api => #{<<"slow">> => {hold, <<"+OK late">>}}}),
    held_api(Call, <<"slow">>),
    ok = chappe_esl_fake_server:hangup(Fake, <<"NORMAL_CLEARING">>),
    ?assertEqual({hangup, <<"NORMAL_CLEARING">>}, owner_msg_soon(Call)),
    responsive(Call),
    ok = chappe_esl_fake_server:release_api(Fake),
    ?assertEqual({ok, <<"+OK late">>}, api_result()).

%% req: ESL-38
api_held_dtmf(_Config) ->
    {Call, Fake} = outbound(#{api => #{<<"slow">> => {hold, <<"+OK">>}}}),
    held_api(Call, <<"slow">>),
    ok = chappe_esl_fake_server:dtmf(Fake, <<"7">>),
    ?assertEqual({dtmf, <<"7">>}, owner_msg_soon(Call)).

%% The exec timer fires, and its uuid_break, queued behind the withheld
%% reply, does not stop the process either.
%% req: ESL-35
api_held_exec_timeout(_Config) ->
    {Call, _Fake} = outbound(#{
        apps => #{<<"park">> => silent},
        api => #{<<"slow">> => {hold, <<"+OK">>}}
    }),
    Self = self(),
    spawn(fun() ->
        Self ! {park, chappe_esl_call:exec(Call, "park", "", #{timeout => 300})}
    end),
    _ = block_with(<<"execute-app-name: park">>),
    held_api(Call, <<"slow">>),
    receive
        {park, Result} -> ?assertEqual({error, timeout}, Result)
    after 2000 ->
        ct:fail(exec_timeout_not_handled)
    end,
    ?assertEqual(
        <<"api uuid_break fake-uuid-1">>, block_with(<<"uuid_break">>)
    ),
    responsive(Call).

%% An exec sent behind the withheld reply waits for its own sendmsg reply
%% outside the process, and still times out.
%% req: ESL-35
api_held_exec_sent(_Config) ->
    {Call, Fake} = outbound(#{api => #{<<"slow">> => {hold, <<"+OK">>}}}),
    held_api(Call, <<"slow">>),
    Self = self(),
    spawn(fun() ->
        Self !
            {answer,
                chappe_esl_call:exec(Call, "answer", "", #{timeout => 300})}
    end),
    _ = block_with(<<"execute-app-name: answer">>),
    responsive(Call),
    receive
        {answer, Result} -> ?assertEqual({error, timeout}, Result)
    after 2000 ->
        ct:fail(exec_timeout_not_handled)
    end,
    ok = chappe_esl_fake_server:release_api(Fake),
    ?assertEqual({ok, <<"+OK">>}, api_result()),
    no_completion(Call, 200).

%% A slow api holds two sendmsg past their 10 s reply limit. They are still
%% queued and will run, so each exec's own timeout rules: the one without a
%% timeout keeps waiting and gets its completion, the one that timed out is
%% broken when it starts and its completion is dropped.
%% req: ESL-35
api_held_past_send_limit(_Config) ->
    {Call, Fake} = outbound(#{api => #{<<"slow">> => {hold, <<"+OK">>}}}),
    held_api(Call, <<"slow">>),
    Self = self(),
    spawn(fun() ->
        Opts = #{timeout => infinity},
        Self ! {long, chappe_esl_call:exec(Call, "playback", "a.wav", Opts)}
    end),
    _ = block_with(<<"execute-app-name: playback">>),
    spawn(fun() ->
        Opts = #{timeout => 11000},
        Self ! {timed, chappe_esl_call:exec(Call, "record", "b.wav", Opts)}
    end),
    _ = block_with(<<"execute-app-name: record">>),
    receive
        {long, Early} -> ct:fail({failed_at_send_limit, Early})
    after 10500 ->
        ok
    end,
    responsive(Call),
    receive
        {timed, Timed} -> ?assertEqual({error, timeout}, Timed)
    after 2000 ->
        ct:fail(exec_timeout_not_handled)
    end,
    ok = chappe_esl_fake_server:release_api(Fake),
    ?assertEqual(
        <<"api uuid_break fake-uuid-1">>, block_with(<<"uuid_break">>)
    ),
    receive
        {long, {ok, Ev}} ->
            ?assertEqual(<<"playback">>, hdr(<<"Application">>, Ev))
    after 2000 ->
        ct:fail(no_completion_for_long_exec)
    end,
    no_completion(Call, 300).

%% The owner dies with a fork start unanswered: the fork is stopped, the
%% channel killed, the waiting caller released, and the process is gone
%% within the cleanup bound of each command (2 s).
%% req: ESL-39
api_held_owner_death(_Config) ->
    Start = <<"uuid_audio_fork fake-uuid-1 start ws://x mono 16000">>,
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{api => #{Start => {hold, <<"+OK">>}}}, Owner),
    Self = self(),
    spawn(fun() ->
        Self ! {api, chappe_esl_call:audio_fork_start(Call, "ws://x", #{})}
    end),
    _ = block_with(<<"api ", Start/binary>>),
    Mon = monitor(process, Call),
    T0 = erlang:monotonic_time(millisecond),
    exit(Owner, kill),
    ?assertEqual(
        [
            <<"api uuid_audio_fork fake-uuid-1 stop">>,
            <<"api uuid_kill fake-uuid-1">>
        ],
        [next_block() || _ <- lists:seq(1, 2)]
    ),
    receive
        {'DOWN', Mon, process, Call, normal} -> ok
    after 6000 ->
        ct:fail(call_not_stopped)
    end,
    ?assert(erlang:monotonic_time(millisecond) - T0 < 5000),
    ?assertEqual({error, closed}, api_result()).

%% The owner dies during a withheld fork stop: its stop went out once, and
%% the kill follows.
%% req: ESL-39
api_held_fork_stop_owner_death(_Config) ->
    Stop = <<"uuid_audio_fork fake-uuid-1 stop">>,
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{api => #{Stop => {hold, <<"+OK">>}}}, Owner),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{}),
    flush_blocks(),
    Self = self(),
    spawn(fun() -> Self ! {api, chappe_esl_call:audio_fork_stop(Call)} end),
    ?assertEqual(<<"api ", Stop/binary>>, next_block()),
    exit(Owner, kill),
    ?assertEqual(<<"api uuid_kill fake-uuid-1">>, next_block()),
    ?assertEqual({error, closed}, api_result()).

%% Requests behind the withheld reply stay unanswered until it comes, and
%% each caller gets its own reply.
%% req: ESL-37
api_held_replies_in_order(_Config) ->
    {Call, Fake} = outbound(#{
        api => #{
            <<"first">> => {hold, <<"+OK first">>},
            <<"second">> => <<"+OK second">>
        }
    }),
    Self = self(),
    Run = fun(Tag, Fun) -> spawn(fun() -> Self ! {Tag, Fun()} end) end,
    Run(first, fun() -> chappe_esl_call:api(Call, <<"first">>) end),
    _ = block_with(<<"api first">>),
    Run(second, fun() -> chappe_esl_call:api(Call, <<"second">>) end),
    _ = block_with(<<"api second">>),
    Run(nowait, fun() ->
        chappe_esl_call:exec(Call, "set", "a=1", #{wait => false})
    end),
    _ = block_with(<<"execute-app-name: set">>),
    responsive(Call),
    receive
        {Tag, Early} when Tag =:= first; Tag =:= second; Tag =:= nowait ->
            ct:fail({answered_early, Tag, Early})
    after 200 ->
        ok
    end,
    ok = chappe_esl_fake_server:release_api(Fake),
    receive
        {first, First} -> ?assertEqual({ok, <<"+OK first">>}, First)
    after 2000 ->
        ct:fail(no_first_reply)
    end,
    receive
        {second, Second} -> ?assertEqual({ok, <<"+OK second">>}, Second)
    after 2000 ->
        ct:fail(no_second_reply)
    end,
    receive
        {nowait, Nowait} -> ?assertMatch({ok, <<_:36/binary>>}, Nowait)
    after 2000 ->
        ct:fail(no_nowait_reply)
    end.

%% req: ESL-38
api_held_connection_closed(_Config) ->
    {Call, Fake} = outbound(#{api => #{<<"slow">> => {hold, <<"+OK">>}}}),
    held_api(Call, <<"slow">>),
    ok = chappe_esl_fake_server:drop(Fake),
    ?assertEqual(closed, owner_msg_soon(Call)),
    ?assertEqual({error, closed}, api_result()).

%% A helper that dies abnormally answers its caller {error, closed}, and
%% the call goes on.
api_helper_killed(_Config) ->
    {Call, _Fake} = outbound(#{api => #{<<"slow">> => {hold, <<"+OK">>}}}),
    held_api(Call, <<"slow">>),
    {monitors, Mons} = process_info(Call, monitors),
    [Helper] = [
        P
     || {process, P} <- Mons,
        P =/= self(),
        process_info(P, initial_call) =:= {initial_call, {erlang, apply, 2}}
    ],
    exit(Helper, kill),
    ?assertEqual({error, closed}, api_result()),
    responsive(Call).

%% A helper exits with its result: that is no crash, nothing gets logged. A
%% crash at the end shows the capture works.
api_helper_quiet(_Config) ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{
        level => warning, config => self()
    }),
    try
        {Call, _Fake} = outbound(#{api => #{<<"bad">> => <<"-ERR bad">>}}),
        ?assertEqual({ok, <<"+OK">>}, chappe_esl_call:api(Call, "status")),
        ?assertMatch({error, _}, chappe_esl_call:api(Call, "bad")),
        ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{}),
        ok = chappe_esl_call:audio_fork_stop(Call),
        ok = chappe_esl_call:answer(Call),
        receive
            {logged, Logged} -> ct:fail({logged, Logged})
        after 300 ->
            ok
        end,
        spawn(fun() -> error(control_crash) end),
        receive
            {logged, _} -> ok
        after 2000 ->
            ct:fail(capture_sees_nothing)
        end
    after
        ok = logger:remove_handler(?MODULE)
    end.

log(#{msg := Msg}, #{config := Pid}) ->
    Pid ! {logged, Msg},
    ok.

%% A fork that failed to start is not stopped at the owner's death.
%% req: ESL-39
fork_start_failed(_Config) ->
    Start = <<"uuid_audio_fork fake-uuid-1 start ws://x mono 16000">>,
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{api => #{Start => <<"-ERR no">>}}, Owner),
    ?assertMatch(
        {error, _}, chappe_esl_call:audio_fork_start(Call, "ws://x", #{})
    ),
    flush_blocks(),
    exit(Owner, kill),
    ?assertEqual(<<"api uuid_kill fake-uuid-1">>, next_block()).

%% A second start refused while the first fork runs does not forget it.
%% req: ESL-39
fork_start_failed_while_running(_Config) ->
    Second = <<"uuid_audio_fork fake-uuid-1 start ws://y mono 16000">>,
    Owner = spawn(fun() -> receive after infinity -> ok end end),
    {Call, _Fake} = outbound(#{api => #{Second => <<"-ERR busy">>}}, Owner),
    ok = chappe_esl_call:audio_fork_start(Call, "ws://x", #{}),
    ?assertMatch(
        {error, _}, chappe_esl_call:audio_fork_start(Call, "ws://y", #{})
    ),
    flush_blocks(),
    exit(Owner, kill),
    ?assertEqual(<<"api uuid_audio_fork fake-uuid-1 stop">>, next_block()),
    ?assertEqual(<<"api uuid_kill fake-uuid-1">>, next_block()).

%% The channel hung up with the socket lingering: the owner hears linger,
%% the final events still follow, then disconnect, and closed only when the
%% socket goes.
%% req: ESL-38
call_linger_then_disconnect(_Config) ->
    {Call, Fake} = outbound(#{}),
    Mon = monitor(process, Call),
    ok = chappe_esl_fake_server:hangup(Fake, <<"NORMAL_CLEARING">>),
    ?assertEqual({hangup, <<"NORMAL_CLEARING">>}, owner_msg_soon(Call)),
    ok = chappe_esl_fake_server:inject(Fake, notice(<<"linger">>)),
    ?assertEqual(linger, owner_msg_soon(Call)),
    ok = chappe_esl_fake_server:inject(
        Fake, chappe_esl_fake_server:plain_event(<<"CUSTOM">>, [])
    ),
    {event, Ev} = owner_msg(Call),
    ?assertEqual(<<"CUSTOM">>, chappe_esl_event:name(Ev)),
    ok = chappe_esl_fake_server:inject(Fake, notice(<<"disconnect">>)),
    ?assertEqual(disconnect, owner_msg(Call)),
    responsive(Call),
    ok = chappe_esl_fake_server:drop(Fake),
    ?assertEqual(closed, owner_msg(Call)),
    receive
        {'DOWN', Mon, process, Call, normal} -> ok
    after 2000 ->
        ct:fail(call_not_stopped)
    end.

%% Without a lingering socket the notice comes alone, and does not fail the
%% requests in flight: closed does.
%% req: ESL-38
call_disconnect_only(_Config) ->
    {Call, Fake} = outbound(#{apps => #{<<"park">> => silent}}),
    Self = self(),
    spawn(fun() -> Self ! {park, chappe_esl_call:exec(Call, "park", "")} end),
    _ = block_with(<<"execute-app-name: park">>),
    ok = chappe_esl_fake_server:inject(Fake, notice(<<"disconnect">>)),
    ?assertEqual(disconnect, owner_msg_soon(Call)),
    receive
        {park, Early} -> ct:fail({released_early, Early})
    after 100 ->
        ok
    end,
    ok = chappe_esl_fake_server:drop(Fake),
    ?assertEqual(closed, owner_msg_soon(Call)),
    receive
        {park, Result} -> ?assertEqual({error, closed}, Result)
    after 2000 ->
        ct:fail(park_not_released)
    end.

%% helpers

%% A text/disconnect-notice as FreeSWITCH sends it, with its
%% Content-Disposition.
notice(Disposition) ->
    Body = <<"Disconnected, goodbye.\n">>,
    [
        <<"Content-Type: text/disconnect-notice\nContent-Disposition: ">>,
        Disposition,
        <<"\nContent-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\n\n">>,
        Body
    ].

%% Send Cmd from another process, and return once the fake got it. The
%% result comes back through api_result/0.
held_api(Call, Cmd) ->
    Self = self(),
    spawn(fun() -> Self ! {api, chappe_esl_call:api(Call, Cmd)} end),
    _ = block_with(<<"api ", Cmd/binary>>),
    ok.

api_result() ->
    receive
        {api, Result} -> Result
    after 5000 ->
        ct:fail(no_api_result)
    end.

%% The call process answers now, whatever the connection is waiting for.
responsive(Call) ->
    ?assertEqual(?UUID, gen_server:call(Call, uuid, 500)).

owner_msg_soon(Call) ->
    receive
        {chappe_esl_call, Call, {event, _}} -> owner_msg_soon(Call);
        {chappe_esl_call, Call, Msg} -> Msg
    after 2000 ->
        ct:fail(no_owner_msg)
    end.

outbound(FakeOpts) ->
    outbound(FakeOpts, self()).

outbound(FakeOpts, Owner) ->
    Port = pick_port(),
    {ok, _} = chappe_esl:start_listener(Port, ?MODULE, {self(), Owner}),
    {ok, Fake} = chappe_esl_fake_server:start_outbound(Port, FakeOpts),
    receive
        {call, {ok, Call}} ->
            ok = chappe_esl:stop_listener(Port),
            {Call, Fake};
        {call, Error} ->
            ct:fail({call_start, Error})
    after 5000 ->
        ct:fail(no_call)
    end.

pick_port() ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(L),
    gen_tcp:close(L),
    P.

next_block() ->
    receive
        {fake_server, _, Block} -> Block
    after 5000 ->
        ct:fail(no_block)
    end.

%% The next block containing Needle, skipping the others.
block_with(Needle) ->
    Block = next_block(),
    case contains(Block, Needle) of
        true -> Block;
        false -> block_with(Needle)
    end.

flush_blocks() ->
    receive
        {fake_server, _, _} -> flush_blocks()
    after 100 ->
        ok
    end.

expect_app(App, Arg) ->
    Block = block_with(<<"execute-app-name: ", App/binary, "\n">>),
    ?assert(contains(Block, <<"execute-app-arg: ", Arg/binary>>)),
    ?assert(contains(Block, <<"Event-UUID: ">>)),
    ?assert(contains(Block, <<"event-lock: true">>)).

%% No completion reaches the owner within Ms.
no_completion(Call, Ms) ->
    receive
        {chappe_esl_call, Call, {complete, _, _} = Msg} ->
            ct:fail({leaked, Msg})
    after Ms ->
        ok
    end.

owner_msg(Call) ->
    receive
        {chappe_esl_call, Call, Msg} -> Msg
    after 5000 ->
        ct:fail(no_owner_msg)
    end.

%% The next owner message that is not a plain event.
owner_msg_skip_events(Call) ->
    case owner_msg(Call) of
        {event, _} -> owner_msg_skip_events(Call);
        Msg -> Msg
    end.

hdr(Key, Ev) ->
    chappe_esl_event:header(Key, Ev).

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

wait(Fun) ->
    wait(Fun, 100).

wait(_Fun, 0) ->
    ct:fail(wait_timeout);
wait(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            wait(Fun, N - 1)
    end.
