%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The two shapes a recording/interpreter product needs from a real
%% rtpengine:
%%
%%   1. a passive, receive-only anchor for an inbound multi-stream
%%      recording offer (SIPREC: N sendonly m-lines, one per recorded
%%      party) with no second leg to negotiate, and each of those
%%      streams forked out as its own clean PCMU flow to its own
%%      receiver socket;
%%   2. injecting audio into one party's leg of an anchored call while
%%      the other party is ducked, and restoring both.
%%
%% Gated on RTPENGINE_HOST; the media cases also need RTPENGINE_MEDIA_IP
%% (the address rtpengine can send media back to). test/e2e.sh starts the
%% dockerized rtpengine and sets both.
-module(chappe_rtpengine_siprec_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    publish_anchors_every_stream/1,
    per_stream_fork_to_receivers/1,
    one_subscription_many_receivers/1,
    inject_into_one_leg_while_ducked/1
]).

-define(NODE, chappe_rtpengine_siprec).
%% one m-line per recorded party in the SIPREC offer
-define(STREAMS, 3).

all() ->
    [
        publish_anchors_every_stream,
        per_stream_fork_to_receivers,
        one_subscription_many_receivers,
        inject_into_one_leg_while_ducked
    ].

init_per_suite(Config) ->
    case os:getenv("RTPENGINE_HOST") of
        false ->
            {skip, "RTPENGINE_HOST not set"};
        Host ->
            Port =
                case os:getenv("RTPENGINE_PORT") of
                    false -> 2223;
                    P -> list_to_integer(P)
                end,
            {ok, _} = application:ensure_all_started(chappe_rtpengine),
            ok = chappe_rtpengine:add_node(?NODE, #{host => Host, port => Port}),
            Config
    end.

end_per_suite(_Config) ->
    _ = chappe_rtpengine:remove_node(?NODE),
    ok = application:stop(chappe_rtpengine).

%% cases

%% The control-plane half of a recording server: one dialog, one
%% from-tag, N sendonly streams, no onward leg. publish answers all of
%% them itself (recvonly, at rtpengine's own addresses) and the
%% subscription offer that follows exposes the same N streams in
%% m-line order, still carrying the source labels. No media, so this
%% case runs without RTPENGINE_MEDIA_IP.
publish_anchors_every_stream(_Config) ->
    {CallId, SrcTag} = tags(<<"publish">>),
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => ?NODE
    }),
    {ok, PubReply} = chappe_rtpengine_session:publish(Sess, #{
        from_tag => SrcTag,
        sdp => recording_offer(<<"198.51.100.1">>, [40000, 40002, 40004]),
        ice => remove
    }),
    Answer = chappe_rtpengine_ng:sdp(PubReply),
    ?assertEqual(?STREAMS, length(chappe_rtpengine_sdp:streams(Answer))),
    lists:foreach(
        fun(#{port := Port}) -> ?assert(Port > 0) end,
        chappe_rtpengine_sdp:streams(Answer)
    ),
    %% the recording server only receives
    ?assertEqual(?STREAMS, count(Answer, <<"a=recvonly">>)),
    ?assertEqual(
        established, maps:get(state, chappe_rtpengine_session:info(Sess))
    ),

    {ok, Sub} = subscribe(Sess, SrcTag),
    Streams = chappe_rtpengine_sdp:streams(chappe_rtpengine_ng:sdp(Sub)),
    ?assertEqual(
        [<<"1">>, <<"2">>, <<"3">>],
        [L || #{label := L} <- Streams]
    ),
    ?assertEqual([0, 1, 2], [I || #{index := I} <- Streams]),

    {ok, _} = chappe_rtpengine_cmd:unsubscribe(Sess, #{
        to_tag => maps:get(<<"to-tag">>, Sub)
    }),

    %% the siprec flag relabels the streams zero-based, in m-line order:
    %% the source labels are gone (rtpengine 26.3; 11.5 kept them and
    %% added the zero-based one beside each, so label "1" named two
    %% streams)
    {ok, Sub2} = chappe_rtpengine_cmd:subscribe_request(Sess, #{
        from_tags => [SrcTag], flags => [siprec]
    }),
    Labelled = chappe_rtpengine_sdp:streams(chappe_rtpengine_ng:sdp(Sub2)),
    ?assertEqual(
        [[<<"0">>], [<<"1">>], [<<"2">>]],
        [Ls || #{labels := Ls} <- Labelled]
    ),
    {ok, _} = chappe_rtpengine_cmd:unsubscribe(Sess, #{
        to_tag => maps:get(<<"to-tag">>, Sub2)
    }),
    ok = chappe_rtpengine_session:stop(Sess),
    ok.

%% The end-to-end recording fork: anchor a three-stream offer, then one
%% subscription per stream, each transcoded to PCMU at ptime 20 and
%% answered so that only its own m-line is live, at its own receiver
%% socket. Each recorded party then sends a distinct tone, and every
%% receiver must decode its own party's tone and nothing else.
per_stream_fork_to_receivers(_Config) ->
    MediaIP = media_ip(),
    {CallId, SrcTag} = tags(<<"fork">>),
    Sources = [socket() || _ <- lists:seq(1, ?STREAMS)],
    Receivers = [socket() || _ <- lists:seq(1, ?STREAMS)],
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => ?NODE
    }),
    SrcPorts = anchor(Sess, SrcTag, MediaIP, Sources),

    %% one subscription per recorded party, keyed on its SDP label
    Subs = [
        begin
            {ok, Sub} = subscribe(Sess, SrcTag),
            SubTag = maps:get(<<"to-tag">>, Sub),
            {ok, Answer} = chappe_rtpengine_sdp:fork_answer(
                chappe_rtpengine_ng:sdp(Sub),
                {label, label(I)},
                #{
                    address => MediaIP,
                    port => port_of(I, Receivers),
                    ptime => 20
                }
            ),
            {ok, _} = chappe_rtpengine_cmd:subscribe_answer(Sess, #{
                to_tag => SubTag,
                sdp => Answer,
                flags => [allow_transcoding]
            }),
            SubTag
        end
     || I <- lists:seq(1, ?STREAMS)
    ],

    ok = pump(Sources, SrcPorts),
    assert_separated(Receivers),

    lists:foreach(
        fun(SubTag) ->
            {ok, _} = chappe_rtpengine_cmd:unsubscribe(Sess, #{
                to_tag => SubTag
            })
        end,
        Subs
    ),
    ok = chappe_rtpengine_session:stop(Sess),
    close(Sources ++ Receivers),
    ok.

