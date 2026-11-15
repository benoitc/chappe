%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mrf_app).
-behaviour(application).

-export([start/2, stop/1]).

%% With the esl_port env set, the listener the FreeSWITCH dialplan socket
%% application connects back to starts with the app, on esl_ip and taking
%% the peers of esl_allow when those are set.
-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_Type, _Args) ->
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

-spec stop(term()) -> ok.
stop(_State) ->
    _ = chappe_mrf:stop_listener(),
    ok.
