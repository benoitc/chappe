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

%% A machine whose first leader has graced (term 1).
init() ->
    S = ?M:init(#{name => test, region => r1, reap_ms => 2000}),
    {S1, ok, _} = ?M:apply(meta(1, 0), {timeout, grace}, S),
    S1.

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


%% ---- leader changes and compaction ----

%% A new leader appends `grace': every node keeps at least lease_ms from
%% the new leader's clock, so a leader whose clock runs ahead never expires
%% a node early.
grace_extends_every_node_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), 10, S1),
    %% the new leader's clock is 2000 ms ahead of the old one's
    {S3, ok, _} = ap({timeout, grace}, 2000, S2),
    {Eb, S4} = renew(b, 7000, S3),
    {_, R, _} = claim(k, b, Eb, pid(2), 7500, S4),
    ?assertMatch({error, {owned, _}}, R).

grace_never_shortens_test() ->
    {Ea, S1} = renew(a, 5000, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), 5010, S1),
    {S3, ok, _} = ap({timeout, grace}, 0, S2),
    {Eb, S4} = renew(b, 10500, S3),
    ?assertMatch({error, {owned, _}}, element(2, claim(k, b, Eb, pid(2), 10500, S4))).

leader_enter_starts_grace_test() ->
    {_, S1} = renew(a, 0, init()),
    ?assert(lists:member({timer, grace, 0}, ?M:state_enter(leader, S1))).

%% Before its grace, a new term expires nobody: an ahead clock cannot take
%% a key or start a new epoch.
no_expiry_before_grace_test() ->
    {Ea, S1} = renew(a, 0, init()),
    {S2, {ok, _}, _} = claim(k, a, Ea, pid(1), 10, S1),
    {Eb, S3} = renew(b, 0, S2),
    Late = ?LEASE + 3000,
    {S4, R1, _} = ?M:apply(meta2(5, Late, 2), {claim, k, b, Eb, pid(2), make_ref(), 100}, S3),
    ?assertMatch({error, {owned, _}}, R1),
    {S5, {ok, Ea}, _} = ?M:apply(meta2(6, Late, 2), {renew, a, ?LEASE, []}, S4),
    {_, ok, _} = ?M:apply(meta2(7, Late, 2), {timeout, reap}, S5),
    {S6, ok, _} = ?M:apply(meta2(8, Late, 2), {timeout, grace}, S4),
    {_, R2, _} = ?M:apply(meta2(9, Late + 1, 2), {claim, k, b, Eb, pid(2), make_ref(), 100}, S6),
    %% grace gave a a full lease from the new clock
    ?assertMatch({error, {owned, _}}, R2).

meta2(Idx, Now, Term) ->
    #{index => Idx, term => Term, system_time => Now}.

release_cursor_after_n_entries_test() ->
    {_, S1} = renew(a, 0, init()),
    %% no user command lands on a multiple of the interval
    {S2, _, E2} = ap(4095, {renew, a, ?LEASE, []}, 1, S1),
    ?assertEqual([], [E || {release_cursor, _, _} = E <- E2]),
    {S3, _, E3} = ap(4097, {renew, a, ?LEASE, []}, 2, S2),
    ?assertMatch([{release_cursor, 4097, _}], [E || {release_cursor, _, _} = E <- E3]),
    {_, _, E4} = ap(4098, {renew, a, ?LEASE, []}, 3, S3),
    ?assertEqual([], [E || {release_cursor, _, _} = E <- E4]).

%% ---- properties ----

-define(NODES, [a, b, c]).
-define(KEYS, [k1, k2, k3]).
-define(PIDS, [1, 2, 3, 4, 5, 6]).
-define(RENEW, 2000).
%% what a holder believes: its node's last renewal, sent at T, holds until
%% T + lease_ms - renew_ms / 2 (chappe_cluster_node)
-define(MARGIN, (?RENEW div 2)).

delay() ->
    range(0, ?RENEW).

op() ->
    oneof([
        {renew, oneof(?NODES), delay()},
        {claim, oneof(?KEYS), oneof(?NODES), oneof(?PIDS), delay(), boolean()},
        {release, oneof(?KEYS), delay()},
        {down, oneof(?PIDS)},
        {wait, range(1, 2 * ?LEASE)},
        %% a new leader, its clock off by up to three renew periods
        {leader, range(-3 * ?RENEW, 3 * ?RENEW)},
        grace,
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
            M = run(Ops, model()),
            replays(M),
            true
        end
    ).

leases_property_test() ->
    ?assert(
        proper:quickcheck(prop_leases_and_kv(), [
            {numtests, 1000}, {max_size, 100}, {to_file, user}
        ])
    ).

%% The model, in real time (`now'), with the leader's clock at now + off:
%% - live: node -> {Epoch, SentAt} of its last renewal that came back;
%% - held: key -> {Node, Epoch, Pid, Seq}, the holder that believes it
%%   holds the key (it got {ok, Lease} in time);
%% - pending: node -> what its next renewal carries (abandoned claims,
%%   leases its holders gave up), as chappe_cluster_node queues them;
%% - log: every {Meta, Command} applied, for the replay check.
model() ->
    #{
        s => init(),
        now => 0,
        off => 0,
        term => 1,
        idx => 1,
        live => #{},
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

%% Apply one command stamped by the current leader `Delay' ms after it was
%% sent at `now'; the reply comes back at the same time.
apply_cmd(Cmd, Delay, M = #{s := S, now := Now, off := Off, idx := Idx, log := Log}) ->
    Meta = meta2(Idx, Now + Delay + Off, maps:get(term, M)),
    {S1, Reply, _} =
        case ?M:apply(Meta, Cmd, S) of
            {A, B} -> {A, B, []};
            {A, B, C} -> {A, B, C}
        end,
    {Reply, M#{s := S1, idx := Idx + 1, now := Now + Delay, log := [{Meta, Cmd} | Log]}}.

step({wait, Ms}, M = #{now := Now}) ->
    M#{now := Now + Ms};
step({leader, Off}, M = #{term := T}) ->
    %% a new leader; its grace comes as a later entry
    M#{off := Off, term := T + 1};
step(grace, M) ->
    {ok, M1} = apply_cmd({timeout, grace}, 0, M),
    M1;
step({renew, N, Delay}, M0) ->
    M = give_up(N, M0),
    #{pending := P, now := Sent} = M,
    Items = maps:get(N, P, []),
    {{ok, E}, M1 = #{live := Live}} = apply_cmd({renew, N, ?LEASE, Items}, Delay, M),
    M1#{live := Live#{N => {E, Sent}}, pending := P#{N => []}};
step({claim, K, N, P, Delay, Timeout}, M) ->
    case node_live(N, M) of
        false ->
            %% chappe_cluster:claim/2 returns no_quorum without sending
            M;
        {true, E} ->
            CRef = make_ref(),
            Cmd = {claim, K, N, E, pid(P), CRef, 100},
            {Reply, M1} = apply_cmd(Cmd, Delay, M),
            claimed(Reply, K, N, P, CRef, Timeout, M1)
    end;
step({release, K, Delay}, M = #{held := Held}) ->
    case Held of
        #{K := {_, _, _, Seq}} ->
            {ok, M1} = apply_cmd({release, K, Seq}, Delay, M),
            M1#{held := maps:remove(K, Held)};
        _ ->
            M
    end;
step({down, P}, M = #{held := Held}) ->
    Pid = pid(P),
    {ok, M1} = apply_cmd({down, Pid, killed}, 0, M),
    M1#{held := maps:filter(fun(_, {_, _, H, _}) -> H =/= Pid end, Held)};
step(reap, M) ->
    {ok, M1} = apply_cmd({timeout, reap}, 0, M),
    M1;
step({put, K, V}, M = #{kv := Kv}) ->
    {{ok, New}, M1} = apply_cmd({put, K, V, 100}, 0, M),
    ?assert(New > maps:get(K, Kv, 0)),
    M1#{kv := Kv#{K => New}};
step({cas, K, Ver, V}, M = #{kv := Kv}) ->
    Cur = maps:get(K, Kv, 0),
    case apply_cmd({cas, K, Ver, V, 100}, 0, M) of
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
    {ok, M1} = apply_cmd({delete, K}, 0, M),
    M1#{kv := maps:remove(K, Kv)}.

claimed({ok, L}, K, N, _P, CRef, true, M) ->
    %% the caller timed out: it abandons the claim by its ref
    fence(K, L, queue(N, {claim, K, CRef}, M));
claimed({ok, L}, K, N, P, _CRef, false, M) ->
    #{epoch := E, seq := Seq} = L,
    M1 = fence(K, L, M),
    case node_live(N, M1) of
        {true, E} ->
            Pid = pid(P),
            #{held := Held, now := Now} = M1,
            case Held of
                #{K := {_, _, OldPid, _} = Prev} when OldPid =/= Pid ->
                    ?assert(not believes(Prev, M1), {overlap, K, Prev, L, Now});
                _ ->
                    ok
            end,
            M1#{held := Held#{K => {N, E, Pid, Seq}}};
        _ ->
            %% the reply came after the node's deadline: no_quorum, and
            %% the lease goes back with the next renewal
            queue(N, {seq, K, Seq}, M1)
    end;
claimed(_Error, _K, _N, _P, _CRef, _Timeout, M) ->
    M.

fence(K, #{seq := Seq}, M = #{seqs := Seqs}) ->
    case Seqs of
        #{K := Prev} -> ?assert(Seq > Prev);
        _ -> ok
    end,
    M#{seqs := Seqs#{K => Seq}}.

queue(N, Item, M = #{pending := P}) ->
    M#{pending := P#{N => [Item | maps:get(N, P, [])]}}.

%% The node's holders whose belief ended give their leases up, queued for
%% the next renewal (the lapse in chappe_cluster_node).
give_up(N, M = #{held := Held}) ->
    Gone = [{K, Seq} || K := {HN, _, _, Seq} = H <- Held, HN =:= N, not believes(H, M)],
    lists:foldl(
        fun({K, Seq}, MA = #{held := HA}) ->
            queue(N, {seq, K, Seq}, MA#{held := maps:remove(K, HA)})
        end,
        M,
        Gone
    ).

node_live(N, #{live := Live, now := Now}) ->
    case Live of
        #{N := {E, T}} when Now < T + ?LEASE - ?MARGIN -> {true, E};
        _ -> false
    end.

believes({N, E, _, _}, M) ->
    node_live(N, M) =:= {true, E}.

%% The same log applied again, and a snapshot taken half way plus the rest
%% of the log, give the same state.
replays(#{s := S, log := Log0}) ->
    Log = lists:reverse(Log0),
    Fold = fun(Entries, From) ->
        lists:foldl(
            fun({Meta, Cmd}, SA) -> element(1, ?M:apply(Meta, Cmd, SA)) end,
            From,
            Entries
        )
    end,
    S0 = init(),
    ?assertEqual(S, Fold(Log, S0)),
    {First, Rest} = lists:split(length(Log) div 2, Log),
    Snapshot = binary_to_term(term_to_binary(Fold(First, S0))),
    ?assertEqual(S, Fold(Rest, Snapshot)).
