%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The supervision tree, rest_for_one so that what depends on a process
%% restarts with it:
%%
%% - chappe_cluster's own pg scope, `chappe_cluster' (running singletons);
%% - the watch hub, before the member that feeds it;
%% - the node agent: the Ra system and member, liveness, tracked leases;
%% - the singleton supervisor, one contender per singleton name.
-module(chappe_cluster_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => chappe_cluster_pg, start => {pg, start_link, [chappe_cluster]}},
        #{
            id => chappe_cluster_watch,
            start => {chappe_cluster_watch, start_link, []}
        },
        #{
            id => chappe_cluster_node,
            start => {chappe_cluster_node, start_link, []},
            shutdown => 10000
        },
        #{
            id => chappe_cluster_singleton_sup,
            start => {chappe_cluster_singleton_sup, start_link, []},
            type => supervisor
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}}.
