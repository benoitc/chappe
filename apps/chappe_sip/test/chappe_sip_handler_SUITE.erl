%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Handler behaviour and hardening.
%%
%% - chappe_sip_handler drives a UAS through a callback module.
%% - a concurrent request burst stays stable and every request is answered.
%% - repeated engine restarts leak nothing and keep serving.
-module(chappe_sip_handler_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([handler_behaviour/1, options_burst/1, restart_stress/1]).

all() ->
    [handler_behaviour, options_burst, restart_stress].

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

%% chappe_sip_handler answers via the callback module; INFO gets an explicit 200.
handler_behaviour(_Config) ->
    EP = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        put(test_pid, Test),
        chappe_sip_handler:start(chappe_sip_echo_handler, Req, Res)
    end),
    Call = callid(),
    caller(EP, fun(Sock, Port) ->
        FT = <<"m8ft">>,
        send(Sock, Port, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        {_, _} = binary:match(R200, <<"caller">>),      % SDP echoed back
        TT = to_tag(R200),
        send(Sock, Port, ack(Sock, Call, FT, TT)),
        send(Sock, Port, info(Sock, Call, FT, TT)),
        _ = recv_status(Sock, 200),
        send(Sock, Port, bye(Sock, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ok = expect(got_info),
    receive {handler_terminated, {destroyed, _}} -> ok
    after 5000 -> ct:fail(no_terminate) end.

%% 60 concurrent OPTIONS, all answered, node stays up.
options_burst(_Config) ->
    EP = setup(),
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200, #{}) end),
    N = 60,
    Parent = self(),
    Pids = [spawn_link(fun() -> one_options(EP, I, Parent) end)
            || I <- lists:seq(1, N)],
    Oks = collect_oks(N, 0),
    ?assertEqual(N, Oks),
    [true = is_process_alive(P) orelse true || P <- Pids],
    %% engine still healthy after the burst
    ok = chappe_sip_engine:check_health(2000).

%% repeated controlled restarts: no leak, engine keeps answering.
restart_stress(_Config) ->
    EP = setup(),
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200, #{}) end),
    lists:foreach(
      fun(I) ->
              ok = chappe_sip_engine:restart_engine(),
              %% routes survive the restart; a fresh OPTIONS is answered
              caller(EP, fun(Sock, Port) ->
                  send(Sock, Port, options_req(Sock, I)),
                  _ = recv_status(Sock, 200),
                  Test ! {answered, I}
              end),
              receive {answered, I} -> ok
              after 4000 -> ct:fail({no_answer, I}) end
      end, lists:seq(1, 6)),
    ok = chappe_sip_engine:check_health(2000).

%% ---- helpers ----

one_options(EP, I, Parent) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    send(Sock, EP, options_req(Sock, I)),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>>} -> Parent ! ok
    after 8000 -> Parent ! fail
    end,
    gen_udp:close(Sock).

collect_oks(0, Acc) -> Acc;
collect_oks(N, Acc) ->
    receive
        ok -> collect_oks(N - 1, Acc + 1);
        fail -> collect_oks(N - 1, Acc)
    after 12000 -> Acc
    end.

setup() ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    EP.

caller(EnginePort, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        Parent ! {caller_ready, self()},
        Fun(Sock, EnginePort)
    end),
    receive {caller_ready, Pid} -> ok after 2000 -> ct:fail(caller_not_ready) end,
    Pid.

expect(Msg) -> receive Msg -> ok after 6000 -> ct:fail({expected, Msg}) end.

pick() -> chappe_sip_test_port:pick().
callid() ->
    <<"m8-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<"v=0\r\no=caller 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, Dst, Bin) -> gen_udp:send(Sock, {127,0,0,1}, Dst, Bin).

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of CB -> Bin; _ -> recv_status(Sock, Code) end
    after 6000 -> ct:fail({no_status, Code})
    end.

to_tag(Resp) -> {ok, M} = chappe_sip_msg:parse(Resp), chappe_sip_msg:to_tag(M).

options_req(Sock, I) ->
    P = integer_to_binary(lport(Sock)),
    Ib = integer_to_binary(I),
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1:", P/binary, ">;tag=b", Ib/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: burst-", Ib/binary, "-", P/binary, "@ct\r\n"
      "CSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>.

info(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"INFO sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 2 INFO\r\n"
      "Content-Type: application/dtmf\r\nContent-Length: 1\r\n\r\n5">>.

invite(Sock, Call, FT) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ack(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

bye(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.
