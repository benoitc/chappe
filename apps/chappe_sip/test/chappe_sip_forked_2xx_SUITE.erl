%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Forked second 2xx.
%%
%% A parallel fork where both branches answer 200 with different To-tags.
%% The first 2xx is relayed on the server transaction; the second is
%% forwarded statelessly upstream. The caller must receive both.
-module(chappe_sip_forked_2xx_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([proxy_dual_2xx/1]).

all() ->
    [proxy_dual_2xx].

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

%% both branches answer 200 (distinct To-tags); caller receives both.
proxy_dual_2xx(_Config) ->
    {EP, [D1, D2]} = setup(2),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        R = chappe_sip:proxy_request(Req, [dest(D1), dest(D2)],
                               #{forking => parallel}),
        Test ! {proxy_done, R}
    end),
    branch_uas(D1, <<"tagA">>),
    branch_uas(D2, <<"tagB">>),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), <<"d2x">>)),
        Tags = collect_tags(Sock, [], 2),
        Test ! {caller_tags, Tags}
    end),
    receive {caller_tags, Tags} ->
        ?assertEqual([<<"tagA">>, <<"tagB">>], lists:usort(Tags))
    after 9000 -> ct:fail(no_tags) end,
    receive {proxy_done, {ok, #{final_status := 200}}} -> ok
    after 6000 -> ct:fail(no_proxy_done) end.

%% ---- peers ----

branch_uas(Port, Tag) ->
    peer(Port, fun(Sock) ->
        {Inv, Src} = recv(Sock, <<"INVITE">>),
        send(Sock, Src, resp(Inv, 200, <<"OK">>, Tag,
                             [{<<"Contact">>, ctc(Port)}], sdp())),
        %% answer any CANCEL that races in after our 200
        drain_cancel(Sock)
    end).

drain_cancel(Sock) ->
    receive
        {udp, Sock, _, Src, <<"CANCEL", _/binary>> = Bin} ->
            send(Sock, Src, resp(Bin, 200, <<"OK">>, <<"c">>, [], <<>>)),
            drain_cancel(Sock);
        {udp, Sock, _, _, _} ->
            drain_cancel(Sock)
    after 2000 -> ok
    end.

setup(N) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    {EP, [pick() || _ <- lists:seq(1, N)]}.

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

%% ---- SIP helpers ----

collect_tags(Sock, Acc, N) ->
    case length(lists:usort(Acc)) >= N of
        true -> Acc;
        false ->
            receive
                {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>> = Bin} ->
                    case to_tag(Bin) of
                        undefined -> collect_tags(Sock, Acc, N);
                        Tag -> collect_tags(Sock, [Tag | Acc], N)
                    end;
                {udp, Sock, _, _, _} ->
                    collect_tags(Sock, Acc, N)
            after 4000 -> Acc
            end
    end.

pick() -> 40000 + rand:uniform(20000).
dest(P) -> <<"127.0.0.1:", (integer_to_binary(P))/binary>>.
ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
callid() ->
    <<"m11-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "@ct">>.
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, DstPort, Bin) -> gen_udp:send(Sock, {127,0,0,1}, DstPort, Bin).
to_tag(Resp) -> {ok, M} = chappe_sip_msg:parse(Resp), chappe_sip_msg:to_tag(M).

recv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method ->
            {Bin, Src};
        {udp, Sock, _, _, _} -> recv(Sock, Method)
    after 6000 -> ct:fail({no_req, Method})
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
