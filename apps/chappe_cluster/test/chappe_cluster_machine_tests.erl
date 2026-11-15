%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The Ra machine, applied directly: unit cases for each command, a PropEr
%% property over adversarial command schedules (the machine has no clock,
%% so time never appears in it), and a property over the timers of the
%% leader and the holders under a clock rate drift bound.
-module(chappe_cluster_machine_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(M, chappe_cluster_machine).
-define(LEASE, 6000).

%% ---- helpers ----

init() ->
    ?M:init(#{name => test, region => r1}).

%% The stamp is never read by the machine: give each entry a random one.
meta(Idx) ->
    #{index => Idx, term => 1, system_time => rand:uniform(1 bsl 40)}.

ap(Cmd, S) ->
    ap(1, Cmd, S).

ap(Idx, Cmd, S) ->
    case ?M:apply(meta(Idx), Cmd, S) of
        {S1, Reply} -> {S1, Reply, []};
        {S1, Reply, Effs} when is_list(Effs) -> {S1, Reply, Effs};
        {S1, Reply, Eff} -> {S1, Reply, [Eff]}
    end.

renew(Node, S) ->
    renew(Node, undefined, S).

renew(Node, Epoch, S) ->
    {S1, {ok, E}, _} = ap({renew, Node, Epoch, ?LEASE, []}, S),
    {E, S1}.

claim(Key, Node, Epoch, Pid, S) ->
    ap({claim, Key, Node, Epoch, Pid, make_ref(), 100, hlc(1)}, S).

expire(Node, Epoch, S) ->
    ap({timeout, {expire, Node, Epoch}}, S).

hlc(N) ->
    {hlc, N}.

pid(N) ->
    list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

%% ---- liveness ----

renew_keeps_epoch_test() ->
    {E1, S1} = renew(a, init()),
    {E2, _} = renew(a, E1, S1),
    ?assertEqual(E1, E2).

renew_arms_the_leader_timer_test() ->
    {S1, {ok, E}, Effs} = ap({renew, a, undefined, ?LEASE, []}, init()),
    ?assert(lists:member({timer, {expire, a, E}, ?LEASE}, Effs)),
    {_, {ok, E}, Effs2} = ap({renew, a, E, ?LEASE, []}, S1),
    ?assert(lists:member({timer, {expire, a, E}, ?LEASE}, Effs2)).

renew_without_the_current_epoch_starts_a_new_one_test() ->
    {E1, S1} = renew(a, init()),
    {S2, {ok, _}, _} = claim(k, a, E1, pid(1), S1),
    {S3, {ok, E2}, Effs} = ap({renew, a, undefined, ?LEASE, []}, S2),
    ?assert(E2 > E1),
    %% the old epoch's timer stops, its leases are gone
    ?assert(lists:member({timer, {expire, a, E1}, infinity}, Effs)),
    ?assertEqual([], ?M:leases(S3)).

expire_frees_the_node_keys_test() ->
    {Ea, S1} = renew(a, init()),
    {Eb, S2} = renew(b, S1),
    {S3, {ok, L1}, _} = claim(k, a, Ea, pid(1), S2),
    {_, R0, _} = claim(k, b, Eb, pid(2), S3),
    ?assertMatch({error, {owned, _}}, R0),
    {S4, ok, Effs} = expire(a, Ea, S3),
    Taken = {chappe_cluster_taken, k, maps:get(seq, L1)},
    ?assert(lists:member({send_msg, {chappe_cluster_node, a}, Taken}, Effs)),
    {_, {ok, L2}, _} = claim(k, b, Eb, pid(2), S4),
    ?assert(maps:get(seq, L2) > maps:get(seq, L1)).

expire_of_an_old_epoch_is_a_no_op_test() ->
    {E1, S1} = renew(a, init()),
    {_, S2} = renew(a, undefined, S1),
    {S3, {ok, _}, _} = claim(k, a, maps:get(a, ?M:epochs(S2)), pid(1), S2),
    %% a deposed leader's expire for E1, applied late
    {S4, ok, []} = expire(a, E1, S3),
    ?assertEqual(S3, S4).

expire_of_an_unknown_node_is_a_no_op_test() ->
    S = init(),
    ?assertMatch({S, ok, []}, expire(zz, 3, S)).

%% ---- leases ----

claim_needs_the_current_epoch_test() ->
    {_, R, _} = claim(k, a, 1, pid(1), init()),
    ?assertEqual({error, stale_epoch}, R),
    {Ea, S1} = renew(a, init()),
    {S2, ok, _} = expire(a, Ea, S1),
    ?assertEqual({error, stale_epoch}, element(2, claim(k, a, Ea, pid(1), S2))).

claim_and_owned_test() ->
    {Ea, S1} = renew(a, init()),
    {Eb, S2} = renew(b, S1),
    {S3, {ok, L}, Effs} = claim(k, a, Ea, pid(1), S2),
    ?assertMatch(
        #{key := k, node := a, epoch := Ea, region := r1, hlc := {hlc, 1}}, L
    ),
    ?assert(lists:member({monitor, process, pid(1)}, Effs)),
    {_, R, _} = claim(k, b, Eb, pid(2), S3),
    ?assertMatch({error, {owned, #{node := a, fence := {r1, Ea, _}}}}, R).

claim_again_by_the_holder_bumps_the_fence_test() ->
    {Ea, S1} = renew(a, init()),
    {S2, {ok, L1}, _} = claim(k, a, Ea, pid(1), S1),
    {S3, {ok, L2}, []} = claim(k, a, Ea, pid(1), S2),
    ?assert(maps:get(seq, L2) > maps:get(seq, L1)),
    {S4, {ok, Ea}, _} =
        ap({renew, a, Ea, ?LEASE, [{seq, k, maps:get(seq, L1)}]}, S3),
    ?assertMatch([#{key := k}], ?M:leases(S4)).

release_frees_the_key_test() ->
    {Ea, S1} = renew(a, init()),
    {Eb, S2} = renew(b, S1),
    {S3, {ok, L}, _} = claim(k, a, Ea, pid(1), S2),
    {S4, ok, _} = ap({release, k, maps:get(seq, L)}, S3),
    ?assertMatch({ok, _}, element(2, claim(k, b, Eb, pid(2), S4))).

release_with_a_stale_seq_is_ignored_test() ->
    {Ea, S1} = renew(a, init()),
    {S2, {ok, L}, _} = claim(k, a, Ea, pid(1), S1),
    {S3, ok, _} = ap({release, k, maps:get(seq, L) + 100}, S2),
    ?assertMatch([#{key := k}], ?M:leases(S3)).

holder_death_releases_test() ->
    {Ea, S1} = renew(a, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), S1),
    {S3, ok, _} = ap({down, pid(1), killed}, S2),
    ?assertEqual([], ?M:leases(S3)).

noconnection_keeps_the_lease_and_watches_the_node_test() ->
    {Ea, S1} = renew(a, init()),
    P = pid(1),
    {S2, {ok, _}, _} = claim(k, a, Ea, P, S1),
    {S3, ok, Effs} = ap({down, P, noconnection}, S2),
    ?assert(lists:member({monitor, node, node(P)}, Effs)),
    {S4, ok, Effs2} = ap({nodeup, node(P)}, S3),
    ?assert(lists:member({monitor, process, P}, Effs2)),
    ?assertMatch([#{key := k}], ?M:leases(S4)).

abandoned_claim_is_released_on_renew_test() ->
    {Ea, S1} = renew(a, init()),
    CRef = make_ref(),
    {S2, {ok, _}, _} = ap({claim, k, a, Ea, pid(1), CRef, 100, hlc(1)}, S1),
    {S3, {ok, Ea}, _} = ap({renew, a, Ea, ?LEASE, [{claim, k, CRef}]}, S2),
    ?assertEqual([], ?M:leases(S3)).

max_leases_test() ->
    {Ea, S1} = renew(a, init()),
    Cmd = fun(K) -> {claim, K, a, Ea, pid(1), make_ref(), 2, hlc(1)} end,
    {S2, {ok, _}, _} = ap(Cmd(k1), S1),
    {S3, {ok, _}, _} = ap(Cmd(k2), S2),
    ?assertEqual({error, max_leases}, element(2, ap(Cmd(k3), S3))).

leader_enter_arms_every_node_test() ->
    {Ea, S1} = renew(a, init()),
    {Eb, S2} = renew(b, S1),
    {S3, {ok, _}, _} = claim(k, a, Ea, pid(1), S2),
    Effs = ?M:state_enter(leader, S3),
    ?assert(lists:member({monitor, process, pid(1)}, Effs)),
    ?assert(lists:member({timer, {expire, a, Ea}, ?LEASE}, Effs)),
    ?assert(lists:member({timer, {expire, b, Eb}, ?LEASE}, Effs)),
    ?assertEqual([], ?M:state_enter(follower, S3)).

owner_query_test() ->
    {Ea, S1} = renew(a, init()),
    {S2, {ok, L}, _} = claim(k, a, Ea, pid(1), S1),
    Fence = {r1, Ea, maps:get(seq, L)},
    ?assertEqual(
        {ok, #{node => a, pid => pid(1), fence => Fence}},
        ?M:query_owner(k, S2)
    ),
    ?assertEqual(none, ?M:query_owner(other, S2)),
    ?assertMatch([#{key := k, fence := Fence, hlc := {hlc, 1}}], ?M:leases(S2)).

release_cursor_after_n_entries_test() ->
    {E, S1} = renew(a, init()),
    {S2, _, E2} = ap(4095, {renew, a, E, ?LEASE, []}, S1),
    ?assertEqual([], [X || {release_cursor, _, _} = X <- E2]),
    {S3, _, E3} = ap(4097, {renew, a, E, ?LEASE, []}, S2),
    ?assertMatch([{release_cursor, 4097, _}], [X || {release_cursor, _, _} = X <- E3]),
    {_, _, E4} = ap(4098, {renew, a, E, ?LEASE, []}, S3),
    ?assertEqual([], [X || {release_cursor, _, _} = X <- E4]).

%% ---- KV ----

kv_put_get_delete_test() ->
    {_, S0} = renew(a, init()),
    {S1, {ok, V1}, E1} = ap({put, <<"a/1">>, x, 10, hlc(1)}, S0),
    ?assertMatch(
        [
            {send_msg, {chappe_cluster_watch, a},
                {chappe_cluster_kv, put, <<"a/1">>, x, {hlc, 1}}, [local]}
        ],
        E1
    ),
    ?assertEqual({ok, x, V1}, ?M:query_get(<<"a/1">>, S1)),
    {S2, {ok, V2}, _} = ap({put, <<"a/1">>, y, 10, hlc(2)}, S1),
    ?assert(V2 > V1),
    {S3, ok, E3} = ap({delete, <<"a/1">>, hlc(3)}, S2),
    ?assertMatch(
        [{send_msg, _, {chappe_cluster_kv, delete, <<"a/1">>, y, {hlc, 3}}, _}], E3
    ),
    ?assertEqual(not_found, ?M:query_get(<<"a/1">>, S3)),
    {_, ok, []} = ap({delete, <<"a/1">>, hlc(4)}, S3).

kv_cas_test() ->
    S0 = init(),
    {S1, {ok, V1}, _} = ap({cas, <<"k">>, 0, x, 10, hlc(1)}, S0),
    ?assertEqual({error, {version, V1}}, element(2, ap({cas, <<"k">>, 0, y, 10, hlc(2)}, S1))),
    {S2, {ok, V2}, _} = ap({cas, <<"k">>, V1, y, 10, hlc(3)}, S1),
    ?assert(V2 > V1),
    {_, {error, {version, V2}}, _} = ap({cas, <<"k">>, V1, z, 10, hlc(4)}, S2).

kv_max_keys_test() ->
    {S1, {ok, _}, _} = ap({put, <<"a">>, 1, 1, hlc(1)}, init()),
    {S2, {ok, _}, _} = ap({put, <<"a">>, 2, 1, hlc(2)}, S1),
    ?assertEqual({error, max_keys}, element(2, ap({put, <<"b">>, 1, 1, hlc(3)}, S2))).

%% ---- property: adversarial schedules ----

-define(NODES, [a, b, c]).
-define(KEYS, [k1, k2, k3]).
-define(PIDS, [1, 2, 3, 4, 5, 6]).

op() ->
    oneof([
        {renew, oneof(?NODES), boolean()},
        %% an expire for an epoch the leader saw; old ones come from a
        %% deposed leader, applied late
        {expire, oneof(?NODES), range(0, 5)},
        {claim, oneof(?KEYS), oneof(?NODES), oneof(?PIDS), boolean()},
        {release, oneof(?KEYS)},
        {down, oneof(?PIDS)},
        {put, oneof([<<"x">>, <<"y">>]), int()},
        {cas, oneof([<<"x">>, <<"y">>]), range(0, 40), int()},
        {delete, oneof([<<"x">>, <<"y">>])}
    ]).

prop_schedules() ->
    ?FORALL(
        Ops,
        list(op()),
        begin
            M = run(Ops, model()),
            replays(M),
            true
        end
    ).

schedules_property_test() ->
    ?assert(
        proper:quickcheck(prop_schedules(), [
            {numtests, 1000}, {max_size, 120}, {to_file, user}
        ])
    ).

%% The model, from the replies only:
%% - epochs: node -> its current epoch as the node knows it;
%% - seen: node -> every epoch it was ever given (newest first);
%% - dead: the {node, epoch} pairs ended by an expire or a new epoch;
%% - held: key -> {Node, Epoch, Pid, Seq}, the holder the region granted;
%% - pending: node -> what its next renewal carries.
model() ->
    #{
        s => init(),
        idx => 1,
        epochs => #{},
        seen => #{},
        dead => #{},
        held => #{},
        seqs => #{},
        kv => #{},
        pending => #{},
        log => []
    }.

run([], M) ->
    M;
run([Op | Ops], M) ->
    run(Ops, step(Op, M)).

apply_cmd(Cmd, M = #{s := S, idx := Idx, log := Log}) ->
    Meta = meta(Idx),
    {S1, Reply} =
        case ?M:apply(Meta, Cmd, S) of
            {A, B} -> {A, B};
            {A, B, _} -> {A, B}
        end,
    {Reply, M#{s := S1, idx := Idx + 1, log := [{Meta, Cmd} | Log]}}.

step({renew, N, KeepEpoch}, M = #{epochs := Es, pending := P}) ->
    Given =
        case KeepEpoch of
            true -> maps:get(N, Es, undefined);
            false -> undefined
        end,
    {{ok, E}, M1} = apply_cmd({renew, N, Given, ?LEASE, maps:get(N, P, [])}, M),
    M2 =
        case maps:get(N, Es, undefined) of
            E -> M1;
            undefined -> M1;
            Old -> kill(N, Old, M1)
        end,
    #{seen := Seen} = M2,
    M2#{
        epochs := Es#{N => E},
        seen := Seen#{N => [E | maps:get(N, Seen, [])]},
        pending := P#{N => []}
    };
step({expire, N, Back}, M = #{seen := Seen, epochs := Es}) ->
    case maps:get(N, Seen, []) of
        [] ->
            M;
        Epochs ->
            E = lists:nth(1 + Back rem length(Epochs), Epochs),
            {ok, M1} = apply_cmd({timeout, {expire, N, E}}, M),
            case maps:get(N, Es, undefined) of
                E -> kill(N, E, M1#{epochs := maps:remove(N, Es)});
                _ -> M1
            end
    end;
step({claim, K, N, P, Timeout}, M = #{epochs := Es}) ->
    E = maps:get(N, Es, 0),
    CRef = make_ref(),
    {Reply, M1} = apply_cmd({claim, K, N, E, pid(P), CRef, 100, hlc(0)}, M),
    claimed(Reply, K, N, pid(P), CRef, Timeout, M1);
step({release, K}, M = #{held := Held}) ->
    case Held of
        #{K := {_, _, _, Seq}} ->
            {ok, M1} = apply_cmd({release, K, Seq}, M),
            M1#{held := maps:remove(K, Held)};
        _ ->
            M
    end;
step({down, P}, M) ->
    Pid = pid(P),
    {ok, M1 = #{held := Held}} = apply_cmd({down, Pid, killed}, M),
    M1#{held := maps:filter(fun(_, {_, _, H, _}) -> H =/= Pid end, Held)};
step({put, K, V}, M = #{kv := Kv}) ->
    {{ok, New}, M1} = apply_cmd({put, K, V, 100, hlc(0)}, M),
    ?assert(New > maps:get(K, Kv, 0)),
    M1#{kv := Kv#{K => New}};
step({cas, K, Ver, V}, M = #{kv := Kv}) ->
    Cur = maps:get(K, Kv, 0),
    case apply_cmd({cas, K, Ver, V, 100, hlc(0)}, M) of
        {{ok, New}, M1} ->
            ?assertEqual(Cur, Ver),
            ?assert(New > Cur),
            M1#{kv := Kv#{K => New}};
        {{error, {version, Got}}, M1} ->
            ?assertNotEqual(Cur, Ver),
            ?assertEqual(Cur, Got),
            M1
    end;
step({delete, K}, M = #{kv := Kv}) ->
    {ok, M1} = apply_cmd({delete, K, hlc(0)}, M),
    M1#{kv := maps:remove(K, Kv)}.

%% A grant: the previous holder of the key, if any, was released, died, or
%% its epoch is dead. The fence grows.
claimed({ok, L}, K, N, Pid, CRef, Timeout, M) ->
    #{epoch := E, seq := Seq} = L,
    #{held := Held, seqs := Seqs, dead := Dead} = M,
    case Held of
        #{K := {PN, PE, PPid, _} = Prev} when PPid =/= Pid ->
            ?assert(maps:is_key({PN, PE}, Dead), {two_holders, K, Prev, L});
        _ ->
            ok
    end,
    case Seqs of
        #{K := S0} -> ?assert(Seq > S0);
        _ -> ok
    end,
    case Timeout of
        true ->
            %% the caller timed out: nobody believes it holds the key, and
            %% the next renewal gives it back
            queue(N, {claim, K, CRef}, M#{held := maps:remove(K, Held), seqs := Seqs#{K => Seq}});
        false ->
            M#{held := Held#{K => {N, E, Pid, Seq}}, seqs := Seqs#{K => Seq}}
    end;
claimed(_Error, _K, _N, _Pid, _CRef, _Timeout, M) ->
    M.

kill(N, E, M = #{dead := Dead, held := Held}) ->
    M#{
        dead := Dead#{{N, E} => true},
        held := maps:filter(fun(_, {HN, HE, _, _}) -> {HN, HE} =/= {N, E} end, Held)
    }.

queue(N, Item, M = #{pending := P}) ->
    M#{pending := P#{N => [Item | maps:get(N, P, [])]}}.

%% The same log applied again with other stamps, and a snapshot taken half
%% way plus the rest of the log, give the same state.
replays(#{s := S, log := Log0}) ->
    Log = [{meta(maps:get(index, Meta)), Cmd} || {Meta, Cmd} <- lists:reverse(Log0)],
    Fold = fun(Entries, From) ->
        lists:foldl(
            fun({Meta, Cmd}, SA) -> element(1, ?M:apply(Meta, Cmd, SA)) end,
            From,
            Entries
        )
    end,
    ?assertEqual(S, Fold(Log, init())),
    {First, Rest} = lists:split(length(Log) div 2, Log),
    Snapshot = binary_to_term(term_to_binary(Fold(First, init()))),
    ?assertEqual(S, Fold(Rest, Snapshot)).

%% ---- property: the timers under drift ----

%% A holder's node sends its last good renewal at T; the leader applies it
%% D ms later and expires the node lease_ms after that by its own clock, or
%% lease_ms after it became leader if that came later. The holder gives up
%% lease_ms - renew_ms / 2 after T by its own clock. Each clock runs at a
%% rate within max_drift of real time. Whenever the configuration is
%% accepted, the holder gives up first.
prop_holder_gives_up_first() ->
    ?FORALL(
        {L, R, Drift, T, D, Elect, NodeRate, LeaderRate},
        {
            range(300, 60000),
            range(50, 20000),
            range(0, 20),
            range(0, 100000),
            range(0, 20000),
            range(-20000, 20000),
            range(-1000, 1000),
            range(-1000, 1000)
        },
        case chappe_cluster_config:timing_ok(L, R, Drift) of
            false ->
                true;
            true ->
                %% rates within the drift: Drift % of 1000 permille steps
                Rn = 1 + Drift / 100 * NodeRate / 1000,
                Rl = 1 + Drift / 100 * LeaderRate / 1000,
                Holder = T + (L - R / 2) / Rn,
                Start = max(T + D, T + D + Elect),
                Leader = Start + L / Rl,
                Holder < Leader
        end
    ).

timers_property_test() ->
    ?assert(
        proper:quickcheck(prop_holder_gives_up_first(), [
            {numtests, 5000}, {to_file, user}
        ])
    ).

timing_ok_test() ->
    ?assert(chappe_cluster_config:timing_ok(6000, 2000, 1)),
    ?assertNot(chappe_cluster_config:timing_ok(6000, 2000, 20)),
    ?assertNot(chappe_cluster_config:timing_ok(5000, 2000, 1)).
