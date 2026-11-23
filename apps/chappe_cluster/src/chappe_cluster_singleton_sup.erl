%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The node's singletons: one chappe_cluster_singleton per name this node
%% contends for (one_for_one, id = the name). The contender that holds the
%% name's lease runs the child under a supervisor of its own, linked to it
%% (the `{child, Spec}' clause), so the child never outlives the contender
%% and its lease.
-module(chappe_cluster_singleton_sup).
-behaviour(supervisor).

-export([start_link/0, start_child_sup/1, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

%% The supervisor of one running singleton, linked to its caller.
-spec start_child_sup(supervisor:child_spec()) -> {ok, pid()} | {error, term()}.
start_child_sup(Spec) ->
    supervisor:start_link(?MODULE, {child, Spec}).

init(top) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}};
init({child, Spec}) ->
    %% the child does not restart here: its contender sees it go, gives
    %% the lease back and contends again, so another node may run it
    {ok,
        {#{strategy => one_for_one, intensity => 0, period => 1}, [
            Spec#{restart => temporary}
        ]}}.
