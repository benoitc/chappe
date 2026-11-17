%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Peers probed by one node of a chappe_cluster region (probe =>
%% singleton): three peer nodes run chappe_cluster and a SIP stack each,
%% and this node plays the trunk, a UDP socket that answers OPTIONS and
%% notes the port each one came from (each node's SIP port).
-module(chappe_sip_peers_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2,
         end_per_testcase/2]).
-export([singleton_probe/1, prober_crash_and_overflow/1,
         singleton_needs_cluster/1, env_peer_starts_cluster/1,
         missed_event_resynced/1, stale_write_refused/1,
         prober_table_without_quorum/1]).

-define(UA, chappe_sip_test_ua).
-define(C, chappe_sip_test_cluster).

all() ->
    [singleton_probe, prober_crash_and_overflow, singleton_needs_cluster,
     env_peer_starts_cluster, missed_event_resynced, stale_write_refused,
     prober_table_without_quorum].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif, [{persistent, true}]),
    ok = ?C:ensure(),
    Config.

end_per_suite(_Config) ->
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(env_peer_starts_cluster, Config) ->
    {Peer, Node} = ?C:peer("pc"),
    [{peers, [{Peer, Node}]}, {nodes, [Node]} | Config];
init_per_testcase(prober_table_without_quorum = Case, Config) ->
    %% a long lease: the pinger keeps it while the trunk goes down
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    Peers = [?C:peer("pc" ++ integer_to_list(I)) || I <- [1, 2, 3]],
    Nodes = [N || {_, N} <- Peers],
    Long = #{lease_ms => 9000, renew_ms => 3000, command_timeout => 1000},
    [ok = ?C:start_cluster(N, Nodes, Dir, Long) || N <- Nodes],
    [ok = ?C:wait_live(N) || N <- Nodes],
    Ports = [{start_sip(N, cluster), N} || N <- Nodes],
    [{peers, Peers}, {nodes, Nodes}, {ports, Ports} | Config];
init_per_testcase(Case, Config) when Case =/= singleton_needs_cluster ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    Peers = [?C:peer("pc" ++ integer_to_list(I)) || I <- [1, 2, 3]],
    Nodes = [N || {_, N} <- Peers],
    [ok = ?C:start_cluster(N, Nodes, Dir) || N <- Nodes],
    [ok = ?C:wait_live(N) || N <- Nodes],
    Ports = [{start_sip(N, cluster), N} || N <- Nodes],
    [{peers, Peers}, {nodes, Nodes}, {ports, Ports} | Config];
init_per_testcase(_Case, Config) ->
    {Peer, Node} = ?C:peer("pc"),
    _ = start_sip(Node, none),
    [{peers, [{Peer, Node}]}, {nodes, [Node]} | Config].

end_per_testcase(_Case, Config) ->
    [?C:stop_peer(P) || {P, _} <- ?config(peers, Config)],
    ok.

