%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The engine's record of closed connections (bounded, cleared on a new
%% engine) and the chappe_sip_engine_restart message its handle owners get
%% when the stack goes away.
-module(chappe_sip_engine_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    conn_closed_recorded/1,
    conn_closed_trimmed/1,
    conn_closed_cleared_on_start/1,
    restart_tells_owners/1,
    stop_tells_owners/1
]).

-define(CONNS, chappe_sip_engine_conns).
-define(MAX_CLOSED, 10000).

all() ->
    [
        conn_closed_recorded,
        conn_closed_trimmed,
        conn_closed_cleared_on_start,
        restart_tells_owners,
        stop_tells_owners
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip).

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip_engine:stop(),
    ok.

%% a flow_closed event marks the connection closed; others stay open
conn_closed_recorded(_Config) ->
    ?assertNot(?CONNS:conn_closed(910001)),
    closed([910001]),
    ?assert(?CONNS:conn_closed(910001)),
    ?assertNot(?CONNS:conn_closed(910002)).

%% past MAX_CLOSED entries the older half of the record goes
conn_closed_trimmed(_Config) ->
    ok = start(17101),
    Ids = lists:seq(1, ?MAX_CLOSED + 1),
    closed(Ids),
    Half = ?MAX_CLOSED div 2,
    ?assertNot(lists:any(fun ?CONNS:conn_closed/1, lists:seq(1, Half - 1))),
    ?assert(lists:all(fun ?CONNS:conn_closed/1, lists:seq(Half, ?MAX_CLOSED + 1))),
    ?assertEqual(?MAX_CLOSED - Half + 2, ets:info(chappe_sip_closed_conns, size)).

%% a new engine starts with no record of closed connections
conn_closed_cleared_on_start(_Config) ->
    closed([920001]),
    ?assert(?CONNS:conn_closed(920001)),
    ok = start(17102),
    ?assertNot(?CONNS:conn_closed(920001)).

%% a restart tells every handle owner its SIP state is gone
restart_tells_owners(_Config) ->
    ok = start(17103),
    ok = chappe_sip_engine:reg_handle(930001, self()),
    ok = chappe_sip_engine:restart_engine(),
    receive
        {chappe_sip_engine_restart, undefined} -> ok
    after 3000 -> ct:fail(no_restart_message)
    end.

%% so does a stop
stop_tells_owners(_Config) ->
    ok = start(17104),
    ok = chappe_sip_engine:reg_handle(940001, self()),
    ok = chappe_sip_engine:stop(),
    receive
        {chappe_sip_engine_restart, undefined} -> ok
    after 3000 -> ct:fail(no_restart_message)
    end.

%% helpers

start(Port) ->
    chappe_sip_engine:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>
    }).

%% feed flow_closed events in, as the WS transport would, and wait until
%% the engine has handled them
closed(Ids) ->
    _ = [chappe_sip_engine ! {chappe_sip_engine, ws, {flow_closed, Id}} || Id <- Ids],
    _ = sys:get_state(chappe_sip_engine),
    ok.
