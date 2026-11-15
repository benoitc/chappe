%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The Ra machine, applied directly: unit cases for each command, and PropEr
%% properties over random command sequences for the lease and KV invariants.
-module(chappe_cluster_machine_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(M, chappe_cluster_machine).
-define(LEASE, 6000).

%% ---- helpers ----

init() ->
    ?M:init(#{name => test, region => r1, reap_ms => 2000}).

meta(Idx, Now) ->
    #{index => Idx, term => 1, system_time => Now}.

%% Apply one command; return {State, Reply, Effects}.
ap(Cmd, Now, S) ->
    ap(1, Cmd, Now, S).

ap(Idx, Cmd, Now, S) ->
    case ?M:apply(meta(Idx, Now), Cmd, S) of
        {S1, Reply} -> {S1, Reply, []};
        {S1, Reply, Effs} when is_list(Effs) -> {S1, Reply, Effs};
        {S1, Reply, Eff} -> {S1, Reply, [Eff]}
    end.

renew(Node, Now, S) ->
    {S1, {ok, Epoch}, _} = ap({renew, Node, ?LEASE, []}, Now, S),
    {Epoch, S1}.

claim(Key, Node, Epoch, Pid, Now, S) ->
    ap({claim, Key, Node, Epoch, Pid, make_ref(), 100}, Now, S).

pid(N) ->
    list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

%% ---- liveness ----

renew_keeps_epoch_test() ->
    S0 = init(),
    {E1, S1} = renew(a, 0, S0),
    {E2, _} = renew(a, 1000, S1),
    ?assertEqual(E1, E2).

renew_after_expiry_takes_a_new_epoch_test() ->
    S0 = init(),
    {E1, S1} = renew(a, 0, S0),
    {E2, _} = renew(a, ?LEASE + 1, S1),
    ?assert(E2 > E1).

%% ---- leases ----

claim_needs_a_live_node_test() ->
    S0 = init(),
    {_, R, _} = claim(k, a, 1, pid(1), 0, S0),
    ?assertEqual({error, stale_epoch}, R).

claim_and_owned_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {Eb, S2} = renew(b, 0, S1),
    {S3, {ok, L}, Effs} = claim(k, a, Ea, pid(1), 10, S2),
    ?assertMatch(#{key := k, node := a, pid := _, epoch := Ea, region := r1}, L),
    ?assert(lists:member({monitor, process, pid(1)}, Effs)),
    {_, R, _} = claim(k, b, Eb, pid(2), 20, S3),
    ?assertMatch({error, {owned, #{node := a, fence := {r1, Ea, _}}}}, R).

claim_again_by_the_holder_bumps_the_fence_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, L1}, _} = claim(k, a, Ea, pid(1), 10, S1),
    {S3, {ok, L2}, Effs} = claim(k, a, Ea, pid(1), 20, S2),
    ?assertEqual([], Effs),
    ?assert(maps:get(seq, L2) > maps:get(seq, L1)),
    %% a release queued for the first claim leaves the second alone
    {S4, {ok, Ea}, _} =
        ap({renew, a, ?LEASE, [{seq, k, maps:get(seq, L1)}]}, 30, S3),
    ?assertMatch([#{key := k}], ?M:leases(40, S4)).

takeover_after_expiry_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, L1}, _} = claim(k, a, Ea, pid(1), 10, S1),
    {Eb, S3} = renew(b, ?LEASE + 5, S2),
    {_, {ok, L2}, Effs} = claim(k, b, Eb, pid(2), ?LEASE + 6, S3),
    ?assert(maps:get(seq, L2) > maps:get(seq, L1)),
    Taken = {chappe_cluster_taken, k, maps:get(seq, L1)},
    ?assert(lists:member({send_msg, {chappe_cluster_node, a}, Taken}, Effs)).

renewal_keeps_the_lease_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), 10, S1),
    {Ea, S3} = renew(a, 4000, S2),
    {Eb, S4} = renew(b, 9000, S3),
    {_, R, _} = claim(k, b, Eb, pid(2), 9001, S4),
    ?assertMatch({error, {owned, _}}, R).

release_frees_the_key_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {Eb, S2} = renew(b, 0, S1),
    {S3, {ok, L}, _} = claim(k, a, Ea, pid(1), 10, S2),
    {S4, ok, _} = ap({release, k, maps:get(seq, L)}, 20, S3),
    {_, R, _} = claim(k, b, Eb, pid(2), 30, S4),
    ?assertMatch({ok, _}, R).

release_with_a_stale_seq_is_ignored_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {Eb, S2} = renew(b, 0, S1),
    {S3, {ok, L}, _} = claim(k, a, Ea, pid(1), 10, S2),
    {S4, ok, _} = ap({release, k, maps:get(seq, L) + 100}, 20, S3),
    {_, R, _} = claim(k, b, Eb, pid(2), 30, S4),
    ?assertMatch({error, {owned, _}}, R).

holder_death_releases_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {Eb, S2} = renew(b, 0, S1),
    {S3, {ok, _}, _} = claim(k, a, Ea, pid(1), 10, S2),
    {S4, ok, _} = ap({down, pid(1), killed}, 20, S3),
    {_, R, _} = claim(k, b, Eb, pid(2), 30, S4),
    ?assertMatch({ok, _}, R).

noconnection_keeps_the_lease_and_watches_the_node_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {Eb, S2} = renew(b, 0, S1),
    P = pid(1),
    {S3, {ok, _}, _} = claim(k, a, Ea, P, 10, S2),
    {S4, ok, Effs} = ap({down, P, noconnection}, 20, S3),
    ?assert(lists:member({monitor, node, node(P)}, Effs)),
    {S5, ok, Effs2} = ap({nodeup, node(P)}, 30, S4),
    ?assert(lists:member({monitor, process, P}, Effs2)),
    {_, R, _} = claim(k, b, Eb, pid(2), 40, S5),
    ?assertMatch({error, {owned, _}}, R).

abandoned_claim_is_released_on_renew_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {Eb, S2} = renew(b, 0, S1),
    CRef = make_ref(),
    {S3, {ok, _}, _} =
        ap({claim, k, a, Ea, pid(1), CRef, 100}, 10, S2),
    {S4, {ok, Ea}, _} = ap({renew, a, ?LEASE, [{claim, k, CRef}]}, 20, S3),
    {_, R, _} = claim(k, b, Eb, pid(2), 30, S4),
    ?assertMatch({ok, _}, R).

max_leases_test() ->
    {Ea, S1} = renew(a, 0, init()),
    Cmd = fun(K) -> {claim, K, a, Ea, pid(1), make_ref(), 2} end,
    {S2, {ok, _}, _} = ap(Cmd(k1), 1, S1),
    {S3, {ok, _}, _} = ap(Cmd(k2), 2, S2),
    {_, R, _} = ap(Cmd(k3), 3, S3),
    ?assertEqual({error, max_leases}, R).

reap_drops_expired_leases_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), 10, S1),
    {S3, ok, Effs} = ap({timeout, reap}, ?LEASE + 10, S2),
    ?assert(lists:member({demonitor, process, pid(1)}, Effs)),
    ?assertEqual([], ?M:leases(?LEASE + 10, S3)),
    ?assertEqual(#{}, ?M:counts(S3)).

leader_enter_monitors_holders_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), 10, S1),
    Effs = ?M:state_enter(leader, S2),
    ?assert(lists:member({monitor, process, pid(1)}, Effs)),
    ?assert(lists:keymember(timer, 1, Effs)),
    ?assertEqual([], ?M:state_enter(follower, S2)).

