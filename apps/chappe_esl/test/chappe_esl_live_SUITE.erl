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
%% start fs1.
-module(chappe_esl_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([status/1, reloadxml/1, originate_and_events/1, conference/1]).
-export([nodes_up_with_load/1, sessions_rise/1, stop_and_restart/1]).

all() ->
    [{group, conn}, {group, nodes}].

groups() ->
    [
        {conn, [], [status, reloadxml, originate_and_events, conference]},
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
init_per_testcase(_Case, Config) ->
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

end_per_testcase(_Case, Config) ->
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
