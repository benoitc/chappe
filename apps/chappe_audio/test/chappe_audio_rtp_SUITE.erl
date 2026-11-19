%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_audio_rtp, started with chappe_audio:rtp_receiver/1: G.711 to a
%% process, the source latch, SRTP with replay and forgery, a port range,
%% the owner's exit, a recording of the store, and RTCP: a fake source
%% sends RTP and an SR, muxed (RFC 5761) or on the next port, plain or
%% SRTCP, and the case reads the receiver report that comes back.
-module(chappe_audio_rtp_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    plain_to_pid/1,
    latches_to_first_source/1,
    srtp_drops_forged_and_replayed/1,
    port_range/1,
    stops_with_owner/1,
    store_sink/1,
    not_started/1,
    flood_past_queue/1,
    own_crash/1,
    store_crash_spares_receiver/1,
    rtcp_mux_report/1,
    rtcp_port_report/1,
    rtcp_port_default_address/1,
    srtcp_report/1,
    rtcp_none_sends_nothing/1,
    rtcp_port_pair/1,
    rtcp_source_on_last_port/1,
    rtcp_feedback_and_unknown/1
]).

%% the store seam, for store_sink
-export([open/2, write/2, close/2]).

-define(LO, {127, 0, 0, 1}).
-define(SRTP, chappe_audio_test_srtp).
-define(RTCP, chappe_audio_rtcp).
%% RFC 3550 figure 2: the SR's NTP time, and the LSR it gives
-define(NTP, 16#b44db70520000000).
-define(LSR, 16#b7052000).
%% the first report comes 1.25 to 3.75 s after the start (RFC 3550 6.2)
-define(RR_WAIT, 9000).

all() ->
    [
        plain_to_pid,
        latches_to_first_source,
        srtp_drops_forged_and_replayed,
        port_range,
        stops_with_owner,
        store_sink,
        not_started,
        flood_past_queue,
        own_crash,
        store_crash_spares_receiver,
        rtcp_mux_report,
        rtcp_port_report,
        rtcp_port_default_address,
        srtcp_report,
        rtcp_none_sends_nothing,
        rtcp_port_pair,
        rtcp_source_on_last_port,
        rtcp_feedback_and_unknown
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_audio).

plain_to_pid(_Config) ->
    {ok, R} = receiver(#{}),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    Payload = binary:copy(<<16#20>>, 160),
    ok = gen_udp:send(Src, ?LO, chappe_audio_rtp:port(R), rtp(0, 1, Payload)),
    Pcm = chappe_audio_pcm:decode(ulaw, Payload),
    receive
        {chappe_audio_rtp, R, {audio, Got}} -> ?assertEqual(Pcm, Got)
    after 2000 -> ct:fail(no_audio)
    end,
    %% another payload type and garbage are dropped
    ok = gen_udp:send(Src, ?LO, chappe_audio_rtp:port(R), rtp(18, 2, Payload)),
    ok = gen_udp:send(Src, ?LO, chappe_audio_rtp:port(R), <<1, 2, 3>>),
    no_audio(R),
    ?assertMatch(#{packets := 1}, chappe_audio_rtp:stats(R)),
    ok = chappe_audio_rtp:stop(R),
    gen_udp:close(Src).

latches_to_first_source(_Config) ->
    {ok, R} = receiver(#{tag => mytag, remote => {?LO, 9}}),
    {ok, A} = gen_udp:open(0, [binary, {ip, ?LO}]),
    {ok, B} = gen_udp:open(0, [binary, {ip, ?LO}]),
    Port = chappe_audio_rtp:port(R),
    ok = gen_udp:send(A, ?LO, Port, rtp(8, 1, <<16#D5>>)),
    receive
        {mytag, R, {audio, <<8:16/little-signed>>}} -> ok
    after 2000 -> ct:fail(no_audio)
    end,
    ok = gen_udp:send(B, ?LO, Port, rtp(8, 2, <<16#D5>>)),
    receive
        {mytag, R, _} -> ct:fail(other_source_heard)
    after 300 -> ok
    end,
    ok = chappe_audio_rtp:stop(R),
    gen_udp:close(A),
    gen_udp:close(B).

srtp_drops_forged_and_replayed(_Config) ->
    Master = ?SRTP:master(),
    <<Key:16/binary, Salt:14/binary>> = Master,
    {ok, Ctx} = chappe_audio_srtp:new(#{
        suite => aes_cm_128_hmac_sha1_80, key => Key, salt => Salt
    }),
    {ok, R} = receiver(#{srtp => Ctx}),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    Port = chappe_audio_rtp:port(R),
    Snd = ?SRTP:sender(Master),
    Payload = binary:copy(<<16#20>>, 160),
    Forged = ?SRTP:protect(rtp(0, 1, Payload), 0, ?SRTP:sender(?SRTP:master())),
    ok = gen_udp:send(Src, ?LO, Port, Forged),
    Pkt = ?SRTP:protect(rtp(0, 2, Payload), 0, Snd),
    ok = gen_udp:send(Src, ?LO, Port, Pkt),
    receive
        {chappe_audio_rtp, R, {audio, _}} -> ok
    after 2000 -> ct:fail(no_audio)
    end,
    ok = gen_udp:send(Src, ?LO, Port, Pkt),
    no_audio(R),
    ?assertEqual(
        #{packets => 1, failed => 1, replayed => 1},
        chappe_audio_rtp:stats(R)
    ),
    ok = chappe_audio_rtp:stop(R),
    gen_udp:close(Src).

port_range(_Config) ->
    {ok, Hold} = gen_udp:open(0, [binary, {ip, ?LO}]),
    {ok, P} = inet:port(Hold),
    ?assertEqual({error, no_port}, receiver(#{ports => {P, P}})),
    gen_udp:close(Hold),
    {ok, R} = receiver(#{ports => {P, P}}),
    ?assertEqual(P, chappe_audio_rtp:port(R)),
    ok = chappe_audio_rtp:stop(R).

stops_with_owner(_Config) ->
    Self = self(),
    Owner = spawn(fun() ->
        Self ! {receiver, receiver(#{})},
        receive
            stop -> ok
        end
    end),
    R =
        receive
            {receiver, {ok, Pid}} -> Pid
        after 2000 -> ct:fail(no_receiver)
        end,
    Mon = erlang:monitor(process, R),
    Owner ! stop,
    receive
        {'DOWN', Mon, process, R, normal} -> ok
    after 2000 -> ct:fail(still_running)
    end.

store_sink(_Config) ->
    {ok, R} = chappe_audio:rtp_receiver(#{
        owner => self(),
        ip => ?LO,
        label => <<"1">>,
        sink => {store, ?MODULE, #{meta => self()}}
    }),
    receive
        {store, opened} -> ok
    after 2000 -> ct:fail(not_opened)
    end,
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    ok = gen_udp:send(Src, ?LO, chappe_audio_rtp:port(R), rtp(0, 1, <<16#FF>>)),
    receive
        {store, written, <<0:16>>} -> ok
    after 2000 -> ct:fail(not_written)
    end,
    ?assertEqual({ok, <<"rec">>}, chappe_audio_rtp:stop(R)),
    receive
        {store, closed, #{packets := 1}} -> ok
    after 2000 -> ct:fail(not_closed)
    end,
    gen_udp:close(Src).

not_started(_Config) ->
    ok = application:stop(chappe_audio),
    try
        ?assertEqual({error, not_started}, receiver(#{}))
    after
        {ok, _} = application:ensure_all_started(chappe_audio)
    end.

%% a sink that does not read gets at most max_queue frames
flood_past_queue(_Config) ->
    {ok, R} = receiver(#{max_queue => 2}),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    Port = chappe_audio_rtp:port(R),
    [
        ok = gen_udp:send(Src, ?LO, Port, rtp(0, Seq, <<16#FF>>))
     || Seq <- lists:seq(1, 20)
    ],
    wait_packets(R, 20, 50),
    {messages, Ms} = process_info(self(), messages),
    ?assertEqual(2, length([M || {chappe_audio_rtp, P, _} = M <- Ms, P =:= R])),
    ok = chappe_audio_rtp:stop(R),
    flush(R),
    gen_udp:close(Src).

%% a receiver that crashes leaves its owner running
own_crash(_Config) ->
    {ok, R} = receiver(#{}),
    Mon = erlang:monitor(process, R),
    exit(R, kill),
    receive
        {'DOWN', Mon, process, R, killed} -> ok
    after 2000 -> ct:fail(not_killed)
    end,
    {ok, R2} = receiver(#{}),
    ok = chappe_audio_rtp:stop(R2).

%% the store's process (and so the registry's restart order) crashing
%% leaves a live receiver alone
store_crash_spares_receiver(_Config) ->
    {ok, R} = receiver(#{}),
    Store = whereis(chappe_audio_store_srv),
    Mon = erlang:monitor(process, Store),
    exit(Store, kill),
    receive
        {'DOWN', Mon, process, Store, killed} -> ok
    after 2000 -> ct:fail(store_alive)
    end,
    wait_restarted(chappe_audio_store_srv, Store, 50),
    ?assert(is_process_alive(R)),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    ok = gen_udp:send(Src, ?LO, chappe_audio_rtp:port(R), rtp(0, 1, <<16#FF>>)),
    receive
        {chappe_audio_rtp, R, {audio, _}} -> ok
    after 2000 -> ct:fail(no_audio)
    end,
    ok = chappe_audio_rtp:stop(R),
    gen_udp:close(Src).

%% Muxed RTCP (RFC 5761 4): 19 of 20 packets and an SR with a CNAME
%% come in on the RTP port; the receiver report goes back to the source's
%% address, one block for the source (RFC 3550 6.4.2: 1 lost, fraction
%% 1 * 256 div 20, highest 20, LSR and DLSR from the SR), then SDES with
%% the receiver's CNAME (6.1).
%% Stopping sends an empty RR (nothing heard since, 6.4.2), SDES and a
%% BYE (6.3.7).
%% req: R7866-8.1.1-1 R7866-8.1.8-1 R7866-8.1.5.1-1 R5761-4-1 R5761-5.1.1-1
%% req: R3550-6.1-1 R3550-6.1-2 R3550-6.1-3 R3550-6.4.1-1 R3550-6.4.1-2
%% req: R3550-6.4.1-5 R3550-6.4.2-1 R3550-6.2-1 R3550-6.2-2 R3550-6.3-1
%% The packets go out back to back, so each one's D is its timestamp step
%% and the block's jitter follows J += (|D| - J) / 16 (6.4.1), within the
%% slack of the loopback.
%% req: R3550-6.3.7-1 R3550-6.4.1-3 R3550-6.4.1-4
rtcp_mux_report(_Config) ->
    {ok, R} = receiver(#{rtcp => mux, cname => <<"srs@test">>}),
    Port = chappe_audio_rtp:port(R),
    ?assertEqual(Port, chappe_audio_rtp:rtcp_port(R)),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    [
        ok = gen_udp:send(Src, ?LO, Port, rtp(0, Seq, <<16#FF>>))
     || Seq <- lists:seq(1, 20), Seq =/= 7
    ],
    ok = gen_udp:send(Src, ?LO, Port, sr(16#1234, <<"src@test">>)),
    {Parts, {?LO, Port}} = rtcp_in(Src, ?RR_WAIT),
    [#{type := rr, ssrc := Me, blocks := [B]}, #{type := sdes} = Sdes] = Parts,
    ?assertMatch(
        #{
            ssrc := 16#1234,
            lost := 1,
            fraction := 12,
            highest := 20,
            lsr := ?LSR
        },
        B
    ),
    ?assert(maps:get(dlsr, B) > 0 andalso maps:get(dlsr, B) < 10 * 65536),
    Expected = jitter([Q || Q <- lists:seq(1, 20), Q =/= 7]),
    Jitter = maps:get(jitter, B),
    ?assert(
        Jitter >= 0.6 * Expected andalso Jitter =< 1.4 * Expected,
        {jitter, Jitter, Expected}
    ),
    ?assertEqual(
        #{type => sdes, chunks => [{Me, [{cname, <<"srs@test">>}]}]}, Sdes
    ),
    ?assertMatch(
        #{
            packets := 19,
            rtcp_received := 1,
            sources := [
                #{ssrc := 16#1234, cname := <<"src@test">>, lost := 1}
            ]
        },
        chappe_audio_rtp:stats(R)
    ),
    ?assert(maps:get(rtcp_sent, chappe_audio_rtp:stats(R)) >= 1),
    ok = chappe_audio_rtp:stop(R),
    {Bye, _} = rtcp_in(Src, 2000),
    ?assertMatch(
        [
            #{type := rr, ssrc := Me, blocks := []},
            #{type := sdes},
            #{type := bye, ssrcs := [Me]}
        ],
        Bye
    ),
    flush(R),
    gen_udp:close(Src).

%% RTCP on the next port (rtcp => port): an even RTP port, RTCP on the
%% odd one above it; the SR comes from the source's RTCP socket, and the
%% report goes back to it from the receiver's RTCP port (symmetric RTCP,
%% RFC 7866 8.1.8)
%% req: R7866-8.1.1-1 R7866-8.1.8-1 R3550-11-1
rtcp_port_report(_Config) ->
    {ok, R} = receiver(#{rtcp => port}),
    Port = chappe_audio_rtp:port(R),
    ?assertEqual(0, Port rem 2),
    ?assertEqual(Port + 1, chappe_audio_rtp:rtcp_port(R)),
    {ok, A} = gen_udp:open(0, [binary, {ip, ?LO}]),
    {ok, B} = gen_udp:open(0, [binary, {ip, ?LO}]),
    [
        ok = gen_udp:send(A, ?LO, Port, rtp(8, Seq, <<16#D5>>))
     || Seq <- lists:seq(1, 5)
    ],
    ok = gen_udp:send(B, ?LO, Port + 1, sr(16#1234, <<"src">>)),
    {[#{type := rr, blocks := [Blk]} | _], From} = rtcp_in(B, ?RR_WAIT),
    ?assertEqual({?LO, Port + 1}, From),
    ?assertMatch(
        #{ssrc := 16#1234, lost := 0, highest := 5, lsr := ?LSR}, Blk
    ),
    %% nothing goes to the RTP socket
    no_udp(A, 0),
    ok = chappe_audio_rtp:stop(R),
    flush(R),
    gen_udp:close(A),
    gen_udp:close(B).

%% with no RTCP heard from the source, the report goes to the port above
%% its RTP port (RFC 3550 11)
%% req: R3550-11-1
rtcp_port_default_address(_Config) ->
    {ok, R} = receiver(#{rtcp => port}),
    Port = chappe_audio_rtp:port(R),
    {A, B} = pair(),
    [
        ok = gen_udp:send(A, ?LO, Port, rtp(0, Seq, <<16#FF>>))
     || Seq <- lists:seq(1, 3)
    ],
    {[#{type := rr, blocks := [Blk]} | _], From} = rtcp_in(B, ?RR_WAIT),
    ?assertEqual({?LO, Port + 1}, From),
    ?assertMatch(#{ssrc := 16#1234, highest := 3, lsr := 0, dlsr := 0}, Blk),
    ok = chappe_audio_rtp:stop(R),
    flush(R),
    gen_udp:close(A),
    gen_udp:close(B).

%% SRTP with the receiver's own key (srtcp_out): the SRTCP SR is taken,
%% and the report goes back as SRTCP (RFC 3711 3.4) that the key of the
%% receiver's SDP answer opens, index 0 first, and the sender's key does
%% not
%% A new pair of keys (rekey/3) keeps the SRTCP index going: the BYE on
%% stop, under the new key, has index 1 (RFC 3711 3.4).
%% req: R3711-3.4-1 R3711-3.4-2 R3711-3.4-3 R7866-8.1.1-1
srtcp_report(_Config) ->
    In = ?SRTP:master(),
    Out = ?SRTP:master(),
    {ok, R} = receiver(#{
        rtcp => mux, srtp => ctx(In), srtcp_out => ctx(Out)
    }),
    Port = chappe_audio_rtp:port(R),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    Snd = ?SRTP:sender(In),
    [
        ok = gen_udp:send(
            Src, ?LO, Port, ?SRTP:protect(rtp(0, Seq, <<16#FF>>), 0, Snd)
        )
     || Seq <- lists:seq(1, 10), Seq =/= 4
    ],
    Sr = ?SRTP:protect_rtcp(sr(16#1234, <<"s">>), 0, Snd),
    ok = gen_udp:send(Src, ?LO, Port, Sr),
    Pkt = udp_in(Src, ?RR_WAIT),
    ?assertEqual({error, invalid}, ?RTCP:parse(Pkt)),
    ?assertEqual({error, auth}, chappe_audio_srtp:unprotect_rtcp(Pkt, ctx(In))),
    {ok, Plain, _} = chappe_audio_srtp:unprotect_rtcp(Pkt, ctx(Out)),
    {ok, [#{type := rr, blocks := [Blk]}, #{type := sdes} | _]} =
        ?RTCP:parse(Plain),
    ?assertMatch(
        #{ssrc := 16#1234, lost := 1, highest := 10, lsr := ?LSR}, Blk
    ),
    %% E set and SRTCP index 0, before the 10-octet tag
    Skip = byte_size(Pkt) - 14,
    <<_:Skip/binary, 1:1, 0:31, _:10/binary>> = Pkt,
    ?assertMatch(#{rtcp_received := 1}, chappe_audio_rtp:stats(R)),
    Out2 = ?SRTP:master(),
    ok = chappe_audio_rtp:rekey(R, ctx(?SRTP:master()), ctx(Out2)),
    ok = chappe_audio_rtp:stop(R),
    Bye = udp_in(Src, 2000),
    ?assertEqual({error, auth}, chappe_audio_srtp:unprotect_rtcp(Bye, ctx(Out))),
    {ok, ByePlain, _} = chappe_audio_srtp:unprotect_rtcp(Bye, ctx(Out2)),
    ?assertMatch({ok, [_, _, #{type := bye}]}, ?RTCP:parse(ByePlain)),
    ByeSkip = byte_size(Bye) - 14,
    <<_:ByeSkip/binary, 1:1, 1:31, _:10/binary>> = Bye,
    flush(R),
    gen_udp:close(Src).

%% rtcp => none (the default) sends nothing and keeps stats/1 as it was;
%% neither does an SRTP stream without a key of its own to protect its
%% reports with, nor one stopped before its first report (no BYE, RFC
%% 3550 6.3.7)
%% req: R3550-6.3.7-2
rtcp_none_sends_nothing(_Config) ->
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    {ok, SrcPort} = inet:port(Src),
    {ok, R3} = receiver(#{rtcp => mux, remote => {?LO, SrcPort}}),
    ok = gen_udp:send(
        Src, ?LO, chappe_audio_rtp:port(R3), rtp(0, 1, <<16#FF>>)
    ),
    ok = chappe_audio_rtp:stop(R3),
    {ok, R1} = receiver(#{}),
    In = ?SRTP:master(),
    {ok, R2} = receiver(#{rtcp => mux, srtp => ctx(In)}),
    Snd = ?SRTP:sender(In),
    P1 = chappe_audio_rtp:port(R1),
    P2 = chappe_audio_rtp:port(R2),
    ?assertEqual(undefined, chappe_audio_rtp:rtcp_port(R1)),
    ok = gen_udp:send(Src, ?LO, P1, rtp(0, 1, <<16#FF>>)),
    ok = gen_udp:send(Src, ?LO, P1, sr(16#1234, <<"s">>)),
    ok = gen_udp:send(Src, ?LO, P2, ?SRTP:protect(rtp(0, 1, <<16#FF>>), 0, Snd)),
    no_udp(Src, 4000),
    ?assertEqual(
        #{packets => 1, failed => 0, replayed => 0},
        chappe_audio_rtp:stats(R1)
    ),
    ok = chappe_audio_rtp:stop(R1),
    ok = chappe_audio_rtp:stop(R2),
    flush(R1),
    flush(R2),
    flush(R3),
    gen_udp:close(Src).

%% rtcp => port binds an even port and the one above it from the range,
%% or none ({error, no_port}); a bad rtcp value is refused
rtcp_port_pair(_Config) ->
    {A, B} = pair(),
    {ok, P} = inet:port(A),
    gen_udp:close(A),
    ?assertEqual(
        {error, no_port}, receiver(#{rtcp => port, ports => {P, P + 1}})
    ),
    gen_udp:close(B),
    ?assertEqual(
        {error, no_port}, receiver(#{rtcp => port, ports => {P + 1, P + 1}})
    ),
    {ok, R} = receiver(#{rtcp => port, ports => {P, P + 1}}),
    ?assertEqual(
        {P, P + 1},
        {chappe_audio_rtp:port(R), chappe_audio_rtp:rtcp_port(R)}
    ),
    ok = chappe_audio_rtp:stop(R),
    ?assertEqual({error, {bad_option, rtcp}}, receiver(#{rtcp => yes})).

%% A source on UDP port 65535 has no port above it (RFC 3550 11): with
%% rtcp => port and no RTCP heard, the receiver sends no report, and
%% keeps running and recording.
rtcp_source_on_last_port(_Config) ->
    case gen_udp:open(65535, [binary, {ip, ?LO}]) of
        {ok, Src} ->
            {ok, R} = receiver(#{rtcp => port}),
            Port = chappe_audio_rtp:port(R),
            Mon = erlang:monitor(process, R),
            ok = gen_udp:send(Src, ?LO, Port, rtp(0, 1, <<16#FF>>)),
            %% past the first report's window (at most 3.75 s)
            receive
                {'DOWN', Mon, process, R, Why} -> ct:fail({receiver_died, Why})
            after 4500 -> ok
            end,
            ok = gen_udp:send(Src, ?LO, Port, rtp(0, 2, <<16#FF>>)),
            wait_packets(R, 2, 50),
            ?assertMatch(#{rtcp_sent := 0}, chappe_audio_rtp:stats(R)),
            ok = chappe_audio_rtp:stop(R),
            flush(R),
            gen_udp:close(Src);
        {error, Why} ->
            {skip, {port_65535, Why}}
    end.

%% Muxed feedback (PSFB 206) and XR (207) on the RTP port are RTCP (RFC
%% 5761 4), never counted as RTP of another source; a compound packet
%% with an RTCP type the receiver does not read (APP) is taken, the type
%% ignored and the SDES after it read (RFC 3550 6.1).
%% req: R5761-4-1 R3550-6.1-4
rtcp_feedback_and_unknown(_Config) ->
    {ok, P} = receiver(#{rtcp => port}),
    {ok, M} = receiver(#{rtcp => mux}),
    {ok, Src} = gen_udp:open(0, [binary, {ip, ?LO}]),
    PP = chappe_audio_rtp:port(P),
    Psfb = <<16#81, 206, 0, 2, 16#9999:32, 16#1234:32>>,
    Xr = <<16#80, 207, 0, 1, 16#9998:32>>,
    [ok = gen_udp:send(Src, ?LO, PP, rtp(0, Q, <<16#FF>>)) || Q <- [1, 2]],
    ok = gen_udp:send(Src, ?LO, PP, Psfb),
    ok = gen_udp:send(Src, ?LO, PP, Xr),
    ok = gen_udp:send(Src, ?LO, PP, rtp(0, 3, <<16#FF>>)),
    wait_packets(P, 3, 50),
    ?assertMatch(
        #{sources := [#{ssrc := 16#1234, received := 3}]},
        chappe_audio_rtp:stats(P)
    ),
    MP = chappe_audio_rtp:port(M),
    ok = gen_udp:send(Src, ?LO, MP, rtp(0, 1, <<16#FF>>)),
    ok = gen_udp:send(Src, ?LO, MP, Psfb),
    App = <<16#80, 204, 0, 2, 16#1234:32, "abcd">>,
    Compound = iolist_to_binary([
        ?RTCP:build([#{type => rr, ssrc => 16#1234, blocks => []}]),
        App,
        ?RTCP:build([#{type => sdes, chunks => [{16#1234, [{cname, <<"app">>}]}]}])
    ]),
    ok = gen_udp:send(Src, ?LO, MP, Compound),
    wait_rtcp(M, 1, 50),
    ?assertMatch(
        #{
            rtcp_received := 1,
            sources := [#{ssrc := 16#1234, cname := <<"app">>, received := 1}]
        },
        chappe_audio_rtp:stats(M)
    ),
    ok = chappe_audio_rtp:stop(P),
    ok = chappe_audio_rtp:stop(M),
    flush(P),
    flush(M),
    gen_udp:close(Src).

%% ---- a store module, for store_sink ----


open(#{meta := Test}, #{owner := _}) ->
    Test ! {store, opened},
    {ok, Test}.

write(Test, Pcm) ->
    Test ! {store, written, Pcm},
    ok.

close(Test, Info) ->
    Test ! {store, closed, Info},
    {ok, <<"rec">>}.

%% ---- helpers ----

receiver(Opts) ->
    chappe_audio:rtp_receiver(
        maps:merge(
            #{
                owner => self(),
                ip => ?LO,
                label => <<"1">>,
                sink => {pid, self()}
            },
            Opts
        )
    ).

rtp(PT, Seq, Payload) ->
    <<2:2, 0:1, 0:1, 0:4, 0:1, PT:7, Seq:16, (Seq * 160):32, 16#1234:32,
        Payload/binary>>.

wait_packets(R, N, 0) ->
    ct:fail({packets, N, chappe_audio_rtp:stats(R)});
wait_packets(R, N, Tries) ->
    case chappe_audio_rtp:stats(R) of
        #{packets := N} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_packets(R, N, Tries - 1)
    end.

wait_restarted(Name, _Old, 0) ->
    ct:fail({not_restarted, Name});
wait_restarted(Name, Old, Tries) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old ->
            ok;
        _ ->
            timer:sleep(20),
            wait_restarted(Name, Old, Tries - 1)
    end.

ctx(<<Key:16/binary, Salt:14/binary>>) ->
    {ok, C} = chappe_audio_srtp:new(#{
        suite => aes_cm_128_hmac_sha1_80, key => Key, salt => Salt
    }),
    C.

%% an SR of Ssrc with no report block, at the NTP time of RFC 3550
%% figure 2, and its CNAME
sr(Ssrc, Cname) ->
    ?RTCP:build([
        #{
            type => sr,
            ssrc => Ssrc,
            ntp => ?NTP,
            ts => 0,
            packets => 20,
            octets => 3200,
            blocks => []
        },
        #{type => sdes, chunks => [{Ssrc, [{cname, Cname}]}]}
    ]).

%% the next RTCP compound packet on Sock, parsed, and where it came from
rtcp_in(Sock, Timeout) ->
    receive
        {udp, Sock, Ip, Port, Bin} ->
            case ?RTCP:parse(Bin) of
                {ok, Parts} -> {Parts, {Ip, Port}};
                {error, _} -> rtcp_in(Sock, Timeout)
            end
    after Timeout -> ct:fail(no_rtcp)
    end.

udp_in(Sock, Timeout) ->
    receive
        {udp, Sock, _Ip, _Port, Bin} -> Bin
    after Timeout -> ct:fail(no_udp)
    end.

no_udp(Sock, Timeout) ->
    receive
        {udp, Sock, _, _, Bin} -> ct:fail({unexpected, Bin})
    after Timeout -> ok
    end.

%% two sockets on an even port and the one above it
pair() -> pair(20).

pair(0) ->
    ct:fail(no_port_pair);
pair(N) ->
    {ok, A} = gen_udp:open(0, [binary, {ip, ?LO}]),
    {ok, P} = inet:port(A),
    case P rem 2 =:= 0 andalso gen_udp:open(P + 1, [binary, {ip, ?LO}]) of
        {ok, B} ->
            {A, B};
        _ ->
            gen_udp:close(A),
            pair(N - 1)
    end.

%% RFC 3550 6.4.1 in floating point, for packets of these sequence
%% numbers sent back to back at 160 timestamp units each
jitter([First | Rest]) ->
    {J, _} = lists:foldl(
        fun(Q, {J, Prev}) -> {J + (abs((Q - Prev) * 160) - J) / 16, Q} end,
        {0.0, First},
        Rest
    ),
    J.

wait_rtcp(R, N, 0) ->
    ct:fail({rtcp_received, N, chappe_audio_rtp:stats(R)});
wait_rtcp(R, N, Tries) ->
    case chappe_audio_rtp:stats(R) of
        #{rtcp_received := N} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_rtcp(R, N, Tries - 1)
    end.

flush(R) ->
    receive
        {_, R, _} -> flush(R)
    after 0 -> ok
    end.

no_audio(R) ->
    receive
        {_, R, {audio, _}} -> ct:fail(dropped_heard)
    after 300 -> ok
    end.
