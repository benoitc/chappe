%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% End-to-end tests against a real rtpengine: encryption negotiation
%% (SDES-SRTP and DTLS-SRTP offer/answer rewriting) and an actual RTP
%% packet relayed through rtpengine both ways via a media session.
%%
%% Gated on RTPENGINE_HOST (and RTPENGINE_MEDIA_IP for the relay
%% case). test/e2e.sh starts a dockerized rtpengine with the right
%% configuration and runs this suite plus chappe_rtpengine_live_SUITE.
-module(chappe_rtpengine_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    srtp_sdes_negotiation/1,
    dtls_srtp_negotiation/1,
    media_relay_through_session/1,
    interpreter_primitives/1,
    recording_and_dtmf/1,
    ws_media_relay_through_session/1,
    ws_blob_playback_over_mtu/1
]).

all() ->
    [
        srtp_sdes_negotiation,
        dtls_srtp_negotiation,
        media_relay_through_session,
        interpreter_primitives,
        recording_and_dtmf,
        ws_media_relay_through_session,
        ws_blob_playback_over_mtu
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
            {ok, _} = application:ensure_all_started(crypto),
            {ok, _} = application:ensure_all_started(chappe_rtpengine),
            ok = chappe_rtpengine:add_node(chappe_rtpengine_e2e, #{
                host => Host, port => Port
            }),
            Config
    end.

end_per_suite(_Config) ->
    _ = chappe_rtpengine:remove_node(chappe_rtpengine_e2e),
    ok = application:stop(chappe_rtpengine).

%% cases

%% A plain-RTP caller bridged to an SRTP (SDES) callee: the rewritten
%% offer must carry crypto attributes, the rewritten answer toward the
%% caller must not.
srtp_sdes_negotiation(_Config) ->
    {CallId, FromTag, ToTag} = tags(<<"sdes">>),
    {ok, OfferReply} = chappe_rtpengine:offer(chappe_rtpengine_e2e, #{
        call_id => CallId,
        from_tag => FromTag,
        sdp => sdp(<<"198.51.100.1">>, 40000, <<"RTP/AVP">>, []),
        transport_protocol => <<"RTP/SAVP">>,
        ice => remove
    }),
    OfferSDP = chappe_rtpengine_ng:sdp(OfferReply),
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"RTP/SAVP">>)),
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"a=crypto:">>)),

    {ok, AnswerReply} = chappe_rtpengine:answer(chappe_rtpengine_e2e, #{
        call_id => CallId,
        from_tag => FromTag,
        to_tag => ToTag,
        sdp => sdp(<<"198.51.100.2">>, 40002, <<"RTP/SAVP">>, [sdes_attr()]),
        transport_protocol => <<"RTP/AVP">>,
        ice => remove
    }),
    AnswerSDP = chappe_rtpengine_ng:sdp(AnswerReply),
    ?assertNotEqual(nomatch, binary:match(AnswerSDP, <<"RTP/AVP">>)),
    ?assertEqual(nomatch, binary:match(AnswerSDP, <<"a=crypto:">>)),

    {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_e2e, #{
        call_id => CallId, from_tag => FromTag
    }),
    ok.

%% A plain-RTP caller bridged to a DTLS-SRTP (WebRTC-style) callee:
%% the rewritten offer must carry rtpengine's certificate fingerprint
%% and a setup role.
dtls_srtp_negotiation(_Config) ->
    {CallId, FromTag, ToTag} = tags(<<"dtls">>),
    {ok, OfferReply} = chappe_rtpengine:offer(chappe_rtpengine_e2e, #{
        call_id => CallId,
        from_tag => FromTag,
        sdp => sdp(<<"198.51.100.1">>, 40004, <<"RTP/AVP">>, []),
        transport_protocol => <<"UDP/TLS/RTP/SAVPF">>,
        ice => remove
    }),
    OfferSDP = chappe_rtpengine_ng:sdp(OfferReply),
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"UDP/TLS/RTP/SAVPF">>)),
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"a=fingerprint:">>)),
    ?assertNotEqual(nomatch, binary:match(OfferSDP, <<"a=setup:">>)),

    {ok, AnswerReply} = chappe_rtpengine:answer(chappe_rtpengine_e2e, #{
        call_id => CallId,
        from_tag => FromTag,
        to_tag => ToTag,
        sdp => sdp(<<"198.51.100.2">>, 40006, <<"UDP/TLS/RTP/SAVPF">>, [
            <<"a=setup:active\r\n">>,
            fingerprint_attr()
        ]),
        transport_protocol => <<"RTP/AVP">>,
        ice => remove
    }),
    AnswerSDP = chappe_rtpengine_ng:sdp(AnswerReply),
    ?assertEqual(nomatch, binary:match(AnswerSDP, <<"a=fingerprint:">>)),

    {ok, _} = chappe_rtpengine:delete(chappe_rtpengine_e2e, #{
        call_id => CallId, from_tag => FromTag
    }),
    ok.

