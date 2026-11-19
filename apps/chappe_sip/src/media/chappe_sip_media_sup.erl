%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for the media control-plane subsystem.
%%
%% Sits under chappe_sip_sup, above the stack supervisor, so media backend
%% state survives SIP engine restarts. It starts empty; the media libraries
%% (chappe_rtpengine, chappe_mix) stay dormant until
%% chappe_sip_media:configure/1 brings a backend up with ensure_app/1
%% (mirroring chappe_sip_ws_sup's lazy application:ensure_all_started of
%% livery). rtpengine supervises its own sessions inside chappe_rtpengine;
%% the conference room server (chappe_sip_media_mix) is added here as a
%% child when the mix backend is configured.
-module(chappe_sip_media_sup).
-behaviour(supervisor).

-export([start_link/0, ensure_app/1, start_child/1]).
-ifdef(TEST).
-export([stop_child/1]).
-endif.
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok, {SupFlags, []}}.

%% Bring a dormant media library up on demand.
-spec ensure_app(atom()) -> ok | {error, term()}.
ensure_app(App) ->
    case application:ensure_all_started(App) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.

%% Add a backend-owned child (the conference room server for chappe_mix).
-spec start_child(supervisor:child_spec()) ->
    {ok, pid()} | {error, term()}.
start_child(Spec) ->
    supervisor:start_child(?MODULE, Spec).

-ifdef(TEST).
-spec stop_child(term()) -> ok.
stop_child(Id) ->
    _ = supervisor:terminate_child(?MODULE, Id),
    _ = supervisor:delete_child(?MODULE, Id),
    ok.
-endif.
