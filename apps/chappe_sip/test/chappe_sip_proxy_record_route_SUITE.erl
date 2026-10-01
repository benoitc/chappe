%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Proxy record-route in-dialog forwarding.
%%
%% A caller and a callee talk through a record-routing proxy. After the proxy
%% inserts Record-Route on the INVITE, the endpoints loose-route their
%% in-dialog requests back through it: the 2xx ACK, a BYE from either side,
%% and a re-INVITE. Each must be forwarded to the far end and its responses
%% relayed back.
-module(chappe_sip_proxy_record_route_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([record_route_call/1, callee_bye/1, reinvite_through_proxy/1,
         forged_route_marker_not_relayed/1]).

all() ->
    [record_route_call, callee_bye, reinvite_through_proxy,
     forged_route_marker_not_relayed].

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

%% Full call through the proxy: caller INVITE, callee 200, caller ACK and BYE
%% both routed via the proxy's Record-Route.
record_route_call(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    proxy_app(CP),
    Call = callid(),
    FT = <<"m9a">>,

    peer(CP, fun(Sock) ->
        {Inv, PSrc} = recv(Sock, <<"INVITE">>),
        RR = record_route_of(Inv),
        send(Sock, PSrc, resp(Inv, 200, <<"OK">>, tag(),
                              [{<<"Contact">>, ctc(CP)},
                               {<<"Record-Route">>, RR}], sdp())),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! callee_got_ack,
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! callee_got_bye
    end),

    peer(0, fun(Sock) ->
        send(Sock, EP, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        RR = record_route_of(R200),
        Callee = contact_of(R200),
        send(Sock, EP, ack(Sock, Call, FT, TT, RR, Callee, 1)),
        send(Sock, EP, bye(Sock, Call, FT, TT, RR, Callee, 2)),
        _ = recv_status(Sock, 200),
        Test ! caller_got_bye_200
    end),

    ok = expect(callee_got_ack),
    ok = expect(callee_got_bye),
    ok = expect(caller_got_bye_200).

%% The callee tears the call down: its BYE routes back through the proxy to
%% the caller, and the 200 returns.
callee_bye(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    proxy_app(CP),
    Call = callid(),
    FT = <<"m9b">>,

    peer(CP, fun(Sock) ->
        {Inv, PSrc} = recv(Sock, <<"INVITE">>),
        RR = record_route_of(Inv),
        Caller = contact_of(Inv),
        CTag = tag(),
        send(Sock, PSrc, resp(Inv, 200, <<"OK">>, CTag,
                              [{<<"Contact">>, ctc(CP)},
                               {<<"Record-Route">>, RR}], sdp())),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        %% callee-initiated BYE, routed through the proxy
        send(Sock, EP, callee_bye_req(Sock, Call, CTag, FT, RR, Caller)),
        _ = recv_status(Sock, 200),
        Test ! callee_bye_done
    end),

    peer(0, fun(Sock) ->
        send(Sock, EP, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        RR = record_route_of(R200),
        Callee = contact_of(R200),
        send(Sock, EP, ack(Sock, Call, FT, TT, RR, Callee, 1)),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! caller_relayed_bye
    end),

    ok = expect(caller_relayed_bye),
    ok = expect(callee_bye_done).

%% A mid-dialog re-INVITE from the caller is forwarded to the callee and its
%% 200 relayed back.
reinvite_through_proxy(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    proxy_app(CP),
    Call = callid(),
    FT = <<"m9r">>,

    peer(CP, fun(Sock) ->
        {Inv, PSrc} = recv(Sock, <<"INVITE">>),
        RR = record_route_of(Inv),
        send(Sock, PSrc, resp(Inv, 200, <<"OK">>, tag(),
                              [{<<"Contact">>, ctc(CP)},
                               {<<"Record-Route">>, RR}], sdp())),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Re, RSrc} = recv(Sock, <<"INVITE">>),
        Test ! callee_got_reinvite,
        send(Sock, RSrc, resp(Re, 200, <<"OK">>, keep, [{<<"Contact">>, ctc(CP)}], sdp())),
        {_Ack2, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, tag(), [], <<>>))
    end),

    peer(0, fun(Sock) ->
        send(Sock, EP, invite(Sock, Call, FT)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        RR = record_route_of(R200),
        Callee = contact_of(R200),
        send(Sock, EP, ack(Sock, Call, FT, TT, RR, Callee, 1)),
        send(Sock, EP, reinvite(Sock, Call, FT, TT, RR, Callee, 2)),
        _ = recv_status(Sock, 200),
        Test ! caller_reinvite_200,
        send(Sock, EP, ack(Sock, Call, FT, TT, RR, Callee, 2)),
        send(Sock, EP, bye(Sock, Call, FT, TT, RR, Callee, 3)),
        _ = recv_status(Sock, 200)
    end),

    ok = expect(callee_got_reinvite),
    ok = expect(caller_reinvite_200).

%% F4: a request whose top Route carries our marker but no valid MAC must not
%% be loose-routed (open-relay bypass). The proxy refuses it (405) instead of
%% forwarding it to the attacker-chosen target, and the target sees nothing.
forged_route_marker_not_relayed(_Config) ->
    {EP, VictimP} = setup(),
    Test = self(),
    proxy_app(VictimP),
    Call = callid(),
    peer(VictimP, fun(Sock) ->
        receive
            {udp, Sock, _, _, <<"BYE ", _/binary>>} -> Test ! victim_got_bye
        after 3000 -> Test ! victim_quiet
        end
    end),
    peer(0, fun(Sock) ->
        EPB = integer_to_binary(EP),
        %% a short marker (wrong length) must not crash the engine's compare,
        %% and a full-length but wrong MAC must not be accepted either
        Short = <<"<sip:127.0.0.1:", EPB/binary, ";lr;espx=abc>">>,
        send(Sock, EP, bye(Sock, Call, <<"atk">>, <<"vtag">>, Short,
                           ctc(VictimP), 2)),
        %% a BYE naming no dialog of ours (RFC 3261 15.1.2)
        _ = recv_status(Sock, 481),
        Full = <<"<sip:127.0.0.1:", EPB/binary,
                 ";lr;espx=00000000000000000000000000000000>">>,
        send(Sock, EP, bye(Sock, Call, <<"atk">>, <<"vtag">>, Full,
                           ctc(VictimP), 3)),
        _ = recv_status(Sock, 481),          % refused, not relayed
        Test ! atk_refused
    end),
    ok = expect(atk_refused),
    ok = expect(victim_quiet).

%% ---- app + peers ----

proxy_app(CP) ->
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, [dest(CP)], #{record_route => true})
    end).

setup() ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    {EP, pick()}.

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
dest(P) -> <<"127.0.0.1:", (integer_to_binary(P))/binary>>.
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"m9-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
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
            case C of CB -> Bin; _ -> recv_status(Sock, Code) end
    after 6000 -> ct:fail({no_status, Code})
    end.

to_tag(Resp) -> {ok, M} = chappe_sip_msg:parse(Resp), chappe_sip_msg:to_tag(M).

record_route_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(<<"record-route">>, M).

contact_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    case chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"contact">>, M)) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> chappe_sip_msg:get(<<"contact">>, M)
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

reinvite(Sock, Call, FT, TT, RR, RURI, CSeq) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    CS = integer_to_binary(CSeq),
    <<"INVITE ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:callee@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: ", CS/binary, " INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ack(Sock, Call, FT, TT, RR, RURI, CSeq) ->
    P = integer_to_binary(lport(Sock)),
    CS = integer_to_binary(CSeq),
    <<"ACK ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:callee@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: ", CS/binary, " ACK\r\n"
      "Content-Length: 0\r\n\r\n">>.

bye(Sock, Call, FT, TT, RR, RURI, CSeq) ->
    P = integer_to_binary(lport(Sock)),
    CS = integer_to_binary(CSeq),
    <<"BYE ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:callee@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: ", CS/binary, " BYE\r\n"
      "Content-Length: 0\r\n\r\n">>.

%% callee-originated BYE: From is the callee (with its tag), To is the caller.
callee_bye_req(Sock, Call, CTag, FT, RR, RURI) ->
    P = integer_to_binary(lport(Sock)),
    <<"BYE ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: <sip:x@127.0.0.1:", P/binary, ">;tag=", CTag/binary, "\r\n"
      "To: Caller <sip:caller@127.0.0.1>;tag=", FT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% Response echoing all Vias; keeps the To tag if present, else adds ToTag
%% (or `keep` to leave To untouched).
resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case {chappe_sip_msg:to_tag(Msg), ToTag} of
             {undefined, keep} -> To0;
             {undefined, _} when Status > 100 -> <<To0/binary, ";tag=", ToTag/binary>>;
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
