%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% A ws_handler used as the test WebSocket client: it forwards every text
%% frame (a SIP message) to the notify pid given in handler_opts as
%% {ws_in, Data}, every binary frame as {ws_in_bin, Data}, and its own end
%% as {ws_closed, Reason}.
-module(chappe_sip_ws_test_client).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, Opts) ->
    {ok, maps:get(notify, Opts)}.

handle_in({text, Data}, Pid) ->
    Pid ! {ws_in, Data},
    {ok, Pid};
handle_in({binary, Data}, Pid) ->
    Pid ! {ws_in_bin, Data},
    {ok, Pid};
handle_in(_Frame, Pid) ->
    {ok, Pid}.

handle_info(_Msg, Pid) ->
    {ok, Pid}.

terminate(Reason, Pid) ->
    Pid ! {ws_closed, Reason},
    ok.
