%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc WebSocket connection handler (RFC 7118 SIP-over-WS).
%%
%% One process per WS connection (the ws_session). init registers the
%% connection with chappe_sip_ws_transport and gets a Flow id; inbound text
%% and binary frames (one SIP message each, RFC 7118 4.2) are fed to the
%% transport; the connection is dropped on terminate. Outbound frames are
%% sent directly with ws:send/2 by the transport.
%%
%% The connection pings the client every ws_ping_interval_ms. The pong is
%% inbound traffic, so the session's idle timeout (ws_idle_timeout_ms) only
%% reaps a connection whose client stopped answering.
-module(chappe_sip_ws_conn).
-behaviour(ws_handler).

-export([init/2, handle_in/2, handle_info/2, terminate/2]).

%% RFC 6455 7.4.1: the message is too big to process
-define(TOO_BIG, 1009).

init(Req, Opts) ->
    %% livery carries the client peer {IpAddress, Port} in the WS Req, read
    %% from the accepted socket; used for SIP Via received/rport.
    Peer = maps:get(peer, Req, undefined),
    Proto = maps:get(proto, Opts, ws),
    case chappe_sip_ws_transport:connect(self(), Peer, Proto) of
        {ok, Flow} ->
            %% if the transport dies it loses our flow mapping and we become a
            %% deaf zombie; close so the client reconnects and re-registers
            TMon = erlang:monitor(process, chappe_sip_ws_transport),
            arm_ping(),
            {ok, #{flow => Flow, tmon => TMon}};
        {error, Reason} ->
            %% at the connection cap: refuse this session
            {stop, Reason}
    end.

handle_in({text, Bytes}, S) ->
    message_in(Bytes, S);
handle_in({binary, Bytes}, S) ->
    message_in(Bytes, S);
handle_in(_Frame, S) ->
    {ok, S}.

%% A message past max_message_size is not handed on; the connection is
%% closed with 1009 instead, so the client learns why.
message_in(Bytes, #{flow := Flow} = S) ->
    case byte_size(Bytes) > chappe_sip_config:get(max_message_size) of
        true ->
            ok = ws:close(self(), ?TOO_BIG, <<"message too big">>),
            {ok, S};
        false ->
            ok = chappe_sip_ws_transport:incoming(Flow, Bytes),
            {ok, S}
    end.

handle_info(ws_ping, S) ->
    arm_ping(),
    {reply, {ping, <<>>}, S};
handle_info({'DOWN', TMon, process, _, _}, #{tmon := TMon} = S) ->
    {stop, transport_down, S};
handle_info(_Msg, S) ->
    {ok, S}.

terminate(_Reason, #{flow := Flow}) ->
    chappe_sip_ws_transport:disconnect(Flow),
    ok;
terminate(_Reason, _S) ->
    ok.

arm_ping() ->
    case chappe_sip_config:get(ws_ping_interval_ms) of
        infinity -> ok;
        Ms -> _ = erlang:send_after(Ms, self(), ws_ping)
    end,
    ok.
