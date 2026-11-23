%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for chappe_rtpengine_client processes, one per rtpengine node.
%% Clients are added at runtime through chappe_rtpengine:add_node/2.
-module(chappe_rtpengine_client_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{
        id => chappe_rtpengine_client,
        start => {chappe_rtpengine_client, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker
    },
    {ok, {SupFlags, [Child]}}.
