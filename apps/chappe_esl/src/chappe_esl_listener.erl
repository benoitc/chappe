%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Outbound listener. Owns one listen socket and a linked acceptor loop. For
%% each connection FreeSWITCH opens, it starts a chappe_esl_conn (outbound) under
%% chappe_esl_outbound_sup, transfers socket ownership to it, and activates it. The
%% connection then sends "connect", reads the channel data, and runs the
%% user handler.
-module(chappe_esl_listener).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

%% Backoff after a transient accept error (e.g. emfile under fd exhaustion):
%% without it the loop spins at 100% CPU and floods the log, retrying the same
%% failing accept instantly. The sleep also rate-limits the warning.
-define(ACCEPT_ERROR_BACKOFF_MS, 100).

-record(state, {
    ref :: term(),
    handler :: module(),
    handler_args :: term(),
    listen :: gen_tcp:socket(),
    acceptor :: pid()
}).

-type state() :: #state{}.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec init(map()) -> {ok, state()} | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    Port = maps:get(port, Opts),
    Handler = maps:get(handler, Opts),
    Args = maps:get(handler_args, Opts, undefined),
    ConnOpts = maps:with([linger], Opts),
    ListenOpts = [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {backlog, maps:get(backlog, Opts, 128)}
    ],
    case gen_tcp:listen(Port, ListenOpts) of
        {ok, Listen} ->
            Self = self(),
            Acceptor = spawn_link(fun() ->
                accept_loop(Self, Listen, Handler, Args, ConnOpts)
            end),
            {ok, #state{
                ref = maps:get(ref, Opts, Port),
                handler = Handler,
                handler_args = Args,
                listen = Listen,
                acceptor = Acceptor
            }};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #state{acceptor = Pid} = State) ->
    {stop, {acceptor_down, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen = Listen}) ->
    _ = gen_tcp:close(Listen),
    ok.

%% internal

accept_loop(Owner, Listen, Handler, Args, ConnOpts) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            handoff(Socket, Handler, Args, ConnOpts),
            accept_loop(Owner, Listen, Handler, Args, ConnOpts);
        {error, closed} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING("chappe_esl_listener: accept error ~p", [Reason]),
            timer:sleep(?ACCEPT_ERROR_BACKOFF_MS),
            accept_loop(Owner, Listen, Handler, Args, ConnOpts)
    end.

handoff(Socket, Handler, Args, ConnOpts) ->
    case chappe_esl_outbound_sup:start_conn(Handler, Args, ConnOpts) of
        {ok, Conn} ->
            ok = gen_tcp:controlling_process(Socket, Conn),
            ok = chappe_esl_conn:activate(Conn, Socket);
        {error, Reason} ->
            ?LOG_WARNING("chappe_esl_listener: start_conn failed ~p", [Reason]),
            gen_tcp:close(Socket)
    end.
