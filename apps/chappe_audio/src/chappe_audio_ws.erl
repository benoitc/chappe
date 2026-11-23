%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The ws_handler of a stream's connection. It runs in the ws_session
%% process and only relays: each message in goes to the stream as
%% {chappe_audio_ws, Session, {binary | text, Data}}, and a message over
%% the stream's max_frame as {chappe_audio_ws, Session, too_large} (the
%% stream then closes with 1009). Pings are answered by the session
%% before they reach here.
-module(chappe_audio_ws).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(_Req, #{stream := _} = State) ->
    {ok, State}.

handle_in({_, Data}, #{stream := Stream, max := Max} = State) when
    byte_size(Data) > Max
->
    Stream ! {chappe_audio_ws, self(), too_large},
    {ok, State};
handle_in({binary, Data}, #{stream := Stream} = State) ->
    Stream ! {chappe_audio_ws, self(), {binary, Data}},
    {ok, State};
handle_in({text, Data}, #{stream := Stream} = State) ->
    Stream ! {chappe_audio_ws, self(), {text, Data}},
    {ok, State};
handle_in(_Other, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
