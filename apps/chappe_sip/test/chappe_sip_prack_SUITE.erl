%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% PRACK / 100rel reliable provisionals.
%%
%% uas_reliable: our UAS sends a reliable 183; a gen_udp UAC PRACKs it and
%% the UAS is notified before answering 200.
%% uac_prack: our UAC (rel100 => supported) auto-PRACKs a reliable 183 sent
%% by a gen_udp UAS.
-module(chappe_sip_prack_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip_uac.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([uas_reliable/1, uac_prack/1]).

all() ->
    [uas_reliable, uac_prack].

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

%% our UAS: reliable 183 -> UAC PRACK -> UAS notified -> 200 -> ACK
uas_reliable(_Config) ->
    EP = start_engine(),
    Test = self(),
    C = <<"<sip:app@127.0.0.1:", (integer_to_binary(EP))/binary, ">">>,
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send_reliable(Res, #{status => 183, to_tag => <<"uastag">>,
                                           headers => [{<<"Contact">>, C}],
                                           body => sdp()}),
        case chappe_sip_res:await_prack(Res, 5000) of
            {ok, _} -> Test ! uas_got_prack;
            {error, timeout} -> Test ! uas_prack_timeout
        end,
        _ = chappe_sip_res:send(Res, 200, #{to_tag => <<"uastag">>,
                                      headers => [{<<"Contact">>, C}],
                                      body => sdp()})
    end),
    Call = <<"m13a@ct">>,
    peer(0, fun(Sock) ->
        send(Sock, EP, invite(Sock, Call, <<"uacft">>, true)),
        R183 = recv_status(Sock, 183),
        {_, _} = binary:match(R183, <<"100rel">>),        % Require: 100rel
        RSeq = header(<<"rseq">>, R183),
        TT = to_tag(R183),
        send(Sock, EP, prack(Sock, Call, <<"uacft">>, TT, RSeq, 1, 2)),
        %% a 200 for the PRACK and a 200 for the INVITE both arrive
        ok = await_200_invite(Sock),
        send(Sock, EP, ack(Sock, Call, <<"uacft">>, TT)),
        Test ! caller_done
    end),
    ok = expect(uas_got_prack),
    ok = expect(caller_done).

%% our UAC: INVITE (100rel) -> gen_udp UAS reliable 183 -> UAC auto-PRACK
%% -> 200 PRACK -> 200 INVITE -> UAC ACK -> {ok, Dialog}
uac_prack(_Config) ->
    EP = start_engine(),
    Test = self(),
    UP = pick(),
    %% gen_udp UAS
    peer(UP, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        {_, _} = binary:match(Inv, <<"100rel">>),          % Supported: 100rel
        Ct = <<"<sip:callee@127.0.0.1:", (integer_to_binary(UP))/binary, ">">>,
        send(Sock, Src, rel183(Inv, <<"ptag">>, 1, Ct)),
        {Pr, PSrc} = recv(Sock, <<"PRACK">>),
        {_, _} = binary:match(Pr, <<"RAck">>),
        Test ! uas_got_prack,
        send(Sock, PSrc, ok200(Pr, undefined, [])),        % 200 PRACK
        send(Sock, Src, ok200(Inv, <<"ptag">>,
                              [{<<"Contact">>, Ct}])),      % 200 INVITE
        {_Ack, _} = recv(Sock, <<"ACK">>),
        Test ! uas_got_ack
    end),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(UP))/binary>>,
    spawn_link(fun() ->
        R = chappe_sip:create_uac(Uri, #{rel100 => supported, local_sdp => sdp(),
                                   timeout => 8000}),
        Test ! {uac_result, R}
    end),
    ok = expect(uas_got_prack),
    ok = expect(uas_got_ack),
    receive {uac_result, {ok, _Dialog}} -> ok
    after 8000 -> ct:fail(no_uac_dialog) end,
    _ = EP.

%% ---- helpers ----

start_engine() ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    EP.

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

expect(Msg) -> receive Msg -> ok after 8000 -> ct:fail({expected, Msg}) end.

%% collect responses until the 200 for the INVITE (skip the 200 for PRACK)
await_200_invite(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>> = Bin} ->
            case cseq_method(Bin) of
                <<"INVITE">> -> ok;
                _ -> await_200_invite(Sock)
            end;
        {udp, Sock, _, _, _} -> await_200_invite(Sock)
    after 6000 -> ct:fail(no_200_invite)
    end.

pick() -> chappe_sip_test_port:pick().
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, Dst, Bin) -> gen_udp:send(Sock, {127,0,0,1}, Dst, Bin).
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

to_tag(Resp) -> {ok, M} = chappe_sip_msg:parse(Resp), chappe_sip_msg:to_tag(M).
header(Name, Bin) -> {ok, M} = chappe_sip_msg:parse(Bin), chappe_sip_msg:get(Name, M).
cseq_method(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    case chappe_sip_msg:cseq(M) of {ok, #{method := Me}} -> Me; _ -> undefined end.

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

%% ---- UAC-side (gen_udp) message builders ----

invite(Sock, Call, FT, Rel100) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    Sup = case Rel100 of true -> <<"Supported: 100rel\r\n">>; false -> <<>> end,
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n",
      Sup/binary,
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

prack(Sock, Call, FT, TT, RSeq, InvCSeq, PCSeq) ->
    P = integer_to_binary(lport(Sock)),
    <<"PRACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: ", (integer_to_binary(PCSeq))/binary, " PRACK\r\n"
      "RAck: ", RSeq/binary, " ", (integer_to_binary(InvCSeq))/binary, " INVITE\r\n"
      "Content-Length: 0\r\n\r\n">>.

ack(Sock, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

%% ---- UAS-side (gen_udp) response builders ----

%% reliable 183 with Require: 100rel, RSeq, Contact and SDP
rel183(ReqBin, ToTag, RSeq, Contact) ->
    S = sdp(),
    resp(ReqBin, 183, <<"Session Progress">>, ToTag,
         [{<<"Require">>, <<"100rel">>},
          {<<"RSeq">>, integer_to_binary(RSeq)},
          {<<"Contact">>, Contact},
          {<<"Content-Type">>, <<"application/sdp">>}], S).

ok200(ReqBin, ToTag, Extra) ->
    resp(ReqBin, 200, <<"OK">>, ToTag, Extra, <<>>).

resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case {chappe_sip_msg:to_tag(Msg), ToTag} of
             {undefined, T} when T =/= undefined, Status > 100 ->
                 <<To0/binary, ";tag=", T/binary>>;
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
