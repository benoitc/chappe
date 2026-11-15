%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_cluster on one node (voters = [node()]): leases, KV, watches,
%% singletons, the directory, and the four tests per process (owner death,
%% own crash, bound; the peer-node ones are in chappe_cluster_peer_SUITE).
-module(chappe_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(LEASE, 1500).
-define(RENEW, 300).
-define(MAX_LEASES, 50).
-define(MAX_KEYS, 50).
-define(MAX_MAILBOX, 100).

all() ->
    [
        claim_owner_release,
        owned_by_another_holder,
        claim_again_bumps_the_fence,
        holder_death_releases,
        lease_for_another_pid,
        agent_crash_keeps_leases,
        agent_crash_without_quorum_tells_the_holder,
        lapse_tells_the_holder,
        lapse_fires_through_a_flooded_agent,
        late_claim_reply_is_no_quorum,
        valid_follows_the_lease,
        no_quorum_is_bounded,
        max_leases_bound,
        kv_put_get_cas_delete,
        kv_bounds,
        watch_events,
        watch_survives_a_hub_crash,
        watcher_death_drops_the_watch,
        watch_overflow_bound,
        singleton_runs_one_child,
        singleton_child_crash_restarts_it,
        singleton_contender_crash_stops_its_child,
        singleton_lost_kills_a_slow_child,
        stop_singleton,
        directory_local,
        bad_arguments,
        bad_config_fails_the_start
    ].

init_per_suite(Config) ->
    ok = chappe_cluster_test_dist:ensure(),
    Dir = filename:join(?config(priv_dir, Config), "ra"),
    Env = #{
        data_dir => Dir,
        lease_ms => ?LEASE,
        renew_ms => ?RENEW,
        max_leases => ?MAX_LEASES,
        max_keys => ?MAX_KEYS,
        max_value_bytes => 1024,
        max_watch_mailbox => ?MAX_MAILBOX,
        command_timeout => 2000
    },
    ok = application:load(chappe_cluster),
    [application:set_env(chappe_cluster, K, V) || K := V <- Env],
    {ok, _} = application:ensure_all_started(chappe_cluster),
    ok = wait_live(),
    [{env, Env} | Config].

end_per_suite(_Config) ->
    %% leave the CT node as it was for the suites that run after this one
    _ = application:stop(chappe_cluster),
    [_ = application:stop(A) || A <- [ra, aten, gen_batch_server, seshat]],
    ok.

init_per_testcase(_Case, Config) ->
    ok = wait_live(),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

%% ---- leases ----