%% Full path through the library and the daemon: a session pins the
%% node, negotiates both legs, and an RTP packet sent by each party
%% comes out at the other party's socket, relayed by rtpengine.
%% Needs RTPENGINE_MEDIA_IP: the address rtpengine can reach this
%% machine at (test/e2e.sh discovers it from inside the container).
media_relay_through_session(_Config) ->
    MediaIP =
        case os:getenv("RTPENGINE_MEDIA_IP") of
            false -> throw({skip, "RTPENGINE_MEDIA_IP not set"});
            "" -> throw({skip, "RTPENGINE_MEDIA_IP empty"});
            IP -> list_to_binary(IP)
        end,
    {CallId, FromTag, ToTag} = tags(<<"relay">>),
    {ok, SockA} = gen_udp:open(0, [binary, {active, true}]),
    {ok, SockB} = gen_udp:open(0, [binary, {active, true}]),
    {ok, PortA} = inet:port(SockA),
    {ok, PortB} = inet:port(SockB),

    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => chappe_rtpengine_e2e
    }),
    {ok, OfferReply} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => FromTag,
        sdp => sdp(MediaIP, PortA, <<"RTP/AVP">>, []),
        ice => remove
    }),
    ToCalleePort = sdp_audio_port(chappe_rtpengine_ng:sdp(OfferReply)),
    {ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => ToTag,
        sdp => sdp(MediaIP, PortB, <<"RTP/AVP">>, []),
        ice => remove
    }),
    ToCallerPort = sdp_audio_port(chappe_rtpengine_ng:sdp(AnswerReply)),

    Host = os:getenv("RTPENGINE_HOST"),
    {ok, RtpeIP} = inet:parse_address(Host),
    Payload = <<"chappe-rtpengine-e2e-payload">>,
    %% caller -> rtpengine (caller-side port) -> callee socket
    ok = relay(SockA, RtpeIP, ToCallerPort, SockB, rtp(1, Payload)),
    %% callee -> rtpengine (callee-side port) -> caller socket
    ok = relay(SockB, RtpeIP, ToCalleePort, SockA, rtp(2, Payload)),

    ok = chappe_rtpengine_session:stop(Sess),
    gen_udp:close(SockA),
    gen_udp:close(SockB),
    ok.