start_sip(Node, Cluster) ->
    ok = erpc:call(Node, application, set_env, [chappe_sip, cluster, cluster_mode(Cluster)]),
    {ok, _} = erpc:call(Node, application, ensure_all_started, [chappe_sip]),
    Port = ?UA:pick(),
    ok = erpc:call(Node, chappe_sip, start,
                   [#{contact => <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>}]),
    Port.

cluster_mode(cluster) -> chappe_cluster;
cluster_mode(none) -> none.

%% ---- cases ----

%% Every node adds the trunk with probe => singleton: the OPTIONS leave
%% from one node only, every node sees the same state, and when that
%% node stops the pings move to another one, whose word every node left
%% takes (the trunk going down shows on both).
singleton_probe(Config) ->
    Ports = ?config(ports, Config),
    [N1 | _] = Nodes = ?config(nodes, Config),
    {TPort, Trunk} = trunk(),
    Opts = #{uri => <<"sip:trunk@127.0.0.1:", (integer_to_binary(TPort))/binary>>,
             interval_ms => 300, timeout_ms => 300, up_after => 1, down_after => 2,
             probe => singleton},
    %% the first node to add it holds the singleton
    ok = erpc:call(N1, chappe_sip, peer_add, [trunk, Opts]),
    First = wait_prober(N1),
    [ok = erpc:call(N, chappe_sip, peer_add, [trunk, Opts]) || N <- Nodes -- [N1]],
    Subs = [{N, subscriber(N)} || N <- Nodes],
    [ok = wait_state(N, up) || N <- Nodes],
    flush_options(),
    Senders = senders(2000),
    ct:pal("pings from ~p (nodes ~p)", [Senders, Ports]),
    ?assertEqual([First], [proplists:get_value(P, Ports) || P <- Senders]),
    %% stop the prober: another node takes the pings over
    {FirstPeer, First} = lists:keyfind(First, 2, ?config(peers, Config)),
    ok = ?C:stop_peer(FirstPeer),
    Rest = Nodes -- [First],
    %% the stopped node stays in pg until its nodedown reaches hd(Rest)
    Second = wait_prober(hd(Rest), Rest),
    ?assert(lists:member(Second, Rest)),
    flush_options(),
    Senders2 = senders(2000),
    ?assertEqual([Second], [proplists:get_value(P, Ports) || P <- Senders2]),
    [{ok, #{state := up}} = erpc:call(N, chappe_sip, peer_status, [trunk]) || N <- Rest],
    %% the new prober's word reaches every node: the trunk goes down
    Trunk ! {mode, silent},
    [ok = wait_state(N, down) || N <- Rest],
    [ok = expect({sub, N, {chappe_sip_peer, trunk, down}}, 5000) || {N, _} <- Subs, N =/= First],
    ok = erpc:call(Second, chappe_sip, peer_remove, [trunk]),
    ?assertEqual({error, not_found}, erpc:call(Second, chappe_sip, peer_status, [trunk])).

%% The prober crashes: the singleton starts it again, from the state the
%% KV holds, so no node sees the trunk leave up. A node whose KV watch
%% overflowed watches again and reads the state back.
prober_crash_and_overflow(Config) ->
    Nodes = ?config(nodes, Config),
    {TPort, Trunk} = trunk(),
    Opts = #{uri => <<"sip:trunk@127.0.0.1:", (integer_to_binary(TPort))/binary>>,
             interval_ms => 300, timeout_ms => 300, up_after => 1, down_after => 2,
             probe => singleton},
    [ok = erpc:call(N, chappe_sip, peer_add, [trunk, Opts]) || N <- Nodes],
    [ok = wait_state(N, up) || N <- Nodes],
    _ = [subscriber(N) || N <- Nodes],
    {ok, Child} = erpc:call(hd(Nodes), chappe_cluster, whereis_singleton, [{chappe_sip_peer, trunk}]),
    exit(Child, kill),
    _ = wait(fun() ->
                 case erpc:call(hd(Nodes), chappe_cluster, whereis_singleton, [{chappe_sip_peer, trunk}]) of
                     {ok, P} when P =/= Child -> {true, P};
                     _ -> false
                 end
             end, 100),
    flush_options(),
    [_ | _] = senders(1000),
    receive
        {sub, _, {chappe_sip_peer, trunk, _} = E} -> ct:fail({state_moved, E})
    after 500 -> ok
    end,
    [{ok, #{state := up}} = erpc:call(N, chappe_sip, peer_status, [trunk]) || N <- Nodes],
    Last = lists:last(Nodes),
    erpc:call(Last, erlang, send, [chappe_sip_peers, {chappe_cluster, watch, overflow}]),
    Trunk ! {mode, silent},
    [ok = wait_state(N, down) || N <- Nodes].

%% probe => singleton without the cluster setting is refused, and an
%% unknown probe mode is a bad option.
singleton_needs_cluster(Config) ->
    [N] = ?config(nodes, Config),
    Uri = <<"sip:trunk@127.0.0.1:5999">>,
    ?assertEqual({error, no_cluster},
                 erpc:call(N, chappe_sip, peer_add, [t, #{uri => Uri, probe => singleton}])),
    ?assertEqual({error, {bad_option, probe}},
                 erpc:call(N, chappe_sip, peer_add, [t, #{uri => Uri, probe => sometimes}])),
    ok = erpc:call(N, chappe_sip, peer_add, [t, #{uri => Uri, probe => all_nodes}]),
    ok = erpc:call(N, chappe_sip, peer_remove, [t]).

%% A singleton peer of the `peers' setting, with chappe_cluster configured
%% but not started: chappe_sip starts it during its own start, and the
%% peer is pinged.
env_peer_starts_cluster(Config) ->
    [N] = ?config(nodes, Config),
    {TPort, _Trunk} = trunk(),
    Dir = filename:join(?config(priv_dir, Config), "env_peer"),
    Env = #{voters => [N], lease_ms => 2000, renew_ms => 500,
            data_dir => filename:join(Dir, atom_to_list(N))},
    ok = erpc:call(N, application, load, [chappe_cluster]),
    [ok = erpc:call(N, application, set_env, [chappe_cluster, K, V]) || K := V <- Env],
    Opts = #{uri => <<"sip:trunk@127.0.0.1:", (integer_to_binary(TPort))/binary>>,
             interval_ms => 300, timeout_ms => 300, probe => singleton},
    ok = erpc:call(N, application, set_env, [chappe_sip, peers, [{envtrunk, Opts}]]),
    _ = start_sip(N, cluster),
    ?assert(lists:keymember(chappe_cluster, 1, erpc:call(N, application, which_applications, []))),
    ok = wait(fun() ->
                  case erpc:call(N, chappe_sip, peer_status, [envtrunk]) of
                      {ok, #{state := up}} -> {true, ok};
                      _ -> false
                  end
              end, 150).

%% A node that missed a KV event (it was not live yet when the pinger
%% wrote, so the region sent it none) reads the state back on its own
%% within the resync period.
missed_event_resynced(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    {TPort, _Trunk} = trunk(),
    Opts = #{uri => <<"sip:trunk@127.0.0.1:", (integer_to_binary(TPort))/binary>>,
             interval_ms => 300, timeout_ms => 300, probe => singleton},
    [ok = erpc:call(N, chappe_sip, peer_add, [trunk, Opts]) || N <- [N1, N2]],
    [ok = wait_state(N, up) || N <- [N1, N2]],
    %% N2's row as if the last event never came
    {ok, Info} = erpc:call(N2, chappe_sip, peer_status, [trunk]),
    ok = erpc:call(N2, chappe_sip_peers, put, [trunk, Info#{state := unknown}]),
    {ok, #{state := unknown}} = erpc:call(N2, chappe_sip, peer_status, [trunk]),
    ok = wait_state(N2, up).

%% A write from a pinger whose fence is older than the one in the KV (a
%% paused holder that wakes up after the takeover) is refused, so a node
%% that reads the KV later never takes its word.
stale_write_refused(Config) ->
    [N1 | _] = Nodes = ?config(nodes, Config),
    {TPort, _Trunk} = trunk(),
    Opts = #{uri => <<"sip:trunk@127.0.0.1:", (integer_to_binary(TPort))/binary>>,
             interval_ms => 300, timeout_ms => 300, probe => singleton},
    [ok = erpc:call(N, chappe_sip, peer_add, [trunk, Opts]) || N <- Nodes],
    [ok = wait_state(N, up) || N <- Nodes],
    Key = erpc:call(N1, chappe_sip_peers, kv_key, [trunk]),
    {ok, #{info := Info, fence := {R, E, Seq}}, _} = erpc:call(N1, chappe_cluster, get, [Key]),
    Stale = {R, E, Seq - 1},
    ?assertEqual({error, stale},
                 erpc:call(N1, chappe_sip_peer, share, [trunk, Info#{state := down}, Stale])),
    {ok, #{info := #{state := up}, fence := {_, _, Seq}}, _} = erpc:call(N1, chappe_cluster, get, [Key]).

%% Without a quorum the pinger's KV write fails, yet its own node's table
%% follows what it sees: the trunk going down shows there.
prober_table_without_quorum(Config) ->
    Peers = ?config(peers, Config),
    [N1 | _] = ?config(nodes, Config),
    {TPort, Trunk} = trunk(),
    Opts = #{uri => <<"sip:trunk@127.0.0.1:", (integer_to_binary(TPort))/binary>>,
             interval_ms => 200, timeout_ms => 200, up_after => 1, down_after => 2,
             probe => singleton},
    ok = erpc:call(N1, chappe_sip, peer_add, [trunk, Opts]),
    N1 = wait_prober(N1),
    ok = wait_state(N1, up),
    [?C:stop_peer(P) || {P, N} <- Peers, N =/= N1],
    Trunk ! {mode, silent},
    ok = wait_state(N1, down).

%% ---- helpers ----

%% The node running the trunk's singleton, once one does.
wait_prober(Any) ->
    wait_prober(Any, any).

%% The node running the prober, as Any sees it; with a node list, only
%% once it is one of them.
wait_prober(Any, Among) ->
    wait(fun() ->
             case erpc:call(Any, chappe_cluster, whereis_singleton, [{chappe_sip_peer, trunk}]) of
                 {ok, Pid} -> among(node(Pid), Among);
                 none -> false
             end
         end, 100).

among(Node, any) -> {true, Node};
among(Node, Nodes) -> lists:member(Node, Nodes) andalso {true, Node}.

wait_state(N, State) ->
    ok = wait(fun() ->
                          case erpc:call(N, chappe_sip, peer_status, [trunk]) of
                              {ok, #{state := State}} -> {true, ok};
                              _ -> false
                          end
                      end, 100).

wait(F, 0) ->
    error({timeout, F});
wait(F, N) ->
    case F() of
        {true, V} -> V;
        false -> timer:sleep(100), wait(F, N - 1)
    end.

%% A process on N subscribed to its peer events, forwarding them here.
subscriber(N) ->
    Test = self(),
    erpc:call(N, erlang, spawn, [fun() ->
        ok = chappe_sip:peer_subscribe(self()),
        Test ! {subscribed, node()},
        fwd(Test)
    end]),
    receive {subscribed, N} -> ok after 5000 -> ct:fail(no_subscriber) end.

fwd(Test) ->
    receive M -> Test ! {sub, node(), M}, fwd(Test) end.

expect(M, T) ->
    receive M -> ok after T -> {error, {timeout, M}} end.

%% The trunk: answers OPTIONS 200 (or nothing, after {mode, silent}) and
%% tells the test the port each came from.
trunk() ->
    Test = self(),
    Port = ?UA:pick(),
    Pid = ?UA:peer(Port, fun(Sock) -> trunk_loop(Sock, 200, Test) end),
    {Port, Pid}.

trunk_loop(Sock, Mode, Test) ->
    receive
        {mode, M} ->
            trunk_loop(Sock, M, Test);
        {udp, Sock, _, Src, <<"OPTIONS ", _/binary>> = Req} ->
            Test ! {options, Src},
            _ = case Mode of
                    silent -> ok;
                    St -> ?UA:send(Sock, Src, ?UA:resp(Req, St, <<"OK">>, ?UA:tag(), [], <<>>))
                end,
            trunk_loop(Sock, Mode, Test);
        _ ->
            trunk_loop(Sock, Mode, Test)
    end.

flush_options() ->
    receive {options, _} -> flush_options() after 0 -> ok end.

%% The source ports of the OPTIONS seen for Ms.
senders(Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    senders(Deadline, []).

senders(Deadline, Acc) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {options, Src} -> senders(Deadline, [Src | Acc])
    after Left ->
        lists:usort(Acc)
    end.
