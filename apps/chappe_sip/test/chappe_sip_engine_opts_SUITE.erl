%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The agent settings of chappe_sip:start/1, on the native stack: the RFC
%% 3261 timers, the UDP MTU above which a request goes over TCP, the CRLF
%% keep-alive of TCP connections, the outbound proxy and the aliases. Each
%% case checks what goes on the wire, so it fails when the option is
%% ignored.
-module(chappe_sip_engine_opts_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([t1_sets_retransmissions/1, timer_a_starts_at_t1/1, udp_mtu_moves_to_tcp/1,
         tcp_keepalive_pings/1, outbound_proxy_takes_requests/1,
         outbound_route_preloaded/1,
         aliases_are_own/1, bad_options/1]).

-define(LO, {127, 0, 0, 1}).

all() ->
    [t1_sets_retransmissions, timer_a_starts_at_t1, udp_mtu_moves_to_tcp, tcp_keepalive_pings,
     outbound_proxy_takes_requests, outbound_route_preloaded, aliases_are_own,
     bad_options].

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

%% req: R3261-298 R3261-296
%% With T1 at 100 ms and T2 at 400 ms the first copy is sent again after
%% about T1 (sofia patch 0005: the fork waited at least 1 s), the interval
%% doubles to T2 and stays there from the fourth gap on (100, 200, 400,
%% 400, ...), and the request times out after 64*T1 = 6.4 s instead of 32.
%% The Erlang side's 64*T1 timers (Timer M of the proxy, Timer H over
%% WebSocket) follow the same T1.
t1_sets_retransmissions(_Config) ->
    start(#{sip_timers => #{t1 => 100, t2 => 400}}),
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, Port} = inet:port(S),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Ref} = chappe_sip:request(target(Port), #{method => <<"OPTIONS">>}),
    Sent = [recv_udp(S) || _ <- lists:seq(1, 7)],
    Gaps = [B - A || {A, B} <- lists:zip(lists:droplast(Sent), tl(Sent))],
    ct:log("retransmit gaps ~p ms", [Gaps]),
    [G1, G2, G3 | Capped] = Gaps,
    ?assert(G1 >= 80 andalso G1 < 250),
    ?assert(G2 >= 170 andalso G2 < 350),
    ?assert(G3 >= 350 andalso G3 < 600),
    ?assert(lists:all(fun(G) -> G >= 350 andalso G < 600 end, Capped)),
    _ = chappe_sip_uac:await_response(Ref, 12000),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:log("timed out after ~p ms", [Took]),
    ?assert(Took >= 6300 andalso Took < 7500),
    ?assertEqual(6400, chappe_sip_config:get(proxy_accepted_ms)),
    ?assertEqual(6400, chappe_sip_config:get(ws_ack_timeout_ms)),
    gen_udp:close(S),
    %% a timer the app sets keeps its value; T1's default gives 32 s
    ok = chappe_sip:stop(),
    application:set_env(chappe_sip, proxy_accepted_ms, 1234),
    start(#{sip_timers => #{t1 => 2000}}),
    ?assertEqual(1234, chappe_sip_config:get(proxy_accepted_ms)),
    ?assertEqual(128000, chappe_sip_config:get(ws_ack_timeout_ms)),
    application:unset_env(chappe_sip, proxy_accepted_ms),
    ok = chappe_sip:stop(),
    start(#{}),
    ?assertEqual(32000, chappe_sip_config:get(proxy_accepted_ms)).

%% req: R3261-264
%% An INVITE over UDP is sent again after T1 (100 ms here), not after the
%% 1 s floor of the unpatched fork (sofia patch 0005).
timer_a_starts_at_t1(_Config) ->
    start(#{sip_timers => #{t1 => 100}}),
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, Port} = inet:port(S),
    {ok, _Ref} = chappe_sip:request(target(Port), #{method => <<"INVITE">>}),
    First = recv_udp(S, <<"INVITE">>),
    Second = recv_udp(S, <<"INVITE">>),
    ct:log("timer A gap ~p ms", [Second - First]),
    ?assert(Second - First < 500),
    gen_udp:close(S).

%% req: R3261-339
%% udp_mtu 576: a request of about 1500 bytes to a peer listening on UDP
%% and TCP arrives over TCP.
udp_mtu_moves_to_tcp(_Config) ->
    start(#{udp_mtu => 576}),
    {ok, L} = gen_tcp:listen(0, [binary, {ip, ?LO}, {active, false},
                                 {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    {ok, U} = gen_udp:open(Port, [binary, {ip, ?LO}, {active, true}]),
    {ok, _Ref} = chappe_sip:request(target(Port), #{
        method => <<"OPTIONS">>,
        headers => [{<<"X-Pad">>, binary:copy(<<"a">>, 1500)}]
    }),
    {ok, C} = gen_tcp:accept(L, 5000),
    {ok, Data} = gen_tcp:recv(C, 0, 5000),
    ?assertMatch(<<"OPTIONS ", _/binary>>, Data),
    receive
        {udp, U, _, _, _} -> ct:fail(sent_over_udp)
    after 0 -> ok
    end,
    gen_tcp:close(C),
    gen_tcp:close(L),
    gen_udp:close(U).

%% The CRLF keep-alive of RFC 5626 4.4.1, sent by the stack.
%% tcp_keepalive_ms: an idle TCP connection to the stack gets a CRLFCRLF
%% ping.
tcp_keepalive_pings(_Config) ->
    P = start(#{tcp_keepalive_ms => 1000}),
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    {ok, C} = gen_tcp:connect(?LO, P, [binary, {active, true}]),
    {ok, LPort} = inet:port(C),
    ok = gen_tcp:send(C, options(LPort, P)),
    receive
        {tcp, C, <<"SIP/2.0 200", _/binary>>} -> ok
    after 5000 -> ct:fail(no_response)
    end,
    receive
        {tcp, C, <<"\r\n\r\n">>} -> ok
    after 4000 -> ct:fail(no_keepalive)
    end,
    gen_tcp:close(C).

%% outbound_proxy: a request with no route of its own goes to the proxy,
%% its Request-URI unchanged.
outbound_proxy_takes_requests(_Config) ->
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, Port} = inet:port(S),
    start(#{outbound_proxy =>
                <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary,
                  ";transport=udp">>}),
    {ok, _Ref} = chappe_sip:request(<<"sip:far@192.0.2.99:5070">>,
                                    #{method => <<"OPTIONS">>}),
    receive
        {udp, S, _, _, <<"OPTIONS sip:far@192.0.2.99:5070 SIP/2.0", _/binary>>} ->
            ok
    after 5000 -> ct:fail(not_at_proxy)
    end,
    gen_udp:close(S).

%% req: R3261-003 R3261-004 R3261-038
%% outbound_route: a request with no route of its own carries the proxy as
%% a preloaded Route (RFC 3261 8.1.2), its Request-URI the target, and goes
%% to it; one sent with a proxy option of its own does not.
outbound_route_preloaded(_Config) ->
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, Port} = inet:port(S),
    PB = integer_to_binary(Port),
    start(#{outbound_route => <<"sip:127.0.0.1:", PB/binary, ";transport=udp">>}),
    {ok, _} = chappe_sip:request(<<"sip:far@192.0.2.99:5070">>,
                                 #{method => <<"OPTIONS">>}),
    Req = receive
              {udp, S, _, _, <<"OPTIONS sip:far@192.0.2.99:5070 SIP/2.0", _/binary>> = B} -> B
          after 5000 -> ct:fail(not_at_proxy)
          end,
    {ok, M} = chappe_sip_msg:parse(Req),
    ?assertEqual(<<"<sip:127.0.0.1:", PB/binary, ";transport=udp;lr>">>,
                 chappe_sip_msg:get(<<"route">>, M)),
    {ok, S2} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, Port2} = inet:port(S2),
    {ok, _} = chappe_sip:request(target(Port2),
                                 #{method => <<"OPTIONS">>, proxy => target(Port2)}),
    receive
        {udp, S2, _, _, <<"OPTIONS ", _/binary>> = B2} ->
            {ok, M2} = chappe_sip_msg:parse(B2),
            ?assertEqual(undefined, chappe_sip_msg:get(<<"route">>, M2))
    after 5000 -> ct:fail(not_sent)
    end,
    gen_udp:close(S),
    gen_udp:close(S2).

%% aliases: other names of the node, with or without a port, are its own
%% addresses (a Route naming one is ours to pop).
aliases_are_own(_Config) ->
    P = start(#{aliases => [<<"sbc.example.com">>,
                            <<"sip:edge.example.com:5099">>]}),
    PB = integer_to_binary(P),
    [?assert(chappe_sip_proxy_rules:is_own_address(U))
     || U <- [<<"sip:sbc.example.com:", PB/binary>>,
              <<"<sip:sbc.example.com:", PB/binary, ";lr>">>,
              <<"sip:edge.example.com:5099">>]],
    [?assertNot(chappe_sip_proxy_rules:is_own_address(U))
     || U <- [<<"sip:other.example.com:", PB/binary>>,
              <<"sip:edge.example.com:", PB/binary>>]].

%% Out of bounds or of the wrong shape: the start fails with the option;
%% outbound_route and outbound_proxy together are refused.
bad_options(_Config) ->
    [?assertEqual({error, {Key, V}},
                  chappe_sip:start(#{contact => contact(), Key => V}))
     || {Key, V} <- [
            {sip_timers, #{t1 => 5}},
            {sip_timers, #{t1 => 1000, t2 => 500}},
            {sip_timers, #{t2 => 100}},
            {sip_timers, #{t4 => 0}},
            {sip_timers, #{t3 => 100}},
            {sip_timers, [{t1, 100}]},
            {udp_mtu, 100},
            {udp_mtu, 70000},
            {tcp_keepalive_ms, 10},
            {tcp_keepalive_ms, infinity},
            {outbound_proxy, <<"http://proxy">>},
            {outbound_proxy, <<"sip:p", 0, ":5060">>},
            {outbound_proxy, "sip:proxy"},
            {outbound_route, <<"http://proxy">>},
            {outbound_route, <<"sip:p", 0, ":5060">>},
            {outbound_route, 42},
            {aliases, <<"sbc.example.com">>},
            {aliases, [<<"a b">>]},
            {aliases, [<<"sip:u@sbc.example.com">>]},
            {aliases, [<<"sbc.example.com;lr">>]},
            {aliases, lists:duplicate(17, <<"a.example.com">>)}
        ]],
    ?assertMatch({error, {outbound_route, {with_outbound_proxy, _}}},
                 chappe_sip:start(#{contact => contact(),
                                    outbound_proxy => <<"sip:a">>,
                                    outbound_route => <<"sip:b">>})).

%% ---- helpers ----

start(Opts) ->
    P = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(Opts#{contact => contact(P)}),
    P.

contact() ->
    contact(chappe_sip_test_port:pick()).

contact(P) ->
    <<"sip:127.0.0.1:", (integer_to_binary(P))/binary>>.

target(Port) ->
    <<"sip:peer@127.0.0.1:", (integer_to_binary(Port))/binary,
      ";transport=udp">>.

recv_udp(S) ->
    recv_udp(S, <<"OPTIONS">>).

recv_udp(S, Method) ->
    L = byte_size(Method),
    receive
        {udp, S, _, _, <<M:L/binary, " ", _/binary>>} when M =:= Method ->
            erlang:monotonic_time(millisecond)
    after 3000 -> ct:fail({no_request, Method})
    end.

options(LPort, P) ->
    iolist_to_binary([
        "OPTIONS sip:x@127.0.0.1:", integer_to_binary(P), ";transport=tcp",
        " SIP/2.0\r\n",
        "Via: SIP/2.0/TCP 127.0.0.1:", integer_to_binary(LPort),
        ";branch=z9hG4bKka", integer_to_binary(erlang:unique_integer([positive])),
        "\r\n",
        "Max-Forwards: 70\r\n",
        "From: <sip:ka@127.0.0.1>;tag=ka1\r\n",
        "To: <sip:x@127.0.0.1>\r\n",
        "Call-ID: ka-", integer_to_binary(erlang:unique_integer([positive])),
        "\r\n",
        "CSeq: 1 OPTIONS\r\n",
        "Content-Length: 0\r\n\r\n"
    ]).
