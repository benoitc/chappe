%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Who waits for what, by key, in one ETS table:
%%   {call, Id}  the endpoint whose FreeSWITCH channel carries
%%               X-Chappe-Call: Id (the outbound socket finds it here);
%%   {loop, Id}  the conference a loopback INVITE to the mixer belongs to;
%%   {conf, Name} a conference by name;
%%   {a_dialog, Ref, Dialog} the caller's dialog of the call Ref, under
%%               the process that runs the call.
%% An entry goes with the process that put it there.
%%
%% The table belongs to the app's supervisor (new_table/0 in its init),
%% not to this server: a registry that restarts finds every entry, and
%% watches their processes again (one that died meanwhile loses its
%% entries at once), so a room keeps its name and a join under way is
%% still found. The table is public so that readers never wait on the
%% server, but only this server writes it (put/2 and delete/1 go through
%% it): an entry another process wrote would be watched by nobody. A
%% process deletes only its own entries, so a delete made again never
%% takes a key another process holds by then.
-module(chappe_mrf_registry).
-behaviour(gen_server).

-export([new_table/0, start_link/0, put/2, delete/1, lookup/1, select/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).
%% how long put/2 and delete/1 wait for a registry that restarts
-define(RESTART_WAIT, 20).
-define(RESTART_TRIES, 50).

-record(state, {mons = #{} :: #{reference() => {term(), pid()}}}).
-type state() :: #state{}.

%% The named table, made in the supervisor's init so that it owns it.
-spec new_table() -> ok.
new_table() ->
    _ = ets:new(?TAB, [named_table, public, {read_concurrency, true}]),
    ok.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Key now names Pid. {error, exists} when it names another live
%% process; ok when it names Pid already, so a put made again after a
%% restart of the registry (call/2) is no error. Pid is checked here: no
%% write can make the server crash, so none is made again on a crash of
%% its own.
-spec put(term(), pid()) -> ok | {error, exists}.
put(Key, Pid) when is_pid(Pid) ->
    call({put, Key, Pid}, ?RESTART_TRIES).

%% The caller's own entry at Key goes; an entry of another process stays.
%% A delete made again after a restart of the registry (call/2) may come
%% once another process took Key: it leaves that entry alone.
-spec delete(term()) -> ok.
delete(Key) ->
    call({delete, Key, self()}, ?RESTART_TRIES).

-spec lookup(term()) -> {ok, pid()} | error.
lookup(Key) ->
    try ets:lookup(?TAB, Key) of
        [{_, Pid}] -> {ok, Pid};
        [] -> error
    catch
        %% no table: the app is not running
        error:badarg -> error
    end.

%% Every {Key, Pid} whose key matches Pattern (an ets match pattern).
-spec select(term()) -> [{term(), pid()}].
select(Pattern) ->
    try
        ets:match_object(?TAB, {Pattern, '_'})
    catch
        error:badarg -> []
    end.

%% The writes go through the server, which watches each process. One the
%% server did not answer because it went down (before it took the
%% request, with the request queued, or after it made the change) is made
%% again once its supervisor restarted it: both writes may run twice. They
%% wait a little, then fail as before; a server that does not answer in
%% time is no restart, and fails at once.
call(Req, Tries) ->
    try
        gen_server:call(?MODULE, Req)
    catch
        exit:{Why, {gen_server, call, _}} when Why =/= timeout, Tries > 0 ->
            timer:sleep(?RESTART_WAIT),
            call(Req, Tries - 1)
    end.

-spec init([]) -> {ok, state()}.
init([]) ->
    %% the entries of the server before this one: watched again, and a
    %% process already gone sends its 'DOWN' at once
    Mons =
        #{
            monitor(process, Pid) => {Key, Pid}
         || {Key, Pid} <- ets:tab2list(?TAB)
        },
    {ok, #state{mons = Mons}}.

handle_call({put, Key, Pid}, _From, S) ->
    case ets:insert_new(?TAB, {Key, Pid}) of
        true -> {reply, ok, watch(Key, Pid, S)};
        false -> taken(Key, Pid, S)
    end;
handle_call({delete, Key, Pid}, _From, #state{mons = M} = S) ->
    true = ets:delete_object(?TAB, {Key, Pid}),
    M1 = maps:filter(
        fun(Ref, Entry) ->
            Entry =/= {Key, Pid} orelse (demonitor(Ref, [flush]) andalso false)
        end,
        M
    ),
    {reply, ok, S#state{mons = M1}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

watch(Key, Pid, #state{mons = M} = S) ->
    S#state{mons = M#{monitor(process, Pid) => {Key, Pid}}}.

%% Key is taken: by Pid itself (a put made again, call/2), by a live
%% process, or by one of this node that died before its 'DOWN' reached
%% this server (after a restart), whose entry goes now; its 'DOWN' then
%% finds the entry another's and leaves it.
taken(Key, Pid, S) ->
    case ets:lookup(?TAB, Key) of
        [{_, Pid}] ->
            %% watched already: by the server that put it, or by init/1
            {reply, ok, S};
        [{_, Old}] when node(Old) =:= node() ->
            case is_process_alive(Old) of
                true ->
                    {reply, {error, exists}, S};
                false ->
                    true = ets:insert(?TAB, {Key, Pid}),
                    {reply, ok, watch(Key, Pid, S)}
            end;
        _ ->
            {reply, {error, exists}, S}
    end.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', Ref, process, Pid, _}, #state{mons = M} = S) ->
    case maps:take(Ref, M) of
        {{Key, _Pid}, M1} ->
            _ = ets:delete_object(?TAB, {Key, Pid}),
            {noreply, S#state{mons = M1}};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.
