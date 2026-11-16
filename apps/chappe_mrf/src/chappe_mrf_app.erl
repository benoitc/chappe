%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mrf_app).
-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

%% With the esl_port env set, the listener the FreeSWITCH dialplan socket
%% application connects back to starts with the app, on esl_ip and taking
%% the peers of esl_allow when those are set.
-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_Type, _Args) ->
    %% cluster: chappe_cluster starts first, so it stops after this app
    %% and the rooms can still hand their leases off in prep_stop/1
    ok =
        case application:get_env(chappe_mrf, cluster, none) of
            chappe_cluster ->
                {ok, _} = application:ensure_all_started(chappe_cluster),
                ok;
            _ ->
                ok
        end,
    {ok, Sup} = chappe_mrf_sup:start_link(),
    ok =
        case application:get_env(chappe_mrf, esl_port) of
            {ok, Port} ->
                Env = maps:from_list(application:get_all_env(chappe_mrf)),
                chappe_mrf:listen(Port, chappe_mrf:listener_opts(Env));
            undefined ->
                ok
        end,
    {ok, Sup}.

%% A clean stop on a cluster: before the rooms' processes and dialogs
%% end, each room hands its members off to a room of the same name on a
%% live node, within drain_ms (5000) in all (chappe_mrf_conf_move).
-spec prep_stop(term()) -> term().
prep_stop(State) ->
    _ =
        application:get_env(chappe_mrf, cluster, none) =:= chappe_cluster andalso
            chappe_mrf_conf_move:drain(
                application:get_env(chappe_mrf, drain_ms, 5000)
            ),
    State.

-spec stop(term()) -> ok.
stop(_State) ->
    _ = chappe_mrf:stop_listener(),
    ok.
