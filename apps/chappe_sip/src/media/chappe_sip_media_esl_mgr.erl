%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc ESL control-connection manager for the FreeSWITCH media backend.
%%
%% Holds one inbound chappe_esl connection per configured FreeSWITCH node and
%% vends it to chappe_sip_media_freeswitch for control commands (execute / api). A
%% connection is opened lazily on first use and re-opened after it drops, so a
%% FreeSWITCH restart or a transient network fault self-heals. It lives under
%% chappe_sip_media_sup (added when the FreeSWITCH backend is configured), above the
%% SIP stack, so control connections survive engine restarts.
-module(chappe_sip_media_esl_mgr).
-behaviour(gen_server).

-export([start_link/1, conn/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CALL_TIMEOUT, 10000).

start_link(Nodes) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Nodes, []).

%% The live ESL connection for a node, connecting on demand.
-spec conn(atom()) -> {ok, pid()} | {error, term()}.
conn(Node) ->
    gen_server:call(?MODULE, {conn, Node}, ?CALL_TIMEOUT).

init(Nodes) ->
    process_flag(trap_exit, true),
    NodeMap = maps:from_list(
        [{maps:get(name, N), maps:without([name], N)} || N <- Nodes]
    ),
    {ok, #{nodes => NodeMap, conns => #{}, mons => #{}}}.

handle_call({conn, Node}, _From, State) ->
    case maps:find(Node, maps:get(conns, State)) of
        {ok, Pid} ->
            {reply, {ok, Pid}, State};
        error ->
            connect(Node, State)
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    {noreply, drop_conn(Ref, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
        fun(_Node, Pid) -> close_quietly(Pid) end,
        maps:get(conns, State)
    ),
    ok.

close_quietly(Pid) ->
    try chappe_esl:close(Pid) of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% internal

connect(Node, State) ->
    case maps:find(Node, maps:get(nodes, State)) of
        error ->
            {reply, {error, unknown_node}, State};
        {ok, Cfg} ->
            case chappe_esl:connect(Cfg) of
                {ok, Pid} ->
                    Ref = erlang:monitor(process, Pid),
                    {reply, {ok, Pid}, store(Node, Pid, Ref, State)};
                {error, _} = Err ->
                    {reply, Err, State}
            end
    end.

store(Node, Pid, Ref, State) ->
    State#{
        conns := maps:put(Node, Pid, maps:get(conns, State)),
        mons := maps:put(Ref, Node, maps:get(mons, State))
    }.

drop_conn(Ref, State) ->
    case maps:take(Ref, maps:get(mons, State)) of
        {Node, Mons} ->
            State#{
                mons := Mons,
                conns := maps:remove(Node, maps:get(conns, State))
            };
        error ->
            State
    end.
