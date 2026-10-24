%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node registry against chappe_esl_fake_server nodes: connection state,
%% backoff, heartbeat and probe health, load, selection, draining and tags.
-module(chappe_esl_nodes_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    no_nodes_no_registry/1,
    options/1,
    add_remove/1,
    up_with_load/1,
    channel_events/1,
    heartbeat_timeout/1,
    probe_failure/1,
    probe_timeout/1,
    up_after_probes/1,
    socket_drop/1,
    refused_then_up/1,
    backoff_bounds/1,
    backoff_spacing/1,
    select_least_sessions/1,
    select_idle_cpu/1,
    select_weighted/1,
    select_skips_full/1,
    select_tags/1,
    select_none_up/1,
    draining/1,
    node_api/1,
    node_bgapi/1,
    subscribe_all/1,
    env_nodes/1
]).

all() ->
    [
        no_nodes_no_registry,
        options,
        add_remove,
        up_with_load,
        channel_events,
        heartbeat_timeout,
        probe_failure,
        probe_timeout,
        up_after_probes,
        socket_drop,
        refused_then_up,
        backoff_bounds,
        backoff_spacing,
        select_least_sessions,
        select_idle_cpu,
        select_weighted,
        select_skips_full,
        select_tags,
        select_none_up,
        draining,
        node_api,
        node_bgapi,
        subscribe_all,
        env_nodes
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_esl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_esl).

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    [chappe_esl:node_remove(Name) || {Name, _} <- chappe_esl:nodes()],
    [chappe_esl_fake_server:stop(S) || S <- get_fakes()],
    erase(fakes),
    flush(),
    ok.