%% The three interpreter primitives over one anchored call, against a
%% transcoding-enabled rtpengine: fork a party's media to an external
%% receiver (the STT feed), inject a synthesized clip into one leg
%% (TTS), and block/unblock one direction (ducking). Two UDP sockets
%% act as the parties, a third as the receiver. Skips when the build
%% has no subscribe support or RTPENGINE_MEDIA_IP is not set.
interpreter_primitives(_Config) ->
    MediaIP =
        case os:getenv("RTPENGINE_MEDIA_IP") of
            false -> throw({skip, "RTPENGINE_MEDIA_IP not set"});
            "" -> throw({skip, "RTPENGINE_MEDIA_IP empty"});
            IP -> list_to_binary(IP)
        end,
    {CallId, FromTag, ToTag} = tags(<<"interp">>),
    {ok, SockA} = gen_udp:open(0, [binary, {active, true}]),
    {ok, SockB} = gen_udp:open(0, [binary, {active, true}]),
    {ok, SockR} = gen_udp:open(0, [binary, {active, true}]),
    {ok, PortA} = inet:port(SockA),
    {ok, PortB} = inet:port(SockB),
    {ok, PortR} = inet:port(SockR),
    Host = os:getenv("RTPENGINE_HOST"),
    {ok, RtpeIP} = inet:parse_address(Host),

    %% anchor the call
    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => chappe_rtpengine_e2e
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => FromTag,
        sdp => sdp(MediaIP, PortA, <<"RTP/AVP">>, []),
        ice => remove
    }),
    {ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => ToTag,
        sdp => sdp(MediaIP, PortB, <<"RTP/AVP">>, []),
        ice => remove
    }),
    ToCallerPort = sdp_audio_port(chappe_rtpengine_ng:sdp(AnswerReply)),
    Payload = <<"chappe-interpreter-e2e">>,
    ok = relay(SockA, RtpeIP, ToCallerPort, SockB, rtp(1, Payload)),

    %% 1) fork the caller's media to the receiver as plain PCMU
    case
        chappe_rtpengine_cmd:subscribe_request(Sess, #{
            from_tags => [FromTag],
            codec => #{mask => [all], transcode => ['PCMU']},
            ptime => 20
        })
    of
        {error, <<"Unrecognized command">>, _} ->
            ok = chappe_rtpengine_session:stop(Sess),
            throw({skip, "rtpengine built without subscribe support"});
        {ok, SubReply} ->
            SubTag = maps:get(<<"to-tag">>, SubReply),
            %% allow-transcoding lets the receiver answer with fewer
            %% codecs than the source party offers (PCMU only here);
            %% without it rtpengine requires a full answer
            {ok, _} = chappe_rtpengine_cmd:subscribe_answer(Sess, #{
                to_tag => SubTag,
                sdp => receiver_sdp(MediaIP, PortR),
                flags => [allow_transcoding]
            }),
            ok = fork_received(SockA, RtpeIP, ToCallerPort, SockR),

            %% 2) inject a synthesized clip into the callee leg. The
            %% clip is kept under one MTU: blobs ride inside the NG
            %% datagram, so real-size TTS clips belong on the TCP
            %% transport or on a file path.
            {ok, _} = chappe_rtpengine_cmd:play_media(Sess, #{
                blob => wav_blob(400),
                party => callee
            }),
            %% the clip is 50 ms; it may already be done when we stop
            case chappe_rtpengine_cmd:stop_media(Sess) of
                {ok, _} -> ok;
                {error, <<"Not currently playing media">>, _} -> ok
            end,
            %% let the player's paced packets toward the callee land
            %% before asserting on blocked media
            timer:sleep(300),
            drain(SockB),

            %% 3) duck the caller direction and restore it
            {ok, _} = chappe_rtpengine_cmd:block_media(Sess, #{party => caller}),
            ok = assert_blocked(SockA, RtpeIP, ToCallerPort, SockB),
            {ok, _} = chappe_rtpengine_cmd:unblock_media(Sess, #{
                party => caller
            }),
            ok = relay(SockA, RtpeIP, ToCallerPort, SockB, rtp(60, Payload)),
            {ok, _} = chappe_rtpengine_cmd:silence_media(Sess, #{
                party => caller
            }),
            {ok, _} = chappe_rtpengine_cmd:unsilence_media(Sess, #{
                party => caller
            }),

            {ok, _} = chappe_rtpengine_cmd:unsubscribe(Sess, #{to_tag => SubTag}),
            ok = chappe_rtpengine_session:stop(Sess)
    end,
    gen_udp:close(SockA),
    gen_udp:close(SockB),
    gen_udp:close(SockR),
    ok.

%% Recording and DTMF over one anchored call, completing the e2e feature
%% matrix (the other cases cover relay, subscribe/play/block/silence).
%% start/stop recording needs an rtpengine started with a recording dir,
%% and DTMF injection needs transcoding; both degrade to a log line when
%% the build/config lacks them, so a minimal rtpengine still passes on the
%% always-available block/unblock DTMF. No media relay, so no MediaIP.
recording_and_dtmf(_Config) ->
    {CallId, FromTag, ToTag} = tags(<<"recdtmf">>),
    {ok, SockA} = gen_udp:open(0, [binary, {active, true}]),
    {ok, SockB} = gen_udp:open(0, [binary, {active, true}]),
    {ok, PortA} = inet:port(SockA),
    {ok, PortB} = inet:port(SockB),
    IP = <<"127.0.0.1">>,

    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => chappe_rtpengine_e2e
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => FromTag,
        sdp => sdp(IP, PortA, <<"RTP/AVP">>, []),
        ice => remove
    }),
    {ok, _} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => ToTag,
        sdp => sdp(IP, PortB, <<"RTP/AVP">>, []),
        ice => remove
    }),

    %% recording (needs --recording-dir on the rtpengine)
    case chappe_rtpengine_cmd:start_recording(Sess) of
        {ok, _} ->
            {ok, _} = chappe_rtpengine_cmd:stop_recording(Sess);
        Other1 ->
            ct:log("recording unavailable: ~p", [Other1])
    end,

    %% DTMF injection (needs transcoding)
    case chappe_rtpengine_cmd:play_dtmf(Sess, #{code => 5, duration => 100}) of
        {ok, _} ->
            case chappe_rtpengine_cmd:stop_media(Sess) of
                {ok, _} -> ok;
                {error, _, _} -> ok
            end;
        Other2 ->
            ct:log("DTMF injection unavailable: ~p", [Other2])
    end,

    %% DTMF blocking is core (no transcoding); assert it works.
    {ok, _} = chappe_rtpengine_cmd:block_dtmf(Sess),
    {ok, _} = chappe_rtpengine_cmd:unblock_dtmf(Sess),

    ok = chappe_rtpengine_session:stop(Sess),
    gen_udp:close(SockA),
    gen_udp:close(SockB),
    ok.

%% The same full path as media_relay_through_session, but the control
%% channel is a WebSocket: a session pins a ws-transport node, both
%% legs negotiate over it, and RTP relays both ways. Needs
%% RTPENGINE_HTTP_PORT and RTPENGINE_MEDIA_IP.
ws_media_relay_through_session(_Config) ->
    HttpPort = ws_port(),
    MediaIP = media_ip(),
    Host = os:getenv("RTPENGINE_HOST"),
    ok = chappe_rtpengine:add_node(chappe_rtpengine_e2e_ws, #{
        host => Host, port => HttpPort, transport => ws
    }),
    {CallId, FromTag, ToTag} = tags(<<"ws-relay">>),
    {ok, SockA} = gen_udp:open(0, [binary, {active, true}]),
    {ok, SockB} = gen_udp:open(0, [binary, {active, true}]),
    {ok, PortA} = inet:port(SockA),
    {ok, PortB} = inet:port(SockB),

    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => chappe_rtpengine_e2e_ws
    }),
    {ok, OfferReply} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => FromTag,
        sdp => sdp(MediaIP, PortA, <<"RTP/AVP">>, []),
        ice => remove
    }),
    ToCalleePort = sdp_audio_port(chappe_rtpengine_ng:sdp(OfferReply)),
    {ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => ToTag,
        sdp => sdp(MediaIP, PortB, <<"RTP/AVP">>, []),
        ice => remove
    }),
    ToCallerPort = sdp_audio_port(chappe_rtpengine_ng:sdp(AnswerReply)),

    {ok, RtpeIP} = inet:parse_address(Host),
    Payload = <<"chappe-rtpengine-ws-e2e">>,
    ok = relay(SockA, RtpeIP, ToCallerPort, SockB, rtp(1, Payload)),
    ok = relay(SockB, RtpeIP, ToCalleePort, SockA, rtp(2, Payload)),

    ok = chappe_rtpengine_session:stop(Sess),
    gen_udp:close(SockA),
    gen_udp:close(SockB),
    _ = chappe_rtpengine:remove_node(chappe_rtpengine_e2e_ws),
    ok.

