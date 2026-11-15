%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_cluster_lab_schedule_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, chappe_cluster_lab_schedule).

names(N) -> ["n" ++ integer_to_list(I) || I <- lists:seq(1, N)].

caps() -> [isolate, split, kill, delay].

same_seed_same_schedule_test() ->
    A = ?S:build(42, 300000, names(5), caps()),
    ?assertEqual(A, ?S:build(42, 300000, names(5), caps())),
    ?assertNotEqual(A, ?S:build(43, 300000, names(5), caps())).

every_fault_is_healed_in_order_test() ->
    [
        check_pairs(?S:build(Seed, 600000, names(N), caps()))
     || Seed <- lists:seq(1, 50), N <- [3, 4, 5]
    ].

check_pairs([]) ->
    ok;
check_pairs([{T1, Fault}, {T2, {heal, Fault}} | Rest]) ->
    ?assert(T2 > T1),
    case Rest of
        [{T3, _} | _] -> ?assert(T3 > T2);
        [] -> ok
    end,
    check_pairs(Rest).

within_the_run_test() ->
    Sched = ?S:build(7, 120000, names(3), caps()),
    ?assertNotEqual([], Sched),
    {First, _} = hd(Sched),
    {Last, _} = lists:last(Sched),
    ?assert(First >= 10000),
    ?assert(Last =< 120000 - 15000).

sizes_test() ->
    Faults = lists:append([
        [F || {_, F} <- ?S:build(Seed, 600000, names(5), caps())]
     || Seed <- lists:seq(1, 30)
    ]),
    [
        ?assert(length(Min) =< 2 andalso length(Min) + length(Rest) =:= 5)
     || {split, Min, Rest} <- Faults
    ],
    Isolated = lists:usort([length(Ns) || {isolate, Ns} <- Faults]),
    ?assertEqual([1, 2, 3], Isolated),
    [?assert(Ms >= 50 andalso Ms =< 400) || {delay, _, Ms} <- Faults].

caps_limit_the_faults_test() ->
    Sched = ?S:build(3, 600000, names(3), [kill]),
    ?assertEqual([kill], lists:usort([kind(A) || {_, A} <- Sched])).

kind({heal, F}) -> kind(F);
kind(F) -> element(1, F).

describe_test() ->
    Text = iolist_to_binary(?S:describe([{1500, {kill, ["n1"]}}])),
    ?assertMatch({_, _}, binary:match(Text, <<"1.500 s">>)).