%% The same fork from a single subscription: the one answer routes each
%% m-line to its own receiver. Cheaper on the daemon (one subscription
%% instead of N), same separation at the receivers.
one_subscription_many_receivers(_Config) ->
    MediaIP = media_ip(),
    {CallId, SrcTag} = tags(<<"multi">>),
    Sources = [socket() || _ <- lists:seq(1, ?STREAMS)],
    Receivers = [socket() || _ <- lists:seq(1, ?STREAMS)],
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => ?NODE
    }),
    SrcPorts = anchor(Sess, SrcTag, MediaIP, Sources),

    {ok, Sub} = subscribe(Sess, SrcTag),
    SubTag = maps:get(<<"to-tag">>, Sub),
    Routes = [
        {
            {label, label(I)},
            #{address => MediaIP, port => port_of(I, Receivers), ptime => 20}
        }
     || I <- lists:seq(1, ?STREAMS)
    ],
    {ok, Answer} = chappe_rtpengine_sdp:fork_answer(
        chappe_rtpengine_ng:sdp(Sub), Routes
    ),
    {ok, _} = chappe_rtpengine_cmd:subscribe_answer(Sess, #{
        to_tag => SubTag, sdp => Answer, flags => [allow_transcoding]
    }),

    ok = pump(Sources, SrcPorts),
    assert_separated(Receivers),

    {ok, _} = chappe_rtpengine_cmd:unsubscribe(Sess, #{to_tag => SubTag}),
    ok = chappe_rtpengine_session:stop(Sess),
    close(Sources ++ Receivers),
    ok.

%% The interpreter primitive on a two-legged call: duck one party, play
%% a clip into the other party's leg, then restore. While the caller is
%% blocked the only media reaching the callee is the injected clip, and
%% after stop media plus unblock the caller's own media flows again.
inject_into_one_leg_while_ducked(_Config) ->
    MediaIP = media_ip(),
    {CallId, FromTag} = tags(<<"inject">>),
    ToTag = <<"to-", FromTag/binary>>,
    {SockA, PortA} = socket(),
    {SockB, PortB} = socket(),
    {ok, RtpeIP} = inet:parse_address(os:getenv("RTPENGINE_HOST")),

    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => ?NODE
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => FromTag,
        sdp => leg_sdp(MediaIP, PortA),
        ice => remove
    }),
    {ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => ToTag,
        sdp => leg_sdp(MediaIP, PortB),
        ice => remove
    }),
    ToCaller = audio_port(chappe_rtpengine_ng:sdp(AnswerReply)),
    ok = relay(SockA, RtpeIP, ToCaller, SockB),

    %% duck the caller: nothing it sends reaches the callee
    {ok, _} = chappe_rtpengine_cmd:block_media(Sess, #{party => caller}),
    ok = assert_blocked(SockA, RtpeIP, ToCaller, SockB),

    %% inject into the callee's leg; with the caller ducked, anything
    %% arriving at the callee socket is the injected clip
    case
        chappe_rtpengine_cmd:play_media(Sess, #{
            blob => wav_blob(400), party => callee
        })
    of
        {ok, _} ->
            ?assert(received_within(SockB, 3000)),
            case chappe_rtpengine_cmd:stop_media(Sess) of
                {ok, _} -> ok;
                {error, <<"Not currently playing media">>, _} -> ok
            end,
            timer:sleep(300),
            drain(SockB);
        {error, <<"Unrecognized command">>, _} ->
            ct:log("rtpengine built without the media player");
        Other ->
            error({play_media_failed, Other})
    end,

    %% restore: the caller's own media relays again
    {ok, _} = chappe_rtpengine_cmd:unblock_media(Sess, #{party => caller}),
    ok = relay(SockA, RtpeIP, ToCaller, SockB),

    ok = chappe_rtpengine_session:stop(Sess),
    close([{SockA, PortA}, {SockB, PortB}]),
    ok.

%% helpers

media_ip() ->
    case os:getenv("RTPENGINE_MEDIA_IP") of
        false -> throw({skip, "RTPENGINE_MEDIA_IP not set"});
        "" -> throw({skip, "RTPENGINE_MEDIA_IP empty"});
        IP -> list_to_binary(IP)
    end.

%% Anchor the recording offer and return rtpengine's receiving port per
%% stream, in m-line order.
anchor(Sess, SrcTag, MediaIP, Sources) ->
    Offer = recording_offer(MediaIP, [P || {_, P} <- Sources]),
    {ok, PubReply} = chappe_rtpengine_session:publish(Sess, #{
        from_tag => SrcTag, sdp => Offer, ice => remove
    }),
    Ports = [
        P
     || #{port := P} <- chappe_rtpengine_sdp:streams(
            chappe_rtpengine_ng:sdp(PubReply)
        )
    ],
    ?assertEqual(?STREAMS, length(Ports)),
    Ports.