%% No configured node: the registry does not run.
no_nodes_no_registry(_Config) ->
    restart_app(),
    ?assertEqual(undefined, whereis(chappe_esl_nodes)),
    ?assertEqual([], chappe_esl:nodes()),
    ?assertEqual({error, none_up}, chappe_esl:node_select(#{})),
    ?assertEqual({error, not_found}, chappe_esl:node_status(fs1)),
    ?assertEqual({error, not_found}, chappe_esl:node_remove(fs1)),
    ?assertEqual({error, not_found}, chappe_esl:node_drain(fs1)).

%% req: ESL-30
options(_Config) ->
    ?assertEqual(
        {error, {missing_option, host}}, chappe_esl:node_add(fs1, #{})
    ),
    ?assertEqual(
        {error, {bad_option, port}},
        chappe_esl:node_add(fs1, #{host => "127.0.0.1", port => 0})
    ),
    ?assertEqual(
        {error, {bad_option, colour}},
        chappe_esl:node_add(fs1, #{host => "127.0.0.1", colour => red})
    ),
    {ok, C} = chappe_esl_node:validate(#{
        host => <<"10.0.0.1">>, password => "secret", events => ['DTMF']
    }),
    ?assertMatch(
        #{
            host := "10.0.0.1",
            port := 8021,
            password := <<"secret">>,
            events := [<<"DTMF">>],
            weight := 1,
            max_sessions := infinity
        },
        C
    ).

%% req: ESL-24
add_remove(_Config) ->
    {_, Port} = fake(#{}),
    ok = add(fs1, Port, #{tags => [edge], sip_uri => <<"sip:fs1">>}),
    ?assertEqual({error, already_exists}, add(fs1, Port, #{})),
    ok = wait_state(fs1, up),
    ?assertEqual([{fs1, up}], chappe_esl:nodes()),
    {ok, Status} = chappe_esl:node_status(fs1),
    ?assertMatch(
        #{
            name := fs1,
            state := up,
            port := Port,
            tags := [edge],
            sip_uri := <<"sip:fs1">>
        },
        Status
    ),
    ?assertNot(maps:is_key(password, Status)),
    ok = chappe_esl:node_subscribe(fs1),
    ok = chappe_esl:node_remove(fs1),
    ?assertEqual(down, expect_state(fs1)),
    ?assertEqual([], chappe_esl:nodes()),
    ?assertEqual({error, not_found}, chappe_esl:node_remove(fs1)).

%% Up, then the load from HEARTBEAT and from the probes.
%% req: ESL-24 ESL-25 ESL-27
up_with_load(_Config) ->
    {Fake, Port} = fake(#{
        load => #{
            <<"Session-Count">> => <<"3">>,
            <<"Max-Sessions">> => <<"500">>,
            <<"Idle-CPU">> => <<"87.500000">>
        },
        api => #{
            <<"status">> => status_body(4, 900),
            <<"show calls count">> => <<"\n2 total.\n\n">>
        }
    }),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{}),
    ?assertEqual(up, expect_state(fs1)),
    ?assertEqual(
        <<"event json HEARTBEAT BACKGROUND_JOB CHANNEL_CREATE",
            " CHANNEL_HANGUP_COMPLETE">>,
        fake_block(Fake, <<"event ">>)
    ),
    [fake_block(Fake, <<"api ", P/binary>>) || P <- probes()],
    Load = expect_load(fs1, fun(L) -> maps:is_key(heartbeat_at, L) end),
    ?assertMatch(
        #{
            max_sessions := 500,
            idle_cpu := 87.5,
            sessions_per_sec := 0,
            uptime_ms := 1000
        },
        Load
    ),
    Probed = expect_load(fs1, fun(L) -> maps:is_key(calls, L) end),
    ?assertMatch(#{calls := 2}, Probed),
    {ok, #{load := L}} = chappe_esl:node_status(fs1),
    ?assert(maps:is_key(probe_at, L)).

%% CHANNEL_CREATE and CHANNEL_HANGUP_COMPLETE move the session count between
%% heartbeats; event subscribers get the events.
%% req: ESL-25 ESL-29
channel_events(_Config) ->
    {Fake, Port} = fake(#{heartbeat => 60000}),
    ok = add(fs1, Port, #{heartbeat_interval_ms => 60000}),
    ok = wait_state(fs1, up),
    ok = chappe_esl:node_events(fs1),
    Create = chappe_esl_fake_server:json_event(<<"CHANNEL_CREATE">>, [
        {<<"Unique-ID">>, <<"u-1">>},
        {<<"variable_sip_h_X-Chappe-Call">>, <<"call-1">>}
    ]),
    chappe_esl_fake_server:inject(Fake, [Create, Create]),
    Ev = expect_event(fs1, <<"CHANNEL_CREATE">>),
    ?assertEqual(
        <<"call-1">>,
        chappe_esl_event:header(<<"variable_sip_h_X-Chappe-Call">>, Ev)
    ),
    _ = expect_event(fs1, <<"CHANNEL_CREATE">>),
    ?assertEqual(2, sessions(fs1)),
    Hangup = chappe_esl_fake_server:json_event(
        <<"CHANNEL_HANGUP_COMPLETE">>, [{<<"Unique-ID">>, <<"u-1">>}]
    ),
    chappe_esl_fake_server:inject(Fake, [Hangup, Hangup, Hangup]),
    [expect_event(fs1, <<"CHANNEL_HANGUP_COMPLETE">>) || _ <- [1, 2, 3]],
    ?assertEqual(0, sessions(fs1)),
    ok = chappe_esl:node_unsubscribe(fs1),
    chappe_esl_fake_server:inject(Fake, Create),
    receive
        {chappe_esl_node, fs1, {event, _}} -> ct:fail(still_subscribed)
    after 200 -> ok
    end.

%% No HEARTBEAT within twice the interval: down, then up again on reconnect.
%% req: ESL-26
heartbeat_timeout(_Config) ->
    {_, Port} = fake(#{heartbeat => 0}),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{}),
    ?assertEqual(up, expect_state(fs1)),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual(down, expect_state(fs1)),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 180),
    ?assertEqual(up, expect_state(fs1)).

%% A probe answered -ERR marks the node down; it is up again once the probe
%% passes.
%% req: ESL-27
probe_failure(_Config) ->
    {Fake, Port} = fake(#{}),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{backoff_min_ms => 400}),
    ?assertEqual(up, expect_state(fs1)),
    ok = chappe_esl_fake_server:set_api(
        Fake, <<"sofia status">>, <<"-ERR sofia Command not found!\n">>
    ),
    ?assertEqual(down, expect_state(fs1)),
    {ok, #{state := down, load := Load}} = chappe_esl:node_status(fs1),
    ?assertEqual(#{}, Load),
    ok = chappe_esl_fake_server:set_api(Fake, <<"sofia status">>, <<"+OK">>),
    ?assertEqual(up, expect_state(fs1)).

%% A probe with no answer within probe_timeout_ms marks the node down.
%% req: ESL-27
probe_timeout(_Config) ->
    {Fake, Port} = fake(#{}),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{}),
    ?assertEqual(up, expect_state(fs1)),
    ok = chappe_esl_fake_server:set_api(Fake, <<"status">>, silent),
    ?assertEqual(down, expect_state(fs1)).

%% A node that answers the login but fails its probes (a FreeSWITCH still
%% loading mod_sofia) is never up; once the probes pass, it is.
%% req: ESL-27
up_after_probes(_Config) ->
    {Fake, Port} = fake(#{
        api => #{<<"sofia status">> => <<"-ERR sofia Command not found!\n">>}
    }),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{}),
    _ = [accept_time() || _ <- [1, 2, 3]],
    ?assertMatch({ok, #{state := down}}, chappe_esl:node_status(fs1)),
    receive
        {chappe_esl_node, fs1, up} -> ct:fail(up_before_probes)
    after 0 -> ok
    end,
    ok = chappe_esl_fake_server:set_api(Fake, <<"sofia status">>, <<"+OK">>),
    ?assertEqual(up, expect_state(fs1)).

%% The node closes the socket: down, then reconnected.
%% req: ESL-24
socket_drop(_Config) ->
    {Fake, Port} = fake(#{}),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{}),
    ?assertEqual(up, expect_state(fs1)),
    ok = chappe_esl_fake_server:drop(Fake),
    ?assertEqual(down, expect_state(fs1)),
    ?assertEqual(up, expect_state(fs1)),
    ?assertEqual({ok, <<"+OK">>}, chappe_esl:node_api(fs1, "uptime")).

%% Nothing listens: down and retrying; once the node listens, up.
%% req: ESL-24 ESL-28
refused_then_up(_Config) ->
    {Fake0, Port} = fake(#{}),
    ok = chappe_esl_fake_server:stop(Fake0),
    put(fakes, []),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{}),
    ok = wait_state(fs1, down),
    ?assertEqual({error, down}, chappe_esl:node_api(fs1, "status")),
    timer:sleep(150),
    _ = fake(#{port => Port}),
    ?assertEqual(up, expect_state(fs1)).

%% Each wait is in the upper half of Min * 2^(N-1), capped at Max.
%% req: ESL-28
backoff_bounds(_Config) ->
    lists:foreach(
        fun(N) ->
            Ceil = min(1000, 100 bsl (N - 1)),
            [
                begin
                    W = chappe_esl_node:backoff(N, 100, 1000),
                    ?assert(W >= Ceil div 2),
                    ?assert(W =< Ceil)
                end
             || _ <- lists:seq(1, 50)
            ]
        end,
        lists:seq(1, 12)
    ),
    ?assert(chappe_esl_node:backoff(100, 100, 1000) =< 1000).

%% Refused logins are retried further and further apart.
%% req: ESL-28
backoff_spacing(_Config) ->
    {_, Port} = fake(#{auth => reject}),
    ok = add(fs1, Port, #{backoff_min_ms => 40, backoff_max_ms => 320}),
    Times = [accept_time() || _ <- lists:seq(1, 6)],
    Gaps = gaps(Times),
    ct:pal("gaps ~p", [Gaps]),
    Ceils = [min(320, 40 bsl (N - 1)) || N <- lists:seq(1, length(Gaps))],
    lists:foreach(
        fun({Gap, Ceil}) ->
            ?assert(Gap >= Ceil div 2 - 5),
            ?assert(Gap =< Ceil + 150)
        end,
        lists:zip(Gaps, Ceils)
    ).

%% req: ESL-31
select_least_sessions(_Config) ->
    three(),
    ?assertEqual({ok, fs3}, chappe_esl:node_select(#{})),
    ?assertEqual(
        {ok, fs3}, chappe_esl:node_select(#{policy => least_sessions})
    ).

%% req: ESL-31
select_idle_cpu(_Config) ->
    three(),
    ?assertEqual({ok, fs2}, chappe_esl:node_select(#{policy => idle_cpu})).

%% A weight 0 node is never picked; the others in proportion to weight.
%% req: ESL-31
select_weighted(_Config) ->
    three(),
    Picks = [
        element(2, chappe_esl:node_select(#{policy => weighted}))
     || _ <- lists:seq(1, 2000)
    ],
    Count = fun(N) -> length([P || P <- Picks, P =:= N]) end,
    ct:pal("fs1 ~p fs2 ~p fs3 ~p", [Count(fs1), Count(fs2), Count(fs3)]),
    ?assertEqual(0, Count(fs3)),
    %% weights 1 and 3
    ?assert(Count(fs2) > 2 * Count(fs1)).

%% A node at its max_sessions (configured or reported) is skipped.
%% req: ESL-31
select_skips_full(_Config) ->
    load_node(fs1, #{<<"Session-Count">> => <<"5">>}, #{max_sessions => 5}),
    load_node(
        fs2,
        #{<<"Session-Count">> => <<"8">>, <<"Max-Sessions">> => <<"8">>},
        #{}
    ),
    load_node(fs3, #{<<"Session-Count">> => <<"9">>}, #{}),
    ?assertEqual({ok, fs3}, chappe_esl:node_select(#{})).

%% req: ESL-31
select_tags(_Config) ->
    load_node(fs1, #{<<"Session-Count">> => <<"1">>}, #{tags => [conf]}),
    load_node(
        fs2, #{<<"Session-Count">> => <<"4">>}, #{tags => [conf, record]}
    ),
    ?assertEqual({ok, fs1}, chappe_esl:node_select(#{tags => [conf]})),
    ?assertEqual({ok, fs2}, chappe_esl:node_select(#{tags => [record]})),
    ?assertEqual(
        {ok, fs2}, chappe_esl:node_select(#{tags => [record, conf]})
    ),
    ?assertEqual({error, none_up}, chappe_esl:node_select(#{tags => [video]})).

%% req: ESL-31
select_none_up(_Config) ->
    {Fake, Port} = fake(#{}),
    ok = chappe_esl:node_subscribe(fs1),
    ok = add(fs1, Port, #{backoff_min_ms => 400}),
    ?assertEqual(up, expect_state(fs1)),
    ?assertEqual({ok, fs1}, chappe_esl:node_select(#{})),
    ok = chappe_esl_fake_server:set_api(Fake, <<"status">>, <<"-ERR">>),
    ?assertEqual(down, expect_state(fs1)),
    ?assertEqual({error, none_up}, chappe_esl:node_select(#{})).

%% A drained node stays connected and usable for api but is not selected.
%% req: ESL-32
draining(_Config) ->
    load_node(fs1, #{<<"Session-Count">> => <<"0">>}, #{}),
    load_node(fs2, #{<<"Session-Count">> => <<"7">>}, #{}),
    ok = chappe_esl:node_subscribe(fs1),
    ?assertEqual({ok, fs1}, chappe_esl:node_select(#{})),
    ok = chappe_esl:node_drain(fs1),
    ?assertEqual(draining, expect_state(fs1)),
    ?assertEqual([{fs1, draining}, {fs2, up}], chappe_esl:nodes()),
    ?assertEqual({ok, fs2}, chappe_esl:node_select(#{})),
    ?assertEqual({ok, <<"+OK">>}, chappe_esl:node_api(fs1, "uptime")),
    ok = chappe_esl:node_drain(fs1),
    ok = chappe_esl:node_resume(fs1),
    ?assertEqual(up, expect_state(fs1)),
    ?assertEqual({ok, fs1}, chappe_esl:node_select(#{})).

%% req: ESL-33
node_api(_Config) ->
    {_, Port} = fake(#{api => #{<<"uptime">> => <<"42">>}}),
    ok = add(fs1, Port, #{}),
    ok = wait_state(fs1, up),
    ?assertEqual({ok, <<"42">>}, chappe_esl:node_api(fs1, "uptime")),
    ?assertEqual({error, not_found}, chappe_esl:node_api(fs9, "uptime")).

%% bgapi runs on the node connection; its BACKGROUND_JOB reaches event
%% subscribers.
%% req: ESL-33
node_bgapi(_Config) ->
    {_, Port} = fake(#{api => #{<<"reloadxml">> => <<"+OK done">>}}),
    ok = add(fs1, Port, #{}),
    ok = wait_state(fs1, up),
    ok = chappe_esl:node_events(fs1),
    {ok, Job} = chappe_esl:node_bgapi(fs1, "reloadxml"),
    Ev = expect_event(fs1, <<"BACKGROUND_JOB">>),
    ?assertEqual(Job, chappe_esl_event:header(<<"Job-UUID">>, Ev)),
    ?assertEqual(<<"+OK done">>, chappe_esl_event:body(Ev)).

%% `all' gets the notices of every node.
%% req: ESL-29
subscribe_all(_Config) ->
    ok = chappe_esl:node_subscribe(all),
    {_, P1} = fake(#{}),
    {_, P2} = fake(#{}),
    ok = add(fs1, P1, #{}),
    ok = add(fs2, P2, #{}),
    ?assertEqual(up, expect_state(fs1)),
    ?assertEqual(up, expect_state(fs2)),
    ok = chappe_esl:node_unsubscribe(all).

%% Nodes listed in the app env start with the app.
%% req: ESL-30
env_nodes(_Config) ->
    {_, Port} = fake(#{}),
    ok = application:set_env(chappe_esl, nodes, #{
        fs1 => (opts(Port))#{tags => [env]}
    }),
    try
        restart_app(),
        ok = wait_state(fs1, up),
        ?assertMatch({ok, #{tags := [env]}}, chappe_esl:node_status(fs1))
    after
        application:unset_env(chappe_esl, nodes)
    end.

%% helpers

probes() ->
    [<<"status">>, <<"show calls count">>, <<"sofia status">>].

opts(Port) ->
    #{
        host => {127, 0, 0, 1},
        port => Port,
        heartbeat_interval_ms => 100,
        probe_interval_ms => 100,
        probe_timeout_ms => 200,
        backoff_min_ms => 20,
        backoff_max_ms => 100
    }.

add(Name, Port, Extra) ->
    chappe_esl:node_add(Name, maps:merge(opts(Port), Extra)).

fake(Extra) ->
    {ok, Fake, Port} = chappe_esl_fake_server:start(
        maps:merge(#{heartbeat => 50, reaccept => true}, Extra)
    ),
    put(fakes, [Fake | get_fakes()]),
    {Fake, Port}.

get_fakes() ->
    case get(fakes) of
        undefined -> [];
        L -> L
    end.

%% A node with the given HEARTBEAT load, once that load has arrived.
load_node(Name, Load, Extra) ->
    {_, Port} = fake(#{load => Load}),
    ok = add(Name, Port, Extra),
    Want = binary_to_integer(maps:get(<<"Session-Count">>, Load)),
    wait(fun() ->
        case chappe_esl:node_status(Name) of
            {ok, #{state := S, load := #{sessions := Want}}} when
                S =:= up; S =:= draining
            ->
                true;
            _ ->
                false
        end
    end).

%% fs1: 4 sessions, 50% idle, weight 1; fs2: 6 sessions, 90% idle,
%% weight 3; fs3: 2 sessions, 10% idle, weight 0.
three() ->
    load_node(
        fs1,
        #{<<"Session-Count">> => <<"4">>, <<"Idle-CPU">> => <<"50.0">>},
        #{weight => 1}
    ),
    load_node(
        fs2,
        #{<<"Session-Count">> => <<"6">>, <<"Idle-CPU">> => <<"90.0">>},
        #{weight => 3}
    ),
    load_node(
        fs3,
        #{<<"Session-Count">> => <<"2">>, <<"Idle-CPU">> => <<"10.0">>},
        #{weight => 0}
    ).

status_body(Sessions, Max) ->
    iolist_to_binary([
        "UP 0 years, 0 days, 0 hours, 0 minutes, 5 seconds\n",
        "FreeSWITCH (Version 1.10.10) is ready\n",
        "12 session(s) since startup\n",
        integer_to_list(Sessions),
        " session(s) - peak 3, last 5min 2 \n",
        "0 session(s) per Sec out of max 30, peak 1, last 5min 1 \n",
        integer_to_list(Max),
        " session(s) max\n",
        "min idle cpu 0.00/99.00\n"
    ]).

sessions(Name) ->
    {ok, #{load := Load}} = chappe_esl:node_status(Name),
    maps:get(sessions, Load, 0).

wait_state(Name, State) ->
    wait(fun() ->
        case chappe_esl:node_status(Name) of
            {ok, #{state := State}} -> true;
            _ -> false
        end
    end).

wait(Fun) ->
    wait(Fun, 300).

wait(_Fun, 0) ->
    ct:fail(wait_timeout);
wait(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait(Fun, N - 1)
    end.

%% The next up / down / draining notice for Name (load notices skipped).
expect_state(Name) ->
    receive
        {chappe_esl_node, Name, {load, _}} -> expect_state(Name);
        {chappe_esl_node, Name, State} when is_atom(State) -> State
    after 3000 ->
        ct:fail({no_state, Name})
    end.

expect_load(Name, Pred) ->
    receive
        {chappe_esl_node, Name, {load, Load}} ->
            case Pred(Load) of
                true -> Load;
                false -> expect_load(Name, Pred)
            end
    after 3000 ->
        ct:fail({no_load, Name})
    end.

expect_event(Name, EventName) ->
    receive
        {chappe_esl_node, Name, {event, Ev}} ->
            case chappe_esl_event:name(Ev) of
                EventName -> Ev;
                _ -> expect_event(Name, EventName)
            end
    after 3000 ->
        ct:fail({no_event, EventName})
    end.

fake_block(Fake, Prefix) ->
    Size = byte_size(Prefix),
    receive
        {fake_server, Fake, <<Prefix:Size/binary, _/binary>> = Block} -> Block
    after 3000 ->
        ct:fail({no_block, Prefix})
    end.

accept_time() ->
    receive
        {fake_server_accept, _} -> erlang:monotonic_time(millisecond)
    after 3000 ->
        ct:fail(no_accept)
    end.

gaps([A, B | Rest]) -> [B - A | gaps([B | Rest])];
gaps(_) -> [].

restart_app() ->
    ok = application:stop(chappe_esl),
    {ok, _} = application:ensure_all_started(chappe_esl),
    ok.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
