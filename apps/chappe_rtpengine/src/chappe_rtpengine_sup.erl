%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Root supervisor. rest_for_one so that when the node registry (pool,
%% added later) restarts, the client supervisor restarts after it.
-module(chappe_rtpengine_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => chappe_rtpengine_pool,
            start => {chappe_rtpengine_pool, start_link, []},
            shutdown => 5000
        },
        #{
            id => chappe_rtpengine_dtmf,
            start => {chappe_rtpengine_dtmf, start_link, []},
            shutdown => 5000
        },
        #{
            id => chappe_rtpengine_client_sup,
            start => {chappe_rtpengine_client_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        },
        #{
            id => chappe_rtpengine_session_sup,
            start => {chappe_rtpengine_session_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        }
    ],
    {ok, {SupFlags, Children}}.
