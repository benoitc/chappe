%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Peer nodes for the suites that run chappe_mrf on several nodes, with
%% or without chappe_cluster. ensure/0 names this node @localhost (a
%% loaded host may not resolve its own name for -sname peers); a node
%% already distributed keeps its name, and its peers still run on
%% localhost.
-module(chappe_mrf_test_cluster).

-export([
    ensure/0,
    peer/1, peer/2,
    stop_peer/1,
    start_cluster/3, start_cluster/4,
    wait_live/1
]).

-spec ensure() -> ok.
ensure() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            Name = list_to_atom("chappe_ct_" ++ os:getpid() ++ "@localhost"),
            {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.

%% A peer named after Base with this node's code path and the engine
%% backend this node runs.
-spec peer(string()) -> {pid(), node()}.
peer(Base) ->
    peer(Base, []).

%% The same without the code of the apps in Without (as a release that
%% leaves them out).
-spec peer(string(), [atom()]) -> {pid(), node()}.
peer(Base, Without) ->
    Name = list_to_atom(
        Base ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Out = [code:lib_dir(A) || A <- Without],
    Paths = lists:append([
        ["-pa", P]
     || P <- code:get_path(),
        not lists:any(fun(D) -> lists:prefix(D, P) end, Out)
    ]),
    %% always localhost: a peer on this host's own name may not reach the
    %% others when that name resolves badly (a laptop between networks),
    %% and this node, whatever its name, reaches localhost
    {ok, Peer, Node} = peer:start_link(#{
        name => Name,
        host => "localhost",
        connection => standard_io,
        args => ["-kernel", "prevent_overlapping_partitions", "false" | Paths]
    }),
    ok = connect(Node, 50),
    Mod = application:get_env(chappe_sip, engine_mod, chappe_sip_nif),
    ok = erpc:call(Node, application, load, [chappe_sip]),
    ok = erpc:call(Node, application, set_env, [chappe_sip, engine_mod, Mod]),
    {Peer, Node}.

connect(Node, 0) ->
    error({no_connection, Node});
connect(Node, N) ->
    case net_kernel:connect_node(Node) of
        true ->
            ok;
        _ ->
            timer:sleep(200),
            connect(Node, N - 1)
    end.

-spec stop_peer(pid()) -> ok.
stop_peer(Peer) ->
    try
        peer:stop(Peer)
    catch
        exit:_ -> ok
    end.

%% Start chappe_cluster on Node, in a region of Voters, short leases.
-spec start_cluster(node(), [node()], string()) -> ok.
start_cluster(Node, Voters, Dir) ->
    start_cluster(Node, Voters, Dir, #{}).

%% The same with Extra over the defaults (lease_ms, renew_ms, ...).
-spec start_cluster(node(), [node()], string(), map()) -> ok.
start_cluster(Node, Voters, Dir, Extra) ->
    Env0 = #{
        voters => Voters,
        lease_ms => 2000,
        renew_ms => 500,
        command_timeout => 2000,
        data_dir => filename:join(Dir, atom_to_list(Node))
    },
    Env = maps:merge(Env0, Extra),
    ok = erpc:call(Node, application, load, [chappe_cluster]),
    [
        ok = erpc:call(Node, application, set_env, [chappe_cluster, K, V])
     || K := V <- Env
    ],
    {ok, _} = erpc:call(Node, application, ensure_all_started, [chappe_cluster]),
    ok.

%% Wait until Node's chappe_cluster takes leases.
-spec wait_live(node()) -> ok.
wait_live(Node) ->
    wait_live(Node, 300).

wait_live(Node, 0) ->
    error({not_live, Node});
wait_live(Node, N) ->
    case erpc:call(Node, chappe_cluster, status, []) of
        #{live := true} ->
            ok;
        _ ->
            timer:sleep(200),
            wait_live(Node, N - 1)
    end.
