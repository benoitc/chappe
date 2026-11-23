%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The node's table of streams by id: what a handshake looks the path up
%% in. The registry owns the table and monitors each stream it holds, so
%% a stream that ends, normally or not, leaves it. Reads go straight to
%% the table.
-module(chappe_audio_registry).
-behaviour(gen_server).

-export([start_link/0, register/2, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, chappe_audio_registry).

-record(state, {mons = #{} :: #{reference() => binary()}}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Hold the calling stream under Id, with the hash of its token.
-spec register(binary(), binary()) -> ok.
register(Id, TokenHash) ->
    gen_server:call(?MODULE, {register, Id, self(), TokenHash}).

-spec lookup(binary()) -> {ok, pid(), binary()} | error.
lookup(Id) ->
    case ets:lookup(?TAB, Id) of
        [{Id, Pid, Hash}] -> {ok, Pid, Hash};
        [] -> error
    end.

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({register, Id, Pid, Hash}, _From, #state{mons = Mons} = S) ->
    true = ets:insert_new(?TAB, {Id, Pid, Hash}),
    Mon = monitor(process, Pid),
    {reply, ok, S#state{mons = Mons#{Mon => Id}}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Mon, process, _Pid, _}, #state{mons = Mons} = S) ->
    case maps:take(Mon, Mons) of
        {Id, Mons1} ->
            true = ets:delete(?TAB, Id),
            {noreply, S#state{mons = Mons1}};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.
