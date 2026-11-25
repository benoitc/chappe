%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The jitter buffer of a 16 kHz room: L16 samples are two octets, a
%% 20 ms frame is 320 samples (640 octets), and timestamps, depths and
%% gaps count samples, not octets.
-module(chappe_mix_jbuf_l16_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FRAME, 320).

new(Depth) ->
    chappe_mix_jbuf:new(Depth, 0, false, #{frame => ?FRAME, width => 2}).

%% Count packets of N samples each from Seq0 and Ts0; sample I of the
%% stream is the 16-bit value I.
pkts(J, Seq0, Ts0, N, Count) ->
    lists:foldl(
        fun(K, Acc) ->
            Ts = (Ts0 + K * N) band 16#FFFFFFFF,
            chappe_mix_jbuf:push(1, Seq0 + K, Ts, samples(K * N, N), Acc)
        end,
        J,
        lists:seq(0, Count - 1)
    ).

samples(From, N) ->
    <<<<(I band 16#7FFF):16/big>> || I <- lists:seq(From, From + N - 1)>>.

silence(N) -> <<0:(N * 16)>>.

pops(J, 0, Acc) ->
    {lists:reverse(Acc), J};
pops(J, N, Acc) ->
    {F, J1} = chappe_mix_jbuf:pop(J),
    pops(J1, N - 1, [F | Acc]).

pops(J, N) -> pops(J, N, []).

%% 20 ms packets (640 octets) play as they come.
twenty_ms_test() ->
    J = pkts(new(3), 1, 0, 320, 3),
    {Fs, J1} = pops(J, 4),
    ?assertEqual(
        [samples(0, 320), samples(320, 320), samples(640, 320), silence], Fs
    ),
    ?assertMatch(#{lost := 0, dropped := 0}, chappe_mix_jbuf:stats(J1)).

%% 10 ms packets (320 octets) make a frame two at a time, 30 ms ones
%% (960 octets) a frame and a half each: every sample once, in order.
ten_and_thirty_ms_test() ->
    {Ten, _} = pops(pkts(new(3), 1, 0, 160, 6), 3),
    ?assertEqual([samples(K * 320, 320) || K <- [0, 1, 2]], Ten),
    {Thirty, _} = pops(pkts(new(4), 1, 0, 480, 2), 3),
    ?assertEqual([samples(K * 320, 320) || K <- [0, 1, 2]], Thirty),
    [?assertEqual(640, byte_size(F)) || F <- Ten ++ Thirty].

%% A lost 10 ms packet is 160 samples of silence: 320 zero octets, not
%% 160, so the frame around it keeps its length and its alignment.
loss_fill_test() ->
    J = lists:foldl(
        fun(K, Acc) ->
            chappe_mix_jbuf:push(1, K, K * 160, samples(K * 160, 160), Acc)
        end,
        new(3),
        [0, 2, 3]
    ),
    {[F1, F2], J1} = pops(J, 2),
    ?assertEqual(<<(samples(0, 160))/binary, (silence(160))/binary>>, F1),
    ?assertEqual(samples(320, 320), F2),
    ?assertMatch(#{lost := 1}, chappe_mix_jbuf:stats(J1)).

%% A whole lost frame plays as silence and the stream goes on.
lost_frame_test() ->
    J = lists:foldl(
        fun(K, Acc) ->
            chappe_mix_jbuf:push(1, K, K * 320, samples(K * 320, 320), Acc)
        end,
        new(3),
        [0, 2, 3]
    ),
    ?assertMatch(
        {[_, silence, _, _], _}, pops(J, 4)
    ).

%% The depth counts frames of 320 samples: a burst of six 20 ms packets
%% into a buffer of three keeps the newest three.
overflow_test() ->
    J = pkts(new(3), 1, 0, 320, 6),
    {[F | _], J1} = pops(J, 1),
    ?assertEqual(samples(3 * 320, 320), F),
    ?assertMatch(#{dropped := 3}, chappe_mix_jbuf:stats(J1)).

%% A 200 ms packet (3200 samples, 6400 octets) plays over ten ticks.
two_hundred_ms_test() ->
    {Fs, J1} = pops(pkts(new(3), 1, 0, 3200, 1), 11),
    ?assertEqual(
        [samples(I * 320, 320) || I <- lists:seq(0, 9)], lists:sublist(Fs, 10)
    ),
    ?assertEqual(silence, lists:last(Fs)),
    ?assertMatch(#{dropped := 0}, chappe_mix_jbuf:stats(J1)).

%% A jump of more than 3000 frames of 320 samples (60 s) restarts the
%% buffer on the new position; one of less than that, with packets
%% missing, is loss played as silence. Counted in octets the far jump
%% would be under the bound.
resync_test() ->
    J0 = pkts(new(3), 1, 0, 320, 2),
    {_, J1} = pops(J0, 2),
    Far = 3001 * 320 + 640,
    J2 = chappe_mix_jbuf:push(1, 100, Far, samples(7, 320), J1),
    {[F], _} = pops(J2, 1),
    ?assertEqual(samples(7, 320), F),
    Near = 2999 * 320,
    J3 = chappe_mix_jbuf:push(1, 100, Near, samples(7, 320), J1),
    {[G], _} = pops(J3, 1),
    ?assertEqual(silence, G).

%% Silence suppression: a pause is jumped over, nothing lost.
suppression_test() ->
    J0 = pkts(new(3), 1, 0, 320, 2),
    {_, J1} = pops(J0, 3),
    J2 = chappe_mix_jbuf:push(1, 3, 320 * 52, samples(9, 320), J1),
    J3 = chappe_mix_jbuf:push(1, 4, 320 * 53, samples(0, 320), J2),
    {[F | _], J4} = pops(J3, 1),
    ?assertEqual(samples(9, 320), F),
    ?assertMatch(#{lost := 0}, chappe_mix_jbuf:stats(J4)).

%% An odd payload (a sample cut in two) counts its whole samples only;
%% the frame played is still 640 octets.
odd_length_test() ->
    J = chappe_mix_jbuf:push(
        1, 1, 0, <<(samples(0, 320))/binary, 16#AB>>, new(3)
    ),
    {[F], _} = pops(J, 1),
    ?assertEqual(samples(0, 320), F).

%% Placed by sequence number alone (push/4), a frame is 320 samples.
by_seq_test() ->
    J = lists:foldl(
        fun(N, Acc) -> chappe_mix_jbuf:push(1, N, samples(N, 320), Acc) end,
        new(3),
        [10, 12, 11]
    ),
    {Fs, _} = pops(J, 3),
    ?assertEqual([samples(N, 320) || N <- [10, 11, 12]], Fs),
    %% a short one plays as it came (the mix pads it, chappe_mix_dsp),
    %% and a sample cut in two is not played
    J1 = chappe_mix_jbuf:push(1, 1, <<(samples(0, 100))/binary, 1>>, new(3)),
    {[P], _} = pops(J1, 1),
    ?assertEqual(samples(0, 100), P).
