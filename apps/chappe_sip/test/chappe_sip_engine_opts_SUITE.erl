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
-export([t1_sets_retransmissions/1, udp_mtu_moves_to_tcp/1,
         tcp_keepalive_pings/1, outbound_proxy_takes_requests/1,
         aliases_are_own/1, bad_options/1]).

-define(LO, {127, 0, 0, 1}).

all() ->
    [t1_sets_retransmissions, udp_mtu_moves_to_tcp, tcp_keepalive_pings,
     outbound_proxy_takes_requests, aliases_are_own, bad_options].

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

%% req: RFC3261-17.1.2.2 T1 sets the first retransmit interval of a
%% non-INVITE client transaction, and Timer F is 64*T1
%% req: RFC3261-17.1.2.2 the client transaction MUST set timer E to fire
%% in T1 seconds
%% With T1 at 100 ms and T2 at 400 ms the first copy is sent again after
%% about T1 (sofia patch 0005: the fork waited at least 1 s), the
%% interval is capped at T2, and the request times out after 64*T1 =
%% 6.4 s instead of 32.
t1_sets_retransmissions(_Config) ->
    start(#{sip_timers => #{t1 => 100, t2 => 400}}),
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, Port} = inet:port(S),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Ref} = chappe_sip:request(target(Port), #{method => <<"OPTIONS">>}),
    First = recv_udp(S),
    Second = recv_udp(S),
    Third = recv_udp(S),
    ct:log("retransmit gaps ~p ms, ~p ms", [Second - First, Third - Second]),
    ?assert(Second - First < 500),
    ?assert(Third - Second < 900),
    _ = chappe_sip_uac:await_response(Ref, 12000),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:log("timed out after ~p ms", [Took]),
    ?assert(Took < 12000),
    gen_udp:close(S).

%% req: RFC3261-18.1.1 a request larger than the path MTU goes over a
%% congestion-controlled transport
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

%% req: RFC5626-4.4.1 the CRLF keep-alive: a double-CRLF ping on a
%% connection-oriented transport
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

%% Out of bounds or of the wrong shape: the start fails with the option.
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
            {aliases, <<"sbc.example.com">>},
            {aliases, [<<"a b">>]},
            {aliases, [<<"sip:u@sbc.example.com">>]},
            {aliases, [<<"sbc.example.com;lr">>]},
            {aliases, lists:duplicate(17, <<"a.example.com">>)}
        ]].

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
    receive
        {udp, S, _, _, <<"OPTIONS ", _/binary>>} ->
            erlang:monotonic_time(millisecond)
    after 3000 -> ct:fail(no_request)
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
