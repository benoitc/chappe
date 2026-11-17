%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_audio_rtp, started with chappe_audio:rtp_receiver/1: G.711 to a
%% process, the source latch, SRTP with replay and forgery, a port range,
%% the owner's exit, and a recording of the store.
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
    own_crash/1
]).

%% the store seam, for store_sink
-export([open/2, write/2, close/2]).

-define(LO, {127, 0, 0, 1}).
-define(SRTP, chappe_audio_test_srtp).

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
        own_crash
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
