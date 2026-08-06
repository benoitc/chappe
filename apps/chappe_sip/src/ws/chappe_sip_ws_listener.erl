%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Holder for a livery WebSocket listener.
%%
%% Starts a livery H1 service that upgrades GET /ws' to chappe_sip_ws_conn, and
%% stops it on terminate. Started on demand by chappe_sip_ws_sup when chappe_sip:start/1
%% (or chappe_sip:ws_listen/1) is given a ws' option.
-module(chappe_sip_ws_listener).
-behaviour(gen_server).

-export([start_link/1, ws_route/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% livery route handler: upgrade to chappe_sip_ws_conn, negotiating the sip'
%% subprotocol (RFC 7118) and disabling the idle timeout (SIP-over-WS
%% connections are long-lived). The peer reaches the handler in the WS Req
%% (livery reads it from the accepted socket).
ws_route(Req) ->
    case origin_allowed(livery_req:header(<<"origin">>, Req, undefined)) of
        true ->
            %% a finite idle timeout reaps half-open connections (a crashed
            %% browser); RFC 7118 clients keepalive, so an active UA never
            %% trips it
            livery_ws:upgrade(
                Req,
                chappe_sip_ws_conn,
                #{
                    subprotocols => [<<"sip">>],
                    idle_timeout =>
                        chappe_sip_config:get(ws_idle_timeout_ms)
                }
            );
        false ->
            livery_resp:text(403, <<"forbidden origin\n">>)
    end.

%% Gate the WS upgrade on an Origin allowlist (browser CSRF protection). Empty
%% allows any origin (and native clients that send none); a configured list
%% rejects everything not on it.
origin_allowed(Origin) ->
    case chappe_sip_config:get(ws_allowed_origins) of
        [] -> true;
        Allowed -> lists:member(Origin, Allowed)
    end.

init(#{port := Port}) ->
    Router = livery_router:compile([
        {<<"GET">>, <<"/ws">>, fun ?MODULE:ws_route/1}
    ]),
    case livery:start_service(#{http => #{port => Port}, router => Router}) of
        {ok, Pid} ->
            %% if the livery service dies, WS accepts silently stop; stop so the
            %% supervisor restarts us (and a fresh service)
            _ = erlang:monitor(process, Pid),
            {ok, #{svc => Pid}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, #{svc := Pid} = S) ->
    {stop, {livery_service_down, Reason}, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #{svc := Pid}) ->
    _ = livery:stop_service(Pid),
    ok;
terminate(_Reason, _S) ->
    ok.
