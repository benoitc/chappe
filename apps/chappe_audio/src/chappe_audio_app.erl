%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_audio_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    chappe_audio_sup:start_link().

stop(_State) ->
    ok.
