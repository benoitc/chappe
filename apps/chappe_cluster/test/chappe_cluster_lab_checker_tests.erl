%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_cluster_lab_checker_tests).

-include_lib("eunit/include/eunit.hrl").

-define(C, chappe_cluster_lab_checker).

a() -> {n1, 1, 1}.
b() -> {n2, 1, 1}.
f(Seq) -> {default, 1, Seq}.

kind({violation, #{kind := K}}) -> K;
kind(ok) -> ok.

handover_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, fence_used, f(1)},
        {30, a(), k, release, f(1)},
        {30, b(), k, claim_ok, f(2)},
        {40, b(), k, lost, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log)).

order_of_input_does_not_matter_test() ->
    Log = [
        {40, b(), k, lost, f(2)},
        {30, a(), k, release, f(1)},
        {10, a(), k, claim_ok, f(1)},
        {35, b(), k, claim_ok, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log)).

overlap_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {25, b(), k, claim_ok, f(2)},
        {30, a(), k, renew, f(1)},
        {31, a(), k, lost, f(1)}
    ],
    {violation, V} = ?C:check(Log),
    ?assertMatch(#{kind := overlap, key := k, at := 25}, V),
    ?assertMatch(#{first := #{holder := {n1, 1, 1}}}, V),
    ?assertMatch(#{second := #{holder := {n2, 1, 1}}}, V),
    ?assertEqual(4, length(maps:get(context, V))).

margin_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {25, b(), k, claim_ok, f(2)},
        {30, a(), k, renew, f(1)},
        {31, a(), k, lost, f(1)}
    ],
    ?assertEqual(ok, ?C:check(Log, #{margin_us => 5})),
    ?assertEqual(overlap, kind(?C:check(Log, #{margin_us => 4}))).

other_keys_are_independent_test() ->
    Log = [
        {10, a(), k1, claim_ok, f(1)},
        {15, b(), k2, claim_ok, f(1)},
        {30, a(), k1, release, f(1)},
        {30, b(), k2, release, f(1)}
    ],
    ?assertEqual(ok, ?C:check(Log)).

%% a killed holder logs no end: it held the key until its last event
killed_holder_ends_at_last_event_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, renew, f(1)},
        {21, b(), k, claim_ok, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log)),
    Late = Log ++ [{22, a(), k, renew, f(1)}],
    ?assertEqual(overlap, kind(?C:check(Late))).

%% a partitioned holder told late that it lost the key
late_lost_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {50, b(), k, claim_ok, f(2)},
        {55, a(), k, fence_used, f(1)},
        {60, b(), k, release, f(2)},
        {70, a(), k, lost, f(1)}
    ],
    ?assertEqual(overlap, kind(?C:check(Log))).

%% a holder paused across the takeover that wakes up to its lost did
%% nothing while the other held the key
lost_after_a_pause_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, fence_used, f(1)},
        {50, b(), k, claim_ok, f(2)},
        {70, a(), k, lost, f(1)},
        {80, b(), k, release, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log)),
    Acted = Log ++ [{65, a(), k, fence_used, f(1)}],
    ?assertEqual(overlap, kind(?C:check(Acted))).

%% a long lease covering a short one behind a third
overlap_with_earlier_long_lease_test() ->
    C = {n3, 1, 1},
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {12, b(), k, claim_ok, f(2)},
        {13, b(), k, release, f(2)},
        {14, C, k, claim_ok, f(3)},
        {15, C, k, release, f(3)},
        {100, a(), k, release, f(1)}
    ],
    {violation, V} = ?C:check(Log),
    ?assertMatch(#{kind := overlap, at := 12}, V).

fence_must_grow_test() ->
    Log = [
        {10, a(), k, claim_ok, f(5)},
        {20, a(), k, release, f(5)},
        {30, b(), k, claim_ok, f(5)},
        {40, b(), k, release, f(5)}
    ],
    {violation, V} = ?C:check(Log),
    ?assertMatch(#{kind := fence_order, at := 30, key := k}, V).

fence_orders_by_seq_not_epoch_test() ->
    Log = [
        {10, a(), k, claim_ok, {default, 9, 1}},
        {20, a(), k, release, {default, 9, 1}},
        {30, b(), k, claim_ok, {default, 2, 2}},
        {40, b(), k, release, {default, 2, 2}}
    ],
    ?assertEqual(ok, ?C:check(Log)),
    Whole = fun(F) -> F end,
    ?assertEqual(fence_order, kind(?C:check(Log, #{fence_key => Whole}))).

use_without_lease_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, release, f(1)},
        {30, a(), k, fence_used, f(1)}
    ],
    ?assertEqual(use_without_lease, kind(?C:check(Log))).

fence_mismatch_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, fence_used, f(7)}
    ],
    ?assertEqual(fence_mismatch, kind(?C:check(Log))).

lost_after_release_is_ignored_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, release, f(1)},
        {21, a(), k, lost, f(1)}
    ],
    ?assertEqual(ok, ?C:check(Log)).

reclaim_by_same_holder_closes_first_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, claim_ok, f(2)},
        {30, a(), k, release, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log)),
    {ok, Leases} = ?C:leases(lists:keysort(1, Log)),
    ?assertEqual(2, length(Leases)).

