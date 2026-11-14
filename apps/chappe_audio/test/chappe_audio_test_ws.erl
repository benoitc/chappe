%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A WebSocket client standing in for a fork module in the suites: every
%% message from the server comes to the test as {ws_client, Pid, Msg},
%% and the end of the session as {ws_client, Pid, {closed, Reason}}.
-module(chappe_audio_test_ws).
-behaviour(ws_handler).

-export([connect/1, connect/2, send/2]).
-export([init/2, handle_in/2, handle_info/2, terminate/2]).

connect(Url) ->
    connect(Url, #{}).

connect(Url, Opts) ->
    ws:connect(Url, Opts#{
        handler => ?MODULE,
        handler_opts => #{to => self()}
    }).

send(Pid, Frames) ->
    ws:send(Pid, Frames).

init(_Req, State) ->
    {ok, State}.

handle_in(Msg, #{to := To} = State) ->
    To ! {ws_client, self(), Msg},
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(Reason, #{to := To}) ->
    To ! {ws_client, self(), {closed, Reason}},
    ok.
