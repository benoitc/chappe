%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The chappe_rtpengine application: starts the root supervisor.
-module(chappe_rtpengine_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    chappe_rtpengine_sup:start_link().

stop(_State) ->
    ok.
