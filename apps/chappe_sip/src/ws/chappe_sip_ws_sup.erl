%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for the SIP-over-WebSocket subsystem.
%%
%% Owns chappe_sip_ws_transport (always running, holds WS connection and
%% transaction state) and, on demand, a chappe_sip_ws_listener child started by
%% chappe_sip:start/1's ws' option. Sits under chappe_sip_sup, above the stack
%% supervisor, so WS state survives sofia engine restarts.
-module(chappe_sip_ws_sup).
-behaviour(supervisor).

-export([start_link/0, start_listener/1, stop_listener/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => chappe_sip_ws_transport,
            start => {chappe_sip_ws_transport, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [chappe_sip_ws_transport]
        }
    ],
    {ok, {SupFlags, Children}}.

%% Start (or replace) the WS listener on the given options (#{port := P}).
-spec start_listener(map()) -> {ok, pid()} | {error, term()}.
start_listener(Opts) ->
    %% bring livery (and its WS/HTTP dep tree) up only now that WS is used
    {ok, _} = application:ensure_all_started(livery),
    _ = stop_listener(),
    Child = #{
        id => chappe_sip_ws_listener,
        start => {chappe_sip_ws_listener, start_link, [Opts]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_ws_listener]
    },
    supervisor:start_child(?MODULE, Child).

-spec stop_listener() -> ok.
stop_listener() ->
    _ = supervisor:terminate_child(?MODULE, chappe_sip_ws_listener),
    _ = supervisor:delete_child(?MODULE, chappe_sip_ws_listener),
    ok.
