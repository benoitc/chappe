%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Where the refer event package finds its subscriptions.
%%
%% Two ETS tables, owned here and read by anyone:
%%   - rows: one per REFER subscription, {Id, Role, Scope, Pid, Info}.
%%     Role is notifier (we accepted the REFER; Pid is the chappe_sip_refer_sub
%%     process) or subscriber (we sent it; Pid is the owner told of the
%%     NOTIFYs). Scope is {dialog, DialogPid} for a REFER inside a dialog,
%%     {tag, LocalTag} for one we sent outside any dialog.
%%   - counts: how many REFERs a dialog received or sent, so the notifier
%%     knows when the Event header needs an id (RFC 3515 2.4.6) and the
%%     routers know the dialog uses the package at all.
%% Rows go when their process or dialog goes down, counts with the dialog.
-module(chappe_sip_refer_registry).
-behaviour(gen_server).

-export([start_link/0]).
-export([add/4, update/2, delete/1, rows/2, bump/2, count/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(ROWS, chappe_sip_refer_rows).
-define(COUNTS, chappe_sip_refer_counts).

%% monitored pid -> true, so each pid is monitored once
-record(state, {mons = #{} :: #{pid() => true}}).
-type state() :: #state{}.

-type role() :: notifier | subscriber.
-type scope() :: {dialog, pid()} | {tag, binary()}.
-type row() :: {reference(), role(), scope(), pid(), map()}.
-export_type([role/0, scope/0, row/0]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Register a subscription; Id is the caller's reference for it.
-spec add(role(), scope(), pid(), map()) -> reference().
add(Role, Scope, Pid, Info) ->
    Id = make_ref(),
    ok = gen_server:call(?MODULE, {add, {Id, Role, Scope, Pid, Info}}),
    Id.

-spec update(reference(), map()) -> ok.
update(Id, Info) ->
    _ = ets:update_element(?ROWS, Id, {5, Info}),
    ok.

-spec delete(reference()) -> ok.
delete(Id) ->
    _ = ets:delete(?ROWS, Id),
    ok.

%% The rows of one role in a scope. Empty when the registry is not running
%% (a node without the package, or the fake engine in unit tests).
-spec rows(role(), scope()) -> [row()].
rows(Role, Scope) ->
    try
        ets:match_object(?ROWS, {'_', Role, Scope, '_', '_'})
    catch
        error:badarg -> []
    end.

%% Count one more REFER received or sent in a dialog; returns the new count.
-spec bump(received | sent, pid()) -> pos_integer().
bump(Dir, DialogPid) ->
    gen_server:call(?MODULE, {bump, Dir, DialogPid}).

-spec count(received | sent, pid()) -> non_neg_integer().
count(Dir, DialogPid) ->
    try ets:lookup(?COUNTS, {Dir, DialogPid}) of
        [{_, N}] -> N;
        [] -> 0
    catch
        error:badarg -> 0
    end.

%% ---- gen_server ----

-spec init([]) -> {ok, state()}.
init([]) ->
    Opts = [named_table, public, {read_concurrency, true}],
    ?ROWS = ets:new(?ROWS, [set | Opts]),
    ?COUNTS = ets:new(?COUNTS, [set | Opts]),
    {ok, #state{}}.

handle_call({add, {_, _, Scope, Pid, _} = Row}, _From, #state{mons = M} = S) ->
    true = ets:insert(?ROWS, Row),
    {reply, ok, S#state{mons = watch(Pid, watch(scope_pid(Scope), M))}};
handle_call({bump, Dir, DialogPid}, _From, #state{mons = M} = S) ->
    Key = {Dir, DialogPid},
    N = ets:update_counter(?COUNTS, Key, 1, {Key, 0}),
    {reply, N, S#state{mons = watch(DialogPid, M)}};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', _MRef, process, Pid, _}, #state{mons = M} = S) ->
    _ = ets:match_delete(?ROWS, {'_', '_', '_', Pid, '_'}),
    _ = ets:match_delete(?ROWS, {'_', '_', {dialog, Pid}, '_', '_'}),
    _ = ets:delete(?COUNTS, {received, Pid}),
    _ = ets:delete(?COUNTS, {sent, Pid}),
    {noreply, S#state{mons = maps:remove(Pid, M)}};
handle_info(_Other, S) ->
    {noreply, S}.

scope_pid({dialog, Pid}) -> Pid;
scope_pid({tag, _}) -> undefined.

watch(undefined, Mons) ->
    Mons;
watch(Pid, Mons) when is_map_key(Pid, Mons) ->
    Mons;
watch(Pid, Mons) ->
    _ = erlang:monitor(process, Pid),
    Mons#{Pid => true}.
