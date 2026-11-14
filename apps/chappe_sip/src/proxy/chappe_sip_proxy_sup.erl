%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor of the proxy's RFC 6026 Accepted-state processes
%% (chappe_sip_proxy_accepted), one temporary child per proxied INVITE. It
%% sits under chappe_sip_stack_sup, after the engine: the transactions the
%% children hold go away with the engine, and so do they.
-module(chappe_sip_proxy_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{
        id => chappe_sip_proxy_accepted,
        start => {chappe_sip_proxy_accepted, start_link, []},
        restart => temporary,
        shutdown => 2000,
        type => worker,
        modules => [chappe_sip_proxy_accepted]
    },
    {ok, {SupFlags, [Child]}}.
