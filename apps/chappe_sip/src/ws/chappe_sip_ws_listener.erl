%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Holder for the livery WebSocket listeners.
%%
%% Starts a livery H1 service that upgrades GET /ws' to chappe_sip_ws_conn on
%% the plain port, and another one over TLS (WSS) when a `tls' map is given,
%% and stops them on terminate. Started on demand by chappe_sip_ws_sup when
%% chappe_sip:start/1 (or chappe_sip:ws_listen/1) is given a ws' or wss' option.
%%
%% Opts: #{port => P, tls => #{port := P, cert_dir => Dir} |
%%                          #{port := P, certfile := F, keyfile := K}}.
%% cert_dir holds agent.pem (certificate and key), as for the SIP TLS
%% listener.
-module(chappe_sip_ws_listener).
-behaviour(gen_server).

-export([start_link/1, ws_route/1, wss_route/1, port/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% livery route handlers: upgrade to chappe_sip_ws_conn, requiring the sip'
%% subprotocol (RFC 7118 4.1: a client that does not offer it is refused).
%% The session closes a connection with no inbound traffic for
%% ws_idle_timeout_ms (a half-open one left by a crashed browser); the
%% connection pings the client more often than that, so a live client always
%% has traffic. The ws parser refuses a frame or a reassembled message past
%% max_message_size with 1009 before buffering it. The peer reaches the
%% handler in the WS Req (livery reads it from the accepted socket).
ws_route(Req) ->
    route(Req, ws).

wss_route(Req) ->
    route(Req, wss).

route(Req, Proto) ->
    case origin_allowed(livery_req:header(<<"origin">>, Req, undefined)) of
        true ->
            MaxSize = chappe_sip_config:get(max_message_size),
            livery_ws:upgrade(
                Req,
                chappe_sip_ws_conn,
                #{
                    subprotocols => [<<"sip">>],
                    idle_timeout =>
                        chappe_sip_config:get(ws_idle_timeout_ms),
                    max_frame_size => MaxSize,
                    max_message_size => MaxSize,
                    proto => Proto
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

init(Opts) ->
    case start_plain(Opts) of
        {ok, Plain} ->
            case start_tls(Opts) of
                {ok, Tls} ->
                    Svcs = [P || P <- [Plain, Tls], is_pid(P)],
                    %% if a livery service dies, WS accepts silently stop;
                    %% stop so the supervisor restarts us (and fresh services)
                    _ = [erlang:monitor(process, P) || P <- Svcs],
                    {ok, #{svcs => Svcs}};
                {error, Reason} ->
                    stop_svc(Plain),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

start_plain(#{port := Port}) ->
    remember(ws, Port),
    service(Port, #{}, fun ?MODULE:ws_route/1);
start_plain(_Opts) ->
    {ok, undefined}.

start_tls(#{tls := #{port := Port} = Tls}) ->
    case cert_files(Tls) of
        {ok, Cert, Key} ->
            remember(wss, Port),
            service(
                Port,
                #{
                    transport => ssl,
                    cert => Cert,
                    key => Key,
                    %% the floor of the SIP TLS listener
                    ssl_opts => [{versions, ['tlsv1.3', 'tlsv1.2']}]
                },
                fun ?MODULE:wss_route/1
            );
        {error, _} = Err ->
            Err
    end;
start_tls(#{tls := _}) ->
    {error, {wss, missing_port}};
start_tls(_Opts) ->
    {ok, undefined}.

cert_files(#{certfile := Cert, keyfile := Key}) ->
    {ok, Cert, Key};
cert_files(#{cert_dir := Dir}) ->
    Pem = filename:join(Dir, "agent.pem"),
    {ok, Pem, Pem};
cert_files(_Tls) ->
    {error, {wss, missing_certificate}}.

%% The port a listener was started on (HEP capture names it as our end).
-spec port(ws | wss) -> inet:port_number().
port(Proto) ->
    persistent_term:get({?MODULE, Proto}, 0).

remember(Proto, Port) ->
    case port(Proto) of
        Port -> ok;
        _ -> persistent_term:put({?MODULE, Proto}, Port)
    end.

service(Port, ListenOpts, Route) ->
    Router = livery_router:compile([{<<"GET">>, <<"/ws">>, Route}]),
    livery:start_service(#{
        http => ListenOpts#{port => Port}, router => Router
    }).

stop_svc(Pid) when is_pid(Pid) ->
    _ = livery:stop_service(Pid),
    ok;
stop_svc(_) ->
    ok.

handle_call(_Req, _From, S) ->
    {reply, ok, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', _Ref, process, Pid, Reason}, #{svcs := Svcs} = S) ->
    case lists:member(Pid, Svcs) of
        true -> {stop, {livery_service_down, Reason}, S};
        false -> {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #{svcs := Svcs}) ->
    _ = [stop_svc(P) || P <- Svcs],
    ok;
terminate(_Reason, _S) ->
    ok.