first_violation_in_time_test() ->
    Log = [
        {100, a(), k2, claim_ok, f(1)},
        {110, b(), k2, claim_ok, f(2)},
        {120, a(), k2, release, f(1)},
        {10, a(), k1, claim_ok, f(1)},
        {50, b(), k1, claim_ok, f(2)},
        {60, a(), k1, release, f(1)}
    ],
    {violation, V} = ?C:check(Log),
    ?assertMatch(#{key := k1, at := 50}, V).

bad_event_test() ->
    ?assertEqual(bad_event, kind(?C:check([{1, a(), k, stolen, f(1)}]))),
    ?assertEqual(bad_event, kind(?C:check([not_an_event]))).

context_is_bounded_test() ->
    Renews = [{T, a(), k, renew, f(1)} || T <- lists:seq(11, 40)],
    Log =
        [{10, a(), k, claim_ok, f(1)}] ++ Renews ++
            [{30, b(), k, claim_ok, f(2)}, {41, a(), k, release, f(1)}],
    {violation, V} = ?C:check(Log, #{context => 2}),
    ?assertEqual(5, length(maps:get(context, V))),
    Text = iolist_to_binary(?C:format(V)),
    ?assertMatch({_, _}, binary:match(Text, <<"overlap">>)).

parse_skips_a_cut_line_test() ->
    Bin = <<
        "{10,{n1,1,1},k,claim_ok,{default,1,1}}.\n"
        "{20,{n1,1,1},k,renew,{default,1,1}}.\n"
        "{30,{n1,1,1},k,ren"
    >>,
    ?assertEqual(
        {[{10, a(), k, claim_ok, f(1)}, {20, a(), k, renew, f(1)}], 1},
        ?C:parse(Bin)
    ).

read_logs_test() ->
    Dir = filename:join(
        "/tmp",
        "clb_checker_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_dir(filename:join([Dir, "n1", "x"])),
    ok = file:write_file(
        filename:join([Dir, "n1", "n1-1.log"]),
        <<"{10,{n1,1,1},k,claim_ok,{default,1,1}}.\n">>
    ),
    ok = file:write_file(
        filename:join(Dir, "n2-1.log"),
        <<"{20,{n2,1,1},k,claim_ok,{default,1,2}}.\n">>
    ),
    {Events, 0} = ?C:read_logs(Dir),
    ?assertEqual(2, length(Events)),
    ok = file:del_dir_r(Dir).

stats_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, fence_used, f(1)},
        {30, a(), k, release, f(1)},
        {31, b(), k, claim_ok, f(2)},
        {40, b(), k, lost, f(2)},
        {50, {n2, 1, 2}, k, claim_ok, f(3)}
    ],
    ?assertMatch(
        #{
            claims := 3,
            losts := 1,
            releases := 1,
            uses := 1,
            holders := 3,
            keys := 1,
            takeovers := 1
        },
        ?C:stats(Log)
    ).

%% a killed holder: the region keeps its lease kill_bound_us past the kill
kill_bound_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, renew, f(1)},
        {25, controller, n1, killed, none},
        {40, b(), k, claim_ok, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log)),
    ?assertEqual(ok, ?C:check(Log, #{kill_bound_us => 15})),
    {violation, V} = ?C:check(Log, #{kill_bound_us => 16}),
    ?assertMatch(#{kind := overlap, at := 40, first := #{killed := 25}}, V).

kill_bound_only_for_open_leases_on_that_node_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, release, f(1)},
        {21, b(), k, claim_ok, f(2)},
        {25, controller, n1, killed, none},
        {26, controller, n2, killed, none},
        {35, {n3, 1, 1}, k, claim_ok, f(3)}
    ],
    %% n1 had released; n2's open lease is held to 26 + the bound
    ?assertEqual(ok, ?C:check(Log, #{kill_bound_us => 9})),
    ?assertEqual(overlap, kind(?C:check(Log, #{kill_bound_us => 10}))).

kill_before_the_claim_does_not_count_test() ->
    Log = [
        {5, controller, n1, killed, none},
        {10, a(), k, claim_ok, f(1)},
        {20, b(), k, claim_ok, f(2)}
    ],
    ?assertEqual(ok, ?C:check(Log, #{kill_bound_us => 100})).

kills_are_not_holders_test() ->
    Log = [{10, a(), k, claim_ok, f(1)}, {15, controller, n1, killed, none}],
    ?assertMatch(#{holders := 1, kills := 1, events := 1}, ?C:stats(Log)).

%% a holder silent long before its node is killed had already stopped (a
%% singleton child killed on lost logs no end): no kill bound for it
kill_bound_skips_a_silent_holder_test() ->
    Old = {n1, 1, {singleton, 1}},
    New = {n1, 2, {singleton, 2}},
    Log = [
        {10, Old, k, claim_ok, f(1)},
        {20, Old, k, fence_used, f(1)},
        {3000020, New, k, claim_ok, f(2)},
        {3000030, New, k, fence_used, f(2)},
        {3000040, controller, n1, killed, none}
    ],
    Opts = #{kill_bound_us => 1000000},
    ?assertEqual(ok, ?C:check(Log, Opts)),
    ?assertEqual(overlap, kind(?C:check(Log, Opts#{kill_slack_us => 4000000}))).

%% a killed node started again may end its old epoch at once
kill_bound_ends_at_the_restart_test() ->
    Log = [
        {10, a(), k, claim_ok, f(1)},
        {20, a(), k, renew, f(1)},
        {25, controller, n1, killed, none},
        {30, controller, n1, started, none},
        {35, b(), k, claim_ok, f(2)}
    ],
    Opts = #{kill_bound_us => 100},
    ?assertEqual(ok, ?C:check(Log, Opts)),
    Early = [E || {T, _, _, _, _} = E <- Log, T =/= 35] ++ [{28, b(), k, claim_ok, f(2)}],
    ?assertEqual(overlap, kind(?C:check(Early, Opts))).
