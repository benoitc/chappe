%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_cluster across `peer' nodes: a region of three voters, a node
%% stopped under a lease, a lost quorum, the API used from another node,
%% membership changes and a singleton moving between nodes.
-module(chappe_cluster_peer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(LEASE, 2000).
-define(RENEW, 500).

all() ->
    [
        takeover_after_a_node_stops,
        quorum_loss_is_bounded,
        leader_change_never_expires_early,
        new_leader_expires_a_node_it_never_heard,
        wall_clock_jumps_change_nothing,
        cut_off_holder_hears_lost_before_takeover,
        api_from_other_nodes,
        join_and_leave,
        singleton_moves_when_its_node_stops,
        paused_singleton_child_sees_its_lease_gone
    ].

init_per_suite(Config) ->
    ok = chappe_cluster_test_dist:ensure(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    Count =
        case Case of
            new_leader_expires_a_node_it_never_heard -> 5;
            _ -> 3
        end,
    Peers = [chappe_cluster_test_dist:peer("cc" ++ integer_to_list(I)) || I <- lists:seq(1, Count)],
    Nodes = [N || {_, N} <- Peers],
    [ok = chappe_cluster_test_dist:start_app(N, env(Nodes), Dir) || N <- Nodes],
    [ok = wait_live(N) || N <- Nodes],
    [{peers, Peers}, {nodes, Nodes}, {dir, Dir} | Config].

end_per_testcase(_Case, Config) ->
    [chappe_cluster_test_dist:stop_peer(P) || {P, _} <- ?config(peers, Config)],
    [chappe_cluster_test_dist:stop_peer(P) || {P, _} <- proplists:get_value(extra, Config, [])],
    ok.

env(Voters) ->
    #{
        voters => Voters,
        lease_ms => ?LEASE,
        wall_clock => {?MODULE, wall_ms, []},
        renew_ms => ?RENEW,
        command_timeout => 2000
    }.

%% Claim on one node, stop it: another node takes the key once the lease
%% runs out, with a greater fence.
takeover_after_a_node_stops(Config) ->
    [{P1, N1} | _] = ?config(peers, Config),
    [_, N2, N3] = ?config(nodes, Config),
    Holder = holder(N1),
    {ok, L1} = erpc:call(N1, chappe_cluster, claim, [room_1, #{pid => Holder}]),
    {_, _, S1} = F1 = chappe_cluster:fence(L1),
    ?assertMatch({error, {owned, #{node := N1}}}, erpc:call(N2, chappe_cluster, claim, [room_1, #{}])),
    wait(fun() -> owner_node(N3, room_1) =:= N1 end),
    T0 = erlang:monotonic_time(millisecond),
    ok = chappe_cluster_test_dist:stop_peer(P1),
    H2 = holder(N2),
    L2 = wait_claim(N2, room_1, H2),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:pal("takeover after ~b ms, fence ~p -> ~p", [Took, F1, chappe_cluster:fence(L2)]),
    {_, _, S2} = chappe_cluster:fence(L2),
    ?assert(S2 > S1),
    ?assert(Took < ?LEASE + 10000),
    ?assertMatch({ok, #{node := N2}}, erpc:call(N3, chappe_cluster, owner, [room_1, consistent])).

%% Stop two of three: the last node's claims return no_quorum, within a
%% bounded time, and its holders are told their lease is lost.
quorum_loss_is_bounded(Config) ->
    [{_, N1}, {P2, _}, {P3, _}] = ?config(peers, Config),
    Self = self(),
    Holder = erpc:call(N1, erlang, spawn, [fun() -> forward(Self) end]),
    {ok, _} = erpc:call(N1, chappe_cluster, claim, [q_held, #{pid => Holder}]),
    ok = chappe_cluster_test_dist:stop_peer(P2),
    ok = chappe_cluster_test_dist:stop_peer(P3),
    T0 = erlang:monotonic_time(millisecond),
    receive
        {fwd, {chappe_cluster, #{key := q_held}, lost}} -> ok
    after 2 * ?LEASE + 5000 -> ct:fail(no_lost)
    end,
    ?assert(erlang:monotonic_time(millisecond) - T0 < ?LEASE + ?RENEW),
    T1 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, no_quorum}, erpc:call(N1, chappe_cluster, claim, [q_new, #{}])),
    ?assert(erlang:monotonic_time(millisecond) - T1 < 3000),
    T2 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, no_quorum}, erpc:call(N1, chappe_cluster, put, [<<"q">>, 1])),
    ?assert(erlang:monotonic_time(millisecond) - T2 < 3000).

%% Stop the leader while another node holds a lease: the new leader starts
%% that node's timer when it takes over, so the holder never hears lost and
%% the key stays its own.
leader_change_never_expires_early(Config) ->
    Peers = ?config(peers, Config),
    Nodes = ?config(nodes, Config),
    {_, LeaderNode} = leader(hd(Nodes)),
    [N | _] = Nodes -- [LeaderNode],
    Self = self(),
    Holder = erpc:call(N, erlang, spawn, [fun() -> forward(Self) end]),
    {ok, L} = erpc:call(N, chappe_cluster, claim, [lc_key, #{pid => Holder}]),
    {LeaderPeer, LeaderNode} = lists:keyfind(LeaderNode, 2, Peers),
    ok = chappe_cluster_test_dist:stop_peer(LeaderPeer),
    Rest = Nodes -- [LeaderNode],
    wait(fun() -> lists:member(element(2, leader(hd(Rest))), Rest) end, 200),
    receive
        {fwd, {chappe_cluster, _, lost}} = M -> ct:fail({lost, M})
    after 3 * ?LEASE -> ok
    end,
    ?assert(erpc:call(N, chappe_cluster, valid, [L])),
    [?assertMatch({ok, #{pid := Holder}}, erpc:call(R, chappe_cluster, owner, [lc_key, consistent])) || R <- Rest].

%% Stop a node, then the leader at once: the new leader never applied a
%% renew of that node, so only the timer it arms as it takes over can
%% expire it. The node's key comes free no earlier than lease_ms after the
%% stop, and no later than lease_ms after the election plus a bound.
new_leader_expires_a_node_it_never_heard(Config) ->
    Peers = ?config(peers, Config),
    Nodes = ?config(nodes, Config),
    {_, LeaderNode} = leader(hd(Nodes)),
    [X | _] = Nodes -- [LeaderNode],
    {ok, _} = erpc:call(X, chappe_cluster, claim, [nl_key, #{pid => holder(X)}]),
    {PX, X} = lists:keyfind(X, 2, Peers),
    {PL, LeaderNode} = lists:keyfind(LeaderNode, 2, Peers),
    T0 = erlang:monotonic_time(millisecond),
    ok = chappe_cluster_test_dist:stop_peer(PX),
    ok = chappe_cluster_test_dist:stop_peer(PL),
    Rest = [R | _] = Nodes -- [X, LeaderNode],
    wait(fun() -> lists:member(element(2, leader(R)), Rest) end, 300),
    TElect = erlang:monotonic_time(millisecond),
    Claimer = holder(R),
    Bound = 5000,
    TFree = claim_by(R, nl_key, Claimer, TElect + ?LEASE + Bound),
    ct:pal("stop at 0, elected at +~b, free at +~b", [TElect - T0, TFree - T0]),
    ?assert(TFree - T0 >= ?LEASE),
    ?assert(TFree - TElect =< ?LEASE + Bound).

%% Claim until it succeeds or the deadline passes; the time it succeeded.
claim_by(Node, Key, Pid, Deadline) ->
    case erpc:call(Node, chappe_cluster, claim, [Key, #{pid => Pid, timeout => 1000}]) of
        {ok, _} ->
            erlang:monotonic_time(millisecond);
        {error, _} = E ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail({never_free, Key, E});
                false ->
                    timer:sleep(50),
                    claim_by(Node, Key, Pid, Deadline)
            end
    end.

%% Move every node's wall clock (the HLC's) an hour forward, then an hour
%% back, under a held lease: nothing expires, nothing is taken over, and
%% the HLC never goes back.
wall_clock_jumps_change_nothing(Config) ->
    Nodes = [N1, N2 | _] = ?config(nodes, Config),
    Self = self(),
    Holder = erpc:call(N1, erlang, spawn, [fun() -> forward(Self) end]),
    {ok, L} = erpc:call(N1, chappe_cluster, claim, [wc_key, #{pid => Holder}]),
    H0 = erpc:call(N1, chappe_cluster, now, []),
    [ok = erpc:call(N, ?MODULE, jump, [3600 * 1000]) || N <- Nodes],
    timer:sleep(2 * ?LEASE),
    [ok = erpc:call(N, ?MODULE, jump, [-3600 * 1000]) || N <- Nodes],
    timer:sleep(2 * ?LEASE),
    receive
        {fwd, {chappe_cluster, _, lost}} = M -> ct:fail({lost, M})
    after 0 -> ok
    end,
    ?assert(erpc:call(N1, chappe_cluster, valid, [L])),
    ?assertMatch({error, {owned, _}}, erpc:call(N2, chappe_cluster, claim, [wc_key, #{}])),
    H1 = erpc:call(N1, chappe_cluster, now, []),
    ?assert(hlc:less(H0, H1)),
    [ok = erpc:call(N, ?MODULE, jump, [0]) || N <- Nodes].

%% The test wall clock: system time plus an offset the test moves.
wall_ms() ->
    erlang:system_time(millisecond) + persistent_term:get({?MODULE, offset}, 0).

jump(Ms) ->
    persistent_term:put({?MODULE, offset}, Ms).

leader(Node) ->
    case catch_call(Node, ra, members, [erpc:call(Node, chappe_cluster_node, members, [])]) of
        {ok, _, Leader} -> Leader;
        _ -> {none, none}
    end.

%% Cut the holder's node off from the other two while the holder runs: it
%% hears lost before the other side's claim succeeds (one host, one clock).
cut_off_holder_hears_lost_before_takeover(Config) ->
    [N1, N2, N3] = ?config(nodes, Config),
    Holder = erpc:call(N1, erlang, spawn, [fun() -> lost_clock(none) end]),
    {ok, L1} = erpc:call(N1, chappe_cluster, claim, [cut_key, #{pid => Holder}]),
    wait(fun() -> owner_node(N2, cut_key) =:= N1 end),
    Cookie = erlang:get_cookie(),
    cut(N1, [N2, N3], Cookie),
    try
        T0 = erlang:system_time(millisecond),
        Claimer = holder(N2),
        L2 = erpc:call(N2, ?MODULE, claim_until, [cut_key, Claimer, 400]),
        TClaim = erpc:call(N2, erlang, system_time, [millisecond]),
        ?assert(seq(L2) > seq(L1)),
        heal(N1, [N2, N3], Cookie),
        Holder ! {get, self()},
        TLost =
            receive
                {lost_at, T} when is_integer(T) -> T;
                {lost_at, none} -> ct:fail(no_lost)
            after 10000 -> ct:fail(holder_gone)
            end,
        ct:pal("cut at ~b, lost at +~b, taken at +~b", [T0, TLost - T0, TClaim - T0]),
        ?assert(TLost < TClaim)
    after
        heal(N1, [N2, N3], Cookie)
    end.

%% A holder that keeps the time it heard lost.
lost_clock(At) ->
    receive
        {chappe_cluster, _, lost} when At =:= none ->
            lost_clock(erlang:system_time(millisecond));
        {get, From} ->
            From ! {lost_at, At},
            lost_clock(At);
        _ ->
            lost_clock(At)
    end.

claim_until(Key, Pid, 0) ->
    error(
        {no_takeover, Key, chappe_cluster:claim(Key, #{pid => Pid}), nodes(),
            erlang:system_time(millisecond),
            ra:local_query(
                chappe_cluster_config:server_id(),
                fun chappe_cluster_machine:overview/1
            )}
    );
claim_until(Key, Pid, N) ->
    case chappe_cluster:claim(Key, #{pid => Pid, timeout => 1000}) of
        {ok, L} ->
            L;
        {error, _} ->
            timer:sleep(50),
            claim_until(Key, Pid, N - 1)
    end.

%% A partition both ways that the nodes cannot heal on their own: each side
%% expects a different cookie from the other, then drops the connection.
cut(N1, Others, _Cookie) ->
    [
        begin
            true = erpc:call(N1, erlang, set_cookie, [N, 'chappe-cut-a']),
            true = erpc:call(N, erlang, set_cookie, [N1, 'chappe-cut-b']),
            _ = erpc:call(N1, erlang, disconnect_node, [N]),
            _ = erpc:call(N, erlang, disconnect_node, [N1])
        end
     || N <- Others
    ],
    ok.

heal(N1, Others, Cookie) ->
    _ = net_kernel:connect_node(N1),
    [
        begin
            _ = catch_call(N1, erlang, set_cookie, [N, Cookie]),
            _ = catch_call(N, erlang, set_cookie, [N1, Cookie]),
            _ = catch_call(N, net_kernel, connect_node, [N1])
        end
     || N <- Others
    ],
    ok.

seq(#{seq := S}) -> S.

%% From another node: owners, watches and singletons are seen across the
%% region; a lease is held on its own node only.
api_from_other_nodes(Config) ->
    [N1, N2, N3] = ?config(nodes, Config),
    Self = self(),
    %% a holder on this CT node cannot hold a lease of N1
    Far = spawn(fun() -> forward(Self) end),
    ?assertEqual(
        {error, badarg}, erpc:call(N1, chappe_cluster, claim, [far_key, #{pid => Far}])
    ),
    Holder = holder(N1),
    {ok, L} = erpc:call(N1, chappe_cluster, claim, [far_key, #{pid => Holder}]),
    wait(fun() -> owner_pid(N3, far_key) =:= Holder end),
    %% a watcher on N2 sees a put made on N3
    W = erpc:call(N2, erlang, spawn, [fun() -> watcher(Self, <<"far/">>) end]),
    receive
        {watching, W} -> ok
    after 5000 -> ct:fail(no_watch)
    end,
    {ok, _} = erpc:call(N3, chappe_cluster, put, [<<"far/1">>, v]),
    receive
        {fwd, {chappe_cluster, watch, {put, <<"far/1">>, v, _}}} -> ok
    after 5000 -> ct:fail(no_event)
    end,
    %% a singleton started on every node runs once, found through pg
    [ok = erpc:call(N, chappe_cluster, singleton, [far_s, child_spec()]) || N <- [N1, N2, N3]],
    wait(fun() -> length(singleton_pids(far_s, [N1, N2, N3])) =:= 1 end),
    [Pid] = singleton_pids(far_s, [N1, N2, N3]),
    timer:sleep(3 * ?RENEW),
    ?assertEqual([Pid], singleton_pids(far_s, [N1, N2, N3])),
    [?assertEqual({ok, Pid}, erpc:call(N, chappe_cluster, whereis_singleton, [far_s])) || N <- [N1, N2, N3]],
    %% the lease is released from another node
    ok = erpc:call(N2, chappe_cluster, release, [L]),
    wait(fun() -> owner_pid(N3, far_key) =:= none end).

%% Add a fourth node as a voter, then remove it.
join_and_leave(Config) ->
    Nodes = [N1 | _] = ?config(nodes, Config),
    {P4, N4} = chappe_cluster_test_dist:peer("cc4"),
    Config1 = [{extra, [{P4, N4}]} | Config],
    ok = chappe_cluster_test_dist:start_app(N4, env(Nodes), ?config(dir, Config)),
    %% not a member yet, but live through the others
    ok = wait_live(N4),
    ?assertNot(erpc:call(N4, chappe_cluster_node, has_member, [])),
    ok = erpc:call(N1, chappe_cluster, join, [N4]),
    wait(fun() -> erpc:call(N4, chappe_cluster_node, has_member, []) end),
    wait(fun() -> length(erpc:call(N1, chappe_cluster_node, members, [])) =:= 4 end),
    {ok, _} = erpc:call(N4, chappe_cluster, put, [<<"joined">>, N4]),
    wait(fun() -> erpc:call(N4, chappe_cluster, get, [<<"joined">>]) =:= {ok, N4, 1} end),
    ok = erpc:call(N1, chappe_cluster, leave, [N4]),
    wait(fun() -> length(erpc:call(N1, chappe_cluster_node, members, [])) =:= 3 end),
    ?assertNot(erpc:call(N4, chappe_cluster_node, has_member, [])),
    _ = Config1,
    ok.

%% The node running a singleton stops: another node runs it.
singleton_moves_when_its_node_stops(Config) ->
    Peers = ?config(peers, Config),
    Nodes = ?config(nodes, Config),
    [ok = erpc:call(N, chappe_cluster, singleton, [mover, child_spec()]) || N <- Nodes],
    wait(fun() -> length(singleton_pids(mover, Nodes)) =:= 1 end),
    [Pid] = singleton_pids(mover, Nodes),
    Runner = node(Pid),
    {Peer, Runner} = lists:keyfind(Runner, 2, Peers),
    ok = chappe_cluster_test_dist:stop_peer(Peer),
    Rest = Nodes -- [Runner],
    wait(fun() -> length(singleton_pids(mover, Rest)) =:= 1 end, 200),
    [Pid2] = singleton_pids(mover, Rest),
    ?assertNotEqual(Runner, node(Pid2)).

%% A paused child, whose contender is paused too so no kill reaches it,
%% wakes up after another node took the singleton over: its check says
%% the lease is gone before it does anything.
paused_singleton_child_sees_its_lease_gone(Config) ->
    Nodes = ?config(nodes, Config),
    Spec = #{id => checker, start => {?MODULE, start_checker, [paused]}},
    [ok = erpc:call(N, chappe_cluster, singleton, [paused, Spec]) || N <- Nodes],
    wait(fun() -> length(singleton_pids(paused, Nodes)) =:= 1 end),
    [Child] = singleton_pids(paused, Nodes),
    X = node(Child),
    Rest = Nodes -- [X],
    ?assert(gen_server:call(Child, check)),
    {ok, {default, _, Seq0}} = erpc:call(X, chappe_cluster, singleton_fence, [paused]),
    Contender = erpc:call(X, ?MODULE, contender, [paused]),
    ok = erpc:call(X, sys, suspend, [Contender]),
    ok = erpc:call(X, sys, suspend, [Child]),
    Cookie = erlang:get_cookie(),
    cut(X, Rest, Cookie),
    try
        wait(fun() -> [P || P <- singleton_pids(paused, Rest), node(P) =/= X] =/= [] end, 200),
        [Other] = [P || P <- singleton_pids(paused, Rest), node(P) =/= X],
        {ok, {default, _, Seq1}} =
            erpc:call(node(Other), chappe_cluster, singleton_fence, [paused]),
        ?assert(Seq1 > Seq0),
        ok = erpc:call(X, sys, resume, [Child]),
        ?assertNot(gen_server:call(Child, check)),
        ?assertNot(erpc:call(X, chappe_cluster, singleton_valid, [paused])),
        ?assertEqual(none, erpc:call(X, chappe_cluster, singleton_fence, [paused]))
    after
        heal(X, Rest, Cookie),
        _ = catch_call(X, sys, resume, [Contender])
    end.

%% A singleton child that answers `check' with singleton_valid/1, the test
%% it runs before each side effect.
start_checker(Name) ->
    gen_server:start_link(?MODULE, {checker, Name}, []).

