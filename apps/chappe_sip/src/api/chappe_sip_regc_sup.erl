%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The outbound registrations (chappe_sip_regc), one child per name,
%% and the pg scope their subscribers join.
%%
%% A registration that crashes is restarted with its options and starts
%% over (a new REGISTER); one that stops normally (unregistered) is not.
-module(chappe_sip_regc_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/2, delete_child/1, whereis/1, children/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child(term(), map()) -> ok | {error, term()}.
start_child(Name, Opts) ->
    Spec = #{
        id => {regc, Name},
        start => {chappe_sip_regc, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_regc]
    },
    case supervisor:start_child(?MODULE, Spec) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            {error, already_started};
        {error, already_present} ->
            %% an unregistered one whose spec is still there: start anew
            _ = supervisor:delete_child(?MODULE, {regc, Name}),
            start_child(Name, Opts);
        {error, _} = Err ->
            Err
    end.

-spec delete_child(term()) -> ok | {error, not_found}.
delete_child(Name) ->
    _ = supervisor:terminate_child(?MODULE, {regc, Name}),
    case supervisor:delete_child(?MODULE, {regc, Name}) of
        ok -> ok;
        {error, _} -> {error, not_found}
    end.

-spec whereis(term()) -> pid() | undefined.
whereis(Name) ->
    case [P || {N, P} <- children(), N =:= Name] of
        [Pid | _] -> Pid;
        [] -> undefined
    end.

%% the running registrations
-spec children() -> [{term(), pid()}].
children() ->
    [
        {Name, Pid}
     || {{regc, Name}, Pid, _, _} <- supervisor:which_children(?MODULE),
        is_pid(Pid)
    ].

init([]) ->
    Scope = #{
        id => chappe_sip_regc_pg,
        start => {pg, start_link, [chappe_sip_regc]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [pg]
    },
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, [Scope]}}.
