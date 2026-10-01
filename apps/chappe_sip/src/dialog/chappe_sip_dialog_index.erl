%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Index of live dialogs by RFC 3261 dialog identity.
%%
%% Keyed by {CallId, LocalTag, RemoteTag}, so an INVITE carrying Replaces
%% (RFC 3891) can be matched to the dialog it names without asking every
%% dialog fsm. Each dialog fsm writes its own entry when it is confirmed and
%% deletes it on every exit it controls, before telling its owner the dialog
%% is gone. The public ETS is written directly by the fsm (no call to this
%% server on the call path), so a slow or restarting index never delays a
%% dialog.
%%
%% This server only covers the exits the fsm does not control (a kill, a
%% supervisor shutdown when the engine restarts): it monitors every indexed
%% fsm and drops the entry on 'DOWN'. The table is owned by
%% chappe_sip_registry_keeper, so a crash here loses no entries; on restart
%% it re-monitors every pid still in the table. Lookups also skip an entry
%% whose pid is already dead, which covers the window before the 'DOWN'.
%%
%% Size is bounded by max_dialogs: the engine refuses a dialog past that
%% ceiling, and insert/5 refuses an entry past it as a second guard.
-module(chappe_sip_dialog_index).
-behaviour(gen_server).

-export([start_link/0]).
-export([insert/5, set_state/2, delete/1, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([key/0, dialog_state/0, role/0]).

-define(TAB, ?MODULE).

-type key() :: {
    CallId :: binary(), LocalTag :: binary(), RemoteTag :: binary()
}.
%% early: dialog-forming response was provisional; confirmed: 2xx;
%% terminated: our BYE is in flight
-type dialog_state() :: early | confirmed | terminated.
-type role() :: uas | uac.

%% the monitor and indexed keys of every watched dialog fsm
-record(state, {watched = #{} :: #{pid() => {reference(), [key()]}}}).
-type state() :: #state{}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Index the calling dialog fsm under Key. Called by the fsm itself.
-spec insert(key(), non_neg_integer(), dialog_state(), role(), pid()) ->
    ok | {error, full | exists | no_index}.
insert(Key, Id, State, Role, Pid) ->
    case safe_size() >= chappe_sip_config:get(max_dialogs) of
        true ->
            {error, full};
        false ->
            try ets:insert_new(?TAB, {Key, Pid, Id, State, Role}) of
                true ->
                    gen_server:cast(?MODULE, {watch, Pid, Key}),
                    ok;
                false ->
                    {error, exists}
            catch
                error:badarg -> {error, no_index}
            end
    end.

%% Update the state of an entry this pid owns (no-op otherwise).
-spec set_state(key(), dialog_state()) -> ok.
set_state(Key, State) ->
    Pid = self(),
    try ets:lookup(?TAB, Key) of
        [{Key, Pid, _, _, _}] ->
            _ = ets:update_element(?TAB, Key, {4, State}),
            ok;
        _ ->
            ok
    catch
        error:badarg -> ok
    end.

%% Drop the calling fsm's entry. Only the owner's own entry is removed.
-spec delete(key()) -> ok.
delete(Key) ->
    delete(Key, self()).

%% {ok, {Pid, Id, State, Role}} for a live dialog, else not_found.
-spec lookup(key()) ->
    {ok, {pid(), non_neg_integer(), dialog_state(), role()}} | not_found.
lookup(Key) ->
    try ets:lookup(?TAB, Key) of
        [{Key, Pid, Id, State, Role}] ->
            case is_process_alive(Pid) of
                true -> {ok, {Pid, Id, State, Role}};
                false -> not_found
            end;
        [] ->
            not_found
    catch
        %% table not there: the application is not running
        error:badarg -> not_found
    end.

%% gen_server

init([]) ->
    %% owned by chappe_sip_registry_keeper (started first); create it here only
    %% as a fallback, as chappe_sip_registry does for its table
    _ =
        case ets:info(?TAB) of
            undefined ->
                ets:new(?TAB, [
                    named_table,
                    set,
                    public,
                    {read_concurrency, true},
                    {write_concurrency, true}
                ]);
            _ ->
                ?TAB
        end,
    %% re-watch what a previous incarnation was watching
    Watched = lists:foldl(
        fun({Key, Pid}, Acc) -> watch(Pid, Key, Acc) end,
        #{},
        ets:select(?TAB, [{{'$1', '$2', '_', '_', '_'}, [], [{{'$1', '$2'}}]}])
    ),
    {ok, #state{watched = Watched}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, {error, unknown_call}, state()}.
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({watch, Pid, Key}, #state{watched = W} = S) ->
    {noreply, S#state{watched = watch(Pid, Key, W)}};
handle_cast(_Msg, S) ->
    {noreply, S}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', _MRef, process, Pid, _Reason}, #state{watched = W} = S) ->
    case maps:take(Pid, W) of
        {{_, Keys}, W1} ->
            lists:foreach(fun(K) -> delete(K, Pid) end, Keys),
            {noreply, S#state{watched = W1}};
        error ->
            {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% internal

%% one monitor per pid, whatever the number of keys it indexed
watch(Pid, Key, W) ->
    case W of
        #{Pid := {MRef, Keys}} ->
            W#{Pid => {MRef, lists:usort([Key | Keys])}};
        _ ->
            W#{Pid => {erlang:monitor(process, Pid), [Key]}}
    end.

delete(Key, Pid) ->
    try ets:select_delete(?TAB, [{{Key, Pid, '_', '_', '_'}, [], [true]}]) of
        _ -> ok
    catch
        error:badarg -> ok
    end.

safe_size() ->
    case ets:info(?TAB, size) of
        undefined -> 0;
        N -> N
    end.
