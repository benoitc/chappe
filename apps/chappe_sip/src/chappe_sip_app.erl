%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Application callback for chappe_sip.
-module(chappe_sip_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([insecure_cookie/1]).

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
            case chappe_sip_route:ensure_secret() of
                ok ->
                    ok = chappe_sip_metrics:setup(),
                    chappe_sip_sup:start_link();
                {error, _} = Err ->
                    Err
            end
    end.

stop(_State) ->
    ok.

%% Reject the shipped placeholder cookie (and the historical default). A
%% non-distributed node reports `nocookie' and passes; a host release with its
%% own cookie passes.
-spec insecure_cookie(atom()) -> boolean().
insecure_cookie(Cookie) ->
    lists:member(Cookie, ['CHANGE_ME_SET_NODE_COOKIE', chappe_sip]).
