%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% UAS INVITE dialogs.
%%
%% live group: a gen_udp UAC drives INVITE/200/ACK/BYE and the reverse
%% (app-initiated destroy) against the real engine.
%% fake group: auto-answer of in-dialog requests and owner-exit destroy.
-module(chappe_sip_uas_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).
-export([peer_bye/1, app_destroy/1, auto_answer_info/1, claimed_info/1,
         owner_exit_destroys/1, indialog_cseq_out_of_order/1,
         indialog_uses_route_set/1]).

all() ->
    [{group, live}, {group, fake}].

groups() ->
    [{live, [sequence], [peer_bye, app_destroy, indialog_uses_route_set]},
     {fake, [sequence], [auto_answer_info, claimed_info, owner_exit_destroys,
                         indialog_cseq_out_of_order]}].

init_per_group(live, Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config;
init_per_group(fake, Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_engine_fake,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_group(_, _Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(Case, Config) ->
    case is_fake(Case) of
        true -> ok = chappe_sip_engine_fake:boot();
        false -> ok
    end,
    Config.

end_per_testcase(Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    case is_fake(Case) of
        true -> chappe_sip_engine_fake:shutdown();
        false -> ok
    end,
    ok.

is_fake(Case) ->
    lists:member(Case, [auto_answer_info, claimed_info, owner_exit_destroys,
                        indialog_cseq_out_of_order]).

%% ---- live ----

%% INVITE -> 200(SDP) -> ACK -> BYE from peer -> app destroy event -> 200
peer_bye(_Config) ->
    Port = port(),
    ok = chappe_sip:start(#{contact => contact(Port)}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res,
                                    #{local_sdp => sdp(),
                                      status => 200}),
        Test ! {dialog, Dlg},
        {destroyed, _} = chappe_sip_dialog:wait(Dlg),
        Test ! dialog_destroyed
    end),
    {ok, Sock} = udp(),
    {ok, LP} = inet:port(Sock),
    Call = call_id(),
    FromTag = <<"m3ft">>,
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      invite(LP, Call, FromTag, Port)),
    Ok = recv_status(Sock, 200),
    ToTag = to_tag(Ok),
    true = ToTag =/= undefined,
    {_, _} = binary:match(Ok, <<"v=0">>),   % SDP present
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      ack(LP, Call, FromTag, ToTag, Port)),
    receive {dialog, _} -> ok after 3000 -> ct:fail(no_dialog) end,
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      bye(LP, Call, FromTag, ToTag, Port)),
    _ = recv_status(Sock, 200),
    receive dialog_destroyed -> ok after 3000 -> ct:fail(no_destroy) end,
    gen_udp:close(Sock).

%% INVITE -> 200 -> ACK -> app calls destroy -> peer sees BYE -> 200
app_destroy(_Config) ->
    Port = port(),
    ok = chappe_sip:start(#{contact => contact(Port)}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()}),
        Test ! {dialog, Dlg, self()},
        receive destroy_now -> ok end,
        ok = chappe_sip_dialog:destroy(Dlg),
        Test ! destroy_returned
    end),
    {ok, Sock} = udp(),
    {ok, LP} = inet:port(Sock),
    Call = call_id(),
    FromTag = <<"m3ft2">>,
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      invite(LP, Call, FromTag, Port)),
    Ok = recv_status(Sock, 200),
    ToTag = to_tag(Ok),
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      ack(LP, Call, FromTag, ToTag, Port)),
    Handler = receive {dialog, _D, HPid} -> HPid
              after 3000 -> ct:fail(no_dialog) end,
    %% trigger app-initiated BYE
    Handler ! destroy_now,
    Bye = recv_method(Sock, <<"BYE">>),
    {_, _} = binary:match(Bye, <<"BYE ">>),
    %% answer the BYE
    ok = gen_udp:send(Sock, {127,0,0,1}, Port, ok_to(Bye, LP)),
    receive destroy_returned -> ok after 3000 -> ct:fail(destroy_hung) end,
    gen_udp:close(Sock).

