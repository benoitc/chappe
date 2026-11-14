%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% SIPREC on a real rtpengine: chappe records an anchored call to chappe
%% as recording server, and both parties are heard, each on its own
%% stream.
%%
%% A caller and a callee (gen_udp, SIP on loopback, RTP on sockets the
%% container reaches at RTPENGINE_MEDIA_IP) make a call through the B2BUA,
%% media anchored on rtpengine. chappe_sip_siprec then taps each party and
%% sends the RS to a route of the same node running
%% chappe_sip_siprec_srs:serve/3 with a process sink. Each party sends its
%% own G.711 level; the recording's first stream must decode to the
%% caller's level only, the second to the callee's only, and each party
%% must hear the other through rtpengine.
%%
%% srtp_call_recorded does the same on a call whose parties speak SRTP
%% (RTP/SAVP, SDES): the recording client taps it as RTP/SAVP with
%% rtpengine's keys, and chappe's SRS decrypts each stream itself.
%%
%% Gated on RTPENGINE_HOST and RTPENGINE_MEDIA_IP (make interop sets them).
-module(chappe_sip_siprec_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([both_parties_recorded/1, srtp_call_recorded/1]).

-define(UA, chappe_sip_test_ua).
-define(NODE, chappe_sip_siprec_live).
%% the mu-law bytes each party sends: two distinct levels
-define(A_BYTE, 16#20).
-define(B_BYTE, 16#10).

all() -> [both_parties_recorded, srtp_call_recorded].

init_per_suite(Config) ->
    case {os:getenv("RTPENGINE_HOST"), os:getenv("RTPENGINE_MEDIA_IP")} of
        {false, _} ->
            {skip, "RTPENGINE_HOST not set"};
        {_, M} when M =:= false; M =:= "" ->
            {skip, "RTPENGINE_MEDIA_IP not set"};
        {Host, MediaIp} ->
            application:set_env(chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]),
            {ok, _} = application:ensure_all_started(chappe_sip),
            Port = list_to_integer(os:getenv("RTPENGINE_PORT", "2223")),
            ok = chappe_sip_media:configure(
                   #{rtpengine => #{nodes => [#{name => ?NODE, host => Host, port => Port}]}}),
            {ok, RtpeIp} = inet:parse_address(Host),
            [{rtpe_ip, RtpeIp}, {media_ip, list_to_binary(MediaIp)} | Config]
    end.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

end_per_suite(_Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_rtpengine:remove_node(?NODE),
    _ = application:stop(chappe_sip),
    _ = application:stop(chappe_rtpengine),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

%% req: R7866-7.1.1-1 R7866-8.3-1 R6341-REQ-012
both_parties_recorded(Config) ->
    record(Config, plain).

%% RFC 7866 12.2: the SRS takes RTP/SAVP with SDES keys from a real SRC
%% (rtpengine's taps) and both parties are heard once decrypted.
%% req: R7866-12.2-1 R7866-12.2-2 R4568-7.1.2-1
srtp_call_recorded(Config) ->
    record(Config, srtp).

record(Config, Mode) ->
    MediaIp = ?config(media_ip, Config),
    RtpeIp = ?config(rtpe_ip, Config),
    Test = self(),
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>}),
    ok = chappe_sip:handle(<<"INVITE">>, fun(Req, Res) ->
        case chappe_sip_req:uri(Req) of
            <<"sip:srs@", _/binary>> ->
                {ok, #{streams := Streams} = Srs} =
                    chappe_sip_siprec_srs:serve(Req, Res, #{
                        sink => Test, ip => {0, 0, 0, 0}, advertise => MediaIp,
                        %% the lab sends the RS over plain UDP
                        keys_over_tls => false
                    }),
                Test ! {srs_streams, Streams},
                Test ! {srs_offer, chappe_sip_req:body(Req)},
                chappe_sip_siprec_srs:run(Srs);
            _ ->
                Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
                {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, b2b_opts(Mode)),
                Test ! {legs, Legs},
                chappe_sip_b2b:relay(Legs)
        end
    end, #{option_tags => [<<"siprec">>]}),
    {MA, PA} = media_socket(),
    {MB, PB} = media_socket(),
    %% each party's own SRTP key (srtp mode)
    KA = chappe_sip_test_srtp:master(),
    KB = chappe_sip_test_srtp:master(),
    %% the callee: answers with its media address, then waits
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Test ! {b_offer, ?UA:body(Inv)},
        Test ! {b_offer_sdp, ?UA:body(Inv)},
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, ?UA:tag(),
                                     [{<<"Contact">>, contact(Sock)}],
                                     sdp(MediaIp, PB, profile(?UA:body(Inv)), KB))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     body => sdp(MediaIp, PA, Mode, KA)}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP),
        Test ! {a_answer, ?UA:body(R)},
        Test ! {a_answer_sdp, ?UA:body(R)},
        timer:sleep(infinity)
    end),
    #{b2b := B2b, call_ref := Ref} = got(legs),
    ToA = audio_port(got(a_answer)),
    ToB = audio_port(got(b_offer)),
    {ok, Rec} = chappe_sip_siprec:start(B2b, <<"sip:srs@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, #{call_ref := Ref}} = event(Rec),
    [#{pid := S1, label := <<"1">>, profile := Prof1},
     #{pid := S2, label := <<"2">>, profile := Prof2}] = got(srs_streams),
    ct:log("SRS offer:~n~s", [got(srs_offer)]),
    Profile = case Mode of plain -> <<"RTP/AVP">>; srtp -> <<"RTP/SAVP">> end,
    ?assertEqual({Profile, Profile}, {Prof1, Prof2}),
    SendA = sender(Mode, KA),
    %% the callee answers in the profile rtpengine offered it
    BOffer = got(b_offer_sdp),
    SendB = sender(profile(BOffer), KB),
    %% both parties talk at once, 1.5 s
    lists:foreach(
        fun(Seq) ->
            ok = gen_udp:send(MA, RtpeIp, ToA, SendA(rtp(16#A, Seq, ?A_BYTE))),
            ok = gen_udp:send(MB, RtpeIp, ToB, SendB(rtp(16#B, Seq, ?B_BYTE))),
            timer:sleep(20)
        end,
        lists:seq(1, 75)
    ),
    timer:sleep(500),
    {N1, L1} = levels(S1),
    {N2, L2} = levels(S2),
    ct:log("recorded: caller ~p frames ~p, callee ~p frames ~p", [N1, L1, N2, L2]),
    LA = level(?A_BYTE),
    LB = level(?B_BYTE),
    ?assert(N1 > 0 andalso N2 > 0),
    ?assertEqual([LA], L1 -- [0]),
    ?assertEqual([LB], L2 -- [0]),
    ?assertMatch(#{failed := 0, replayed := 0}, chappe_sip_siprec_rtp:stats(S1)),
    ?assertMatch(#{failed := 0, replayed := 0}, chappe_sip_siprec_rtp:stats(S2)),
    %% and the call itself carries both ways, each party hearing the other
    AAnswer = got(a_answer_sdp),
    ct:log("A's answer:~n~s~nB's offer:~n~s", [AAnswer, BOffer]),
    %% the caller is answered in its own profile, with a key of rtpengine's
    ?assertEqual(Mode, profile(AAnswer)),
    ?assertEqual(Mode =:= srtp, binary:match(AAnswer, <<"a=crypto:">>) =/= nomatch),
    ?assertEqual([LB], heard(MA, receiver(profile(AAnswer), AAnswer)) -- [0]),
    ?assertEqual([LA], heard(MB, receiver(profile(BOffer), BOffer)) -- [0]),
    ok = chappe_sip_siprec:stop(Rec),
    {stopped, #{reason := stopped}} = event(Rec),
    ok = chappe_sip_b2b:hangup(B2b, #{}).

%% ---- helpers ----

media_socket() ->
    {ok, S} = gen_udp:open(0, [binary, {ip, {0, 0, 0, 0}}, {active, true}]),
    {ok, P} = inet:port(S),
    {S, P}.

sdp(Ip, Port, plain, _Key) ->
    <<"v=0\r\no=- 1 1 IN IP4 ", Ip/binary, "\r\ns=-\r\nc=IN IP4 ", Ip/binary,
      "\r\nt=0 0\r\nm=audio ", (integer_to_binary(Port))/binary,
      " RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n">>;
sdp(Ip, Port, srtp, Key) ->
    <<"v=0\r\no=- 1 1 IN IP4 ", Ip/binary, "\r\ns=-\r\nc=IN IP4 ", Ip/binary,
      "\r\nt=0 0\r\nm=audio ", (integer_to_binary(Port))/binary,
      " RTP/SAVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n"
      "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:",
      (chappe_sip_test_srtp:inline(Key))/binary, "\r\n">>.

%% the anchor as it is: an SRTP caller is answered SRTP by itself
b2b_opts(_Mode) ->
    #{media => anchor}.

%% plain or srtp, as an SDP's first m-line says
profile(Sdp) ->
    case chappe_sip_sdp:parse(Sdp) of
        {_, [#{proto := <<"RTP/SAVP">>} | _]} -> srtp;
        _ -> plain
    end.

%% what a party sends: its RTP as it is, or protected with its key
sender(plain, _Key) ->
    fun(Rtp) -> Rtp end;
sender(srtp, Key) ->
    Snd = chappe_sip_test_srtp:sender(Key),
    fun(Rtp) -> chappe_sip_test_srtp:protect(Rtp, 0, Snd) end.

%% what a party does with what it receives: nothing, or decrypt it with
%% the key rtpengine gave it in its SDP
receiver(plain, _Sdp) ->
    fun(Rtp) -> {ok, Rtp} end;
receiver(srtp, Sdp) ->
    {_, [[_M | Lines] | _]} = chappe_sip_sdp:sections(Sdp),
    {ok, C} = chappe_sip_sdes:select(Lines),
    {ok, Ctx0} = chappe_sip_srtp:new(maps:with([suite, key, salt, mki, lifetime], C)),
    Ref = make_ref(),
    put(Ref, Ctx0),
    fun(Pkt) ->
        case chappe_sip_srtp:unprotect(Pkt, get(Ref)) of
            {ok, Rtp, Ctx} -> put(Ref, Ctx), {ok, Rtp};
            {error, _} = E -> E
        end
    end.

contact(Sock) ->
    <<"<sip:peer@127.0.0.1:", (integer_to_binary(?UA:lport(Sock)))/binary, ">">>.

audio_port(Sdp) ->
    {_, [#{port := P} | _]} = chappe_sip_sdp:parse(Sdp),
    P.

rtp(Ssrc, Seq, Byte) ->
    <<2:2, 0:6, 0:1, 0:7, Seq:16, (Seq * 160):32, Ssrc:32,
      (binary:copy(<<Byte>>, 160))/binary>>.

%% the distinct samples a stream of the recording carried
levels(Stream) ->
    levels(Stream, 0, []).

levels(Stream, N, Acc) ->
    receive
        {chappe_sip_siprec_rtp, Stream, {audio, Pcm}} ->
            Seen = lists:usort([S || <<S:16/little-signed>> <= Pcm]),
            levels(Stream, N + 1, lists:umerge(Acc, Seen))
    after 0 ->
        {N, Acc}
    end.

level(Byte) ->
    <<S:16/little-signed>> = chappe_sip_siprec_rtp:decode(ulaw, <<Byte>>),
    S.

%% the distinct samples a party heard, decrypted as it must be
heard(Sock, Recv) ->
    heard(Sock, Recv, []).

heard(Sock, Recv, Acc) ->
    receive
        {udp, Sock, _, _, Pkt} ->
            case Recv(Pkt) of
                {ok, <<2:2, _:6, _:1, 0:7, _:80, Payload/binary>>} ->
                    Pcm = chappe_sip_siprec_rtp:decode(ulaw, Payload),
                    heard(Sock, Recv, lists:umerge(Acc, lists:usort(
                        [S || <<S:16/little-signed>> <= Pcm])));
                _ ->
                    heard(Sock, Recv, Acc)
            end
    after 0 ->
        Acc
    end.

event(Rec) ->
    receive {chappe_sip_siprec, Rec, Ev} -> Ev after 15000 -> ct:fail(no_event) end.

got(Tag) ->
    receive {Tag, V} -> V after 10000 -> ct:fail({missing, Tag}) end.
