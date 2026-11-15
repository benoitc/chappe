%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Boots one cluster lab node from its environment
%% (apps/chappe_cluster/interop/docker-compose.yml): chappe_cluster with
%% every lab node as a voter, then the lab client.
%%
%%     CLB_NODES     the lab's node hosts, space separated (n1 n2 n3)
%%     CLB_LEASE_MS  lease_ms (6000)        CLB_RENEW_MS  renew_ms (2000)
%%     CLB_WORKERS   workers per node (3)   CLB_KEYS      keys in play (6)
%%     CLB_LOG_DIR   where the event log goes (/logs)
%%     CLB_CLIENT    0 starts chappe_cluster only
%%     CLB_SINGLETON 0 skips the singleton (chappe_cluster_lab_single)
%%     CLB_SINGLETON_STOP_MS  how long its child takes to stop (renew_ms * 3/4)
%%
%% Without chappe_cluster in the code path the node only joins the lab
%% network, which is enough for the topology check.
-module(chappe_cluster_lab_node).

-export([start/0, voters/0]).

-spec start() -> ok.
start() ->
    case code:which(chappe_cluster) of
        non_existing ->
            ok;
        _ ->
            ok = start_cluster(),
            ok = start_client()
    end.

%% @doc Every lab node, by the node name it runs under.
-spec voters() -> [node()].
voters() ->
    [Name, _] = string:split(atom_to_list(node()), "@"),
    [
        list_to_atom(Name ++ "@" ++ Host)
     || Host <- string:lexemes(env("CLB_NODES", "n1 n2 n3"), " ")
    ].

start_cluster() ->
    application:load(chappe_cluster),
    Env = [
        {voters, voters()},
        {data_dir, env("CLB_DATA_DIR", "/data")},
        {lease_ms, int("CLB_LEASE_MS", 6000)},
        {renew_ms, int("CLB_RENEW_MS", 2000)}
    ],
    [ok = application:set_env(chappe_cluster, K, V) || {K, V} <- Env],
    {ok, _} = application:ensure_all_started(chappe_cluster),
    ok.

start_client() ->
    case env("CLB_CLIENT", "1") of
        "0" ->
            ok;
        _ ->
            {ok, _} = chappe_cluster_lab_client:start(#{
                log_dir => env("CLB_LOG_DIR", "/logs"),
                workers => int("CLB_WORKERS", 3),
                keys => int("CLB_KEYS", 6),
                hold_ms => {500, 8000},
                beat_ms => 200
            }),
            start_singleton()
    end.

%% Every node contends for one singleton whose child is slow to stop.
start_singleton() ->
    case env("CLB_SINGLETON", "1") of
        "0" ->
            ok;
        _ ->
            Renew = int("CLB_RENEW_MS", 2000),
            Opts = #{
                beat_ms => 200,
                stop_ms => int("CLB_SINGLETON_STOP_MS", Renew * 3 div 4)
            },
            Spec = chappe_cluster_lab_single:spec(clb, Opts),
            ok = chappe_cluster:singleton(clb, Spec)
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        V -> V
    end.

int(Name, Default) ->
    list_to_integer(env(Name, integer_to_list(Default))).
