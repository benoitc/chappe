%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_cluster_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    case chappe_cluster_config:load() of
        ok -> chappe_cluster_sup:start_link();
        {error, badarg} = E -> E
    end.

stop(_State) ->
    ok.
