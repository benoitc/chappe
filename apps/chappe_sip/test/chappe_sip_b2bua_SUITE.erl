%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% B2BUA.
%%
%% A gen_udp "caller" (UAC) calls the app; the app bridges to a gen_udp
%% "callee" (UAS). Both peers own their own sockets.
-module(chappe_sip_b2bua_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([b2b_success_bye/1, b2b_callee_busy/1, b2b_caller_cancel/1,
         b2b_survives_deadline/1, b2b_rings_past_deadline/1,
         b2b_timer_c_408/1, b2b_timer_c_restarted/1]).

all() ->
    [b2b_success_bye, b2b_callee_busy, b2b_caller_cancel,
     b2b_survives_deadline, b2b_rings_past_deadline, b2b_timer_c_408,
     b2b_timer_c_restarted].

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
    application:unset_env(chappe_sip, handler_deadline_ms),
    application:unset_env(chappe_sip, timer_c_ms),
    ok.

%% caller INVITE -> app b2bua -> callee; 180 relayed, 200 bridged, ACK both
%% ways; caller BYE tears down both legs.
b2b_success_bye(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! b2b_up,
        {done, Why} = chappe_sip_b2b:relay(Legs),
        Test ! {relay_done, Why}
    end),
    %% callee peer
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        {_, _} = binary:match(Inv, <<"v=0">>),         % offer relayed
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! callee_acked,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! callee_byed
    end),
    %% caller peer drives the A leg and asserts
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cft">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        _R180 = recv_status(Sock, 180),
        R200 = recv_status(Sock, 200),
        {_, _} = binary:match(R200, <<"callee">>),      % callee answer bridged
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        Test ! caller_acked,
        %% let the media flow, then hang up
        timer:sleep(200),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200),
        Test ! caller_byed
    end),
    ok = expect(b2b_up),
    ok = expect(callee_acked),
    ok = expect(caller_acked),
    ok = expect(caller_byed),
    ok = expect(callee_byed),
    ok = expect({relay_done, a_bye}).

%% a b2bua call held longer than handler_deadline_ms must survive: the worker
%% owns the dialog and blocks in relay/1, so its handler deadline is disarmed.
%% With the bug it is killed mid-call and neither BYE nor relay_done arrive.
b2b_survives_deadline(_Config) ->
    application:set_env(chappe_sip, handler_deadline_ms, 300),
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! b2b_up,
        {done, Why} = chappe_sip_b2b:relay(Legs),
        Test ! {relay_done, Why}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        ToTag = tag(),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! callee_acked,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! callee_byed
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cftd">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        Test ! caller_acked,
        %% hold the call well past the 300ms handler deadline, then hang up
        timer:sleep(900),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200),
        Test ! caller_byed
    end),
    ok = expect(b2b_up),
    ok = expect(callee_acked),
    ok = expect(caller_acked),
    ok = expect(caller_byed),
    ok = expect(callee_byed),
    ok = expect({relay_done, a_bye}).

%% B rings longer than the handler deadline before it answers: the worker
%% waits on the B-leg UAC, which owns the call, so its deadline is disarmed
%% and A gets the 200, not a 500.
b2b_rings_past_deadline(_Config) ->
    application:set_env(chappe_sip, handler_deadline_ms, 600),
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! b2b_up,
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        ToTag = tag(),
        [begin
             send(Sock, Src, resp(Inv, 180, <<"Ringing">>, ToTag, [], <<>>)),
             timer:sleep(400)
         end || _ <- lists:seq(1, 4)],
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cftr">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R = recv_final(Sock),
        Test ! {caller_final, status_of(R)},
        TT = to_tag(R),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ok = expect(b2b_up),
    ok = expect({caller_final, 200}).

%% Timer C on the B leg (RFC 3261 16.8): B sends one 180 and then nothing;
%% when Timer C fires B is CANCELled and A gets a 408.
%% req: R3261-P-019
b2b_timer_c_408(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{timer_c => 500}),
        Test ! {b2b_result, R}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>)),
        Test ! callee_cancelled
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"cftc">>)),
        R = recv_final(Sock),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"cftc">>, R)),
        Test ! {caller_final, status_of(R)}
    end),
    ok = expect(callee_cancelled),
    ok = expect({caller_final, 408}),
    receive {b2b_result, {error, timeout}} -> ok
    after 5000 -> ct:fail(no_b2b_timeout)
    end.

