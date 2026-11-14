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
%% Gated on RTPENGINE_HOST and RTPENGINE_MEDIA_IP (make interop sets them).
-module(chappe_sip_siprec_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([both_parties_recorded/1]).

-define(UA, chappe_sip_test_ua).
-define(NODE, chappe_sip_siprec_live).
%% the mu-law bytes each party sends: two distinct levels
-define(A_BYTE, 16#20).
-define(B_BYTE, 16#10).

all() -> [both_parties_recorded].

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

end_per_suite(_Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_rtpengine:remove_node(?NODE),
    _ = application:stop(chappe_sip),
    _ = application:stop(chappe_rtpengine),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

%% req: R7866-7.1.1-1 R7866-8.3-1 R6341-REQ-012
both_parties_recorded(Config) ->
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
                        sink => Test, ip => {0, 0, 0, 0}, advertise => MediaIp
                    }),
                Test ! {srs_streams, Streams},
                chappe_sip_siprec_srs:run(Srs);
            _ ->
                Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
                {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{media => anchor}),
                Test ! {legs, Legs},
                chappe_sip_b2b:relay(Legs)
        end
    end, #{option_tags => [<<"siprec">>]}),
    {MA, PA} = media_socket(),
    {MB, PB} = media_socket(),
    %% the callee: answers with its media address, then waits
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Test ! {b_offer, ?UA:body(Inv)},
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, ?UA:tag(),
                                     [{<<"Contact">>, contact(Sock)}], sdp(MediaIp, PB))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     body => sdp(MediaIp, PA)}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP),
        Test ! {a_answer, ?UA:body(R)},
        timer:sleep(infinity)
    end),
    #{b2b := B2b, call_ref := Ref} = got(legs),
    ToA = audio_port(got(a_answer)),
    ToB = audio_port(got(b_offer)),
    {ok, Rec} = chappe_sip_siprec:start(B2b, <<"sip:srs@127.0.0.1:", (integer_to_binary(EP))/binary>>, #{}),
    {started, #{call_ref := Ref}} = event(Rec),
    [#{pid := S1, label := <<"1">>}, #{pid := S2, label := <<"2">>}] = got(srs_streams),
    %% both parties talk at once, 1.5 s
    lists:foreach(
        fun(Seq) ->
            ok = gen_udp:send(MA, RtpeIp, ToA, rtp(16#A, Seq, ?A_BYTE)),
            ok = gen_udp:send(MB, RtpeIp, ToB, rtp(16#B, Seq, ?B_BYTE)),
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
    %% and the call itself carries both ways
    ?assert(heard(MA) > 0),
    ?assert(heard(MB) > 0),
    ok = chappe_sip_siprec:stop(Rec),
    {stopped, #{reason := stopped}} = event(Rec),
    ok = chappe_sip_b2b:hangup(B2b, #{}).

%% ---- helpers ----

media_socket() ->
    {ok, S} = gen_udp:open(0, [binary, {ip, {0, 0, 0, 0}}, {active, true}]),
    {ok, P} = inet:port(S),
    {S, P}.

sdp(Ip, Port) ->
    <<"v=0\r\no=- 1 1 IN IP4 ", Ip/binary, "\r\ns=-\r\nc=IN IP4 ", Ip/binary,
      "\r\nt=0 0\r\nm=audio ", (integer_to_binary(Port))/binary,
      " RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\na=sendrecv\r\n">>.

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

heard(Sock) ->
    heard(Sock, 0).

heard(Sock, N) ->
    receive {udp, Sock, _, _, _} -> heard(Sock, N + 1) after 0 -> N end.

event(Rec) ->
    receive {chappe_sip_siprec, Rec, Ev} -> Ev after 15000 -> ct:fail(no_event) end.

got(Tag) ->
    receive {Tag, V} -> V after 10000 -> ct:fail({missing, Tag}) end.
