%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% What the stack answers out of dialog when the app registered no handler
%% for the method: OPTIONS is answered 200 with our capabilities (RFC 3261
%% 11), a known method gets 405 and an unknown one 501 (21.4.5, 21.5.2).
-module(chappe_sip_ood_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([options_default/1, options_default_events/1,
         options_handler_wins/1, unknown_method_501/1,
         known_method_405/1]).

all() ->
    [options_default, options_default_events, options_handler_wins,
     unknown_method_501, known_method_405].

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
    Port = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => contact(Port)}),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true},
                                  {ip, {127, 0, 0, 1}}]),
    [{port, Port}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    gen_udp:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- cases ----

%% No OPTIONS handler: 200 with Allow (the methods we take), Accept and
%% Supported, the status an INVITE would get from a UA that is up.
%% req: R3261-O-001 R3261-O-006 R3261-O-007
options_default(Config) ->
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 486) end),
    M = ask(Config, <<"OPTIONS">>),
    ?assertEqual(200, chappe_sip_msg:status(M)),
    Allow = tokens(chappe_sip_msg:get(<<"allow">>, M)),
    [?assert(lists:member(T, Allow), {missing, T})
     || T <- [<<"INVITE">>, <<"ACK">>, <<"CANCEL">>, <<"BYE">>, <<"OPTIONS">>]],
    ?assertEqual(<<"application/sdp">>, chappe_sip_msg:get(<<"accept">>, M)),
    ?assert(lists:member(<<"replaces">>,
                         tokens(chappe_sip_msg:get(<<"supported">>, M)))),
    ?assertEqual(undefined, chappe_sip_msg:get(<<"allow-events">>, M)).

%% A notifier with a package list names its packages in Allow-Events on
%% the OPTIONS 200 (RFC 6665 4.4.4).
%% req: R6665-16 R6665-27
options_default_events(Config) ->
    ok = chappe_sip:subscribe([<<"conference">>], fun(_Req, Res) ->
        chappe_sip_res:send(Res, 403)
    end),
    M = ask(Config, <<"OPTIONS">>),
    ?assertEqual(200, chappe_sip_msg:status(M)),
    ?assertEqual(<<"conference">>, chappe_sip_msg:get(<<"allow-events">>, M)),
    ?assert(lists:member(<<"SUBSCRIBE">>,
                         tokens(chappe_sip_msg:get(<<"allow">>, M)))).

%% An app that registers OPTIONS answers it itself.
options_handler_wins(Config) ->
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 480) end),
    ?assertEqual(480, chappe_sip_msg:status(ask(Config, <<"OPTIONS">>))).

%% A method we do not recognise: 501, with Allow.
%% req: R3261-21.5.2-1 R3261-070
unknown_method_501(Config) ->
    M = ask(Config, <<"FROBNICATE">>),
    ?assertEqual(501, chappe_sip_msg:status(M)),
    ?assertNotEqual(undefined, chappe_sip_msg:get(<<"allow">>, M)).

%% A method we recognise but take no handler for: 405 with Allow.
%% req: R3261-071 R3261-072 R3261-426 R3261-070 R3261-485
known_method_405(Config) ->
    M = ask(Config, <<"MESSAGE">>),
    ?assertEqual(405, chappe_sip_msg:status(M)),
    ?assertNotEqual(undefined, chappe_sip_msg:get(<<"allow">>, M)),
    ?assertNot(lists:member(<<"MESSAGE">>,
                            tokens(chappe_sip_msg:get(<<"allow">>, M)))).

%% ---- helpers ----

contact(P) -> <<"sip:127.0.0.1:", (integer_to_binary(P))/binary>>.

ask(Config, Method) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {ok, LP} = inet:port(Sock),
    P = integer_to_binary(LP),
    Req = <<Method/binary, " sip:app@127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bK",
            (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary, "\r\n"
            "Max-Forwards: 70\r\n"
            "From: <sip:caller@127.0.0.1:", P/binary, ">;tag=od1\r\n"
            "To: <sip:app@127.0.0.1>\r\n"
            "Call-ID: od-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary,
            "@127.0.0.1\r\n"
            "CSeq: 1 ", Method/binary, "\r\n"
            "Content-Length: 0\r\n\r\n">>,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, Req),
    final(Sock).

final(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} ->
            final(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            ct:log("~s", [Bin]),
            M
    after 4000 -> ct:fail(no_response)
    end.

tokens(undefined) ->
    [];
tokens(V) ->
    [string:trim(T) || T <- binary:split(V, <<",">>, [global])].
