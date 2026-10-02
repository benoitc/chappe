%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Transport duties on the wire over UDP: 100 Trying from the INVITE server
%% transaction (RFC 3261 17.2.1) and symmetric response routing (RFC 3581)
%% for requests we receive and requests we send.
-module(chappe_sip_transport_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([trying_within_200ms/1, no_trying_for_non_invite/1,
         rport_filled_in/1, response_to_source_port/1,
         rport_on_our_requests/1, timestamp_delay_seconds/1]).

all() ->
    [trying_within_200ms, no_trying_for_non_invite, rport_filled_in,
     response_to_source_port, rport_on_our_requests, timestamp_delay_seconds].

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

%% The app takes a second to answer: the server transaction still sends
%% 100 Trying within 200 ms, for the same transaction, with no To tag
%% added and the request's Timestamp copied.
%% req: R3261-309 R3261-310 R3261-101
trying_within_200ms(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(Req, Res) ->
        timer:sleep(1000),
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
    end),
    {ok, LP} = inet:port(Sock),
    Branch = branch(),
    T0 = erlang:monotonic_time(millisecond),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port,
                      invite(LP, LP, Branch, <<";rport">>)),
    First = recv(Sock, 900),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ct:log("first response after ~p ms:~n~s", [Elapsed, First]),
    ?assertMatch(<<"SIP/2.0 100 ", _/binary>>, First),
    ?assert(Elapsed =< 200, {late_100, Elapsed}),
    {ok, M} = chappe_sip_msg:parse(First),
    ?assertEqual(<<"1 INVITE">>, chappe_sip_msg:get(<<"cseq">>, M)),
    ?assertEqual(undefined, chappe_sip_msg:to_tag(M)),
    %% copied, with the delay value 8.2.6.1 lets the UAS append: the 100
    %% left at once, so well under 0.2 s
    TS = chappe_sip_msg:get(<<"timestamp">>, M),
    ?assertMatch(<<"54", _/binary>>, TS),
    ?assert(timestamp_delay(TS) < 0.2, {delay, TS}),
    ?assertNotEqual(nomatch,
                    binary:match(chappe_sip_msg:get(<<"via">>, M), Branch)).

%% The immediate 100 is for INVITE only: a non-INVITE answered late gets
%% its final response first (RFC 3261 17.2.2 sends no provisional before
%% the TU does).
no_trying_for_non_invite(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) ->
        timer:sleep(600),
        chappe_sip_res:send(Res, 200)
    end),
    {ok, LP} = inet:port(Sock),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, options(LP, branch())),
    ?assertMatch(<<"SIP/2.0 200 ", _/binary>>, recv(Sock, 2000)).

%% The app answers an OPTIONS carrying a Timestamp after 600 ms: the
%% response copies the Timestamp with a delay, in seconds, between the
%% request's arrival and the response (8.2.6.1).
%% req: R3261-103
timestamp_delay_seconds(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) ->
        timer:sleep(600),
        chappe_sip_res:send(Res, 200)
    end),
    {ok, LP} = inet:port(Sock),
    Opt = binary:replace(options(LP, branch()), <<"CSeq: 1 OPTIONS\r\n">>,
                         <<"CSeq: 1 OPTIONS\r\nTimestamp: 54.25\r\n">>),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, Opt),
    {ok, M} = chappe_sip_msg:parse(recv(Sock, 3000)),
    ?assertEqual(200, chappe_sip_msg:status(M)),
    TS = chappe_sip_msg:get(<<"timestamp">>, M),
    ct:log("Timestamp: ~s", [TS]),
    ?assertMatch(<<"54.25 ", _/binary>>, TS),
    Delay = timestamp_delay(TS),
    ?assert(Delay >= 0.5 andalso Delay =< 1.0, {delay, Delay}).

%% A request whose Via carries an empty rport gets it filled with the
%% source port in the response (RFC 3581 4).
%% req: R3581-009
rport_filled_in(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    {ok, LP} = inet:port(Sock),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, options(LP, branch())),
    {ok, M} = chappe_sip_msg:parse(recv(Sock, 2000)),
    Via = chappe_sip_msg:get(<<"via">>, M),
    ct:log("response Via: ~s", [Via]),
    ?assertNotEqual(nomatch,
                    binary:match(Via, <<"rport=", (integer_to_binary(LP))/binary>>)).

