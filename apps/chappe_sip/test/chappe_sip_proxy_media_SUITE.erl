%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Media-anchoring proxy: chappe_sip_proxy with the opt-in `media' option anchors SDP
%% through rtpengine while preserving the Call-ID. A caller and callee talk
%% through a record-routing proxy; the proxy rewrites the offer on the forwarded
%% INVITE and the answer on the 200, and deletes the rtpengine call on BYE. A
%% control case proves the plain proxy (no `media' option) forwards SDP
%% untouched and emits no rtpengine traffic.
%%
%% rtpengine is a fake in-suite NG UDP node (as in chappe_sip_media_SUITE) that
%% records the commands it receives and returns a marker SDP.
-module(chappe_sip_proxy_media_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([anchor_call/1, no_media_passthrough/1]).

all() ->
    [anchor_call, no_media_passthrough].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    _ = application:stop(chappe_rtpengine),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    RtpPort = start_fake(self()),
    ok = chappe_sip_media:configure(
        #{rtpengine =>
              #{nodes => [#{name => chappe_rtpengine_test, host => "127.0.0.1",
                            port => RtpPort}]}}),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    _ = chappe_rtpengine:remove_node(chappe_rtpengine_test),
    stop_fake(),
    ok.

%% ---- tests ----

%% Offer rewrites the forwarded INVITE, answer rewrites the 200, BYE deletes.
anchor_call(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    proxy_app(CP, #{record_route => true, media => #{}}),
    Call = callid(),
    FT = <<"pm-a">>,

    peer(CP, fun(Sock) ->
        {Inv, PSrc} = recv(Sock, <<"INVITE">>),
        %% the caller's offer was anchored: the callee sees the fake's SDP
        Test ! {fwd_offer, body_of(Inv)},
        RR = record_route_of(Inv),
        send(Sock, PSrc, resp(Inv, 200, <<"OK">>, tag(),
                              [{<<"Contact">>, ctc(CP)},
                               {<<"Record-Route">>, RR}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>),
        {Bye, BSrc} = recv(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! callee_got_bye
    end),

    peer(0, fun(Sock) ->
        send(Sock, EP, invite(Sock, Call, FT, sdp(<<"caller">>))),
        R200 = recv_status(Sock, 200),
        %% the callee's answer was anchored: the caller sees the fake's SDP
        Test ! {relayed_answer, body_of(R200)},
        TT = to_tag(R200),
        RR = record_route_of(R200),
        Callee = contact_of(R200),
        send(Sock, EP, ack(Sock, Call, FT, TT, RR, Callee, 1)),
        send(Sock, EP, bye(Sock, Call, FT, TT, RR, Callee, 2)),
        _ = recv_status(Sock, 200),
        Test ! caller_got_bye_200
    end),

    ?assertEqual(<<"v=0 fake-offer">>, expect_val(fwd_offer)),
    ?assertEqual(<<"v=0 fake-answer">>, expect_val(relayed_answer)),
    ok = expect(callee_got_bye),
    ok = expect(caller_got_bye_200),

    %% rtpengine saw offer (from-tag), answer (to-tag), delete (call-id)
    Cmds = drain_cmds(),
    ?assertEqual(FT, tag_of(<<"offer">>, <<"from-tag">>, Cmds)),
    ?assertEqual(Call, tag_of(<<"offer">>, <<"call-id">>, Cmds)),
    ?assert(has_cmd(<<"answer">>, Cmds)),
    ?assertNotEqual(undefined, tag_of(<<"answer">>, <<"to-tag">>, Cmds)),
    ?assertEqual(Call, tag_of(<<"delete">>, <<"call-id">>, Cmds)).

%% Without the media option the proxy forwards SDP unchanged and emits no NG.
no_media_passthrough(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    proxy_app(CP, #{record_route => true}),
    Call = callid(),
    FT = <<"pm-n">>,
    CallerSdp = sdp(<<"caller">>),

    peer(CP, fun(Sock) ->
        {Inv, PSrc} = recv(Sock, <<"INVITE">>),
        Test ! {fwd_offer, body_of(Inv)},
        send(Sock, PSrc, resp(Inv, 200, <<"OK">>, tag(),
                              [{<<"Contact">>, ctc(CP)}], sdp(<<"callee">>))),
        {_Ack, _} = recv(Sock, <<"ACK">>)
    end),

    peer(0, fun(Sock) ->
        send(Sock, EP, invite(Sock, Call, FT, CallerSdp)),
        R200 = recv_status(Sock, 200),
        TT = to_tag(R200),
        Callee = contact_of(R200),
        send(Sock, EP, ack(Sock, Call, FT, TT, <<>>, Callee, 1)),
        Test ! caller_done
    end),

    %% forwarded offer is the caller's original SDP, untouched
    ?assertEqual(CallerSdp, expect_val(fwd_offer)),
    ok = expect(caller_done),
    ?assertEqual([], drain_cmds()).

%% ---- app + peers ----

proxy_app(CP, Opts) ->
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, [dest(CP)], Opts)
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
                                         {ip, {127, 0, 0, 1}}]),
        Parent ! {peer_ready, self()},
        Fun(Sock)
    end),
    receive {peer_ready, Pid} -> ok after 2000 -> ct:fail(peer_not_ready) end,
    Pid.

expect(Msg) ->
    receive Msg -> ok after 6000 -> ct:fail({expected, Msg}) end.

expect_val(Tag) ->
    receive {Tag, V} -> V after 6000 -> ct:fail({expected, Tag}) end.

%% ---- SIP helpers ----

pick() -> 40000 + rand:uniform(20000).
dest(P) -> <<"127.0.0.1:", (integer_to_binary(P))/binary>>.
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
callid() ->
    <<"pm-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp(Who) ->
    <<"v=0 ", Who/binary>>.
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, DstPort, Bin) -> gen_udp:send(Sock, {127, 0, 0, 1}, DstPort, Bin).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin}
          when M =:= Method ->
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

body_of(Bin) -> {ok, M} = chappe_sip_msg:parse(Bin), chappe_sip_msg:body(M).

record_route_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(<<"record-route">>, M).

contact_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    case chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"contact">>, M)) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> chappe_sip_msg:get(<<"contact">>, M)
    end.

