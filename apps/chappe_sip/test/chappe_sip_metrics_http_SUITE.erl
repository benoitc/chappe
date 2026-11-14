%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The built-in metrics listener (chappe_sip_metrics_http): GET /metrics
%% over plain HTTP, started by the `metrics' setting or listen/1.
-module(chappe_sip_metrics_http_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([listen_serves_metrics/1, listener_at_boot/1, bad_options/1,
         service_crash_restarts/1, stop_listening/1]).

all() ->
    [listen_serves_metrics, listener_at_boot, bad_options,
     service_crash_restarts, stop_listening].

init_per_testcase(listener_at_boot, Config) ->
    P = chappe_sip_test_port:pick(),
    application:set_env(chappe_sip, metrics, #{port => P}),
    {ok, _} = application:ensure_all_started(chappe_sip),
    [{port, P} | Config];
init_per_testcase(service_crash_restarts, Config) ->
    init_per_testcase(listener_at_boot, Config);
init_per_testcase(_Case, Config) ->
    {ok, _} = application:ensure_all_started(chappe_sip),
    [{port, chappe_sip_test_port:pick()} | Config].

end_per_testcase(_Case, _Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, metrics),
    ok.

%% listen/1: GET /metrics answers 200 in the Prometheus text format with
%% the SIP metrics; any other path is not served.
listen_serves_metrics(Config) ->
    P = ?config(port, Config),
    ok = chappe_sip_metrics:listen(#{port => P}),
    ?assertEqual(P, chappe_sip_metrics_http:port()),
    {200, Body} = get(P, <<"/metrics">>),
    ?assertNotEqual(nomatch, binary:match(Body, <<"chappe_sip_dialogs">>)),
    {S, _} = get(P, <<"/other">>),
    ?assertNotEqual(200, S).

%% The `metrics' setting #{port => P} starts the listener with the
%% application, on 127.0.0.1.
listener_at_boot(Config) ->
    {200, _} = get(?config(port, Config), <<"/metrics">>).

bad_options(_Config) ->
    [?assertEqual({error, badarg}, chappe_sip_metrics:listen(O))
     || O <- [#{}, #{port => 0}, #{port => 70000}, #{port => <<"80">>},
              #{port => 9999, ip => "127.0.0.1"},
              #{port => 9999, other => 1}, not_a_map]].

%% The livery service dying takes the listener down with it; the
%% supervisor starts a fresh one from the setting and it serves again.
service_crash_restarts(Config) ->
    P = ?config(port, Config),
    Old = whereis(chappe_sip_metrics_http),
    {state, Svc, _, _} = sys:get_state(chappe_sip_metrics_http),
    exit(Svc, kill),
    ok = wait(fun() ->
        New = whereis(chappe_sip_metrics_http),
        is_pid(New) andalso New =/= Old andalso
            try get(P, <<"/metrics">>) of
                {200, _} -> true;
                _ -> false
            catch
                _:_ -> false
            end
    end, 50),
    {200, _} = get(P, <<"/metrics">>).

%% stop_listening/0 closes the port.
stop_listening(Config) ->
    P = ?config(port, Config),
    ok = chappe_sip_metrics:listen(#{port => P}),
    {200, _} = get(P, <<"/metrics">>),
    ok = chappe_sip_metrics:stop_listening(),
    ?assertEqual(undefined, chappe_sip_metrics_http:port()),
    ?assertMatch({error, _},
                 gen_tcp:connect({127, 0, 0, 1}, P, [binary], 1000)).

%% ---- helpers ----

get(Port, Path) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}], 2000),
    ok = gen_tcp:send(S, [<<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
                          <<"Host: localhost\r\nConnection: close\r\n\r\n">>]),
    Resp = recv_all(S, <<>>),
    gen_tcp:close(S),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Resp,
    [_, Body] = binary:split(Resp, <<"\r\n\r\n">>),
    {binary_to_integer(Code), Body}.

recv_all(S, Acc) ->
    case gen_tcp:recv(S, 0, 3000) of
        {ok, Data} -> recv_all(S, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, timeout} -> Acc
    end.

wait(_F, 0) ->
    ct:fail(not_restarted);
wait(F, N) ->
    case F() of
        true -> ok;
        _ -> timer:sleep(100), wait(F, N - 1)
    end.
