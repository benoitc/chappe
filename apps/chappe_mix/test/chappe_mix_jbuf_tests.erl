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
