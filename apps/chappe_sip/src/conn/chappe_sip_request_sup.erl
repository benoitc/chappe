%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for per-request workers (temporary: a crashed worker
%% is not restarted; the engine's monitor answers 500 if no final
%% response went out).
-module(chappe_sip_request_sup).
-behaviour(supervisor).

-export([start_link/0, start_worker/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_worker(map()) -> {ok, pid()} | {error, term()}.
start_worker(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 10
    },
    Child = #{
        id => chappe_sip_request_worker,
        start => {chappe_sip_request_worker, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_request_worker]
    },
    {ok, {SupFlags, [Child]}}.
