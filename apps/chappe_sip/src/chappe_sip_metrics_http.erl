%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The optional built-in metrics listener: GET /metrics on its own
%% HTTP port, served by chappe_sip_metrics:handler/0.
%%
%% It starts at boot when the `metrics' application setting is a map with
%% a port, `#{port := Port, ip => Ip}', and on demand with
%% chappe_sip_metrics:listen/1. The address defaults to 127.0.0.1, so the
%% metrics are not on a public interface unless you ask. A listener that
%% cannot bind fails its start (at boot, the application's). The livery
%% service is monitored: if it dies this process stops, and its supervisor
%% starts a fresh one from the application setting (a listener started by
%% listen/1 alone is not restarted).
-module(chappe_sip_metrics_http).
-behaviour(gen_server).

-export([start_link/0, listen/1, stop_listening/0, port/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(LOOPBACK, {127, 0, 0, 1}).

%% the livery service, its monitor and its port (undefined: not listening)
-record(state, {
    svc :: pid() | undefined,
    mref :: reference() | undefined,
    port :: inet:port_number() | undefined
}).
-type state() :: #state{}.

-spec init([]) -> {ok, state()} | {stop, term()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec listen(#{port := inet:port_number(), ip => inet:ip_address()}) ->
    ok | {error, term()}.
listen(Opts) ->
    case check(Opts) of
        {ok, Cfg} -> gen_server:call(?MODULE, {listen, Cfg}, 10000);
        error -> {error, badarg}
    end.

-spec stop_listening() -> ok.
stop_listening() ->
    gen_server:call(?MODULE, stop_listening).

%% the port it listens on, undefined when off
-spec port() -> inet:port_number() | undefined.
port() ->
    gen_server:call(?MODULE, port).

check(#{port := P} = Opts) when is_integer(P), P > 0, P =< 65535 ->
    Ip = maps:get(ip, Opts, ?LOOPBACK),
    case
        maps:keys(maps:without([port, ip], Opts)) =:= [] andalso
            is_ip(Ip)
    of
        true -> {ok, #{port => P, ip => Ip}};
        false -> error
    end;
check(_) ->
    error.

is_ip(Ip) when is_tuple(Ip) ->
    inet:is_ip_address(Ip);
is_ip(_) ->
    false.

init([]) ->
    process_flag(trap_exit, true),
    case application:get_env(chappe_sip, metrics, true) of
        #{} = Opts ->
            case check(Opts) of
                {ok, Cfg} ->
                    case start_svc(Cfg) of
                        {ok, S} -> {ok, S};
                        {error, Reason} -> {stop, {metrics_listener, Reason}}
                    end;
                error ->
                    {stop, {metrics_listener, {badarg, Opts}}}
            end;
        _ ->
            {ok, #state{}}
    end.

start_svc(#{port := Port, ip := Ip}) ->
    {ok, _} = application:ensure_all_started(livery),
    Router = livery_router:compile([
        {<<"GET">>, <<"/metrics">>, chappe_sip_metrics:handler()}
    ]),
    case
        livery:start_service(#{
            http => #{port => Port, ip => Ip}, router => Router
        })
    of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            {ok, #state{svc = Pid, mref = MRef, port = Port}};
        {error, _} = Err ->
            Err
    end.

handle_call({listen, Cfg}, _From, S) ->
    S1 = stop_svc(S),
    case start_svc(Cfg) of
        {ok, S2} -> {reply, ok, S2};
        {error, _} = Err -> {reply, Err, S1}
    end;
handle_call(stop_listening, _From, S) ->
    {reply, ok, stop_svc(S)};
handle_call(port, _From, S) ->
    {reply, S#state.port, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', MRef, process, _Pid, Reason}, #state{mref = MRef}) ->
    {stop, {livery_service_down, Reason}, #state{}};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    _ = stop_svc(S),
    ok.

stop_svc(#state{svc = Pid, mref = MRef}) when is_pid(Pid) ->
    erlang:demonitor(MRef, [flush]),
    _ = livery:stop_service(Pid),
    #state{};
stop_svc(S) ->
    S.
