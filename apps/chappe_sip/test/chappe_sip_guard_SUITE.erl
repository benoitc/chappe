%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The guard middleware (chappe_sip_guard) on the wire: a raw UDP peer on
%% 127.0.0.1 sends OPTIONS to a handler behind the guard and reads what
%% comes back.
-module(chappe_sip_guard_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [open/0, port/1, send/3, recv/3, recv_none/3,
                               request/3, status/1]).

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([user_agent/1, deny_cidr/1, allow_cidr/1, rate_limit/1, drop/1,
         no_block_without_drop/1, metrics/1]).

all() ->
    [user_agent, deny_cidr, allow_cidr, rate_limit, drop,
     no_block_without_drop, metrics].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    ok = chappe_sip:options(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 200, #{})
    end),
    [{ep, EP}, {sock, open()} | Config].

end_per_testcase(_Case, Config) ->
    ok = chappe_sip_engine:block_source(<<"127.0.0.1">>, 0),
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% A User-Agent matching a pattern, whatever its case, is turned away;
%% another one, or none, reaches the handler.
user_agent(Config) ->
    ok = chappe_sip:use(chappe_sip_guard:new(#{
        user_agents => [<<"friendly-scanner">>, <<"^sipvicious">>]})),
    ?assertEqual(403, options(Config, [{<<"User-Agent">>, <<"friendly-scanner">>}])),
    ?assertEqual(403, options(Config, [{<<"User-Agent">>, <<"SIPVicious 0.3">>}])),
    ?assertEqual(200, options(Config, [{<<"User-Agent">>, <<"Linphone/5.2">>}])),
    ?assertEqual(200, options(Config, [])).

%% A source in a deny list gets the action (503 here).
deny_cidr(Config) ->
    ok = chappe_sip:use(chappe_sip_guard:new(#{
        deny => [<<"127.0.0.0/8">>], action => 503})),
    ?assertEqual(503, options(Config, [])).

%% With an allow list, only the sources in it pass.
allow_cidr(Config) ->
    ok = chappe_sip:use(<<"OPTIONS">>, chappe_sip_guard:new(#{
        allow => [<<"10.0.0.0/8">>]})),
    ?assertEqual(403, options(Config, [])),
    _ = chappe_sip_engine:reset_routes(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 200, #{})
    end),
    ok = chappe_sip:use(chappe_sip_guard:new(#{
        allow => [<<"10.0.0.0/8">>, <<"127.0.0.1">>]})),
    ?assertEqual(200, options(Config, [])).

%% A source past its burst is turned away until tokens come back.
rate_limit(Config) ->
    ok = chappe_sip:use(chappe_sip_guard:new(#{
        rate => #{rate => 2, burst => 3}, action => 503})),
    ?assertEqual([200, 200, 200, 503],
                 [options(Config, []) || _ <- lists:seq(1, 4)]),
    timer:sleep(600),
    ?assertEqual(200, options(Config, [])).

%% drop answers nothing, not even the 500 of a worker gone without a
%% final response.
%% The source is then blocked: a flood from it is discarded before the
%% stack makes a transaction of it, so the transactions held stay flat and
%% nothing is answered, not even a 100 Trying.
drop(Config) ->
    ok = chappe_sip:use(chappe_sip_guard:new(#{
        user_agents => [<<"scanner">>], action => drop, block_ms => 60000})),
    Sock = ?config(sock, Config),
    EP = ?config(ep, Config),
    send(Sock, EP,
         request(<<"OPTIONS">>, ruri(Config),
                 #{port => port(Sock),
                   headers => [{<<"User-Agent">>, <<"scanner">>}]})),
    recv_none(Sock, any, 1000),
    #{incoming := Held, discarded := D0} = chappe_sip_engine:stats(),
    Flood = 2000,
    [send(Sock, EP,
          request(Method, ruri(Config),
                  #{port => port(Sock), cseq => N,
                    headers => [{<<"User-Agent">>, <<"Linphone/5.2">>}]}))
     || N <- lists:seq(1, Flood),
        Method <- [<<"OPTIONS">>, <<"INVITE">>, <<"REGISTER">>]],
    recv_none(Sock, any, 1500),
    #{incoming := Held1, discarded := D1} = chappe_sip_engine:stats(),
    ?assert(Held1 =< Held),
    ?assert(D1 - D0 >= Flood * 3 * 9 div 10),
    %% lifted, the source is served again
    ok = chappe_sip_engine:block_source(<<"127.0.0.1">>, 0),
    ?assertEqual(200, options(Config, [])).

%% Without drop nothing is blocked: a flood is answered and every
%% transaction is released.
no_block_without_drop(Config) ->
    ok = chappe_sip:use(chappe_sip_guard:new(#{
        user_agents => [<<"scanner">>]})),
    ?assertEqual(403, options(Config, [{<<"User-Agent">>, <<"scanner">>}])),
    ?assertEqual(200, options(Config, [])),
    timer:sleep(200),
    #{incoming := Held} = chappe_sip_engine:stats(),
    ?assertEqual(0, Held).

%% Each turned-away request is counted by reason.
metrics(Config) ->
    Before = blocked(<<"user_agent">>),
    ok = chappe_sip:use(chappe_sip_guard:new(#{user_agents => [<<"x-bot">>]})),
    ?assertEqual(403, options(Config, [{<<"User-Agent">>, <<"x-bot">>}])),
    ?assertEqual(Before + 1, blocked(<<"user_agent">>)).

%% ---- helpers ----

ruri(Config) ->
    <<"sip:app@127.0.0.1:", (integer_to_binary(?config(ep, Config)))/binary>>.

options(Config, Hdrs) ->
    Sock = ?config(sock, Config),
    Req = request(<<"OPTIONS">>, ruri(Config),
                  #{port => port(Sock), headers => Hdrs}),
    send(Sock, ?config(ep, Config), Req),
    {Bin, _} = recv(Sock, final, 3000),
    status(Bin).

blocked(Reason) ->
    case instrument_metric:get_counter_vec(chappe_sip_guard_blocked, [Reason]) of
        N when is_number(N) -> round(N);
        _ -> 0
    end.