%% Blobs ride inside the NG message, so a clip over one MTU cannot
%% cross the UDP transport; over the WebSocket it is just a bigger
%% frame. Anchor a call over ws, play a 16 KiB WAV toward the callee,
%% and assert the paced RTP lands at the callee's socket. Needs
%% RTPENGINE_HTTP_PORT and RTPENGINE_MEDIA_IP, plus a build with the
%% media player (skips otherwise, like the interpreter case).
ws_blob_playback_over_mtu(_Config) ->
    HttpPort = ws_port(),
    MediaIP = media_ip(),
    Host = os:getenv("RTPENGINE_HOST"),
    ok = chappe_rtpengine:add_node(chappe_rtpengine_e2e_ws_blob, #{
        host => Host, port => HttpPort, transport => ws
    }),
    {CallId, FromTag, ToTag} = tags(<<"ws-blob">>),
    {ok, SockA} = gen_udp:open(0, [binary, {active, true}]),
    {ok, SockB} = gen_udp:open(0, [binary, {active, true}]),
    {ok, PortA} = inet:port(SockA),
    {ok, PortB} = inet:port(SockB),

    {ok, Sess} = chappe_rtpengine:start_session(#{
        call_id => CallId, node => chappe_rtpengine_e2e_ws_blob
    }),
    {ok, _} = chappe_rtpengine_session:offer(Sess, #{
        from_tag => FromTag,
        sdp => sdp(MediaIP, PortA, <<"RTP/AVP">>, []),
        ice => remove
    }),
    {ok, AnswerReply} = chappe_rtpengine_session:answer(Sess, #{
        to_tag => ToTag,
        sdp => sdp(MediaIP, PortB, <<"RTP/AVP">>, []),
        ice => remove
    }),
    ToCallerPort = sdp_audio_port(chappe_rtpengine_ng:sdp(AnswerReply)),
    {ok, RtpeIP} = inet:parse_address(Host),
    %% prove the legs are up before playing
    ok = relay(SockA, RtpeIP, ToCallerPort, SockB, rtp(1, <<"warmup">>)),
    drain(SockB),

    %% one second of audio, about 16 KiB with the WAV header
    Blob = wav_blob(8000),
    ?assert(byte_size(Blob) > 1500),
    case
        chappe_rtpengine_cmd:play_media(Sess, #{blob => Blob, party => callee})
    of
        {error, <<"Unrecognized command">>, _} ->
            ok = chappe_rtpengine_session:stop(Sess),
            gen_udp:close(SockA),
            gen_udp:close(SockB),
            _ = chappe_rtpengine:remove_node(chappe_rtpengine_e2e_ws_blob),
            throw({skip, "rtpengine built without the media player"});
        {ok, _} ->
            ok = wait_for_packet(SockB, 2000),
            case chappe_rtpengine_cmd:stop_media(Sess) of
                {ok, _} -> ok;
                {error, <<"Not currently playing media">>, _} -> ok
            end,
            ok = chappe_rtpengine_session:stop(Sess),
            gen_udp:close(SockA),
            gen_udp:close(SockB),
            _ = chappe_rtpengine:remove_node(chappe_rtpengine_e2e_ws_blob),
            ok
    end.

%% helpers

ws_port() ->
    case os:getenv("RTPENGINE_HTTP_PORT") of
        false -> throw({skip, "RTPENGINE_HTTP_PORT not set"});
        P -> list_to_integer(P)
    end.

media_ip() ->
    case os:getenv("RTPENGINE_MEDIA_IP") of
        false -> throw({skip, "RTPENGINE_MEDIA_IP not set"});
        "" -> throw({skip, "RTPENGINE_MEDIA_IP empty"});
        IP -> list_to_binary(IP)
    end.

wait_for_packet(Sock, TimeoutMs) ->
    receive
        {udp, Sock, _IP, _Port, _Packet} ->
            drain(Sock),
            ok
    after TimeoutMs -> error(no_played_media)
    end.

%% The receiver's answer to a subscription offer: the offer was
%% masked down to PCMU and rtpengine only sends, so the answer is
%% PCMU-only and recvonly.
receiver_sdp(IP, Port) ->
    iolist_to_binary([
        <<"v=0\r\n">>,
        <<"o=- 1 1 IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"s=stt-feed\r\n">>,
        <<"c=IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"t=0 0\r\n">>,
        <<"m=audio ">>,
        integer_to_binary(Port),
        <<" RTP/AVP 0\r\n">>,
        <<"a=rtpmap:0 PCMU/8000\r\n">>,
        <<"a=ptime:20\r\n">>,
        <<"a=recvonly\r\n">>
    ]).

%% 8 kHz mono 16-bit PCM WAV of silence, built in place (a stand-in
%% for a TTS clip).
wav_blob(Samples) ->
    Data = binary:copy(<<0, 0>>, Samples),
    Sz = byte_size(Data),
    <<"RIFF", (36 + Sz):32/little, "WAVE", "fmt ", 16:32/little, 1:16/little,
        1:16/little, 8000:32/little, 16000:32/little, 2:16/little, 16:16/little,
        "data", Sz:32/little, Data/binary>>.

%% Pump RTP from a party until the subscription receiver sees an RTP
%% packet (version 2). The forked stream is re-packetized, so only
%% the header is checked, not the payload.
fork_received(FromSock, RtpeIP, RtpePort, RecvSock) ->
    fork_received(FromSock, RtpeIP, RtpePort, RecvSock, 25, 100).

fork_received(_FromSock, _RtpeIP, _RtpePort, _RecvSock, 0, _Seq) ->
    error(no_forked_media);
fork_received(FromSock, RtpeIP, RtpePort, RecvSock, N, Seq) ->
    ok = gen_udp:send(
        FromSock, RtpeIP, RtpePort, rtp(Seq, <<"fork-feed">>)
    ),
    receive
        {udp, RecvSock, _IP, _Port, <<2:2, _/bits>>} ->
            drain(RecvSock),
            ok
    after 200 ->
        fork_received(FromSock, RtpeIP, RtpePort, RecvSock, N - 1, Seq + 1)
    end.

%% After block media, nothing sent by the caller may reach the callee.
assert_blocked(FromSock, RtpeIP, RtpePort, ToSock) ->
    drain(ToSock),
    lists:foreach(
        fun(I) ->
            ok = gen_udp:send(
                FromSock, RtpeIP, RtpePort, rtp(200 + I, <<"blocked">>)
            ),
            timer:sleep(40)
        end,
        lists:seq(1, 5)
    ),
    receive
        {udp, ToSock, _IP, _Port, _Packet} ->
            error(media_not_blocked)
    after 300 -> ok
    end.

tags(Kind) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    {
        <<"chappe-e2e-", Kind/binary, "-", Suffix/binary>>,
        <<"from-", Suffix/binary>>,
        <<"to-", Suffix/binary>>
    }.

sdp(IP, Port, Profile, ExtraAttrs) ->
    iolist_to_binary([
        <<"v=0\r\n">>,
        <<"o=- 1545997027 1 IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"s=call\r\n">>,
        <<"c=IN IP4 ">>,
        IP,
        <<"\r\n">>,
        <<"t=0 0\r\n">>,
        <<"m=audio ">>,
        integer_to_binary(Port),
        <<" ">>,
        Profile,
        <<" 0 8 101\r\n">>,
        <<"a=rtpmap:0 PCMU/8000\r\n">>,
        <<"a=rtpmap:8 PCMA/8000\r\n">>,
        <<"a=rtpmap:101 telephone-event/8000\r\n">>,
        <<"a=sendrecv\r\n">>
        | ExtraAttrs
    ]).

sdes_attr() ->
    Key = base64:encode(crypto:strong_rand_bytes(30)),
    <<"a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:", Key/binary, "\r\n">>.

fingerprint_attr() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(32)),
    Pairs = [binary:part(Hex, I * 2, 2) || I <- lists:seq(0, 31)],
    Fp = iolist_to_binary(lists:join(<<":">>, Pairs)),
    <<"a=fingerprint:sha-256 ", Fp/binary, "\r\n">>.

