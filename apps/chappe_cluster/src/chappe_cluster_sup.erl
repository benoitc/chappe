%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The supervision tree, rest_for_one so that what depends on a process
%% restarts with it:
%%
%% - chappe_cluster's own pg scope, `chappe_cluster' (watchers, running
%%   singletons);
%% - the node's hybrid logical clock, `chappe_cluster_hlc' (hlc);
%% - the watch hub, before the member that feeds it;
%% - the lapse timer, before the agent: an agent crash leaves it armed;
%% - the node agent: the Ra system and member, renewals;
%% - the singleton supervisor, one contender per singleton name.
%%
%% This supervisor owns `chappe_cluster_tab' (chappe_cluster_tab), the
%% node's holders and liveness, so that no child's crash loses them.
-module(chappe_cluster_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ok = chappe_cluster_tab:new(),
    Children = [
        #{id => chappe_cluster_pg, start => {pg, start_link, [chappe_cluster]}},
        #{
            id => chappe_cluster_hlc,
            start =>
                {hlc, start_link, [
                    chappe_cluster_hlc,
                    wall_clock(),
                    chappe_cluster_config:get(hlc_max_offset_ms)
                ]}
        },
        #{
            id => chappe_cluster_watch,
            start => {chappe_cluster_watch, start_link, []}
        },
        #{
            id => chappe_cluster_lapse,
            start => {chappe_cluster_lapse, start_link, []}
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

%% The HLC's wall clock, the `wall_clock' env ({M, F, A}).
wall_clock() ->
    {M, F, A} = chappe_cluster_config:get(wall_clock),
    fun() -> erlang:apply(M, F, A) end.
