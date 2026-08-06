%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Engine lifecycle stress.
%%
%% Races inbound SIP traffic (which drives NIF ops through the engine and its
%% request workers) against stop and restart over many cycles. It is meant to
%% run under AddressSanitizer (test/asan/run.sh) to validate the C NIF's
%% enqueue-vs-root-destroy lock (F2), the INIT->READY / abandon CAS (F12), and
%% the thread-ref destructor model (F1): no use-after-free, double-free, or
%% deadlock across start/stop/restart under load.
-module(chappe_sip_engine_lifecycle_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([op_vs_stop_stress/1, restart_under_traffic/1]).

all() ->
    [op_vs_stop_stress, restart_under_traffic].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% Start, drive concurrent OPTIONS traffic, then stop while it is in flight,
%% over many rounds. The traffic makes the stack thread and request workers
%% active exactly as teardown runs.
op_vs_stop_stress(_Config) ->
    Rounds = 60,
    lists:foreach(fun(N) ->
        Port = 47000 + N,
        ok = start_retry(Port, 30),
        ok = chappe_sip:options(fun(_R, Res) -> chappe_sip_res:send(Res, 200, #{}) end),
        Firers = fire_traffic(Port, 6, 15),
        _ = chappe_sip_engine:stop(),
        drain(Firers)
    end, lists:seq(1, Rounds)).

%% Cycle restart_engine (stop + re-establish the native stack) under sustained
%% traffic on a stable port.
restart_under_traffic(_Config) ->
    Port = 46000 + rand:uniform(500),
    ok = start_retry(Port, 30),
    ok = chappe_sip:options(fun(_R, Res) -> chappe_sip_res:send(Res, 200, #{}) end),
    lists:foreach(fun(_) ->
        Firers = fire_traffic(Port, 4, 20),
        _ = chappe_sip_engine:restart_engine(),
        drain(Firers)
    end, lists:seq(1, 20)),
    _ = chappe_sip_engine:stop().

%% ---- helpers ----

%% start can briefly see {error, stopping} while a prior engine tears down;
%% retry a bounded number of times.
start_retry(_Port, 0) -> {error, gave_up};
start_retry(Port, N) ->
    case chappe_sip_engine:start(#{contact => contact(Port)}) of
        ok -> ok;
        {error, stopping} -> timer:sleep(20), start_retry(Port, N - 1);
        {error, already_started} -> _ = chappe_sip_engine:stop(),
            timer:sleep(20), start_retry(Port, N - 1);
        Other -> Other
    end.

fire_traffic(Port, Workers, PerWorker) ->
    Self = self(),
    [spawn(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
        lists:foreach(fun(_) ->
            _ = gen_udp:send(Sock, {127,0,0,1}, Port, options(Sock)),
            timer:sleep(1)
        end, lists:seq(1, PerWorker)),
        gen_udp:close(Sock),
        Self ! {fired, self()}
     end) || _ <- lists:seq(1, Workers)].

drain([]) -> ok;
drain([P | Ps]) ->
    receive {fired, P} -> ok after 8000 -> ok end,
    drain(Ps).

contact(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

options(Sock) ->
    {ok, P0} = inet:port(Sock),
    P = integer_to_binary(P0),
    Br = binary:encode_hex(crypto:strong_rand_bytes(6), lowercase),
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bK", Br/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1:", P/binary, ">;tag=", Br/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: st-", Br/binary, "@ct\r\nCSeq: 1 OPTIONS\r\n"
      "Content-Length: 0\r\n\r\n">>.
