%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% ws_handler for the fake rtpengine WebSocket node: every binary
%% frame goes to the fake's control process, which decides what (and
%% when) to send back by messaging the session:
%%   {send, Bin}       send Bin as one binary frame
%%   {send_text, Bin}  send Bin as one text frame
%%   close        close the connection
-module(chappe_rtpengine_fake_ws_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, State) ->
    {ok, State}.

handle_in({binary, Frame}, #{control := Control} = State) ->
    Control ! {ws_frame, self(), Frame},
    {ok, State};
handle_in(_Other, State) ->
    {ok, State}.

handle_info({send, Bin}, State) ->
    {reply, {binary, Bin}, State};
handle_info({send_text, Bin}, State) ->
    {reply, {text, Bin}, State};
handle_info(close, State) ->
    {stop, normal, State};
handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