%% A fork the receiver needs no codec logic for: source codecs masked
%% out, PCMU only, fixed 20 ms packetization.
subscribe(Sess, SrcTag) ->
    chappe_rtpengine_cmd:subscribe_request(Sess, #{
        from_tags => [SrcTag],
        codec => #{mask => [all], transcode => ['PCMU']},
        ptime => 20
    }).

%% Each recorded party sends a constant tone at its own level, so a
%% receiver's decoded audio names the party it came from.
pump(Sources, SrcPorts) ->
    {ok, RtpeIP} = inet:parse_address(os:getenv("RTPENGINE_HOST")),
    lists:foreach(
        fun(Seq) ->
            lists:foreach(
                fun(I) ->
                    {Sock, _} = lists:nth(I, Sources),
                    Payload = binary:copy(<<(ulaw_byte(I))>>, 160),
                    ok = gen_udp:send(
                        Sock,
                        RtpeIP,
                        lists:nth(I, SrcPorts),
                        rtp(16#100 + I, Seq, Payload)
                    )
                end,
                lists:seq(1, ?STREAMS)
            ),
            timer:sleep(20)
        end,
        lists:seq(1, 75)
    ),
    timer:sleep(500),
    ok.

%% Every receiver decoded its own party's tone, and never another
%% party's: that is what makes the forks separate streams rather than
%% one mixed feed.
assert_separated(Receivers) ->
    lists:foreach(
        fun(I) ->
            {Sock, _} = lists:nth(I, Receivers),
            {Count, Levels} = decoded(Sock),
            ct:log("receiver ~p: ~p packets, levels ~p", [I, Count, Levels]),
            ?assert(Count > 0),
            ?assert(lists:member(level(I), Levels)),
            Foreign = [
                L
             || L <- Levels,
                L =/= level(I),
                lists:member(L, [level(J) || J <- lists:seq(1, ?STREAMS)])
            ],
            ?assertEqual([], Foreign)
        end,
        lists:seq(1, ?STREAMS)
    ).

%% One mu-law byte per recorded party, three segments apart, so a
%% decoded sample names the party that sent it. Silence decodes to 0
%% and is ignored: rtpengine may pad the fork while a source is quiet.
ulaw_byte(1) -> 16#20;
ulaw_byte(2) -> 16#10;
ulaw_byte(3) -> 16#00.

level(I) -> unulaw(ulaw_byte(I)).

label(I) -> integer_to_binary(I).

port_of(I, Socks) ->
    {_, Port} = lists:nth(I, Socks),
    Port.

%% Decode the RTP payloads waiting on a receiver socket, returning the
%% packet count and the distinct PCM levels seen.
decoded(Sock) ->
    decoded(Sock, 0, []).

decoded(Sock, N, Levels) ->
    receive
        {udp, Sock, _IP, _Port,
            <<2:2, _:6, _:8, _:16, _:32, _:32, Payload/binary>>} ->
            Seen = lists:usort([
                unulaw(B)
             || <<B>> <= binary:part(Payload, 0, min(80, byte_size(Payload)))
            ]),
            decoded(Sock, N + 1, lists:umerge(Levels, Seen));
        {udp, Sock, _IP, _Port, _Other} ->
            decoded(Sock, N + 1, Levels)
    after 0 ->
        {N, Levels}
    end.

%% G.711 mu-law decode (the reference implementation), so the suite
%% asserts on decoded audio rather than on payload bytes.
unulaw(Byte) ->
    U = bnot Byte band 16#FF,
    T = (((U band 16#0F) bsl 3) + 16#84) bsl ((U band 16#70) bsr 4),
    case U band 16#80 of
        0 -> T - 16#84;
        _ -> 16#84 - T
    end.

%% A recording offer: one sendonly m-line per recorded party, each
%% carrying the label the metadata refers to.
recording_offer(IP, Ports) ->
    Head = [
        <<"v=0\r\n">>,
        <<"o=- 1 1 IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"s=siprec\r\n">>,
        <<"c=IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"t=0 0\r\n">>
    ],
    Media = [
        [
            <<"m=audio ">>,
            integer_to_binary(lists:nth(I, Ports)),
            <<" RTP/AVP 0 8\r\n">>,
            <<"a=rtpmap:0 PCMU/8000\r\n">>,
            <<"a=rtpmap:8 PCMA/8000\r\n">>,
            <<"a=sendonly\r\n">>,
            <<"a=label:">>,
            label(I),
            <<"\r\n">>
        ]
     || I <- lists:seq(1, length(Ports))
    ],
    iolist_to_binary([Head, Media]).

leg_sdp(IP, Port) ->
    iolist_to_binary([
        <<"v=0\r\n">>,
        <<"o=- 1 1 IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"s=call\r\n">>,
        <<"c=IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"t=0 0\r\n">>,
        <<"m=audio ">>,
        integer_to_binary(Port),
        <<" RTP/AVP 0\r\n">>,
        <<"a=rtpmap:0 PCMU/8000\r\n">>,
        <<"a=sendrecv\r\n">>
    ]).

%% 8 kHz mono 16-bit PCM WAV of silence, a stand-in for a TTS clip.
%% rtpengine paces it out as RTP, which is what the assertion needs.
%% Keep it under one MTU: a blob rides inside the NG datagram, so a
%% real-size clip needs the TCP or WebSocket transport (proven by
%% chappe_rtpengine_e2e_SUITE:ws_blob_playback_over_mtu/1) or a file path.
wav_blob(Samples) ->
    Data = binary:copy(<<0, 0>>, Samples),
    Sz = byte_size(Data),
    <<"RIFF", (36 + Sz):32/little, "WAVE", "fmt ", 16:32/little, 1:16/little,
        1:16/little, 8000:32/little, 16000:32/little, 2:16/little, 16:16/little,
        "data", Sz:32/little, Data/binary>>.

count(Bin, Needle) ->
    length(binary:matches(Bin, Needle)).

audio_port(SDP) ->
    [#{port := Port} | _] = chappe_rtpengine_sdp:streams(SDP),
    Port.

tags(Kind) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    {
        <<"chappe-siprec-", Kind/binary, "-", Suffix/binary>>,
        <<"from-", Suffix/binary>>
    }.

socket() ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}]),
    {ok, Port} = inet:port(Sock),
    {Sock, Port}.

close(Socks) ->
    lists:foreach(fun({Sock, _}) -> gen_udp:close(Sock) end, Socks).

rtp(Ssrc, Seq, Payload) ->
    <<2:2, 0:1, 0:1, 0:4, 0:1, 0:7, (Seq rem 65536):16, (Seq * 160):32, Ssrc:32,
        Payload/binary>>.

%% Send until the far socket sees it: the first packets can race
%% rtpengine's port setup.
relay(FromSock, RtpeIP, RtpePort, ToSock) ->
    relay(FromSock, RtpeIP, RtpePort, ToSock, 25, 1).

relay(_FromSock, _RtpeIP, _RtpePort, _ToSock, 0, _Seq) ->
    error(no_media_relayed);
relay(FromSock, RtpeIP, RtpePort, ToSock, N, Seq) ->
    Packet = rtp(16#2000, Seq, binary:copy(<<(ulaw_byte(1))>>, 160)),
    ok = gen_udp:send(FromSock, RtpeIP, RtpePort, Packet),
    receive
        {udp, ToSock, _IP, _Port, Received} ->
            ?assertEqual(Packet, Received),
            drain(ToSock),
            ok
    after 200 ->
        relay(FromSock, RtpeIP, RtpePort, ToSock, N - 1, Seq + 1)
    end.

assert_blocked(FromSock, RtpeIP, RtpePort, ToSock) ->
    drain(ToSock),
    lists:foreach(
        fun(Seq) ->
            ok = gen_udp:send(
                FromSock,
                RtpeIP,
                RtpePort,
                rtp(16#2000, 500 + Seq, binary:copy(<<16#FF>>, 160))
            ),
            timer:sleep(40)
        end,
        lists:seq(1, 5)
    ),
    receive
        {udp, ToSock, _IP, _Port, _Packet} -> error(media_not_blocked)
    after 300 -> ok
    end.

received_within(Sock, TimeoutMs) ->
    receive
        {udp, Sock, _IP, _Port, _Packet} ->
            drain(Sock),
            true
    after TimeoutMs -> false
    end.

drain(Sock) ->
    receive
        {udp, Sock, _, _, _} -> drain(Sock)
    after 0 -> ok
    end.