%% The Via sent-by names a port nobody listens on; with rport the response
%% still comes back to the port the request came from (RFC 3581 4).
%% req: R3581-011 R3581-012
response_to_source_port(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    {ok, LP} = inet:port(Sock),
    Dead = chappe_sip_test_port:pick(),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port,
                      options(LP, Dead, branch(), <<";rport">>)),
    ?assertMatch(<<"SIP/2.0 200 ", _/binary>>, recv(Sock, 2000)).

%% Our own UDP requests carry an empty rport in the top Via, and the
%% response sent back to the source address and port is taken (RFC 3581 3).
%% req: R3581-001 R3581-002 R3581-003
rport_on_our_requests(Config) ->
    Sock = ?config(sock, Config),
    {ok, LP} = inet:port(Sock),
    Uri = <<"sip:ping@127.0.0.1:", (integer_to_binary(LP))/binary>>,
    {ok, Ref} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>}),
    {Req, {Ip, SrcPort}} =
        receive
            {udp, Sock, I, P, Bin} -> {Bin, {I, P}}
        after 2000 -> ct:fail(no_request)
        end,
    {ok, M} = chappe_sip_msg:parse(Req),
    Via = chappe_sip_msg:get(<<"via">>, M),
    ct:log("request Via: ~s", [Via]),
    ?assertMatch({match, _}, re:run(Via, ";\\s*rport(;|$)")),
    ok = gen_udp:send(Sock, Ip, SrcPort, ok_to(M)),
    {ok, Resp} = chappe_sip_uac:await_response(Ref, 4000),
    ?assertEqual(200, chappe_sip_msg:status(Resp)).

%% ---- helpers ----

%% the delay of a Timestamp value ("54 0.000120"), in seconds
timestamp_delay(TS) ->
    [_, D] = binary:split(string:trim(TS), <<" ">>),
    binary_to_float(string:trim(D)).

ok_to(M) ->
    H = fun(N) -> chappe_sip_msg:get(N, M) end,
    <<"SIP/2.0 200 OK\r\n"
      "Via: ", (H(<<"via">>))/binary, "\r\n"
      "From: ", (H(<<"from">>))/binary, "\r\n"
      "To: ", (H(<<"to">>))/binary, ";tag=tr3\r\n"
      "Call-ID: ", (H(<<"call-id">>))/binary, "\r\n"
      "CSeq: ", (H(<<"cseq">>))/binary, "\r\n"
      "Content-Length: 0\r\n\r\n">>.

contact(P) -> <<"sip:127.0.0.1:", (integer_to_binary(P))/binary>>.

branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

recv(Sock, Timeout) ->
    receive
        {udp, Sock, _, _, Bin} -> Bin
    after Timeout -> ct:fail(no_message)
    end.

invite(LP, SentBy, Branch, Rport) ->
    P = integer_to_binary(LP),
    S = sdp(),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", (integer_to_binary(SentBy))/binary,
      Rport/binary, ";branch=", Branch/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:caller@127.0.0.1:", P/binary, ">;tag=tr1\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", (branch())/binary, "@127.0.0.1\r\n"
      "CSeq: 1 INVITE\r\n"
      "Timestamp: 54\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", (integer_to_binary(byte_size(S)))/binary, "\r\n\r\n",
      S/binary>>.

options(LP, Branch) ->
    options(LP, LP, Branch, <<";rport">>).

options(LP, SentBy, Branch, Rport) ->
    P = integer_to_binary(LP),
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", (integer_to_binary(SentBy))/binary,
      Rport/binary, ";branch=", Branch/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:caller@127.0.0.1:", P/binary, ">;tag=tr2\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: ", (branch())/binary, "@127.0.0.1\r\n"
      "CSeq: 1 OPTIONS\r\n"
      "Content-Length: 0\r\n\r\n">>.
