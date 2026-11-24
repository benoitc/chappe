%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_jbuf_tests).

-include_lib("eunit/include/eunit.hrl").

push(J, Seqs) ->
    lists:foldl(
        fun(S, Acc) -> chappe_mix_jbuf:push(1, S, <<S>>, Acc) end, J, Seqs
    ).

pops(J, 0, Acc) ->
    {lists:reverse(Acc), J};
pops(J, N, Acc) ->
    {F, J1} = chappe_mix_jbuf:pop(J),
    pops(J1, N - 1, [F | Acc]).

pops(J, N) -> pops(J, N, []).

empty_test() ->
    {F, _} = chappe_mix_jbuf:pop(chappe_mix_jbuf:new(3)),
    ?assertEqual(silence, F).

in_order_test() ->
    J = push(chappe_mix_jbuf:new(3), [10, 11, 12]),
    ?assertMatch({[<<10>>, <<11>>, <<12>>, silence], _}, pops(J, 4)).

%% Reordering inside the buffer is repaired.
reorder_test() ->
    J = push(chappe_mix_jbuf:new(3), [10, 12, 11]),
    ?assertMatch({[<<10>>, <<11>>, <<12>>], _}, pops(J, 3)).

%% A lost packet plays as one silent frame and the stream carries on.
loss_test() ->
    J = push(chappe_mix_jbuf:new(3), [10, 12, 13]),
    ?assertMatch({[<<10>>, silence, <<12>>, <<13>>], _}, pops(J, 4)).