%% Each provisional restarts Timer C: B rings for three times the timer
%% with a 180 every 300 ms and still connects.
%% req: R3261-P-018
b2b_timer_c_restarted(_Config) ->
    application:set_env(chappe_sip, timer_c_ms, 600),
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        ToTag = tag(),
        [begin
             send(Sock, Src, resp(Inv, 180, <<"Ringing">>, ToTag, [], <<>>)),
             timer:sleep(300)
         end || _ <- lists:seq(1, 6)],
        send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                             [{<<"Contact">>, ctc(CalleePort)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cftk">>,
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, FT)),
        R = recv_final(Sock),
        Test ! {caller_final, status_of(R)},
        TT = to_tag(R),
        send(Sock, EnginePort, ack(Sock, EnginePort, Call, FT, TT)),
        send(Sock, EnginePort, bye(Sock, EnginePort, Call, FT, TT)),
        _ = recv_status(Sock, 200)
    end),
    ok = expect({caller_final, 200}).

%% callee 486 -> caller gets 486 (pass_failure default true)
b2b_callee_busy(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! {b2b_result, R}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 486, <<"Busy Here">>, tag(), [], <<>>))
    end),
    caller(fun(Sock) ->
        Call = callid(),
        send(Sock, EnginePort, invite(Sock, EnginePort, Call, <<"cft2">>)),
        R = recv_status(Sock, 486),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, <<"cft2">>, R)),
        Test ! caller_got_486
    end),
    ok = expect(caller_got_486),
    receive
        {b2b_result, {error, #chappe_sip_error{status = 486}}} -> ok
    after 5000 -> ct:fail(no_b2b_failure)
    end.

%% caller CANCEL while callee rings -> callee gets CANCEL, caller gets 487
b2b_caller_cancel(_Config) ->
    {EnginePort, CalleePort} = setup(),
    Test = self(),
    CalleeUri = <<"sip:callee@127.0.0.1:", (integer_to_binary(CalleePort))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        R = chappe_sip:create_b2bua(Req, Res, CalleeUri, #{}),
        Test ! {b2b_result, R}
    end),
    callee(CalleePort, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 180, <<"Ringing">>, tag(), [], <<>>)),
        Test ! callee_ringing,
        {Cancel, CSrc} = recv(Sock, <<"CANCEL">>),
        send(Sock, CSrc, resp(Cancel, 200, <<"OK">>, tag(), [], <<>>)),
        send(Sock, Src, resp(Inv, 487, <<"Request Terminated">>, tag(), [], <<>>)),
        Test ! callee_cancelled
    end),
    caller(fun(Sock) ->
        Call = callid(),
        FT = <<"cft3">>,
        Br = branch(),
        send(Sock, EnginePort, invite_br(Sock, Call, FT, Br)),
        _ = recv_status(Sock, 180),
        Test ! caller_ringing,
        %% CANCEL must reuse the INVITE's branch (RFC 3261 9.1)
        send(Sock, EnginePort, cancel_br(Sock, Call, FT, Br)),
        R = recv_status(Sock, 487),
        send(Sock, EnginePort, ack_status(Sock, EnginePort, Call, FT, R)),
        Test ! caller_got_487
    end),
    ok = expect(callee_ringing),
    ok = expect(caller_ringing),
    ok = expect(callee_cancelled),
    ok = expect(caller_got_487),
    receive
        {b2b_result, {error, cancelled}} -> ok
    after 5000 -> ct:fail(no_cancel_result)
    end.

%% ---- peers ----

setup() ->
    EnginePort = pick(),
    CalleePort = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EnginePort))/binary>>}),
    {EnginePort, CalleePort}.

callee(Port, Fun) -> peer(Port, Fun).

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

pick() -> chappe_sip_test_port:pick().
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"m5-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp(Marker) ->
    <<"v=0\r\no=", Marker/binary, " 0 0 IN IP4 127.0.0.1\r\ns=-\r\n"
      "c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

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
                <<"100">> -> recv_status(Sock, Code);
                _ -> recv_status(Sock, Code)   % skip other provisionals
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

to_tag(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).

%% the first final response
recv_final(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} -> recv_final(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} -> Bin;
        {udp, Sock, _, _, _} -> recv_final(Sock)
    after 6000 -> ct:fail(no_final)
    end.

status_of(<<"SIP/2.0 ", C:3/binary, _/binary>>) -> binary_to_integer(C).

invite(Sock, _EP, Call, FT) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(<<"caller">>),
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

ack(Sock, _EP, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

%% ACK for a non-2xx final: To tag comes from the response
ack_status(Sock, _EP, Call, FT, Resp) ->
    TT = case to_tag_of(Resp) of undefined -> <<>>; T -> <<";tag=", T/binary>> end,
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

bye(Sock, _EP, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% INVITE and its CANCEL share a caller-chosen branch.
invite_br(Sock, Call, FT, Br) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(<<"caller">>),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", Br/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

cancel_br(Sock, Call, FT, Br) ->
    P = integer_to_binary(lport(Sock)),
    <<"CANCEL sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", Br/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 CANCEL\r\nContent-Length: 0\r\n\r\n">>.

to_tag_of(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).

%% Build a response echoing Via/From/Call-ID/CSeq; add To tag if absent.
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