owner_query_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, L}, _} = claim(k, a, Ea, pid(1), 10, S1),
    Fence = {r1, Ea, maps:get(seq, L)},
    ?assertEqual(
        {ok, #{node => a, pid => pid(1), fence => Fence}},
        ?M:query_owner(k, 100, S2)
    ),
    ?assertEqual(none, ?M:query_owner(k, ?LEASE + 1, S2)),
    ?assertEqual(none, ?M:query_owner(other, 100, S2)).

release_cursor_test() ->
    {_, S1} = renew(a, 0, init()),
    {_, _, Effs} = ap(4096, {renew, a, ?LEASE, []}, 1, S1),
    ?assertMatch([{release_cursor, 4096, _}], Effs).

%% ---- KV ----

kv_put_get_delete_test() ->
    {_, S0} = renew(a, 0, init()),
    {S1, {ok, V1}, E1} = ap({put, <<"a/1">>, x, 10}, 0, S0),
    ?assertMatch(
        [
            {send_msg, {chappe_cluster_watch, a},
                {chappe_cluster_kv, put, <<"a/1">>, x}, [local]}
        ],
        E1
    ),
    ?assertEqual({ok, x, V1}, ?M:query_get(<<"a/1">>, S1)),
    {S2, {ok, V2}, _} = ap({put, <<"a/1">>, y, 10}, 0, S1),
    ?assert(V2 > V1),
    {S3, ok, E3} = ap({delete, <<"a/1">>}, 0, S2),
    ?assertMatch(
        [{send_msg, _, {chappe_cluster_kv, delete, <<"a/1">>, y}, _}], E3
    ),
    ?assertEqual(not_found, ?M:query_get(<<"a/1">>, S3)),
    {_, ok, []} = ap({delete, <<"a/1">>}, 0, S3).

kv_cas_test() ->
    S0 = init(),
    {S1, {ok, V1}, _} = ap({cas, <<"k">>, 0, x, 10}, 0, S0),
    {_, R, _} = ap({cas, <<"k">>, 0, y, 10}, 0, S1),
    ?assertEqual({error, {version, V1}}, R),
    {S2, {ok, V2}, _} = ap({cas, <<"k">>, V1, y, 10}, 0, S1),
    ?assert(V2 > V1),
    {_, {error, {version, V2}}, _} = ap({cas, <<"k">>, V1, z, 10}, 0, S2).

kv_max_keys_test() ->
    S0 = init(),
    {S1, {ok, _}, _} = ap({put, <<"a">>, 1, 1}, 0, S0),
    {S2, {ok, _}, _} = ap({put, <<"a">>, 2, 1}, 0, S1),
    {_, R, _} = ap({put, <<"b">>, 1, 1}, 0, S2),
    ?assertEqual({error, max_keys}, R).

%% ---- properties ----

-define(NODES, [a, b, c]).
-define(KEYS, [k1, k2, k3]).
-define(PIDS, [1, 2, 3, 4, 5, 6]).

op() ->
    oneof([
        {renew, oneof(?NODES)},
        {claim, oneof(?KEYS), oneof(?NODES), oneof(?PIDS)},
        {release, oneof(?KEYS)},
        {down, oneof(?PIDS)},
        {wait, range(1, 2 * ?LEASE)},
        reap,
        {put, oneof([<<"x">>, <<"y">>]), int()},
        {cas, oneof([<<"x">>, <<"y">>]), range(0, 40), int()},
        {delete, oneof([<<"x">>, <<"y">>])}
    ]).

prop_leases_and_kv() ->
    ?FORALL(
        Ops,
        list(op()),
        begin
            run(Ops, model()),
            true
        end
    ).

leases_property_test() ->
    ?assert(
        proper:quickcheck(prop_leases_and_kv(), [
            {numtests, 500}, {max_size, 80}, {to_file, user}
        ])
    ).

%% The model: what holders and nodes believe, from the replies they got.
%% - live: node -> {Epoch, LastRenewTime} as the node saw its renewals;
%% - held: key -> {Node, Epoch, Pid, Seq} the last grant, while its holder
%%   still believes it owns it;
%% - seqs: key -> the last fence seq granted;
%% - kv: key -> version.
model() ->
    #{
        s => init(),
        now => 0,
        idx => 1,
        live => #{},
        held => #{},
        seqs => #{},
        kv => #{}
    }.

