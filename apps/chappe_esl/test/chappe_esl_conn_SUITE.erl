%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_conn_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    connect_auth/1,
    api/1,
    bgapi/1,
    bgapi_await/1,
    subscribe_event/1,
    execute/1,
    change_controlling_process/1,
    disconnect_notice/1,
    stats/1
]).

all() ->
    [
        connect_auth,
        api,
        bgapi,
        bgapi_await,
        subscribe_event,
        execute,
        change_controlling_process,
        disconnect_notice,
        stats
    ].

fake_opts() ->
    #{
        api => #{
            <<"uptime">> => <<"7200000">>,
            <<"status">> => <<"UP 0 years, 0 days">>
        }
    }.

init_per_testcase(_Case, Config) ->
    {ok, Server, Port} = chappe_esl_fake_server:start(fake_opts()),
    {ok, Conn} = chappe_esl:connect(#{
        host => {127, 0, 0, 1},
        port => Port,
        password => <<"ClueCon">>
    }),
    [{server, Server}, {conn, Conn} | Config].

end_per_testcase(_Case, Config) ->
    safe(fun() -> chappe_esl:close(?config(conn, Config)) end),
    safe(fun() -> chappe_esl_fake_server:stop(?config(server, Config)) end),
    ok.

safe(Fun) ->
    try
        Fun()
    catch
        _:_ -> ok
    end.

connect_auth(Config) ->
    Conn = ?config(conn, Config),
    ?assert(is_process_alive(Conn)).

api(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual({ok, <<"7200000">>}, chappe_esl:api(Conn, "uptime")),
    ?assertEqual({ok, <<"UP 0 years, 0 days">>}, chappe_esl:api(Conn, "status")).

bgapi(Config) ->
    Conn = ?config(conn, Config),
    ?assertMatch({ok, _JobId}, chappe_esl:bgapi(Conn, "reloadxml")).

bgapi_await(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(
        {ok, <<"+OK">>}, chappe_esl:bgapi_await(Conn, "reloadxml", 5000)
    ).

subscribe_event(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    ?assertEqual(ok, chappe_esl:subscribe(Conn, [<<"CHANNEL_ANSWER">>])),
    Frame = chappe_esl_fake_server:plain_event(<<"CHANNEL_ANSWER">>, [
        {<<"Unique-ID">>, <<"abc-123">>}
    ]),
    ok = chappe_esl_fake_server:inject(Server, Frame),
    receive
        {chappe_esl_event, Conn, Event} ->
            ?assertEqual(<<"CHANNEL_ANSWER">>, chappe_esl_event:name(Event)),
            ?assertEqual(
                <<"abc-123">>, chappe_esl_event:header(<<"Unique-ID">>, Event)
            )
    after 5000 ->
        ct:fail(no_event)
    end.

execute(Config) ->
    Conn = ?config(conn, Config),
    ?assertEqual(ok, chappe_esl:execute(Conn, "uuid-1", "playback", "tone.wav")).

change_controlling_process(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    Test = self(),
    Receiver = spawn(fun() ->
        receive
            {chappe_esl_event, Conn, Event} -> Test ! {got, chappe_esl_event:name(Event)}
        after 5000 -> Test ! timeout
        end
    end),
    ok = chappe_esl:set_controlling_process(Conn, Receiver),
    Frame = chappe_esl_fake_server:plain_event(<<"HEARTBEAT">>, []),
    ok = chappe_esl_fake_server:inject(Server, Frame),
    receive
        {got, Name} -> ?assertEqual(<<"HEARTBEAT">>, Name);
        timeout -> ct:fail(receiver_timeout)
    after 6000 ->
        ct:fail(no_forward)
    end.

disconnect_notice(Config) ->
    Conn = ?config(conn, Config),
    Server = ?config(server, Config),
    ok = chappe_esl_fake_server:inject(Server, disconnect_frame()),
    receive
        {chappe_esl_disconnect, Conn} -> ok
    after 5000 ->
        ct:fail(no_disconnect)
    end.

stats(Config) ->
    Conn = ?config(conn, Config),
    {ok, _} = chappe_esl:api(Conn, "uptime"),
    S = chappe_esl:stats(Conn),
    ?assert(maps:get(commands, S) >= 1),
    ?assert(maps:get(replies, S) >= 1).

disconnect_frame() ->
    Body = <<"Disconnected, goodbye.\n">>,
    Len = integer_to_binary(byte_size(Body)),
    <<"Content-Type: text/disconnect-notice\nContent-Length: ", Len/binary,
        "\n\n", Body/binary>>.
