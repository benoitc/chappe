%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_outbound_SUITE).
-behaviour(chappe_esl_handler).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([channel_data/1, execute_on_channel/1]).
%% chappe_esl_handler callback.
-export([handle_channel/3]).

all() ->
    [channel_data, execute_on_channel].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_esl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_esl),
    ok.

%% The handler runs in its own process. It reports the channel to the test,
%% executes an app on the channel, and reports the result.
handle_channel(Conn, Channel, TestPid) ->
    TestPid ! {channel, Conn, Channel},
    Result = chappe_esl:execute(Conn, "playback", "tone.wav"),
    TestPid ! {execute_result, Result},
    ok.

channel_data(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self()),
    try
        S = fs_connect(Port),
        ok = expect_block(S, <<"connect\n\n">>),
        ok = gen_tcp:send(S, channel_frame()),
        receive
            {channel, _Conn, Channel} ->
                ?assertEqual(
                    <<"uuid-out-1">>,
                    chappe_esl_event:header(<<"Channel-Unique-ID">>, Channel)
                )
        after 5000 ->
            ct:fail(no_channel)
        end
    after
        chappe_esl:stop_listener(Port)
    end.

execute_on_channel(_Config) ->
    Port = pick_port(),
    {ok, _Ref} = chappe_esl:start_listener(Port, ?MODULE, self()),
    try
        S = fs_connect(Port),
        ok = expect_block(S, <<"connect\n\n">>),
        ok = gen_tcp:send(S, channel_frame()),
        %% The handler issues a sendmsg execute; answer it +OK.
        Block = recv_block(S),
        ?assertMatch(<<"sendmsg", _/binary>>, Block),
        ?assert(contains(Block, <<"execute-app-name: playback">>)),
        ok = gen_tcp:send(
            S, <<"Content-Type: command/reply\nReply-Text: +OK\n\n">>
        ),
        receive
            {execute_result, Res} -> ?assertEqual(ok, Res)
        after 5000 ->
            ct:fail(no_execute_result)
        end
    after
        chappe_esl:stop_listener(Port)
    end.

%% helpers

pick_port() ->
    {ok, L} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, P} = inet:port(L),
    gen_tcp:close(L),
    P.

fs_connect(Port) ->
    {ok, S} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {packet, raw}, {active, false}], 5000
    ),
    S.

channel_frame() ->
    <<
        "Content-Type: command/reply\n"
        "Reply-Text: +OK\n"
        "Channel-Unique-ID: uuid-out-1\n"
        "Channel-Name: sofia/internal/1000\n"
        "variable_sip_from_user: 1000\n\n"
    >>.

expect_block(S, Expected) ->
    Block = recv_block(S),
    case <<Block/binary, "\n\n">> of
        Expected -> ok;
        Other -> {error, {unexpected, Other}}
    end.

recv_block(S) ->
    recv_block(S, <<>>).

recv_block(S, Acc) ->
    case binary:split(Acc, <<"\n\n">>) of
        [Block, _Rest] ->
            Block;
        [_Incomplete] ->
            {ok, Data} = gen_tcp:recv(S, 0, 5000),
            recv_block(S, <<Acc/binary, Data/binary>>)
    end.

contains(Haystack, Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.
