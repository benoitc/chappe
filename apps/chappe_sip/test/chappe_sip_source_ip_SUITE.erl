%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The engine surfaces the wire source address of an inbound request to the
%% handler via chappe_sip_req:source_ip/1 (the trust anchor for a source-IP ACL). A
%% UDP peer sends OPTIONS from loopback; the handler must see 127.0.0.1 and a
%% real source port.
-module(chappe_sip_source_ip_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([source_ip_reported/1]).

all() ->
    [source_ip_reported].

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

source_ip_reported(_Config) ->
    EP = 40000 + rand:uniform(20000),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    Test = self(),
    ok = chappe_sip:options(fun(Req, Res) ->
        Test ! {src, chappe_sip_req:source_ip(Req), chappe_sip_req:source_port(Req)},
        _ = chappe_sip_res:send(Res, 200),
        ok
    end),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, LP} = inet:port(Sock),
    LPB = integer_to_binary(LP),
    Br = binary:encode_hex(crypto:strong_rand_bytes(6), lowercase),
    Msg = <<"OPTIONS sip:127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 127.0.0.1:", LPB/binary, ";rport;branch=z9hG4bK",
            Br/binary, "\r\nMax-Forwards: 70\r\n"
            "From: <sip:probe@127.0.0.1:", LPB/binary, ">;tag=si1\r\n"
            "To: <sip:127.0.0.1>\r\n"
            "Call-ID: si-", Br/binary, "@ct\r\nCSeq: 1 OPTIONS\r\n"
            "Content-Length: 0\r\n\r\n">>,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Msg),
    receive
        {src, Ip, Port} ->
            ?assertEqual(<<"127.0.0.1">>, Ip),
            ?assertEqual(LP, Port)
    after 6000 ->
        ct:fail(no_source)
    end.