claim_owner_release(_Config) ->
    {ok, L} = chappe_cluster:claim(k_basic, #{}),
    #{key := k_basic, node := N, pid := P, region := default} = L,
    ?assertEqual(node(), N),
    ?assertEqual(self(), P),
    Fence = chappe_cluster:fence(L),
    ?assertMatch({default, _, _}, Fence),
    Owner = #{node => node(), pid => self(), fence => Fence},
    ?assertEqual({ok, Owner}, chappe_cluster:owner(k_basic)),
    ?assertEqual({ok, Owner}, chappe_cluster:owner(k_basic, consistent)),
    ?assert(lists:member(Owner#{key => k_basic}, chappe_cluster:leases())),
    ok = chappe_cluster:release(L),
    ?assertEqual(none, chappe_cluster:owner(k_basic)),
    ?assertEqual(none, chappe_cluster:owner(k_basic, consistent)).

owned_by_another_holder(_Config) ->
    {ok, L} = chappe_cluster:claim(k_owned, #{}),
    Other = spawn_holder(),
    ?assertMatch(
        {error, {owned, #{pid := P}}} when P =:= self(),
        chappe_cluster:claim(k_owned, #{pid => Other})
    ),
    ok = chappe_cluster:release(L),
    {ok, L2} = chappe_cluster:claim(k_owned, #{pid => Other}),
    ?assert(seq(L2) > seq(L)),
    exit(Other, kill).

claim_again_bumps_the_fence(_Config) ->
    {ok, L1} = chappe_cluster:claim(k_again, #{}),
    {ok, L2} = chappe_cluster:claim(k_again, #{}),
    {R, E, S1} = chappe_cluster:fence(L1),
    ?assertMatch({R, E, S2} when S2 > S1, chappe_cluster:fence(L2)),
    %% releasing the first lease leaves the second alone
    ok = chappe_cluster:release(L1),
    ?assertMatch({ok, #{pid := P}} when P =:= self(), chappe_cluster:owner(k_again)),
    ok = chappe_cluster:release(L2).

%% Owner death: the holder dies, the region frees its key.
holder_death_releases(_Config) ->
    H = spawn_holder(),
    {ok, _} = chappe_cluster:claim(k_death, #{pid => H}),
    exit(H, kill),
    wait(fun() -> chappe_cluster:owner(k_death) =:= none end),
    {ok, _} = chappe_cluster:claim(k_death, #{}).

lease_for_another_pid(_Config) ->
    H = spawn_holder(),
    {ok, L} = chappe_cluster:claim(k_for, #{pid => H}),
    ?assertMatch(#{pid := H}, L),
    ok = chappe_cluster:release(L),
    exit(H, kill).

%% Own crash: the agent dies; the leases stay with their holders, and the
%% new agent tracks them again from the region.
agent_crash_keeps_leases(_Config) ->
    {ok, L} = chappe_cluster:claim(k_agent, #{}),
    Old = whereis(chappe_cluster_node),
    exit(Old, kill),
    wait(fun() ->
        case whereis(chappe_cluster_node) of
            undefined -> false;
            Old -> false;
            _ -> true
        end
    end),
    ok = wait_live(),
    ?assertMatch({ok, #{pid := P}} when P =:= self(), chappe_cluster:owner(k_agent)),
    wait(fun() -> tracked(k_agent) end),
    receive
        {chappe_cluster, _, lost} = M -> ct:fail({unexpected, M})
    after 0 -> ok
    end,
    ok = chappe_cluster:release(L).

%% Own crash while the quorum is gone: the holders are still told lost
%% before lease_ms runs out.
agent_crash_without_quorum_tells_the_holder(_Config) ->
    {ok, L} = chappe_cluster:claim(k_agent_nq, #{}),
    T0 = erlang:monotonic_time(millisecond),
    with_member_suspended(fun() ->
        exit(whereis(chappe_cluster_node), kill),
        receive
            {chappe_cluster, #{key := k_agent_nq} = Lost, lost} ->
                ?assertEqual(seq(L), seq(Lost)),
                ?assert(erlang:monotonic_time(millisecond) - T0 < ?LEASE)
        after 3 * ?LEASE ->
            ct:fail(no_lost)
        end
    end),
    ok = wait_live(),
    wait(fun() -> chappe_cluster:owner(k_agent_nq) =:= none end).

%% The lapse fires on time even with the agent's mailbox full.
lapse_fires_through_a_flooded_agent(_Config) ->
    {ok, _} = chappe_cluster:claim(k_flood, #{}),
    Agent = whereis(chappe_cluster_node),
    T0 = erlang:monotonic_time(millisecond),
    with_member_suspended(fun() ->
        ok = sys:suspend(Agent),
        [gen_server:cast(Agent, {junk, I}) || I <- lists:seq(1, 200000)],
        try
            receive
                {chappe_cluster, #{key := k_flood}, lost} ->
                    ?assert(erlang:monotonic_time(millisecond) - T0 < ?LEASE)
            after 3 * ?LEASE ->
                ct:fail(no_lost)
            end
        after
            sys:resume(Agent)
        end
    end),
    ok = wait_live(),
    wait(fun() -> chappe_cluster:owner(k_flood) =:= none end, 300).

%% A grant that comes back after the node's deadline is not a lease.
late_claim_reply_is_no_quorum(_Config) ->
    Self = self(),
    Pid = whereis(chappe_cluster_config:server_name()),
    ok = sys:suspend(Pid),
    C = spawn(fun() ->
        Self ! {claimed, chappe_cluster:claim(k_late, #{timeout => 3 * ?LEASE})}
    end),
    wait(fun() -> chappe_cluster_node:live() =:= not_live end),
    ok = sys:resume(Pid),
    receive
        {claimed, R} -> ?assertEqual({error, no_quorum}, R)
    after 4 * ?LEASE -> ct:fail(no_reply)
    end,
    exit(C, kill),
    ok = wait_live(),
    wait(fun() -> chappe_cluster:owner(k_late) =:= none end).

valid_follows_the_lease(_Config) ->
    {ok, L} = chappe_cluster:claim(k_valid, #{}),
    ?assert(chappe_cluster:valid(L)),
    ok = chappe_cluster:release(L),
    ?assertNot(chappe_cluster:valid(L)),
    {ok, L2} = chappe_cluster:claim(k_valid, #{}),
    with_member_suspended(fun() ->
        receive
            {chappe_cluster, _, lost} -> ok
        after 3 * ?LEASE -> ct:fail(no_lost)
        end,
        ?assertNot(chappe_cluster:valid(L2))
    end),
    ?assertNot(chappe_cluster:valid(nolease)).

%% The node cannot reach the quorum (its member is suspended): its holders
%% are told the lease is lost before lease_ms runs out.
lapse_tells_the_holder(_Config) ->
    {ok, L} = chappe_cluster:claim(k_lapse, #{}),
    T0 = erlang:monotonic_time(millisecond),
    with_member_suspended(fun() ->
        receive
            {chappe_cluster, #{key := k_lapse} = Lost, lost} ->
                ?assertEqual(seq(L), seq(Lost)),
                ?assert(erlang:monotonic_time(millisecond) - T0 < ?LEASE)
        after 3 * ?LEASE ->
            ct:fail(no_lost)
        end
    end),
    ok = wait_live(),
    %% the release queued at the lapse frees the key once the node is back
    wait(fun() -> chappe_cluster:owner(k_lapse) =:= none end).

%% Without a quorum, claim returns no_quorum within a bounded time.
no_quorum_is_bounded(_Config) ->
    with_member_suspended(fun() ->
        T0 = erlang:monotonic_time(millisecond),
        ?assertEqual({error, no_quorum}, chappe_cluster:claim(k_nq, #{timeout => 1000})),
        ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
        wait(fun() -> chappe_cluster_node:live() =:= not_live end),
        T1 = erlang:monotonic_time(millisecond),
        ?assertEqual({error, no_quorum}, chappe_cluster:claim(k_nq, #{})),
        ?assert(erlang:monotonic_time(millisecond) - T1 < 100)
    end),
    ok = wait_live(),
    %% the abandoned claim does not keep the key
    wait(fun() -> chappe_cluster:owner(k_nq) =:= none end).

%% Bound: max_leases per node.
max_leases_bound(_Config) ->
    H = spawn_holder(),
    Base = length([L || #{node := N} = L <- chappe_cluster:leases(), N =:= node()]),
    Results = [chappe_cluster:claim({k_max, I}, #{pid => H}) || I <- lists:seq(1, ?MAX_LEASES - Base)],
    ?assert(lists:all(fun({ok, _}) -> true; (_) -> false end, Results)),
    ?assertEqual({error, max_leases}, chappe_cluster:claim({k_max, over}, #{pid => H})),
    exit(H, kill),
    wait(fun() -> chappe_cluster:owner({k_max, 1}) =:= none end),
    {ok, _} = chappe_cluster:claim({k_max, over}, #{}).

%% ---- KV ----

kv_put_get_cas_delete(_Config) ->
    K = <<"kv/basic">>,
    ?assertEqual(not_found, chappe_cluster:get(K)),
    {ok, V1} = chappe_cluster:put(K, #{a => 1}),
    ?assertEqual({ok, #{a => 1}, V1}, chappe_cluster:get(K)),
    ?assertEqual({error, {version, V1}}, chappe_cluster:cas(K, 0, x)),
    {ok, V2} = chappe_cluster:cas(K, V1, x),
    ?assert(V2 > V1),
    ?assertEqual({error, {version, V2}}, chappe_cluster:cas(K, V1, y)),
    ok = chappe_cluster:delete(K),
    ?assertEqual(not_found, chappe_cluster:get(K)),
    {ok, V3} = chappe_cluster:cas(K, 0, z),
    ?assert(V3 > V2),
    ok = chappe_cluster:delete(K).

%% Bound: max_value_bytes and max_keys.
kv_bounds(_Config) ->
    ?assertEqual({error, too_large}, chappe_cluster:put(<<"kv/big">>, binary:copy(<<0>>, 2048))),
    Keys = [<<"kv/n/", (integer_to_binary(I))/binary>> || I <- lists:seq(1, ?MAX_KEYS + 5)],
    try
        Results = [chappe_cluster:put(K, I) || {I, K} <- lists:enumerate(Keys)],
        ?assertEqual(5, length([R || {error, max_keys} = R <- Results])),
        %% an existing key can still be written
        {ok, _} = chappe_cluster:put(hd(Keys), again)
    after
        [ok = chappe_cluster:delete(K) || K <- Keys]
    end,
    {ok, _} = chappe_cluster:put(<<"kv/after">>, 1),
    ok = chappe_cluster:delete(<<"kv/after">>).

%% ---- watches ----

watch_events(_Config) ->
    ok = chappe_cluster:watch(<<"w/">>),
    {ok, _} = chappe_cluster:put(<<"other/1">>, 0),
    {ok, _} = chappe_cluster:put(<<"w/1">>, 1),
    ?assertEqual({put, <<"w/1">>, 1}, recv_watch()),
    ok = chappe_cluster:delete(<<"w/1">>),
    ?assertEqual({delete, <<"w/1">>, 1}, recv_watch()),
    ok = chappe_cluster:unwatch(<<"w/">>),
    {ok, _} = chappe_cluster:put(<<"w/2">>, 2),
    receive
        {chappe_cluster, watch, E} -> ct:fail({unexpected, E})
    after 300 -> ok
    end,
    ok = chappe_cluster:delete(<<"w/2">>),
    ok = chappe_cluster:delete(<<"other/1">>).

%% Own crash: the hub restarts and the watch goes on (watchers are in pg).
watch_survives_a_hub_crash(_Config) ->
    ok = chappe_cluster:watch(<<"wc/">>),
    Old = whereis(chappe_cluster_watch),
    exit(Old, kill),
    wait(fun() ->
        W = whereis(chappe_cluster_watch),
        W =/= undefined andalso W =/= Old
    end),
    ok = wait_live(),
    {ok, _} = chappe_cluster:put(<<"wc/1">>, 1),
    ?assertEqual({put, <<"wc/1">>, 1}, recv_watch()),
    ok = chappe_cluster:delete(<<"wc/1">>).

%% Owner death: the watcher dies, its watch goes.
watcher_death_drops_the_watch(_Config) ->
    Self = self(),
    W = spawn(fun() ->
        ok = chappe_cluster:watch(<<"wd/">>),
        Self ! watching,
        receive
            stop -> ok
        end
    end),
    receive
        watching -> ok
    end,
    Group = {chappe_cluster_watch, <<"wd/">>},
    ?assertEqual([W], pg:get_local_members(chappe_cluster, Group)),
    exit(W, kill),
    wait(fun() -> pg:get_local_members(chappe_cluster, Group) =:= [] end).

%% Bound: a watcher that does not read gets overflow once and is dropped,
%% and its mailbox stays under the bound.
watch_overflow_bound(_Config) ->
    Self = self(),
    W = spawn(fun() ->
        ok = chappe_cluster:watch(<<"wo/">>),
        Self ! watching,
        receive
            dump -> Self ! {mailbox, drain([])}
        end
    end),
    receive
        watching -> ok
    end,
    N = 3 * ?MAX_MAILBOX,
    [{ok, _} = chappe_cluster:put(<<"wo/k">>, I) || I <- lists:seq(1, N)],
    wait(fun() ->
        pg:get_local_members(chappe_cluster, {chappe_cluster_watch, <<"wo/">>}) =:= []
    end),
    {message_queue_len, Len} = process_info(W, message_queue_len),
    ?assert(Len =< ?MAX_MAILBOX + 1),
    W ! dump,
    Msgs =
        receive
            {mailbox, M} -> M
        after 5000 -> ct:fail(no_dump)
        end,
    ?assertEqual(1, length([x || {chappe_cluster, watch, overflow} <- Msgs])),
    ?assertMatch({chappe_cluster, watch, overflow}, lists:last(Msgs)),
    ok = chappe_cluster:delete(<<"wo/k">>).

%% ---- singletons ----

singleton_runs_one_child(_Config) ->
    ok = chappe_cluster:singleton(s_one, child_spec(s_one)),
    ?assertEqual({error, already_started}, chappe_cluster:singleton(s_one, child_spec(s_one))),
    Pid = wait_singleton(s_one, undefined),
    ?assertEqual(node(), node(Pid)),
    {ok, Fence} = chappe_cluster:singleton_fence(s_one),
    ?assertMatch({ok, #{fence := Fence}}, chappe_cluster:owner({chappe_cluster_singleton, s_one})),
    ok = chappe_cluster:stop_singleton(s_one).

singleton_child_crash_restarts_it(_Config) ->
    ok = chappe_cluster:singleton(s_crash, child_spec(s_crash)),
    P1 = wait_singleton(s_crash, undefined),
    {ok, F1} = chappe_cluster:singleton_fence(s_crash),
    exit(P1, kill),
    P2 = wait_singleton(s_crash, P1),
    wait(fun() -> chappe_cluster:singleton_fence(s_crash) =/= none end),
    {ok, F2} = chappe_cluster:singleton_fence(s_crash),
    ?assert(element(3, F2) > element(3, F1)),
    ?assert(is_process_alive(P2)),
    ok = chappe_cluster:stop_singleton(s_crash).

%% Own crash: the contender dies, its child stops with it, and the
%% restarted contender runs a new child.
singleton_contender_crash_stops_its_child(_Config) ->
    ok = chappe_cluster:singleton(s_cont, child_spec(s_cont)),
    P1 = wait_singleton(s_cont, undefined),
    Ref = erlang:monitor(process, P1),
    [Contender] = [C || {s_cont, C, _, _} <- supervisor:which_children(chappe_cluster_singleton_sup)],
    exit(Contender, kill),
    receive
        {'DOWN', Ref, process, P1, _} -> ok
    after 5000 -> ct:fail(child_alive)
    end,
    _ = wait_singleton(s_cont, P1),
    ok = chappe_cluster:stop_singleton(s_cont).

%% On lost the child is killed, not shut down: a child that takes its time
%% to stop is gone well before another node could run it.
singleton_lost_kills_a_slow_child(_Config) ->
    Spec = #{id => s_slow, start => {?MODULE, start_slow_child, []}},
    ok = chappe_cluster:singleton(s_slow, Spec),
    P = wait_singleton(s_slow, undefined),
    Ref = erlang:monitor(process, P),
    T0 = erlang:monotonic_time(millisecond),
    with_member_suspended(fun() ->
        receive
            {'DOWN', Ref, process, P, Reason} ->
                ?assertEqual(killed, Reason),
                ?assert(erlang:monotonic_time(millisecond) - T0 < ?LEASE)
        after 3 * ?LEASE -> ct:fail(child_alive)
        end
    end),
    ok = chappe_cluster:stop_singleton(s_slow).

stop_singleton(_Config) ->
    ok = chappe_cluster:singleton(s_stop, child_spec(s_stop)),
    P = wait_singleton(s_stop, undefined),
    ok = chappe_cluster:stop_singleton(s_stop),
    ?assertNot(is_process_alive(P)),
    wait(fun() -> chappe_cluster:whereis_singleton(s_stop) =:= none end),
    wait(fun() -> chappe_cluster:owner({chappe_cluster_singleton, s_stop}) =:= none end),
    ?assertEqual({error, not_found}, chappe_cluster:stop_singleton(s_stop)).

%% ---- directory and region ----

directory_local(_Config) ->
    ?assertEqual(default, chappe_cluster:home({room, <<"r1">>})),
    ?assertEqual(not_found, chappe_cluster_directory:resolve({room, <<"r1">>})),
    ok = chappe_cluster_directory:publish({room, <<"r1">>}, default, #{node => node()}),
    ?assertEqual(
        {ok, #{region => default, info => #{node => node()}}},
        chappe_cluster_directory:resolve({room, <<"r1">>})
    ),
    ?assertEqual({error, badarg}, chappe_cluster_directory:publish(k, "r", #{})).

bad_arguments(_Config) ->
    ?assertEqual({error, badarg}, chappe_cluster:claim(k, nomap)),
    ?assertEqual({error, badarg}, chappe_cluster:claim(k, #{pid => notapid})),
    ?assertEqual({error, badarg}, chappe_cluster:claim(k, #{timeout => -1})),
    ?assertEqual({error, badarg}, chappe_cluster:claim(k, #{timeout => infinity})),
    ?assertEqual({error, badarg}, chappe_cluster:release(nolease)),
    ?assertEqual({error, badarg}, chappe_cluster:owner(k, sometimes)),
    ?assertEqual({error, badarg}, chappe_cluster:get(notbinary)),
    ?assertEqual({error, badarg}, chappe_cluster:put(notbinary, 1)),
    ?assertEqual({error, badarg}, chappe_cluster:delete(1)),
    ?assertEqual({error, badarg}, chappe_cluster:cas(<<"k">>, -1, 1)),
    ?assertEqual({error, badarg}, chappe_cluster:watch(notbinary)),
    ?assertEqual({error, badarg}, chappe_cluster:unwatch(notbinary)),
    ?assertEqual({error, badarg}, chappe_cluster:singleton(s, #{id => s})),
    ?assertEqual({error, badarg}, chappe_cluster:join("node")),
    ?assertEqual({error, badarg}, chappe_cluster:leave(1)).

bad_config_fails_the_start(_Config) ->
    Bad = [
        {lease_ms, 100},
        {lease_ms, 2 * ?RENEW},
        {renew_ms, 0},
        {region, "r"},
        {voters, []},
        {data_dir, 1},
        {directory, "m"}
    ],
    lists:foreach(
        fun({K, V}) ->
            Old = application:get_env(chappe_cluster, K),
            ok = application:set_env(chappe_cluster, K, V),
            ?assertEqual({error, badarg}, chappe_cluster_config:load()),
            case Old of
                {ok, O} -> ok = application:set_env(chappe_cluster, K, O);
                undefined -> ok = application:unset_env(chappe_cluster, K)
            end
        end,
        Bad
    ),
    ok = chappe_cluster_config:load(),
    ?assertMatch(#{live := true}, chappe_cluster:status()).

%% ---- helpers ----

seq(#{seq := S}) -> S.

spawn_holder() ->
    spawn(fun() ->
        receive
            stop -> ok
        end
    end).

tracked(Key) ->
    ets:member(chappe_cluster_tab, {holder, Key}).

with_member_suspended(Fun) ->
    Pid = whereis(chappe_cluster_config:server_name()),
    ok = sys:suspend(Pid),
    try
        Fun()
    after
        ok = sys:resume(Pid)
    end.

wait_live() ->
    wait(fun() -> chappe_cluster_node:live() =/= not_live end, 200).

wait(Fun) ->
    wait(Fun, 100).

wait(Fun, 0) ->
    ?assert(Fun());
wait(Fun, N) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait(Fun, N - 1)
    end.

recv_watch() ->
    receive
        {chappe_cluster, watch, E} -> E
    after 5000 -> ct:fail(no_watch_event)
    end.

drain(Acc) ->
    receive
        M -> drain([M | Acc])
    after 0 -> lists:reverse(Acc)
    end.

child_spec(Name) ->
    #{id => Name, start => {?MODULE, start_child, [Name]}}.

start_child(_Name) ->
    {ok,
        spawn_link(fun() ->
            receive
                stop -> ok
            end
        end)}.

%% A child that traps exits and takes 10 s to stop.
start_slow_child() ->
    {ok,
        spawn_link(fun() ->
            process_flag(trap_exit, true),
            receive
                {'EXIT', _, _} -> timer:sleep(10000)
            end
        end)}.

wait_singleton(Name, Not) ->
    wait(fun() ->
        case chappe_cluster:whereis_singleton(Name) of
            {ok, P} -> P =/= Not;
            none -> false
        end
    end),
    {ok, P} = chappe_cluster:whereis_singleton(Name),
    P.