%% A packet older than the playout point is late: dropped and counted.
late_test() ->
    {_, J0} = pops(push(chappe_mix_jbuf:new(3), [10, 11]), 2),
    J1 = push(J0, [10, 12]),
    ?assertMatch({[<<12>>], _}, pops(J1, 1)),
    ?assertMatch(#{late := 1}, chappe_mix_jbuf:stats(J1)).

%% The frame just behind the playout point is late too, and it must not
%% sit in the buffer where it would never be played but would count
%% against the depth.
late_by_one_test() ->
    {_, J0} = pops(push(chappe_mix_jbuf:new(3), [10, 11]), 2),
    J1 = push(J0, [11]),
    ?assertMatch(#{late := 1, buffered := 0}, chappe_mix_jbuf:stats(J1)).

%% An empty tick is an underrun, not a loss: the playout point waits, so a
%% packet that is only late (jitter) is still played, and nothing counts
%% as lost or late.
underrun_waits_test() ->
    J0 = push(chappe_mix_jbuf:new(3), [10]),
    {[<<10>>, silence], J1} = pops(J0, 2),
    J2 = push(J1, [11, 12]),
    ?assertMatch({[<<11>>, <<12>>], _}, pops(J2, 2)),
    ?assertMatch(#{lost := 0, late := 0}, chappe_mix_jbuf:stats(J2)).

%% After an underrun the buffer waits for one more frame than before it
%% resumes, so a sender whose clock is in phase with the mixer's gets one
%% frame of slack instead of racing the tick forever. The prefill never
%% reaches the depth, where trimming would fight it.
underrun_adds_slack_test() ->
    J0 = push(chappe_mix_jbuf:new(3), [10]),
    ?assertMatch(#{prefill := 1}, chappe_mix_jbuf:stats(J0)),
    {[<<10>>, silence], J1} = pops(J0, 2),
    ?assertMatch(#{prefill := 2}, chappe_mix_jbuf:stats(J1)),
    J2 = push(J1, [11]),
    {[silence], J3} = pops(J2, 1),
    J4 = push(J3, [12]),
    {[<<11>>, <<12>>, silence], J5} = pops(J4, 3),
    ?assertMatch(#{prefill := 2}, chappe_mix_jbuf:stats(J5)).

%% A sender running faster than the tick fills the buffer; past its depth
%% the oldest frames are dropped so latency stays bounded.
overflow_test() ->
    J = push(chappe_mix_jbuf:new(3), [10, 11, 12, 13, 14, 15]),
    {[F | _], J1} = pops(J, 1),
    ?assertEqual(<<13>>, F),
    ?assertMatch(#{dropped := 3}, chappe_mix_jbuf:stats(J1)).

%% A new SSRC is a new stream: the buffer restarts on it.
ssrc_change_test() ->
    J0 = push(chappe_mix_jbuf:new(3), [10, 11]),
    J1 = chappe_mix_jbuf:push(2, 5000, <<"n">>, J0),
    ?assertMatch({[<<"n">>, silence], _}, pops(J1, 2)).

%% Sequence numbers wrap at 16 bits without a gap.
wrap_test() ->
    J = push(chappe_mix_jbuf:new(4), [65534, 65535, 0, 1]),
    {Fs, _} = pops(J, 4),
    ?assertEqual([<<254>>, <<255>>, <<0>>, <<1>>], Fs).

%% ---- packets keyed by timestamp (push/5) ----

%% Count packets of N samples each, numbered from Seq0, timestamps from
%% Ts0 (wrapping at 32 bits); sample I of the stream is byte I rem 256.
pkts(J, Seq0, Ts0, N, Count) ->
    lists:foldl(
        fun(K, Acc) ->
            Ts = (Ts0 + K * N) band 16#FFFFFFFF,
            chappe_mix_jbuf:push(1, Seq0 + K, Ts, bytes(K * N, N), Acc)
        end,
        J,
        lists:seq(0, Count - 1)
    ).

bytes(From, N) -> <<<<(I rem 256)>> || I <- lists:seq(From, From + N - 1)>>.

%% 30 ms packets play out as 20 ms frames, every sample once, in order.
thirty_ms_test() ->
    J = pkts(chappe_mix_jbuf:new(4, 16#FF), 100, 5000, 240, 2),
    {Fs, _} = pops(J, 3),
    ?assertEqual([bytes(0, 160), bytes(160, 160), bytes(320, 160)], Fs).

%% Two 10 ms packets make a frame.
ten_ms_test() ->
    J = pkts(chappe_mix_jbuf:new(3, 16#FF), 7, 0, 80, 4),
    {Fs, J1} = pops(J, 2),
    ?assertEqual([bytes(0, 160), bytes(160, 160)], Fs),
    ?assertMatch(#{dropped := 0, lost := 0}, chappe_mix_jbuf:stats(J1)).

%% A lost 10 ms packet is filled with the silence byte; the frame around
%% it still plays.
ten_ms_loss_test() ->
    J = lists:foldl(
        fun(K, Acc) ->
            chappe_mix_jbuf:push(1, K, K * 80, bytes(K * 80, 80), Acc)
        end,
        chappe_mix_jbuf:new(3, 16#FF),
        [0, 2, 3]
    ),
    {[F1, F2], J1} = pops(J, 2),
    Silence = binary:copy(<<16#FF>>, 80),
    ?assertEqual(<<(bytes(0, 80))/binary, Silence/binary>>, F1),
    ?assertEqual(bytes(160, 160), F2),
    ?assertMatch(#{lost := 1}, chappe_mix_jbuf:stats(J1)).

%% A 200 ms packet is larger than the depth; it is kept whole, not
%% trimmed, and plays over ten ticks.
two_hundred_ms_test() ->
    J = pkts(chappe_mix_jbuf:new(3, 16#FF), 1, 0, 1600, 1),
    {Fs, J1} = pops(J, 11),
    ?assertEqual(
        [bytes(I * 160, 160) || I <- lists:seq(0, 9)], lists:sublist(Fs, 10)
    ),
    ?assertEqual(silence, lists:last(Fs)),
    ?assertMatch(#{dropped := 0}, chappe_mix_jbuf:stats(J1)).

%% The next 200 ms packet comes while a frame of the last one is still to
%% play: both are kept, every sample plays once.
two_hundred_ms_back_to_back_test() ->
    J0 = pkts(chappe_mix_jbuf:new(3, 16#FF), 1, 0, 1600, 1),
    {_, J1} = pops(J0, 9),
    J2 = chappe_mix_jbuf:push(1, 2, 1600, bytes(1600, 1600), J1),
    {Fs, J3} = pops(J2, 11),
    ?assertEqual([bytes(I * 160, 160) || I <- lists:seq(9, 19)], Fs),
    ?assertMatch(#{dropped := 0}, chappe_mix_jbuf:stats(J3)).

%% A frame whose second half has not arrived yet is not played half
%% silent: the tick is an underrun and the half waits for the rest.
half_frame_waits_test() ->
    J = pkts(chappe_mix_jbuf:new(4, 16#FF), 1, 0, 240, 1),
    {[F1, silence], J1} = pops(J, 2),
    ?assertEqual(bytes(0, 160), F1),
    ?assertMatch(#{underruns := 1}, chappe_mix_jbuf:stats(J1)),
    J2 = chappe_mix_jbuf:push(1, 2, 240, bytes(240, 240), J1),
    {[F2, F3], _} = pops(J2, 2),
    ?assertEqual([bytes(160, 160), bytes(320, 160)], [F2, F3]).

%% Silence suppression: the packet after a pause has the next sequence
%% number and a timestamp that moved on with the clock. Nothing is lost,
%% and the pause is not played out once the talker is back: the playout
%% point jumps to it.
suppression_test() ->
    J0 = pkts(chappe_mix_jbuf:new(3, 16#FF), 1, 0, 160, 2),
    {_, J1} = pops(J0, 3),
    J2 = chappe_mix_jbuf:push(1, 3, 160 * 52, bytes(7, 160), J1),
    J3 = chappe_mix_jbuf:push(1, 4, 160 * 53, bytes(0, 160), J2),
    {[F | _], J4} = pops(J3, 1),
    ?assertEqual(bytes(7, 160), F),
    ?assertMatch(#{lost := 0}, chappe_mix_jbuf:stats(J4)).

%% Loss across a pause: the first packet of the talkspurt is lost. Only
%% that packet's time plays as silence, not the whole pause.
loss_after_pause_test() ->
    J0 = pkts(chappe_mix_jbuf:new(3, 16#FF), 1, 0, 160, 2),
    {_, J1} = pops(J0, 3),
    %% seq 3 at 160 * 52 is lost
    J2 = chappe_mix_jbuf:push(1, 4, 160 * 53, bytes(0, 160), J1),
    J3 = chappe_mix_jbuf:push(1, 5, 160 * 54, bytes(160, 160), J2),
    {Fs, J4} = pops(J3, 3),
    ?assertEqual([silence, bytes(0, 160), bytes(160, 160)], Fs),
    ?assertMatch(#{lost := 1}, chappe_mix_jbuf:stats(J4)).

%% The 32-bit timestamp wraps without a gap.
ts_wrap_test() ->
    J = pkts(chappe_mix_jbuf:new(4, 16#FF), 10, 16#FFFFFFFF - 239, 160, 4),
    {Fs, _} = pops(J, 4),
    ?assertEqual([bytes(K * 160, 160) || K <- [0, 1, 2, 3]], Fs).

%% Waiting for the first frame of a stream is not an underrun.
no_underrun_before_start_test() ->
    J = chappe_mix_jbuf:push(
        1, 1, 0, bytes(0, 80), chappe_mix_jbuf:new(3, 16#FF)
    ),
    {[silence, silence], J1} = pops(J, 2),
    ?assertMatch(#{underruns := 0}, chappe_mix_jbuf:stats(J1)).

%% After 10 s (500 frames) without an underrun, a prefill that grew is
%% taken back by one, and the frame of slack it was holding is skipped,
%% so a burst long gone stops costing a frame of latency.
prefill_shrinks_test() ->
    P = fun(J, N) -> chappe_mix_jbuf:push(1, N, <<N:16>>, J) end,
    %% an underrun: the prefill grows to 2
    J0 = P(chappe_mix_jbuf:new(3, 16#FF, true), 1),
    {[<<1:16>>, silence], J1} = pops(J0, 2),
    ?assertMatch(#{prefill := 2}, chappe_mix_jbuf:stats(J1)),
    %% a steady sender two frames ahead: one in, one out, 500 times
    J2 = P(P(J1, 2), 3),
    {J3, Out} = lists:foldl(
        fun(N, {J, Acc}) ->
            {F, J4} = chappe_mix_jbuf:pop(P(J, N)),
            {J4, [F | Acc]}
        end,
        {J2, []},
        lists:seq(4, 503)
    ),
    Played = lists:reverse(Out),
    ?assertMatch(#{prefill := 1, underruns := 1}, chappe_mix_jbuf:stats(J3)),
    %% every frame once, in order, two behind the sender; the 500th tick
    %% shrinks the prefill and skips the next frame, 502
    ?assertEqual([<<N:16>> || N <- lists:seq(2, 501)], Played),
    %% one frame less behind: the next tick plays 503, not 502
    {F, _} = chappe_mix_jbuf:pop(P(J3, 504)),
    ?assertEqual(<<503:16>>, F).

%% Unless asked for, a grown prefill stays.
prefill_stays_by_default_test() ->
    P = fun(J, N) -> chappe_mix_jbuf:push(1, N, <<N:16>>, J) end,
    {[<<1:16>>, silence], J1} = pops(P(chappe_mix_jbuf:new(3), 1), 2),
    J2 = lists:foldl(
        fun(N, J) -> element(2, chappe_mix_jbuf:pop(P(J, N))) end,
        P(P(J1, 2), 3),
        lists:seq(4, 603)
    ),
    ?assertMatch(
        #{prefill := 2, prefill_shrunk := 0}, chappe_mix_jbuf:stats(J2)
    ).

%% A prefill of 1 does not shrink, and nothing is skipped.
prefill_floor_test() ->
    {J, Out} = lists:foldl(
        fun(N, {J0, Acc}) ->
            {F, J1} = chappe_mix_jbuf:pop(
                chappe_mix_jbuf:push(1, N, <<N:16>>, J0)
            ),
            {J1, [F | Acc]}
        end,
        {chappe_mix_jbuf:new(3), []},
        lists:seq(1, 600)
    ),
    ?assertEqual([<<N:16>> || N <- lists:seq(1, 600)], lists:reverse(Out)),
    ?assertMatch(#{prefill := 1}, chappe_mix_jbuf:stats(J)).

%% Empty ticks once playout has started are counted as underruns.
underrun_count_test() ->
    J = push(chappe_mix_jbuf:new(3), [10]),
    {_, J1} = pops(J, 3),
    ?assertMatch(#{underruns := 2}, chappe_mix_jbuf:stats(J1)).