invite(Sock, Call, FT, S) ->
    P = integer_to_binary(lport(Sock)),
    L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:callee@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
      (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
      "\r\nTo: <sip:callee@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", L/binary, "\r\n\r\n", S/binary>>.

ack(Sock, Call, FT, TT, RR, RURI, CSeq) ->
    P = integer_to_binary(lport(Sock)),
    CS = integer_to_binary(CSeq),
    RouteLine = route_line(RR),
    <<"ACK ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n", RouteLine/binary,
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
      "\r\nTo: <sip:callee@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: ", CS/binary, " ACK\r\n"
      "Content-Length: 0\r\n\r\n">>.

bye(Sock, Call, FT, TT, RR, RURI, CSeq) ->
    P = integer_to_binary(lport(Sock)),
    CS = integer_to_binary(CSeq),
    RouteLine = route_line(RR),
    <<"BYE ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n", RouteLine/binary,
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary,
      "\r\nTo: <sip:callee@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: ", CS/binary, " BYE\r\n"
      "Content-Length: 0\r\n\r\n">>.

route_line(<<>>) -> <<>>;
route_line(RR) -> <<"Route: ", RR/binary, "\r\n">>.

resp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case {chappe_sip_msg:to_tag(Msg), ToTag} of
             {undefined, keep} -> To0;
             {undefined, _} when Status > 100 ->
                 <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CT = case Body of <<>> -> []; _ -> [<<"Content-Type: application/sdp\r\n">>]
         end,
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines, <<"From: ">>, From, <<"\r\n">>, <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>, Extra,
       CT, <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).

%% ---- fake rtpengine NG node (reused pattern from chappe_sip_media_SUITE) ----

tag_of(Name, Key, Cmds) ->
    case [C || C <- Cmds, maps:get(<<"command">>, C, undefined) =:= Name] of
        [] -> undefined;
        Matches -> maps:get(Key, lists:last(Matches), undefined)
    end.

has_cmd(Name, Cmds) ->
    lists:any(fun(C) -> maps:get(<<"command">>, C, undefined) =:= Name end,
              Cmds).

drain_cmds() -> drain_cmds([]).

drain_cmds(Acc) ->
    receive
        {fake_cmd, Cmd} -> drain_cmds([Cmd | Acc])
    after 100 ->
        lists:reverse(Acc)
    end.

start_fake(Collector) ->
    Starter = self(),
    Pid = spawn(fun() -> fake_init(Starter, Collector) end),
    put(fake_pid, Pid),
    receive
        {fake_port, Pid, Port} -> Port
    after 2000 -> exit(fake_start_timeout)
    end.

stop_fake() ->
    case get(fake_pid) of
        undefined -> ok;
        Pid -> Pid ! stop, ok
    end.

fake_init(Starter, Collector) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}]),
    {ok, Port} = inet:port(Sock),
    Starter ! {fake_port, self(), Port},
    fake_loop(Sock, Collector).

fake_loop(Sock, Collector) ->
    receive
        {udp, Sock, IP, PPort, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Collector ! {fake_cmd, Cmd},
            Reply = fake_reply(maps:get(<<"command">>, Cmd, <<>>)),
            RBin = chappe_rtpengine_bencode:encode_to_binary(Reply),
            ok = gen_udp:send(Sock, IP, PPort,
                              <<Cookie/binary, " ", RBin/binary>>),
            fake_loop(Sock, Collector);
        stop ->
            gen_udp:close(Sock)
    end.

fake_reply(<<"offer">>) ->
    #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0 fake-offer">>};
fake_reply(<<"answer">>) ->
    #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0 fake-answer">>};
fake_reply(_Other) ->
    #{<<"result">> => <<"ok">>}.
