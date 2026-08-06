%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Pool behavior: load-based selection, pinning, timeout-driven node
%% down, health-ping recovery with generation bump.
-module(chappe_rtpengine_pool_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    selection_prefers_least_loaded/1,
    pin_and_unpin_track_counters/1,
    timeout_reports_mark_node_down/1,
    health_ping_recovers_and_bumps_generation/1,
    select_with_no_nodes/1
]).

all() ->
    [
        selection_prefers_least_loaded,
        pin_and_unpin_track_counters,
        timeout_reports_mark_node_down,
        health_ping_recovers_and_bumps_generation,
        select_with_no_nodes
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_rtpengine),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_rtpengine).

end_per_testcase(_Case, _Config) ->
    _ = chappe_rtpengine_pool:unsubscribe(),
    [
        begin
            _ = chappe_rtpengine:remove_node(maps:get(name, Info))
        end
     || Info <- chappe_rtpengine:list_nodes()
    ],
    flush_pool_events(),
    ok.

%% helpers

add_fake_node(Name, NodeOpts) ->
    add_fake_node(Name, NodeOpts, fun chappe_rtpengine_fake_server:default_handler/2).

add_fake_node(Name, NodeOpts, Handler) ->
    {ok, Server, Port} = chappe_rtpengine_fake_server:start(Handler),
    Opts = maps:merge(#{host => {127, 0, 0, 1}, port => Port}, NodeOpts),
    ok = chappe_rtpengine:add_node(Name, Opts),
    Server.

wait_event(Expected) ->
    receive
        {chappe_rtpengine_pool, Expected} -> ok
    after 5000 -> error({missing_pool_event, Expected})
    end.

flush_pool_events() ->
    receive
        {chappe_rtpengine_pool, _} -> flush_pool_events()
    after 0 -> ok
    end.

%% cases

selection_prefers_least_loaded(_Config) ->
    _ = add_fake_node(pool_a, #{}),
    _ = add_fake_node(pool_b, #{}),
    %% two consecutive pins must land on different nodes: the first
    %% pin raises that node's load above the other's
    {ok, First, _} = chappe_rtpengine_pool:pin(<<"call-lb-1">>),
    {ok, Second, _} = chappe_rtpengine_pool:pin(<<"call-lb-2">>),
    ?assertNotEqual(First, Second),
    %% a third pin goes to whichever is now least loaded; unpin one
    %% call from First and the next pin lands there again
    ok = chappe_rtpengine_pool:unpin(<<"call-lb-1">>),
    {ok, Third, _} = chappe_rtpengine_pool:pin(<<"call-lb-3">>),
    ?assertEqual(First, Third),
    ok.

pin_and_unpin_track_counters(_Config) ->
    _ = add_fake_node(pool_counters, #{}),
    {ok, pool_counters, Gen} = chappe_rtpengine_pool:pin_to(
        <<"call-c-1">>, pool_counters
    ),
    ?assertEqual(1, Gen),
    #{pinned := 1} = chappe_rtpengine_pool:node_info(pool_counters),
    {ok, pool_counters, Gen} = chappe_rtpengine_pool:pinned(<<"call-c-1">>),
    ok = chappe_rtpengine_pool:unpin(<<"call-c-1">>),
    #{pinned := 0} = chappe_rtpengine_pool:node_info(pool_counters),
    error = chappe_rtpengine_pool:pinned(<<"call-c-1">>),
    {error, not_managed} = chappe_rtpengine_pool:pin_to(<<"call-c-2">>, nonexistent),
    ok.

timeout_reports_mark_node_down(_Config) ->
    %% health pings pushed out of the way; the facade's timeout
    %% reports alone must take the node down after down_after=2
    Handler = fun(_N, _Cmd) -> drop end,
    _ = add_fake_node(
        pool_report_down,
        #{
            timeout => 50,
            attempts => 1,
            down_after => 2,
            health_interval => 60000
        },
        Handler
    ),
    ok = chappe_rtpengine_pool:subscribe(),
    {ok, pool_report_down} = chappe_rtpengine_pool:select(),
    {error, timeout} = chappe_rtpengine:ping(pool_report_down),
    {error, timeout} = chappe_rtpengine:ping(pool_report_down),
    wait_event({node_down, pool_report_down}),
    #{status := down} = chappe_rtpengine_pool:node_info(pool_report_down),
    {error, no_nodes} = chappe_rtpengine_pool:select(),
    ok.

health_ping_recovers_and_bumps_generation(_Config) ->
    %% node starts unresponsive, goes down via health pings, then the
    %% handler is restored and the next ping brings it up with a
    %% bumped generation (restart detection signal)
    Handler = fun(_N, _Cmd) -> drop end,
    Server = add_fake_node(
        pool_recovery,
        #{
            timeout => 50,
            attempts => 1,
            down_after => 2,
            health_interval => 100
        },
        Handler
    ),
    ok = chappe_rtpengine_pool:subscribe(),
    wait_event({node_down, pool_recovery}),
    chappe_rtpengine_fake_server:set_handler(
        Server, fun chappe_rtpengine_fake_server:default_handler/2
    ),
    wait_event({node_up, pool_recovery, 2}),
    #{status := up, generation := 2} = chappe_rtpengine_pool:node_info(pool_recovery),
    {ok, pool_recovery} = chappe_rtpengine_pool:select(),
    ok.

select_with_no_nodes(_Config) ->
    {error, no_nodes} = chappe_rtpengine_pool:select(),
    {error, no_nodes} = chappe_rtpengine_pool:pin(<<"call-none">>),
    ok.
