%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for per-call media sessions. Sessions are temporary:
%% a crashed session must not restart, because its rtpengine state
%% and its owner's call context are gone; terminate/3 already made
%% the best-effort delete.
-module(chappe_rtpengine_session_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{
        id => chappe_rtpengine_session,
        start => {chappe_rtpengine_session, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker
    },
    {ok, {SupFlags, [Child]}}.