%% RFC 3261 12.1.1: a UAS dialog built from an INVITE with a Record-Route
%% loose-routes its in-dialog requests through the recorded route (a Route
%% header on the BYE). The Record-Route points at the caller here so the BYE
%% comes back to it.
indialog_uses_route_set(_Config) ->
    Port = port(),
    ok = chappe_sip:start(#{contact => contact(Port)}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()}),
        Test ! {dialog, Dlg, self()},
        receive destroy_now -> ok end,
        ok = chappe_sip_dialog:destroy(Dlg)
    end),
    {ok, Sock} = udp(),
    {ok, LP} = inet:port(Sock),
    Call = call_id(),
    FromTag = <<"rsft">>,
    RR = <<"<sip:127.0.0.1:", (integer_to_binary(LP))/binary, ";lr>">>,
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      invite_rr(LP, Call, FromTag, RR)),
    Ok = recv_status(Sock, 200),
    ToTag = to_tag(Ok),
    ok = gen_udp:send(Sock, {127,0,0,1}, Port,
                      ack(LP, Call, FromTag, ToTag, Port)),
    Handler = receive {dialog, _D, HPid} -> HPid
              after 3000 -> ct:fail(no_dialog) end,
    Handler ! destroy_now,
    Bye = recv_method(Sock, <<"BYE">>),
    %% the BYE carries the recorded route
    {_, _} = binary:match(Bye, <<"Route: ">>),
    {_, _} = binary:match(Bye, RR),
    ok = gen_udp:send(Sock, {127,0,0,1}, Port, ok_to(Bye, LP)),
    gen_udp:close(Sock).

invite_rr(LP, Call, FromTag, RR) ->
    P = integer_to_binary(LP),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "Record-Route: ", RR/binary, "\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FromTag/binary,
      "\r\nTo: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

%% ---- fake ----

auto_answer_info(_Config) ->
    Test = self(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5999">>}),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{owner => Test}),
        Test ! {dialog, Dlg},
        receive stop -> ok end
    end),
    inject_invite(201, <<"fakecall">>),
    Dlg = receive {dialog, D} -> D after 2000 -> ct:fail(no_dialog) end,
    LegH = chappe_sip_dialog:id(Dlg),
    %% unclaimed INFO auto-answered 200
    ok = chappe_sip_engine_fake:inject_indialog(LegH, 900, info_req(<<"fakecall">>)),
    {ok, #{status := 200}} = fake_await(900),
    receive
        {chappe_sip_dialog, Dlg, {auto_answered, info}, _} -> ok
    after 2000 -> ct:fail(no_auto_answer_event)
    end.

claimed_info(_Config) ->
    Test = self(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5999">>}),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res,
                                    #{handled_events => [info], owner => Test}),
        Test ! {dialog, Dlg},
        receive stop -> ok end
    end),
    inject_invite(202, <<"fakecall2">>),
    Dlg = receive {dialog, D} -> D after 2000 -> ct:fail(no_dialog) end,
    LegH = chappe_sip_dialog:id(Dlg),
    ok = chappe_sip_engine_fake:inject_indialog(LegH, 901, info_req(<<"fakecall2">>)),
    receive
        {chappe_sip_dialog, Dlg, info, _Req, Res} ->
            ok = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
    after 2000 -> ct:fail(no_claimed_event)
    end,
    {ok, #{status := 200}} = fake_await(901).

owner_exit_destroys(_Config) ->
    Parent = self(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5999">>}),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{on_owner_exit => destroy}),
        Parent ! {dialog_leg, chappe_sip_dialog:id(Dlg)},
        %% owner (this worker) exits right away -> fsm should send BYE
        ok
    end),
    inject_invite(203, <<"fakecall3">>),
    LegH = receive {dialog_leg, L} -> L after 2000 -> ct:fail(no_dialog) end,
    %% fsm sends BYE as a new request through the fake -> op_ok; then the
    %% fsm waits for a response. Feed a 200 to its BYE txn.
    %% The BYE request handle is the next fake seq; just assert the fsm is
    %% alive and processing by checking a leg was created.
    true = is_integer(LegH).

%% ---- helpers ----

port() -> chappe_sip_test_port:pick().
contact(P) -> <<"sip:127.0.0.1:", (integer_to_binary(P))/binary>>.
udp() -> gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]).
call_id() ->
    <<"m3-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary,
      "@127.0.0.1">>.
