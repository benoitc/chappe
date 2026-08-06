%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc WebSocket connection handler (RFC 7118 SIP-over-WS).
%%
%% One process per WS connection (the ws_session). init registers the
%% connection with chappe_sip_ws_transport and gets a Flow id; inbound text
%% frames (one SIP message each) are fed to the transport; the connection
%% is dropped on terminate. Outbound frames are sent directly with
%% ws:send/2 by the transport, so handle_info is a no-op.
-module(chappe_sip_ws_conn).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

init(Req, _Opts) ->
    %% livery carries the client peer {IpAddress, Port} in the WS Req, read
    %% from the accepted socket; used for SIP Via received/rport.
    Peer = maps:get(peer, Req, undefined),
    case chappe_sip_ws_transport:connect(self(), Peer) of
        {ok, Flow} ->
            %% if the transport dies it loses our flow mapping and we become a
            %% deaf zombie; close so the client reconnects and re-registers
            TMon = erlang:monitor(process, chappe_sip_ws_transport),
            {ok, #{flow => Flow, tmon => TMon}};
        {error, Reason} ->
            %% at the connection cap: refuse this session
            {stop, Reason}
    end.

handle_in({text, Bytes}, #{flow := Flow} = S) ->
    ok = chappe_sip_ws_transport:incoming(Flow, Bytes),
    {ok, S};
handle_in(_Frame, S) ->
    {ok, S}.

handle_info({'DOWN', TMon, process, _, _}, #{tmon := TMon} = S) ->
    {stop, transport_down, S};
handle_info(_Msg, S) ->
    {ok, S}.

terminate(_Reason, #{flow := Flow}) ->
    chappe_sip_ws_transport:disconnect(Flow),
    ok;
terminate(_Reason, _S) ->
    ok.
