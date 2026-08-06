%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Forking proxy.
%%
%% A gen_udp caller sends an INVITE to the app; the app proxies it to one
%% or two gen_udp UAS peers.
-module(chappe_sip_proxy_forking_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([proxy_parallel_first_wins/1, proxy_serial_failover/1,
         proxy_single_200/1, proxy_parallel_6xx_cancels/1]).

all() ->
    [proxy_single_200, proxy_serial_failover, proxy_parallel_first_wins,
     proxy_parallel_6xx_cancels].

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

%% single destination answers 200 -> relayed to caller
proxy_single_200(_Config) ->
    {EP, [D1]} = setup(1),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1)], #{}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                             [{<<"Contact">>, ctc(D1)}], sdp()))
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"pft">>)),
        R = recv_status(Sock, 200),
        {_, _} = binary:match(R, <<"v=0">>),
        Test ! caller_got_200
    end),
    ok = expect(caller_got_200),
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% serial: dest1 486, fail over to dest2 200
proxy_serial_failover(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => sequential}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>)),
        Test ! d1_busy
    end),
    uas(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                             [{<<"Contact">>, ctc(D2)}], sdp())),
        Test ! d2_answered
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"psf">>)),
        _ = recv_status(Sock, 200),
        Test ! caller_got_200
    end),
    ok = expect(d1_busy),
    ok = expect(d2_answered),
    ok = expect(caller_got_200),
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% parallel: both ring, dest1 answers 200 first, dest2 gets CANCELled
proxy_parallel_first_wins(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => parallel}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        timer:sleep(150),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, tag(),
                             [{<<"Contact">>, ctc(D1)}], sdp())),
        Test ! d1_answered
    end),
    uas(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {_Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(_Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! d2_cancelled
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"ppf">>)),
        _ = recv_status(Sock, 200),
        Test ! caller_got_200
    end),
    ok = expect(d1_answered),
    ok = expect(d2_cancelled),
    ok = expect(caller_got_200),
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% F13: a 6xx from one branch is a global failure that cancels the other
%% branches and is relayed upstream (RFC 3261 16.7).
proxy_parallel_6xx_cancels(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => parallel}),
        Test ! {proxy_done, R}
    end),
    uas(D1, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        timer:sleep(100),
        send(Sock, Src, resp(Inv, 603, <<"Decline">>, tag(), [], <<>>)),
        Test ! d1_declined
    end),
    uas(D2, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {_Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(_Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! d2_cancelled
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"p6x">>)),
        _ = recv_status(Sock, 603),
        Test ! caller_got_603
    end),
    ok = expect(d1_declined),
    ok = expect(d2_cancelled),
    ok = expect(caller_got_603),
    receive {proxy_done, {ok, #{final_status := 603}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% ---- peers ----

setup(N) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    {EP, [pick() || _ <- lists:seq(1, N)]}.

uas(Port, Fun) -> peer(Port, Fun).
caller(Fun) -> peer(0, Fun).

peer(Port, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(Port, [binary, {active, true},
                                         {ip, {127,0,0,1}}]),
        Parent ! {peer_ready, self()},
        Fun(Sock)
    end),
    receive {peer_ready, Pid} -> ok after 2000 -> ct:fail(peer_not_ready) end,
    Pid.

expect(Msg) ->
    receive Msg -> ok after 6000 -> ct:fail({expected, Msg}) end.

%% ---- SIP helpers ----

pick() -> 40000 + rand:uniform(20000).
dest(P) -> <<"127.0.0.1:", (integer_to_binary(P))/binary>>.
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"m6-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, DstPort, Bin) -> gen_udp:send(Sock, {127,0,0,1}, DstPort, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method ->
            {Bin, Src};
        {udp, Sock, _, _, _} -> recv(Sock, Method)
    after 6000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                _ -> recv_status(Sock, Code)   % skip provisionals/others
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

invite(Sock, Call, FT) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:callee@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:callee@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case chappe_sip_msg:to_tag(Msg) of
             undefined when Status > 100 -> <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines, <<"From: ">>, From, <<"\r\n">>, <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>, Extra,
       <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).
