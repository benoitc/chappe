%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Opt-in interop suite against a live FreeSWITCH. It runs only when FS_HOST is
%% set, otherwise every case is skipped. Point it at a FreeSWITCH with
%% mod_event_socket enabled:
%%
%%   FS_HOST=127.0.0.1 FS_PORT=8021 FS_PASSWORD=ClueCon \
%%     rebar3 ct --suite test/chappe_esl_live_SUITE
%%
%% interop/docker-compose.yml brings up a suitable FreeSWITCH.
-module(chappe_esl_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([status/1, reloadxml/1, originate_and_events/1, conference/1]).

all() ->
    [status, reloadxml, originate_and_events, conference].

init_per_suite(Config) ->
    case os:getenv("FS_HOST") of
        false ->
            {skip, "FS_HOST not set; live FreeSWITCH interop disabled"};
        Host ->
            Port = list_to_integer(os:getenv("FS_PORT", "8021")),
            Password = list_to_binary(os:getenv("FS_PASSWORD", "ClueCon")),
            case
                chappe_esl:connect(#{
                    host => Host,
                    port => Port,
                    password => Password
                })
            of
                {ok, Conn} ->
                    [{conn, Conn} | Config];
                {error, Reason} ->
                    {skip, {connect_failed, Reason}}
            end
    end.

end_per_suite(Config) ->
    case ?config(conn, Config) of
        undefined -> ok;
        Conn -> chappe_esl:close(Conn)
    end.

status(Config) ->
    Conn = ?config(conn, Config),
    {ok, Body} = chappe_esl:api(Conn, "status"),
    ?assert(binary:match(Body, <<"UP">>) =/= nomatch).

reloadxml(Config) ->
    Conn = ?config(conn, Config),
    ?assertMatch({ok, _}, chappe_esl:bgapi_await(Conn, "reloadxml", 15000)).

originate_and_events(Config) ->
    Conn = ?config(conn, Config),
    ok = chappe_esl:subscribe(Conn, ['CHANNEL_CREATE', 'CHANNEL_HANGUP']),
    {ok, Reply} = chappe_esl:bgapi_await(
        Conn, "originate loopback/wait &park", 15000
    ),
    Uuid = originate_uuid(Reply),
    ?assertNotEqual(undefined, Uuid),
    ok = expect_event(Conn, <<"CHANNEL_CREATE">>, 15000),
    {ok, _} = chappe_esl:api(Conn, ["uuid_kill ", Uuid]),
    ok = expect_event(Conn, <<"CHANNEL_HANGUP">>, 15000).

conference(Config) ->
    Conn = ?config(conn, Config),
    {ok, _} = chappe_esl:bgapi_await(
        Conn, "originate loopback/wait &conference(esltest)", 15000
    ),
    {ok, List} = chappe_esl:api(Conn, "conference esltest list"),
    ?assert(is_binary(List)),
    {ok, _} = chappe_esl:api(Conn, "conference esltest hup all").

%% helpers

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
