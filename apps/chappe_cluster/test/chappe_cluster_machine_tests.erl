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
-include_lib("hlc/include/hlc.hrl").

-define(M, chappe_cluster_machine).
-define(LEASE, 6000).

%% ---- helpers ----

%% A machine whose nodes have each started once (incarnation 1).
init() ->
    lists:foldl(
        fun(N, S) -> element(1, ?M:apply(meta(0), {incarnate, N}, S)) end,
        ?M:init(#{name => test, region => r1}),
        [a, b, c, n, m, zz]
    ).

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

%% A request for a new epoch from the node's (one) incarnation, replacing
%% its current epoch.
new_req(Node, S) ->
    {new, max(1, ?M:incarnation(Node, S)), maps:get(Node, ?M:epochs(S), undefined)}.

%% Incarnate the node once, as an app start does.
incarnated(Node, S) ->
    case ?M:incarnation(Node, S) of
        0 -> element(1, ap({incarnate, Node}, S));
        _ -> S
    end.

renew(Node, undefined, S0) ->
    S = incarnated(Node, S0),
    renew(Node, new_req(Node, S), S);
renew(Node, Epoch, S) ->
    {S1, {ok, E}, _} = ap({renew, Node, Epoch, ?LEASE, []}, S),
    {E, S1}.

claim(Key, Node, Epoch, Pid, S) ->
    ap({claim, Key, Node, Epoch, Pid, make_ref(), 100, hlc(1)}, S).

%% The leader's timer for the node's current renew fires.
expire(Node, Epoch, S) ->
    {expire, Node, Epoch, _} = Name = ?M:expire_timer(Node, S),
    ap({timeout, Name}, S).

%% The expire timer a list of effects arms.
armed(Effs) ->
    [Name || {timer, {expire, _, _, _} = Name, T} <- Effs, T =/= infinity].

hlc(N) ->
    #timestamp{wall_time = N}.

pid(N) ->
    list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

%% ---- liveness ----

renew_keeps_epoch_test() ->
    {E1, S1} = renew(a, init()),
    {E2, _} = renew(a, E1, S1),
    ?assertEqual(E1, E2).

renew_arms_the_leader_timer_test() ->
    {S1, {ok, E}, Effs} = ap({renew, a, new_req(a, init()), ?LEASE, []}, init()),
    [{expire, a, E, C1} = N1] = armed(Effs),
    ?assert(lists:member({timer, N1, ?LEASE}, Effs)),
    {_, {ok, E}, Effs2} = ap({renew, a, E, ?LEASE, []}, S1),
    %% each renew arms a timer of its own and cancels the previous one
    [{expire, a, E, C2}] = armed(Effs2),
    ?assert(C2 > C1),
    ?assert(lists:member({timer, N1, infinity}, Effs2)).

%% The leader's timer fired and was appended behind a renew whose commit
%% stalled: when it applies, the renew already kept the epoch, so the
%% stale timer ends nothing.
expire_queued_behind_a_renew_is_stale_test() ->
    {S1, {ok, E}, Effs} = ap({renew, a, new_req(a, init()), ?LEASE, []}, init()),
    [Old] = armed(Effs),
    {S2, {ok, _}, _} = claim(k, a, E, pid(1), S1),
    {Eb, S3} = renew(b, S2),
    {S4, {ok, E}, _} = ap({renew, a, E, ?LEASE, []}, S3),
    {S5, ok, []} = ap({timeout, Old}, S4),
    ?assertEqual(S4, S5),
    ?assertMatch({error, {owned, _}}, element(2, claim(k, b, Eb, pid(2), S5))).

%% A renew that names an epoch the region already ended (a delayed
%% command) is refused and changes nothing.
renew_with_a_superseded_epoch_is_refused_test() ->
    {E1, S1} = renew(a, init()),
    {S2, ok, _} = expire(a, E1, S1),
    {E2, S3} = renew(a, undefined, S2),
    {S4, {ok, _}, _} = claim(k, a, E2, pid(1), S3),
    {S5, R, Effs} = ap({renew, a, E1, ?LEASE, []}, S4),
    ?assertEqual({error, stale_epoch}, R),
    ?assertEqual([], Effs),
    ?assertEqual(S4, S5).

renew_without_the_current_epoch_starts_a_new_one_test() ->
    {E1, S1} = renew(a, init()),
    {S2, {ok, _}, _} = claim(k, a, E1, pid(1), S1),
    {S3, {ok, E2}, Effs} = ap({renew, a, new_req(a, S2), ?LEASE, []}, S2),
    ?assert(E2 > E1),
    %% the old epoch's timer stops, its leases are gone
    ?assert(lists:member({timer, {expire, a, E1, 1}, infinity}, Effs)),
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
    {S4, ok, []} = ap({timeout, {expire, a, E1, 1}}, S3),
    ?assertEqual(S3, S4).

expire_of_an_unknown_node_is_a_no_op_test() ->
    S = init(),
    ?assertMatch({S, ok, []}, ap({timeout, {expire, zz, 3, 1}}, S)).

%% A delayed request for a new epoch, from an attempt that timed out,
%% lands after a later attempt got its epoch: stale, nothing ends.
delayed_new_epoch_request_is_stale_test() ->
    S0 = init(),
    Late = new_req(a, S0),
    {E1, S1} = renew(a, S0),
    {S2, {ok, _}, _} = claim(k, a, E1, pid(1), S1),
    {S3, R, []} = ap({renew, a, Late, ?LEASE, []}, S2),
    ?assertEqual({error, stale_epoch}, R),
    ?assertEqual(S2, S3).

%% A new incarnation (the app restarted) replaces the epoch, and the old
%% incarnation's delayed requests are stale from then on.
new_incarnation_replaces_and_retires_the_old_test() ->
    {E1, S1} = renew(a, init()),
    {S1b, {ok, 2}, _} = ap({incarnate, a}, S1),
    {S2, {ok, E2}, _} = ap({renew, a, {new, 2, undefined}, ?LEASE, []}, S1b),
    ?assert(E2 > E1),
    {S3, R, []} = ap({renew, a, {new, 1, E1}, ?LEASE, []}, S2),
    ?assertEqual({error, stale_epoch}, R),
    ?assertEqual(S2, S3).

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
        #{key := k, node := a, epoch := Ea, region := r1, hlc := #timestamp{wall_time = 1}}, L
    ),
    ?assert(lists:member({monitor, process, pid(1)}, Effs)),
    {_, R, _} = claim(k, b, Eb, pid(2), S3),
    ?assertMatch({error, {owned, #{node := a, fence := {r1, Ea, _}}}}, R).

%% A second claim by the holder (its retry, or a delayed first try) never
%% takes the lease over, so the abandon of the other try drops only its
%% own lease.
claim_again_by_the_holder_is_refused_test() ->
    {Ea, S1} = renew(a, init()),
    C1 = make_ref(),
    C2 = make_ref(),
    {S2, {ok, L2}, _} = ap({claim, k, a, Ea, pid(1), C2, 100, hlc(2)}, S1),
    {S3, R, []} = ap({claim, k, a, Ea, pid(1), C1, 100, hlc(1)}, S2),
    ?assertMatch({error, {owned, #{pid := _}}}, R),
    ?assertEqual(S2, S3),
    {S4, {ok, Ea}, _} = ap({renew, a, Ea, ?LEASE, [{claim, k, C1}]}, S3),
    ?assertMatch([#{key := k}], ?M:leases(S4)),
    {S5, {ok, Ea}, _} = ap({renew, a, Ea, ?LEASE, [{claim, k, C2}]}, S4),
    ?assertEqual([], ?M:leases(S5)),
    _ = L2.

release_frees_the_key_test() ->
    {Ea, S1} = renew(a, init()),
    {Eb, S2} = renew(b, S1),
    {S3, {ok, L}, _} = claim(k, a, Ea, pid(1), S2),
    {S4, {ok, _}, _} = ap({release, k, maps:get(seq, L), hlc(5)}, S3),
    ?assertMatch({ok, _}, element(2, claim(k, b, Eb, pid(2), S4))).

release_with_a_stale_seq_is_ignored_test() ->
    {Ea, S1} = renew(a, init()),
    {S2, {ok, L}, _} = claim(k, a, Ea, pid(1), S1),
    {S3, {ok, _}, _} = ap({release, k, maps:get(seq, L) + 100, hlc(5)}, S2),
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
    ?assert(lists:member({timer, ?M:expire_timer(a, S3), ?LEASE}, Effs)),
    ?assert(lists:member({timer, ?M:expire_timer(b, S3), ?LEASE}, Effs)),
    ?assertMatch({expire, a, Ea, _}, ?M:expire_timer(a, S3)),
    ?assertMatch({expire, b, Eb, _}, ?M:expire_timer(b, S3)),
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
    ?assertMatch([#{key := k, fence := Fence, hlc := #timestamp{wall_time = 1}}], ?M:leases(S2)).

release_cursor_after_n_entries_test() ->
    {E, S1} = renew(a, init()),
    {S2, _, E2} = ap(4095, {renew, a, E, ?LEASE, []}, S1),
    ?assertEqual([], [X || {release_cursor, _, _} = X <- E2]),
    {S3, _, E3} = ap(4097, {renew, a, E, ?LEASE, []}, S2),
    ?assertMatch([{release_cursor, 4097, _}], [X || {release_cursor, _, _} = X <- E3]),
    {_, _, E4} = ap(4098, {renew, a, E, ?LEASE, []}, S3),
    ?assertEqual([], [X || {release_cursor, _, _} = X <- E4]).

%% ---- HLC ----

%% A release on a node whose wall clock runs ahead, then a claim on a node
%% whose clock is behind: the grant comes after the release in HLC order,
%% and so does every later write.
claim_after_release_is_later_in_hlc_test() ->
    {Ea, S1} = renew(a, init()),
    {Eb, S2} = renew(b, S1),
    {S3, {ok, La}, _} = ap({claim, k, a, Ea, pid(1), make_ref(), 100, hlc(1000)}, S2),
    {S4, {ok, Released}, _} = ap({release, k, maps:get(seq, La), hlc(2000)}, S3),
    ?assert(Released >= hlc(2000)),
    {S5, {ok, Lb}, _} = ap({claim, k, b, Eb, pid(2), make_ref(), 100, hlc(10)}, S4),
    ?assert(maps:get(hlc, Lb) > Released),
    {_, {ok, _, Put}, _} = ap({put, <<"x">>, 1, 10, hlc(20)}, S5),
    ?assert(Put > maps:get(hlc, Lb)).

%% A stamp ahead of everything the region saw stays as it is.
a_later_stamp_is_kept_test() ->
    {Ea, S1} = renew(a, init()),
    {_, {ok, L}, _} = ap({claim, k, a, Ea, pid(1), make_ref(), 100, hlc(500)}, S1),
    ?assertEqual(hlc(500), maps:get(hlc, L)).

%% ---- KV ----

kv_put_get_delete_test() ->
    {_, S0} = renew(a, init()),
    {S1, {ok, V1, _}, E1} = ap({put, <<"a/1">>, x, 10, hlc(1)}, S0),
    ?assertMatch(
        [
            {send_msg, {chappe_cluster_watch, a},
                {chappe_cluster_kv, put, <<"a/1">>, x, #timestamp{wall_time = 1}},
                [local]}
        ],
        E1
    ),
    ?assertEqual({ok, x, V1}, ?M:query_get(<<"a/1">>, S1)),
    {S2, {ok, V2, _}, _} = ap({put, <<"a/1">>, y, 10, hlc(2)}, S1),
    ?assert(V2 > V1),
    {S3, {ok, _}, E3} = ap({delete, <<"a/1">>, hlc(3)}, S2),
    ?assertMatch(
        [{send_msg, _, {chappe_cluster_kv, delete, <<"a/1">>, y, #timestamp{wall_time = 3}}, _}], E3
    ),
    ?assertEqual(not_found, ?M:query_get(<<"a/1">>, S3)),
    {_, {ok, _}, []} = ap({delete, <<"a/1">>, hlc(4)}, S3).

kv_cas_test() ->
    S0 = init(),
    {S1, {ok, V1, _}, _} = ap({cas, <<"k">>, 0, x, 10, hlc(1)}, S0),
    ?assertEqual({error, {version, V1}}, element(2, ap({cas, <<"k">>, 0, y, 10, hlc(2)}, S1))),
    {S2, {ok, V2, _}, _} = ap({cas, <<"k">>, V1, y, 10, hlc(3)}, S1),
    ?assert(V2 > V1),
    {_, {error, {version, V2}}, _} = ap({cas, <<"k">>, V1, z, 10, hlc(4)}, S2).

%% A delete names the version it read: a late one, or one that lost a race
%% to a write, leaves the key alone.
kv_versioned_delete_test() ->
    S0 = init(),
    {S1, {ok, V1, _}, _} = ap({cas, <<"k">>, 0, x, 10, hlc(1)}, S0),
    {S2, {ok, V2, _}, _} = ap({cas, <<"k">>, V1, y, 10, hlc(2)}, S1),
    ?assertEqual({error, {version, V2}}, element(2, ap({delete, <<"k">>, V1, hlc(3)}, S2))),
    {S3, {ok, _}, _} = ap({delete, <<"k">>, V2, hlc(4)}, S2),
    ?assertEqual(not_found, ?M:query_get(<<"k">>, S3)),
    ?assertEqual({error, {version, 0}}, element(2, ap({delete, <<"k">>, V2, hlc(5)}, S3))).

kv_keys_by_prefix_test() ->
    S = lists:foldl(
        fun(K, Acc) -> element(1, ap({put, K, 1, 10, hlc(1)}, Acc)) end,
        init(),
        [<<"reg/b">>, <<"reg/a">>, <<"re">>, <<"other">>]
    ),
    ?assertEqual([<<"reg/a">>, <<"reg/b">>], ?M:query_keys(<<"reg/">>, S)),
    ?assertEqual(4, length(?M:query_keys(<<>>, S))).

kv_max_keys_test() ->
    {S1, {ok, _, _}, _} = ap({put, <<"a">>, 1, 1, hlc(1)}, init()),
    {S2, {ok, _, _}, _} = ap({put, <<"a">>, 2, 1, hlc(2)}, S1),
    ?assertEqual({error, max_keys}, element(2, ap({put, <<"b">>, 1, 1, hlc(3)}, S2))).

%% ---- property: adversarial schedules ----

-define(NODES, [a, b, c]).
-define(KEYS, [k1, k2, k3]).
-define(PIDS, [1, 2, 3, 4, 5, 6]).

op() ->
    oneof([
        {renew, oneof(?NODES), boolean()},
        {renew_old, oneof(?NODES), range(0, 5), boolean()},
        {restart, oneof(?NODES)},
        %% a timer the leader armed fires: the latest, or an older one
        %% (queued behind a renew, or from a deposed leader), applied late
        {expire, range(0, 8)},
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
        armed => [],
        incs => #{},
        log => []
    }.

inc(N, #{s := S}) ->
    ?M:incarnation(N, S).

%% The incarnation that took the node's current epoch.
current_inc_of(N, S) ->
    element(4, maps:get(N, element(3, S), {x, x, x, none})).

run([], M) ->
    M;
run([Op | Ops], M) ->
    run(Ops, step(Op, M)).

apply_cmd(Cmd, M = #{s := S, idx := Idx, log := Log, armed := Armed}) ->
    Meta = meta(Idx),
    {S1, Reply, Effs} =
        case ?M:apply(Meta, Cmd, S) of
            {A, B} -> {A, B, []};
            {A, B, C} -> {A, B, C}
        end,
    {Reply, M#{
        s := S1,
        idx := Idx + 1,
        log := [{Meta, Cmd} | Log],
        armed := armed(Effs) ++ Armed
    }}.

step({renew, N, KeepEpoch}, M = #{epochs := Es, pending := P}) ->
    _ = P,
    Given =
        case {KeepEpoch, maps:find(N, Es)} of
            {true, {ok, E0}} -> E0;
            _ -> {new, inc(N, M), maps:get(N, Es, undefined)}
        end,
    case apply_cmd({renew, N, Given, ?LEASE, maps:get(N, P, [])}, M) of
        {{error, stale_epoch}, M1} ->
            %% the region ended that epoch: the node lapses
            M1#{epochs := maps:remove(N, Es)};
        {{ok, E}, M1} ->
            renewed(N, E, M1)
    end;
step({expire, Back}, M = #{armed := []}) ->
    _ = Back,
    M;
step({expire, Back}, M = #{armed := Armed, s := S, epochs := Es}) ->
    {expire, N, E, _} = Name = lists:nth(1 + Back rem length(Armed), Armed),
    Current = ?M:expire_timer(N, S),
    {ok, M1} = apply_cmd({timeout, Name}, M),
    case Name =:= Current of
        true -> kill(N, E, M1#{epochs := maps:remove(N, Es)});
        false -> M1
    end;
%% A renew named an epoch from the node's past: refused, nothing changes,
%% unless it is still the current one.
step({restart, N}, M) ->
    %% the app restarts: a new incarnation, its holders told lost
    {{ok, _}, M1 = #{held := Held}} = apply_cmd({incarnate, N}, M),
    M1#{held := maps:filter(fun(_, {HN, _, _, _}) -> HN =/= N end, Held)};
step({renew_old, N, Back, AsNew}, M = #{seen := Seen, epochs := Es, s := S}) ->
    case maps:get(N, Seen, []) of
        [] ->
            M;
        Epochs ->
            E = lists:nth(1 + Back rem length(Epochs), Epochs),
            %% a delayed command: a renew of an old epoch, or a request for
            %% a new one that names an old epoch (or an old incarnation)
            Given =
                case AsNew of
                    true -> {new, max(1, inc(N, M) - Back rem 2), E};
                    false -> E
                end,
            Current = maps:find(N, Es),
            case apply_cmd({renew, N, Given, ?LEASE, []}, M) of
                {{ok, E2}, M1} when AsNew ->
                    %% only the current incarnation replacing the current
                    %% epoch, or a newer one, may start an epoch
                    ?assert(Current =:= {ok, E} orelse Current =:= error orelse
                        element(2, Given) =/= current_inc_of(N, S)),
                    renewed(N, E2, M1);
                {{ok, E}, M1} ->
                    ?assertEqual({ok, E}, maps:find(N, Es)),
                    M1;
                {{error, stale_epoch}, M1 = #{s := S1}} ->
                    AsNew orelse ?assertNotEqual({ok, E}, maps:find(N, Es)),
                    ?assertEqual(S, S1),
                    M1
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
            {{ok, _}, M1} = apply_cmd({release, K, Seq, hlc(0)}, M),
            M1#{held := maps:remove(K, Held)};
        _ ->
            M
    end;
step({down, P}, M) ->
    Pid = pid(P),
    {ok, M1 = #{held := Held}} = apply_cmd({down, Pid, killed}, M),
    M1#{held := maps:filter(fun(_, {_, _, H, _}) -> H =/= Pid end, Held)};
step({put, K, V}, M = #{kv := Kv}) ->
    {{ok, New, _}, M1} = apply_cmd({put, K, V, 100, hlc(0)}, M),
    ?assert(New > maps:get(K, Kv, 0)),
    M1#{kv := Kv#{K => New}};
step({cas, K, Ver, V}, M = #{kv := Kv}) ->
    Cur = maps:get(K, Kv, 0),
    case apply_cmd({cas, K, Ver, V, 100, hlc(0)}, M) of
        {{ok, New, _}, M1} ->
            ?assertEqual(Cur, Ver),
            ?assert(New > Cur),
            M1#{kv := Kv#{K => New}};
        {{error, {version, Got}}, M1} ->
            ?assertNotEqual(Cur, Ver),
            ?assertEqual(Cur, Got),
            M1
    end;
step({delete, K}, M = #{kv := Kv}) ->
    {{ok, _}, M1} = apply_cmd({delete, K, hlc(0)}, M),
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

renewed(N, E, M1 = #{epochs := Es, seen := Seen, pending := P}) ->
    M2 =
        case maps:get(N, Es, undefined) of
            E -> M1;
            undefined -> M1;
            Old -> kill(N, Old, M1)
        end,
    M2#{
        epochs := Es#{N => E},
        seen := Seen#{N => [E | maps:get(N, Seen, [])]},
        pending := P#{N => []}
    }.

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
    _ = S,
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

%% ---- property: the machine under Ra, with commit delays ----

%% The machine as Ra runs it: one log, entries applied in order once
%% committed, each after its own commit delay; the leader's timers, which
%% Ra appends as `{timeout, Name}' commands when they fire; a leader change
%% that drops the timers and arms state_enter's. Node n renews every
%% renew_ms for a while, holds key k, then stops; node m renews and claims
%% k. When m gets k, n's holder must no longer believe it holds it (its
%% deadline: last answered renew sent at T, T + lease_ms - renew_ms / 2).
-define(R, 2000).
-define(STEP, 50).

prop_no_overlap_under_ra() ->
    ?FORALL(
        {Renews, Delays, LeaderAt},
        {range(2, 8), non_empty(list(oneof([0, 0, range(0, ?R), range(?R, 3 * ?R)]))), oneof([none, range(0, 20000)])},
        begin
            sim(Renews * ?R, list_to_tuple(Delays), LeaderAt),
            true
        end
    ).

no_overlap_under_ra_property_test() ->
    ?assert(
        proper:quickcheck(prop_no_overlap_under_ra(), [
            {numtests, 2000}, {max_size, 30}, {to_file, user}
        ])
    ).

sim(StopAt, Delays, LeaderAt) ->
    W = #{
        t => 0,
        s => init(),
        idx => 1,
        log => queue:new(),
        last_commit => 0,
        timers => #{},
        delays => Delays,
        n => agent(),
        m => agent(),
        holder => none,
        claimed => false,
        stop_at => StopAt,
        leader_at => LeaderAt
    },
    sim_loop(W).

agent() ->
    #{epoch => undefined, deadline => 0, known => undefined}.

sim_loop(#{t := T, stop_at := Stop}) when T > Stop + 6 * ?LEASE ->
    ok;
sim_loop(#{claimed := done}) ->
    ok;
sim_loop(W0) ->
    W1 = leader_change(W0),
    W2 = fire_timers(W1),
    W3 = sends(W2),
    W4 = commit(W3),
    sim_loop(W4#{t := maps:get(t, W4) + ?STEP}).

leader_change(W = #{t := T, leader_at := T, s := S}) ->
    Timers = maps:from_list(
        [{Name, T + Ms} || {timer, Name, Ms} <- ?M:state_enter(leader, S), is_integer(Ms)]
    ),
    W#{timers := Timers};
leader_change(W) ->
    W.

fire_timers(W = #{t := T, timers := Timers}) ->
    Due = lists:sort([{At, Name} || Name := At <- Timers, At =< T]),
    lists:foldl(
        fun({_, Name}, WA = #{timers := TA}) ->
            append({timeout, Name}, leader, WA#{timers := maps:remove(Name, TA)})
        end,
        W,
        Due
    ).

sends(W = #{t := T, stop_at := Stop}) ->
    W1 =
        case T rem ?R =:= 0 andalso T < Stop of
            true -> send_renew(n, W);
            false -> W
        end,
    W2 =
        case T rem ?R =:= 0 of
            true -> send_renew(m, W1);
            false -> W1
        end,
    W3 =
        case maps:get(holder, W2) =:= none andalso T < Stop andalso live(n, W2) of
            true -> send_claim(n, W2);
            false -> W2
        end,
    case T rem (?R div 2) =:= 0 andalso live(m, W3) andalso maps:get(claimed, W3) =:= false of
        true -> send_claim(m, W3);
        false -> W3
    end.

live(X, W = #{t := T}) ->
    #{epoch := E, deadline := D} = maps:get(X, W),
    E =/= undefined andalso T < D.

send_renew(X, W = #{t := T}) ->
    E =
        case live(X, W) of
            true -> maps:get(epoch, maps:get(X, W));
            false -> {new, 1, maps:get(known, maps:get(X, W))}
        end,
    append({renew, X, E, ?LEASE, []}, {renew, X, T}, W).

send_claim(X, W) ->
    #{epoch := E} = maps:get(X, W),
    Pid = pid(case X of n -> 1; m -> 2 end),
    W1 = append({claim, k, X, E, Pid, make_ref(), 100, hlc(0)}, {claim, X, E}, W),
    case X of
        n -> W1#{holder := pending};
        m -> W1#{claimed := pending}
    end.

append(Cmd, From, W = #{t := T, log := Log, idx := I, delays := D}) ->
    Delay = element(1 + I rem tuple_size(D), D),
    W#{log := queue:in({T + Delay, Cmd, From}, Log), idx := I + 1}.

%% Apply the committed head of the log, in order.
commit(W = #{t := T, log := Log, s := S, idx := I}) ->
    case queue:peek(Log) of
        {value, {Ready, Cmd, From}} when Ready =< T ->
            {S1, Reply, Effs} =
                case ?M:apply(meta(I), Cmd, S) of
                    {A, B} -> {A, B, []};
                    {A, B, C} -> {A, B, C}
                end,
            W1 = timers(Effs, W#{s := S1, log := queue:drop(Log)}),
            commit(reply(From, Reply, W1));
        _ ->
            W
    end.

timers(Effs, W = #{t := T, timers := Timers}) ->
    W#{
        timers := lists:foldl(
            fun
                ({timer, Name, infinity}, A) -> maps:remove(Name, A);
                ({timer, Name, Ms}, A) -> A#{Name => T + Ms};
                (_, A) -> A
            end,
            Timers,
            Effs
        )
    }.

reply(leader, _, W) ->
    W;
reply({renew, X, Sent}, {ok, E}, W0 = #{t := T}) ->
    A0 = maps:get(X, W0),
    A = A0#{known := E},
    W = W0#{X := A},
    Deadline = Sent + ?LEASE - ?R div 2,
    case T < Deadline of
        true ->
            W1 = case maps:get(epoch, A) of
                E -> W;
                _ -> lose(X, W)
            end,
            W1#{X := A#{epoch := E, deadline := Deadline}};
        false ->
            W
    end;
reply({renew, X, _}, {error, stale_epoch}, W) ->
    A = maps:get(X, W),
    (lose(X, W))#{X := A#{epoch := undefined, deadline := 0}};
reply({claim, n, E}, {ok, L}, W) ->
    case live(n, W) andalso maps:get(epoch, maps:get(n, W)) =:= E of
        true -> W#{holder := L};
        false -> W#{holder := none}
    end;
reply({claim, n, _}, _, W) ->
    W#{holder := none};
reply({claim, m, _}, {ok, L}, W) ->
    ?assertNot(believes(W), {overlap, maps:get(t, W), maps:get(holder, W), L}),
    W#{claimed := done};
reply({claim, m, _}, _, W) ->
    W#{claimed := false}.

lose(n, W) ->
    W#{holder := none};
lose(m, W) ->
    W.

believes(W = #{holder := #{epoch := E}}) ->
    live(n, W) andalso maps:get(epoch, maps:get(n, W)) =:= E;
believes(_) ->
    false.