init({checker, Name}) ->
    {ok, Name}.

handle_call(check, _From, Name) ->
    {reply, chappe_cluster:singleton_valid(Name), Name}.

handle_cast(_Msg, Name) ->
    {noreply, Name}.

contender(Name) ->
    {Name, Pid, _, _} = lists:keyfind(
        Name, 1, supervisor:which_children(chappe_cluster_singleton_sup)
    ),
    Pid.

%% ---- helpers ----

holder(Node) ->
    erpc:call(Node, erlang, spawn, [fun() -> receive stop -> ok end end]).

forward(To) ->
    receive
        M ->
            To ! {fwd, M},
            forward(To)
    end.

watcher(To, Prefix) ->
    ok = chappe_cluster:watch(Prefix),
    To ! {watching, self()},
    forward(To).

child_spec() ->
    #{id => child, start => {?MODULE, start_child, []}}.

start_child() ->
    {ok, spawn_link(fun() -> receive stop -> ok end end)}.

singleton_pids(Name, Nodes) ->
    lists:usort(
        lists:append([
            [P || {ok, P} <- [catch_call(N, chappe_cluster, whereis_singleton, [Name])], node(P) =:= N]
         || N <- Nodes
        ])
    ).

catch_call(N, M, F, A) ->
    try
        erpc:call(N, M, F, A, 2000)
    catch
        _:_ -> error
    end.

owner_node(Node, Key) ->
    case erpc:call(Node, chappe_cluster, owner, [Key]) of
        {ok, #{node := N}} -> N;
        Other -> Other
    end.

owner_pid(Node, Key) ->
    case erpc:call(Node, chappe_cluster, owner, [Key]) of
        {ok, #{pid := P}} -> P;
        Other -> Other
    end.

wait_claim(Node, Key, Holder) ->
    wait_claim(Node, Key, Holder, 200).

wait_claim(Node, Key, Holder, 0) ->
    ct:fail({no_takeover, Node, Key, erpc:call(Node, chappe_cluster, claim, [Key, #{pid => Holder}])});
wait_claim(Node, Key, Holder, N) ->
    case erpc:call(Node, chappe_cluster, claim, [Key, #{pid => Holder}]) of
        {ok, L} ->
            L;
        {error, _} ->
            timer:sleep(100),
            wait_claim(Node, Key, Holder, N - 1)
    end.

wait_live(Node) ->
    wait(fun() -> erpc:call(Node, chappe_cluster_node, live, []) =/= not_live end, 300).

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
