%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Root supervisor.
%%
%% Child order is deliberate:
%% 1. chappe_sip_registry_keeper: owns the location-store ETS, so the bindings
%%    survive a crash of the chappe_sip_registry gen_server (which holds the logic).
%% 2. chappe_sip_registry: the location store. It sits above the stack supervisor
%%    so its ETS survives SIP engine restarts.
%% 3. chappe_sip_dialog_index: sweeps index entries of dialog fsms that die
%%    without cleaning up (the table itself lives in the keeper). Above the
%%    stack so it sees the dialogs of an engine restart go down.
%% 3b. chappe_sip_refer_sup: REFER subscriptions and their registry; each
%%    subscription watches its dialog, so it too sits above the stack.
%% 4. chappe_sip_ws_sup / chappe_sip_media_sup: optional subsystems (WS transport, media
%%    control plane). They sit above the stack so their state (and the media
%%    backend connections) survive SIP engine restarts; both are populated
%%    lazily and stay empty unless configured.
%% 5. chappe_sip_stack_sup: the SIP engine and per-call state (rest_for_one);
%%    everything there dies with the engine.
-module(chappe_sip_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children = [
        worker(chappe_sip_registry_keeper),
        worker(chappe_sip_registry),
        worker(chappe_sip_dialog_index),
        sup(chappe_sip_refer_sup),
        sup(chappe_sip_ws_sup),
        sup(chappe_sip_media_sup),
        sup(chappe_sip_stack_sup)
    ],
    {ok, {SupFlags, Children}}.

worker(Mod) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Mod]
    }.

sup(Mod) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [Mod]
    }.
