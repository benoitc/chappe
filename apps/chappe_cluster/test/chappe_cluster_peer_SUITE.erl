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
        api_from_other_nodes,
        join_and_leave,
        singleton_moves_when_its_node_stops
    ].

init_per_suite(Config) ->
    ok = chappe_cluster_test_dist:ensure(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    Peers = [chappe_cluster_test_dist:peer("cc" ++ integer_to_list(I)) || I <- [1, 2, 3]],
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

%% From another node: owners, watches and singletons are seen across the
%% region; a holder on a node that runs no chappe_cluster hears lost.
api_from_other_nodes(Config) ->
    [N1, N2, N3] = ?config(nodes, Config),
    Self = self(),
    %% a holder on this CT node, which runs no chappe_cluster
    Holder = spawn(fun() -> forward(Self) end),
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
        {fwd, {chappe_cluster, watch, {put, <<"far/1">>, v}}} -> ok
    after 5000 -> ct:fail(no_event)
    end,
    %% a singleton started on every node runs once, found through pg
    [ok = erpc:call(N, chappe_cluster, singleton, [far_s, child_spec()]) || N <- [N1, N2, N3]],
    wait(fun() -> length(singleton_pids(far_s, [N1, N2, N3])) =:= 1 end),
    [Pid] = singleton_pids(far_s, [N1, N2, N3]),
    timer:sleep(3 * ?RENEW),
    ?assertEqual([Pid], singleton_pids(far_s, [N1, N2, N3])),
    [?assertEqual({ok, Pid}, erpc:call(N, chappe_cluster, whereis_singleton, [far_s])) || N <- [N1, N2, N3]],
    %% the holder on the CT node is released from another node
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
