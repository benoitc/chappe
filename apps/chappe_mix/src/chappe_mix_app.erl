%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ok = chappe_mix_g711:init(),
    chappe_mix_sup:start_link().

stop(_State) ->
    ok.
