%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% DTMF event listener.
%%
%% rtpengine reports detected DTMF digits as one JSON datagram per
%% event when started with --dtmf-log-dest=IP:PORT. This server owns
%% that listening socket and dispatches events to subscribers by
%% call-id as {chappe_rtpengine_dtmf, CallId, Event} messages, where Event is
%%   #{code, digit, duration, volume, source_tag, timestamp, raw}
%% with digit the ASCII character ($0..$9, $*, $#, $A..$D) and raw the
%% decoded JSON object.
%%
%% The listener is disabled until opened: set the application
%% environment {dtmf_listen, Port} or call open/1. Point rtpengine's
%% --dtmf-log-dest at this host and port. Sessions started with
%% dtmf => true subscribe themselves and forward events to their
%% owner as {chappe_rtpengine_session, Pid, {dtmf, Event}}.
-module(chappe_rtpengine_dtmf).
-behaviour(gen_server).

-export([start_link/0, open/1, close/0, port/0]).
-export([subscribe/1, unsubscribe/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

%% bag: {CallId, Pid}
-define(SUBS, chappe_rtpengine_dtmf_subs).
-define(ACTIVE_N, 64).
-define(CALL_TIMEOUT, 5000).

-record(state, {
    socket :: gen_udp:socket() | undefined,
    port :: inet:port_number() | undefined,
    monitors = #{} :: #{reference() => {binary(), pid()}}
}).

-type state() :: #state{}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Open (or move) the listening socket. Port 0 picks an ephemeral
%% port; the actual one is returned.
-spec open(inet:port_number()) ->
    {ok, inet:port_number()} | {error, term()}.
open(Port) ->
    gen_server:call(?MODULE, {open, Port}, ?CALL_TIMEOUT).

-spec close() -> ok.
close() ->
    gen_server:call(?MODULE, close, ?CALL_TIMEOUT).

-spec port() -> inet:port_number() | undefined.
port() ->
    gen_server:call(?MODULE, port, ?CALL_TIMEOUT).

%% The calling process receives {chappe_rtpengine_dtmf, CallId, Event} for every
%% DTMF event on that call until it unsubscribes or dies.
-spec subscribe(binary()) -> ok.
subscribe(CallId) ->
    gen_server:call(?MODULE, {subscribe, CallId, self()}, ?CALL_TIMEOUT).

-spec unsubscribe(binary()) -> ok.
unsubscribe(CallId) ->
    gen_server:call(?MODULE, {unsubscribe, CallId, self()}, ?CALL_TIMEOUT).

%% gen_server callbacks

init([]) ->
    ?SUBS = ets:new(?SUBS, [named_table, bag, protected]),
    case application:get_env(chappe_rtpengine, dtmf_listen) of
        {ok, Port} when is_integer(Port) ->
            case open_socket(Port) of
                {ok, Socket, ActualPort} ->
                    {ok, #state{socket = Socket, port = ActualPort}};
                {error, Reason} ->
                    {stop, {dtmf_listen_failed, Reason}}
            end;
        undefined ->
            {ok, #state{}}
    end.

handle_call({open, Port}, _From, State0) ->
    State = close_socket(State0),
    case open_socket(Port) of
        {ok, Socket, ActualPort} ->
            {reply, {ok, ActualPort}, State#state{
                socket = Socket, port = ActualPort
            }};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(close, _From, State) ->
    {reply, ok, close_socket(State)};
handle_call(port, _From, State) ->
    {reply, State#state.port, State};
handle_call({subscribe, CallId, Pid}, _From, State) ->
    case lists:member({CallId, Pid}, ets:lookup(?SUBS, CallId)) of
        true ->
            {reply, ok, State};
        false ->
            ets:insert(?SUBS, {CallId, Pid}),
            Mon = erlang:monitor(process, Pid),
            Monitors = maps:put(Mon, {CallId, Pid}, State#state.monitors),
            {reply, ok, State#state{monitors = Monitors}}
    end;
handle_call({unsubscribe, CallId, Pid}, _From, State) ->
    ets:delete_object(?SUBS, {CallId, Pid}),
    Monitors = maps:filter(
        fun(Mon, Entry) ->
            case Entry =:= {CallId, Pid} of
                true ->
                    erlang:demonitor(Mon, [flush]),
                    false;
                false ->
                    true
            end
        end,
        State#state.monitors
    ),
    {reply, ok, State#state{monitors = Monitors}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, Socket, _IP, _Port, Packet}, #state{socket = Socket} = State) ->
    dispatch(Packet),
    {noreply, State};
handle_info({udp_passive, Socket}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, ?ACTIVE_N}]),
    {noreply, State};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, State) ->
    case maps:take(Mon, State#state.monitors) of
        {{CallId, Pid}, Monitors} ->
            ets:delete_object(?SUBS, {CallId, Pid}),
            {noreply, State#state{monitors = Monitors}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% internal

open_socket(Port) ->
    SockOpts = [binary, {active, ?ACTIVE_N}, {recbuf, 65535}],
    case gen_udp:open(Port, SockOpts) of
        {ok, Socket} ->
            {ok, ActualPort} = inet:port(Socket),
            {ok, Socket, ActualPort};
        {error, Reason} ->
            {error, Reason}
    end.

-spec close_socket(state()) -> state().
close_socket(#state{socket = undefined} = State) ->
    State;
close_socket(#state{socket = Socket} = State) ->
    gen_udp:close(Socket),
    State#state{socket = undefined, port = undefined}.

dispatch(Packet) ->
    try json:decode(Packet) of
        #{<<"callid">> := CallId} = Decoded when is_binary(CallId) ->
            deliver(CallId, event(Decoded));
        Other ->
            ?LOG_DEBUG("chappe_rtpengine_dtmf: datagram without callid: ~p", [
                Other
            ])
    catch
        _:_ ->
            ?LOG_WARNING(
                "chappe_rtpengine_dtmf: undecodable datagram (~p bytes)", [
                    byte_size(Packet)
                ]
            )
    end.

deliver(CallId, Event) ->
    lists:foreach(
        fun({_, Pid}) -> Pid ! {chappe_rtpengine_dtmf, CallId, Event} end,
        ets:lookup(?SUBS, CallId)
    ).

event(Decoded) ->
    Code = maps:get(<<"event">>, Decoded, undefined),
    #{
        code => Code,
        digit => digit(Code),
        duration => maps:get(<<"duration">>, Decoded, undefined),
        volume => maps:get(<<"volume">>, Decoded, undefined),
        source_tag => maps:get(<<"source_tag">>, Decoded, undefined),
        timestamp => maps:get(<<"timestamp">>, Decoded, undefined),
        raw => Decoded
    }.

digit(N) when is_integer(N), N >= 0, N =< 9 -> $0 + N;
digit(10) -> $*;
digit(11) -> $#;
digit(N) when is_integer(N), N >= 12, N =< 15 -> $A + N - 12;
digit(_) -> undefined.
