%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Outbound listener. Owns one listen socket and a linked acceptor loop. For
%% each connection FreeSWITCH opens, the acceptor checks the peer against the
%% `allow' list first: a refused peer is closed and counted, before any byte
%% is read or any process started. An allowed peer is admitted here, which
%% starts a chappe_esl_conn (outbound) under chappe_esl_outbound_sup unless
%% `max_pending' connections are still waiting for their channel data (the
%% new one is then closed and counted as busy). The acceptor transfers socket
%% ownership to the connection and activates it; the connection sends
%% "connect", reads the channel data within `first_frame_timeout', tells the
%% listener, and runs the user handler.
-module(chappe_esl_listener).
-behaviour(gen_server).

-export([start_link/1, stats/1]).
%% the acceptor's handoff, exported for the failed-handoff test only
-ifdef(TEST).
-export([handoff/2]).
-endif.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

%% Backoff after a transient accept error (e.g. emfile under fd exhaustion):
%% without it the loop spins at 100% CPU and floods the log, retrying the same
%% failing accept instantly. The sleep also rate-limits the warning.
-define(ACCEPT_ERROR_BACKOFF_MS, 100).
-define(MAX_PENDING, 64).
-define(FIRST_FRAME_TIMEOUT, 5000).

-record(state, {
    ref :: term(),
    ip :: inet:ip_address(),
    handler :: module(),
    handler_args :: term(),
    conn_opts :: map(),
    max_pending :: pos_integer(),
    listen :: gen_tcp:socket(),
    acceptor :: pid(),
    %% connections still waiting for their channel data
    pending = #{} :: #{pid() => reference()},
    counters = #{
        accepted => 0, refused => 0, busy => 0, first_frame_timeouts => 0
    } :: #{atom() => non_neg_integer()}
}).

-type state() :: #state{}.

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% Counters: accepted (connections started), refused (peers outside
%% `allow'), busy (closed past `max_pending'), first_frame_timeouts, and
%% pending (connections waiting for their channel data now).
-spec stats(pid()) -> #{atom() => term()}.
stats(Listener) ->
    gen_server:call(Listener, stats).

-spec init(map()) -> {ok, state()} | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    Port = maps:get(port, Opts),
    Handler = maps:get(handler, Opts),
    Args = maps:get(handler_args, Opts, undefined),
    ConnOpts = (maps:with([linger], Opts))#{
        listener => self(),
        first_frame_timeout =>
            maps:get(first_frame_timeout, Opts, ?FIRST_FRAME_TIMEOUT)
    },
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    %% validated by chappe_esl:start_listener/4
    {ok, Allow} = chappe_esl_cidr:parse_list(maps:get(allow, Opts, [])),
    ListenOpts = [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true},
        {backlog, maps:get(backlog, Opts, 128)}
        | ip_opts(Ip)
    ],
    case gen_tcp:listen(Port, ListenOpts) of
        {ok, Listen} ->
            Self = self(),
            Acceptor = spawn_link(fun() -> accept_loop(Self, Listen, Allow) end),
            {ok, #state{
                ref = maps:get(ref, Opts, Port),
                ip = Ip,
                handler = Handler,
                handler_args = Args,
                conn_opts = ConnOpts,
                max_pending = maps:get(max_pending, Opts, ?MAX_PENDING),
                listen = Listen,
                acceptor = Acceptor
            }};
        {error, Reason} ->
            {stop, {listen_failed, Reason}}
    end.

handle_call(admit, _From, State) ->
    admit(State);
handle_call(stats, _From, #state{} = State) ->
    #state{counters = C, pending = P, ip = Ip, ref = Ref} = State,
    {reply, C#{pending => map_size(P), ip => Ip, ref => Ref}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({refused, Peer}, State) ->
    ?LOG_INFO("chappe_esl_listener: refused peer ~p (not in allow)", [Peer]),
    {noreply, bump(refused, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #state{acceptor = Pid} = State) ->
    {stop, {acceptor_down, Reason}, State};
handle_info({chappe_esl_listener, Conn, ready}, State) ->
    {noreply, settle(Conn, State)};
handle_info({chappe_esl_listener, Conn, first_frame_timeout}, State) ->
    {noreply, bump(first_frame_timeouts, settle(Conn, State))};
handle_info({'DOWN', _Mon, process, Conn, _Reason}, State) ->
    {noreply, settle(Conn, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen = Listen}) ->
    _ = gen_tcp:close(Listen),
    ok.

%% internal

%% Start a connection for an accepted socket, unless max_pending are still
%% waiting for their channel data.
admit(#state{pending = P, max_pending = Max} = State) when
    map_size(P) >= Max
->
    {reply, busy, bump(busy, State)};
admit(#state{handler = H, handler_args = A, conn_opts = O} = State) ->
    case chappe_esl_outbound_sup:start_conn(H, A, O) of
        {ok, Conn} ->
            P = (State#state.pending)#{Conn => monitor(process, Conn)},
            {reply, {ok, Conn}, bump(accepted, State#state{pending = P})};
        {error, Reason} ->
            ?LOG_WARNING("chappe_esl_listener: start_conn failed ~p", [Reason]),
            {reply, {error, Reason}, State}
    end.

%% The connection has its channel data, or is gone: it no longer counts.
settle(Conn, #state{pending = P} = State) ->
    case maps:take(Conn, P) of
        {Mon, P1} ->
            demonitor(Mon, [flush]),
            State#state{pending = P1};
        error ->
            State
    end.

bump(Key, #state{counters = C} = State) ->
    State#state{counters = maps:update_with(Key, fun(N) -> N + 1 end, C)}.

%% An IPv6 address needs inet6.
ip_opts({_, _, _, _} = Ip) -> [{ip, Ip}];
ip_opts(Ip) -> [inet6, {ip, Ip}].

accept_loop(Owner, Listen, Allow) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            screen(Owner, Socket, Allow),
            accept_loop(Owner, Listen, Allow);
        {error, closed} ->
            ok;
        {error, Reason} ->
            ?LOG_WARNING("chappe_esl_listener: accept error ~p", [Reason]),
            timer:sleep(?ACCEPT_ERROR_BACKOFF_MS),
            accept_loop(Owner, Listen, Allow)
    end.

%% No allow list takes every peer that reaches the bound address.
screen(Owner, Socket, []) ->
    handoff(Owner, Socket);
screen(Owner, Socket, Allow) ->
    case inet:peername(Socket) of
        {ok, {Ip, _Port} = Peer} ->
            case chappe_esl_cidr:member(Ip, Allow) of
                true -> handoff(Owner, Socket);
                false -> refuse(Owner, Socket, Peer)
            end;
        {error, Reason} ->
            refuse(Owner, Socket, Reason)
    end.

%% counted before the close, so a peer that sees the close also sees the
%% count in listener_stats/1
refuse(Owner, Socket, Peer) ->
    gen_server:cast(Owner, {refused, Peer}),
    _ = gen_tcp:close(Socket),
    ok.

handoff(Owner, Socket) ->
    case gen_server:call(Owner, admit, infinity) of
        {ok, Conn} ->
            case gen_tcp:controlling_process(Socket, Conn) of
                ok ->
                    chappe_esl_conn:activate(Conn, Socket);
                {error, _} ->
                    %% the connection would wait for a socket that never
                    %% comes, holding a max_pending slot
                    _ = gen_tcp:close(Socket),
                    chappe_esl_outbound_sup:stop_conn(Conn)
            end;
        busy ->
            gen_tcp:close(Socket);
        {error, _Reason} ->
            gen_tcp:close(Socket)
    end.
