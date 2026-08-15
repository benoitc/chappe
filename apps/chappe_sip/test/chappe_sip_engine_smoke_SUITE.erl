%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Engine smoke suite: the engine boots inside the VM, answers SIP through the
%% shim, fails to start cleanly, cycles start/stop, and health round-trips
%% through the stack thread event loop.
%%
%% SIP is driven with plain gen_udp; sipp arrives with the M2 live groups.
-module(chappe_sip_engine_smoke_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([options_200/1, start_twice/1, bind_failure/1, start_stop_cycles/1,
         health_roundtrip/1]).

all() ->
    [options_200, start_twice, bind_failure, start_stop_cycles,
     health_roundtrip].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip).

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip_engine:stop(),
    ok.

options_200(_Config) ->
    Port = pick_port(),
    ok = chappe_sip_engine:start(#{contact => contact(Port)}),
    Test = self(),
    ok = chappe_sip:options(fun(Req, Res) ->
        %% raw SIP crossed the NIF boundary and parsed
        <<"OPTIONS ", _/binary>> =
            iolist_to_binary(chappe_sip_msg:encode(chappe_sip_req:msg(Req))),
        Test ! {got, chappe_sip_req:method(Req)},
        ok = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, LocalPort} = inet:port(Sock),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, options_msg(LocalPort)),
    receive
        {got, <<"OPTIONS">>} -> ok
    after 3000 -> ct:fail(no_request_event)
    end,
    receive
        {udp, Sock, _, _, <<"SIP/2.0 200 OK", _/binary>>} ->
            ok;
        {udp, Sock, _, _, Other} ->
            ct:fail({unexpected_response, Other})
    after 3000 ->
        ct:fail(no_sip_response)
    end,
    gen_udp:close(Sock).

start_twice(_Config) ->
    Port = pick_port(),
    ok = chappe_sip_engine:start(#{contact => contact(Port)}),
    {error, already_started} = chappe_sip_engine:start(#{contact => contact(Port + 1)}),
    ok = chappe_sip_engine:stop().

bind_failure(_Config) ->
    %% Occupy a TCP port, then ask the engine to bind it: the readiness
    %% barrier must surface the failure with the thread joined.
    Port = pick_port(),
    {ok, L} = gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}]),
    Contact = <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary,
                ";transport=tcp">>,
    {error, {engine_start, Why}} = chappe_sip_engine:start(#{contact => Contact}),
    true = is_binary(Why),
    gen_tcp:close(L),
    %% the guard must be released: a good start works right after
    ok = chappe_sip_engine:start(#{contact => contact(pick_port())}),
    ok = chappe_sip_engine:stop().

start_stop_cycles(_Config) ->
    Port = pick_port(),
    lists:foreach(
      fun(_) ->
              ok = chappe_sip_engine:start(#{contact => contact(Port)}),
              ok = chappe_sip_engine:stop()
      end, lists:seq(1, 5)).

health_roundtrip(_Config) ->
    ok = chappe_sip_engine:start(#{contact => contact(pick_port())}),
    ok = chappe_sip_engine:check_health(2000),
    ok = chappe_sip_engine:stop().

%% helpers

pick_port() ->
    chappe_sip_test_port:pick().

contact(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

options_msg(LocalPort) ->
    P = integer_to_binary(LocalPort),
    <<"OPTIONS sip:m0@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary,
      ";rport;branch=z9hG4bKm0test", P/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:ct@127.0.0.1>;tag=m0tag\r\n"
      "To: <sip:m0@127.0.0.1>\r\n"
      "Call-ID: m0-", P/binary, "@127.0.0.1\r\n"
      "CSeq: 1 OPTIONS\r\n"
      "Content-Length: 0\r\n\r\n">>.