sdp_audio_port(SDP) ->
    {Pos, Len} = binary:match(SDP, <<"m=audio ">>),
    Rest = binary:part(SDP, Pos + Len, byte_size(SDP) - Pos - Len),
    [PortBin | _] = binary:split(Rest, <<" ">>),
    binary_to_integer(PortBin).

rtp(Seq, Payload) ->
    <<2:2, 0:1, 0:1, 0:4, 0:1, 0:7, Seq:16, 1000:32, 16#11223344:32,
        Payload/binary>>.

%% Send the packet repeatedly until the far socket receives it (the
%% first packets can race rtpengine's port setup), then drain.
relay(FromSock, RtpeIP, RtpePort, ToSock, Packet) ->
    relay(FromSock, RtpeIP, RtpePort, ToSock, Packet, 25).

relay(_FromSock, _RtpeIP, _RtpePort, _ToSock, _Packet, 0) ->
    error(no_media_relayed);
relay(FromSock, RtpeIP, RtpePort, ToSock, Packet, N) ->
    ok = gen_udp:send(FromSock, RtpeIP, RtpePort, Packet),
    receive
        {udp, ToSock, _IP, _Port, Received} ->
            ?assertEqual(Packet, Received),
            drain(ToSock),
            ok
    after 200 ->
        relay(FromSock, RtpeIP, RtpePort, ToSock, Packet, N - 1)
    end.

drain(Sock) ->
    receive
        {udp, Sock, _, _, _} -> drain(Sock)
    after 0 -> ok
    end.
