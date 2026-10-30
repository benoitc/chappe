%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Who waits for what, by key, in one ETS table:
%%   {call, Id}  the endpoint whose FreeSWITCH channel carries
%%               X-Chappe-Call: Id (the outbound socket finds it here);
%%   {loop, Id}  the conference a loopback INVITE to the mixer belongs to;
%%   {conf, Name} a conference by name.
%% An entry goes with the process that put it there.
-module(chappe_mrf_registry).
-behaviour(gen_server).

-export([start_link/0, put/2, delete/1, lookup/1, select/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).

-record(state, {mons = #{} :: #{reference() => term()}}).
-type state() :: #state{}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Key now names Pid. {error, exists} when it names a live process.
-spec put(term(), pid()) -> ok | {error, exists}.
put(Key, Pid) ->
    gen_server:call(?MODULE, {put, Key, Pid}).

-spec delete(term()) -> ok.
delete(Key) ->
    gen_server:call(?MODULE, {delete, Key}).

-spec lookup(term()) -> {ok, pid()} | error.
lookup(Key) ->
    case ets:lookup(?TAB, Key) of
        [{_, Pid}] -> {ok, Pid};
        [] -> error
    end.

%% Every {Key, Pid} whose key matches Pattern (an ets match pattern).
-spec select(term()) -> [{term(), pid()}].
select(Pattern) ->
    ets:match_object(?TAB, {Pattern, '_'}).

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TAB, [named_table, protected, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({put, Key, Pid}, _From, #state{mons = M} = S) ->
    case ets:insert_new(?TAB, {Key, Pid}) of
        true ->
            {reply, ok, S#state{mons = M#{monitor(process, Pid) => Key}}};
        false ->
            {reply, {error, exists}, S}
    end;
handle_call({delete, Key}, _From, #state{mons = M} = S) ->
    true = ets:delete(?TAB, Key),
    M1 = maps:filter(
        fun(Ref, K) ->
            K =/= Key orelse (demonitor(Ref, [flush]) andalso false)
        end,
        M
    ),
    {reply, ok, S#state{mons = M1}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Ref, process, Pid, _}, #state{mons = M} = S) ->
    case maps:take(Ref, M) of
        {Key, M1} ->
            _ = ets:delete_object(?TAB, {Key, Pid}),
            {noreply, S#state{mons = M1}};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.
