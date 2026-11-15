%% Distribution for the suites that start a peer node.
%%
%% A CT node runs undistributed, and net_kernel:start/2 needs an epmd to
%% register with: a fresh CI runner has none, which fails the start with
%% nodistribution. ensure/0 starts epmd first, then the node.
%%
%% The suites also start peer nodes running chappe_cluster: peer/2 starts
%% one with this node's code path, and start_app/3 sets the env and starts
%% the app there.
-module(chappe_cluster_test_dist).

-export([ensure/0, peer/1, start_app/3, stop_peer/1]).

-spec ensure() -> ok.
ensure() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            %% localhost: the host's own name may resolve to an address
            %% other nodes on it cannot reach (a laptop changing network)
            Name = list_to_atom("chappe_ct_" ++ os:getpid() ++ "@localhost"),
            {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.

%% A peer node named after `Base', with this node's code path.
-spec peer(string()) -> {pid(), node()}.
peer(Base) ->
    Name = list_to_atom(Base ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    %% the peer takes this node's host part (localhost when ensure/0
    %% started it)
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, Peer, Node} = peer:start_link(#{
        name => Name,
        host => Host,
        connection => standard_io,
        args => Paths
    }),
    ok = connect(Node, 50),
    {Peer, Node}.

%% A loaded host can refuse the first attempt while the peer's
%% distribution comes up.
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

%% Start chappe_cluster on `Node' with `Env' (a map of app env).
-spec start_app(node(), map(), string()) -> ok.
start_app(Node, Env, DataDir) ->
    Env1 = Env#{data_dir => DataDir},
    ok = erpc:call(Node, application, load, [chappe_cluster]),
    [ok = erpc:call(Node, application, set_env, [chappe_cluster, K, V]) || K := V <- Env1],
    {ok, _} = erpc:call(Node, application, ensure_all_started, [chappe_cluster]),
    ok.

-spec stop_peer(pid()) -> ok.
stop_peer(Peer) ->
    try
        peer:stop(Peer)
    catch
        exit:_ -> ok
    end.
