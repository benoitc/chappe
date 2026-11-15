%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_cluster_lab_schedule_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, chappe_cluster_lab_schedule).

names(N) -> ["n" ++ integer_to_list(I) || I <- lists:seq(1, N)].

caps() -> [isolate, split, kill, delay, pause, skew].

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
check_pairs([
    {T1, {skew, _, _} = F},
    {T2, {isolate, _} = I},
    {T3, {heal, I}},
    {T4, {heal, F}}
    | Rest
]) ->
    %% the isolate nested in a skew
    ?assert(T1 < T2 andalso T2 < T3 andalso T3 < T4),
    check_pairs([{T1, F}, {T4, {heal, F}} | Rest]);
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

pause_and_skew_ranges_test() ->
    Sched = lists:append([
        ?S:build(Seed, 1800000, names(5), [pause, skew])
     || Seed <- lists:seq(1, 20)
    ]),
    Pauses = [Ms || {_, {pause, _, Ms}} <- Sched],
    Skews = [Ms || {_, {skew, _, Ms}} <- Sched],
    %% past lease_ms (6000), or about renew_ms / 2 (1000)
    ?assert(lists:any(fun(Ms) -> Ms > 6000 end, Pauses)),
    ?assert(lists:any(fun(Ms) -> Ms >= 750 andalso Ms =< 1250 end, Pauses)),
    [?assert((Ms > 6000 andalso Ms =< 11000) orelse (Ms >= 750 andalso Ms =< 1250)) || Ms <- Pauses],
    %% below and above renew_ms / 2, both ways
    ?assert(lists:any(fun(Ms) -> abs(Ms) < 1000 end, Skews)),
    ?assert(lists:any(fun(Ms) -> abs(Ms) > 1000 end, Skews)),
    ?assert(lists:any(fun(Ms) -> Ms < 0 end, Skews)),
    [?assert(abs(Ms) >= 200 andalso abs(Ms) =< 4000) || Ms <- Skews].

pause_heals_after_its_length_test() ->
    Sched = ?S:build(5, 600000, names(3), [pause]),
    check_pause(Sched).

check_pause([]) ->
    ok;
check_pause([{T1, {pause, _, Ms} = F}, {T2, {heal, F}} | Rest]) ->
    ?assertEqual(T1 + Ms, T2),
    check_pause(Rest).

skew_nests_an_isolate_test() ->
    Sched = ?S:build(9, 1800000, names(3), [skew]),
    Skews = [T || {T, {skew, _, _}} <- Sched],
    Cuts = [T || {T, {isolate, _}} <- Sched],
    ?assertNotEqual([], Skews),
    ?assertEqual([T + 62000 || T <- Skews], Cuts),
    check_pairs(Sched).
