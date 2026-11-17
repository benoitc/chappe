%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mrf_app).
-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).

%% With the esl_port env set, the listener the FreeSWITCH dialplan socket
%% application connects back to starts with the app, on esl_ip and taking
%% the peers of esl_allow when those are set.
%%
%% With cluster => chappe_cluster, chappe_cluster starts here, before
%% this app's supervisor: it then stops after this app, so the rooms can
%% still hand their leases off in prep_stop/1. It is not in
%% `applications' (nor `optional_applications', which would start it
%% before this app in every mode): a release that runs a cluster includes
%% it as {chappe_cluster, load}, and one without it is refused here.
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    ok = chappe_mrf_conf_move:draining(false),
    case cluster(application:get_env(chappe_mrf, cluster, none)) of
        ok -> start_sup();
        {error, _} = Err -> Err
    end.

cluster(none) ->
    ok;
cluster(chappe_cluster) ->
    case application:load(chappe_cluster) of
        Loaded when
            Loaded =:= ok; Loaded =:= {error, {already_loaded, chappe_cluster}}
        ->
            case application:ensure_all_started(chappe_cluster) of
                {ok, _} -> ok;
                {error, Why} -> {error, {cluster, Why}}
            end;
        {error, Why} ->
            {error, {cluster, {chappe_cluster_not_installed, Why}}}
    end;
cluster(Other) ->
    {error, {cluster, {badarg, Other}}}.

start_sup() ->
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