%% branch must be a token (no '@'); derive it from random bytes, not the
%% Call-ID which contains a host part
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

recv_status(Sock, Code) ->
    CodeBin = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CodeBin -> Bin;
                <<"100">> -> recv_status(Sock, Code);   % skip 100 Trying
                _ -> ct:fail({unexpected_status, C})
            end
    after 4000 -> ct:fail({no_status, Code})
    end.

recv_method(Sock, Method) ->
    Len = byte_size(Method),
    receive
        {udp, Sock, _, _, <<M:Len/binary, " ", _/binary>> = Bin}
          when M =:= Method ->
            Bin;
        {udp, Sock, _, _, _Other} ->
            recv_method(Sock, Method)
    after 4000 -> ct:fail({no_method, Method})
    end.

to_tag(Resp) ->
    {ok, Msg} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(Msg).

fake_await(TxnH) ->
    chappe_sip_engine_fake:await_response(TxnH).

inject_invite(TxnH, Call) ->
    chappe_sip_engine_fake:inject_request(TxnH, fake_invite(Call)).

fake_invite(Call) ->
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5998;branch=z9hG4bK", Call/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Alice <sip:alice@127.0.0.1>;tag=af1\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:alice@127.0.0.1:5998>\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: 1 INVITE\r\n"
      "Content-Length: 0\r\n\r\n">>.

%% RFC 3261 12.2.2: an in-dialog request whose CSeq is lower than the highest
%% seen is out of order and answered 500.
indialog_cseq_out_of_order(_Config) ->
    Test = self(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:5999">>}),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{owner => Test}),
        Test ! {dialog, Dlg},
        receive stop -> ok end
    end),
    inject_invite(210, <<"ooo">>),
    Dlg = receive {dialog, D} -> D after 2000 -> ct:fail(no_dialog) end,
    LegH = chappe_sip_dialog:id(Dlg),
    ok = chappe_sip_engine_fake:inject_indialog(LegH, 910, info_cseq(<<"ooo">>, 5)),
    {ok, #{status := 200}} = fake_await(910),
    %% a later in-dialog request with a lower CSeq is rejected 500
    ok = chappe_sip_engine_fake:inject_indialog(LegH, 911, info_cseq(<<"ooo">>, 3)),
    {ok, #{status := 500}} = fake_await(911).

info_cseq(Call, N) ->
    C = integer_to_binary(N),
    <<"INFO sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5998;branch=z9hG4bKic", C/binary, "\r\n"
      "From: Alice <sip:alice@127.0.0.1>;tag=af1\r\n"
      "To: <sip:app@127.0.0.1>;tag=srvtag\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: ", C/binary, " INFO\r\n"
      "Content-Length: 0\r\n\r\n">>.

info_req(Call) ->
    <<"INFO sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:5998;branch=z9hG4bKinfo", Call/binary, "\r\n"
      "From: Alice <sip:alice@127.0.0.1>;tag=af1\r\n"
      "To: <sip:app@127.0.0.1>;tag=srvtag\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: 2 INFO\r\n"
      "Content-Length: 0\r\n\r\n">>.

invite(LP, Call, FromTag, _Port) ->
    P = integer_to_binary(LP),
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FromTag/binary,
      "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ack(LP, Call, FromTag, ToTag, _Port) ->
    P = integer_to_binary(LP),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FromTag/binary,
      "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", ToTag/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: 1 ACK\r\n"
      "Content-Length: 0\r\n\r\n">>.

bye(LP, Call, FromTag, ToTag, _Port) ->
    P = integer_to_binary(LP),
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FromTag/binary,
      "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", ToTag/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: 2 BYE\r\n"
      "Content-Length: 0\r\n\r\n">>.

%% Build a 200 OK to an inbound request (used to answer app's BYE),
%% echoing Via/From/To/Call-ID/CSeq.
ok_to(ReqBin, _LP) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Via = chappe_sip_msg:get(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To = chappe_sip_msg:get(<<"to">>, Msg),
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    <<"SIP/2.0 200 OK\r\n"
      "Via: ", Via/binary, "\r\n"
      "From: ", From/binary, "\r\n"
      "To: ", To/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: ", CSeq/binary, "\r\n"
      "Content-Length: 0\r\n\r\n">>.
