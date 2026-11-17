%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Application callback for chappe_sip.
-module(chappe_sip_app).
-behaviour(application).

-export([start/2, prep_stop/1, stop/1]).
-ifdef(TEST).
-export([insecure_cookie/1]).
-endif.

start(_Type, _Args) ->
    case insecure_cookie(erlang:get_cookie()) of
        true ->
            %% a reachable node with a known cookie is remote code execution;
            %% refuse to boot until NODE_COOKIE is set to a real secret
            {error, insecure_distribution_cookie};
        false ->
            %% seed the per-node Record-Route/flow-token secret before any
            %% request worker can mint or validate a route marker; a
            %% configured secret that is too short stops the boot
            case
                {
                    chappe_sip_flow:ensure_secret(),
                    chappe_sip_config:check_cluster()
                }
            of
                {ok, ok} ->
                    start_cluster(chappe_sip_config:get(cluster));
                {{error, _} = Err, _} ->
                    Err;
                {ok, {error, _} = Err} ->
                    Err
            end
    end.

%% With cluster => chappe_cluster, chappe_cluster starts here, before the
%% top supervisor: the application controller then stops it after
%% chappe_sip, so prep_stop/1 still finds it and withdraws the registry
%% sweep. It is not in `applications' (nor `optional_applications', which
%% would start it in every mode): a release that runs a cluster includes
%% it as {chappe_cluster, load}. With cluster => none it stays unstarted.
start_cluster(chappe_cluster) ->
    case application:ensure_all_started(chappe_cluster) of
        {ok, _} -> start_sup();
        {error, Why} -> {error, {cluster, Why}}
    end;
start_cluster(_None) ->
    start_sup().

start_sup() ->
    ok = chappe_sip_metrics:setup(),
    chappe_sip_sup:start_link().

%% on a cluster, hand the registry sweep to another node first
prep_stop(State) ->
    ok = chappe_sip_registry:leave_cluster(),
    State.

stop(_State) ->
    ok.

%% Reject the shipped placeholder cookie (and the historical default). A
%% non-distributed node reports `nocookie' and passes; a host release with its
%% own cookie passes.
-spec insecure_cookie(atom()) -> boolean().
insecure_cookie(Cookie) ->
    lists:member(Cookie, ['CHANGE_ME_SET_NODE_COOKIE', chappe_sip]).