run([], M) ->
    M;
run([Op | Ops], M) ->
    run(Ops, step(Op, M)).

step({wait, Ms}, M = #{now := Now}) ->
    M#{now := Now + Ms};
step(Op, M = #{s := S, now := Now, idx := Idx}) ->
    Cmd = command(Op, M),
    {S1, Reply, _} = ap(Idx, Cmd, Now, S),
    check(Op, Cmd, Reply, M#{s := S1, idx := Idx + 1}).

command({renew, N}, _) ->
    {renew, N, ?LEASE, []};
command({claim, K, N, P}, #{live := Live}) ->
    E =
        case Live of
            #{N := {E0, _}} -> E0;
            _ -> 0
        end,
    {claim, K, N, E, pid(P), make_ref(), 100};
command({release, K}, #{held := Held}) ->
    Seq =
        case Held of
            #{K := {_, _, _, S}} -> S;
            _ -> 0
        end,
    {release, K, Seq};
command({down, P}, _) ->
    {down, pid(P), killed};
command(reap, _) ->
    {timeout, reap};
command({put, K, V}, _) ->
    {put, K, V, 100};
command({cas, K, Ver, V}, _) ->
    {cas, K, Ver, V, 100};
command({delete, K}, _) ->
    {delete, K}.

check({renew, N}, _, {ok, E}, M = #{live := Live, now := Now}) ->
    M#{live := Live#{N => {E, Now}}};
check({claim, K, _, P}, _, {ok, L}, M) ->
    #{node := N, epoch := E, seq := Seq} = L,
    Pid = pid(P),
    #{held := Held, seqs := Seqs, now := Now} = M,
    case Held of
        #{K := {_, _, OldPid, _}} when OldPid =:= Pid ->
            %% the holder claimed again: a new fence, the same holder
            fence_grows(K, Seq, Seqs),
            M#{held := Held#{K => {N, E, Pid, Seq}}, seqs := Seqs#{K => Seq}};
        #{K := Prev} ->
            %% a new holder while the previous one may still believe it
            %% holds: its node's last renewal must be past lease_ms
            ?assert(not believes(Prev, M), {overlap, K, Prev, L, Now}),
            fence_grows(K, Seq, Seqs),
            M#{held := Held#{K => {N, E, Pid, Seq}}, seqs := Seqs#{K => Seq}};
        _ ->
            fence_grows(K, Seq, Seqs),
            M#{held := Held#{K => {N, E, Pid, Seq}}, seqs := Seqs#{K => Seq}}
    end;
check({release, K}, {release, K, Seq}, ok, M = #{held := Held}) ->
    case Held of
        #{K := {_, _, _, Seq}} -> M#{held := maps:remove(K, Held)};
        _ -> M
    end;
check({down, P}, _, ok, M = #{held := Held}) ->
    Pid = pid(P),
    M#{held := maps:filter(fun(_, {_, _, H, _}) -> H =/= Pid end, Held)};
check({cas, K, Ver, _}, _, Reply, M = #{kv := Kv}) ->
    Cur = maps:get(K, Kv, 0),
    case Reply of
        {ok, New} ->
            ?assertEqual(Cur, Ver),
            ?assert(New > Cur),
            M#{kv := Kv#{K => New}};
        {error, {version, Got}} ->
            ?assertNotEqual(Cur, Ver),
            ?assertEqual(Cur, Got),
            M
    end;
check({put, K, _}, _, {ok, New}, M = #{kv := Kv}) ->
    ?assert(New > maps:get(K, Kv, 0)),
    M#{kv := Kv#{K => New}};
check({delete, K}, _, ok, M = #{kv := Kv}) ->
    M#{kv := maps:remove(K, Kv)};
check(_, _, _, M) ->
    M.

%% A holder believes it holds while its node renewed the lease's epoch
%% less than lease_ms ago (what chappe_cluster_node enforces locally).
believes({N, E, _, _}, #{live := Live, now := Now}) ->
    case Live of
        #{N := {E, T}} -> Now < T + ?LEASE;
        _ -> false
    end.

fence_grows(K, Seq, Seqs) ->
    case Seqs of
        #{K := Prev} -> ?assert(Seq > Prev);
        _ -> ok
    end.
