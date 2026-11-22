%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc ws_handler bridging a WebSocket session to the owning chappe_rtpengine_client.
%%
%% init/2 runs inside the session start, so rejecting the negotiated
%% subprotocol here makes ws:connect/2 fail synchronously: a server
%% that does not grant ng.rtpengine.com never becomes connected.
%% Each inbound binary or text frame is one complete "Cookie SP
%% bencode" message and is forwarded to the owning client as
%% {chappe_rtpengine_ws_frame, SessionPid, Frame}.
-module(chappe_rtpengine_ws_handler).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

-define(NG_SUBPROTOCOL, <<"ng.rtpengine.com">>).

init(Req, #{owner := _Owner} = State) ->
    Info = maps:get(response, Req, #{}),
    case maps:get(subprotocol, Info, undefined) of
        ?NG_SUBPROTOCOL -> {ok, State};
        Other -> {stop, {subprotocol_rejected, Other}}
    end.

handle_in({binary, Frame}, #{owner := Owner} = State) ->
    Owner ! {chappe_rtpengine_ws_frame, self(), Frame},
    {ok, State};
handle_in({text, Frame}, #{owner := Owner} = State) ->
    %% NG is bencode either way; some servers answer in text frames
    Owner ! {chappe_rtpengine_ws_frame, self(), Frame},
    {ok, State};
handle_in(_Other, State) ->
    {ok, State}.

handle_info(_Msg, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
