%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Root supervisor: the registry of the calls waiting for FreeSWITCH, then
%% one pool for cleanup jobs, one for endpoints and one for conferences
%% (all temporary: an endpoint or a conference that stops is not
%% restarted, its owner hears of it). The supervisor owns the registry's
%% table, so a registry that restarts keeps every entry. The jobs' pool
%% starts before the others, so it stops after them: the cleanups of an
%% endpoint or a room that stops with the app still find it.
-module(chappe_mrf_sup).
-behaviour(supervisor).

-export([start_link/0, start_endpoint/1, start_conf/1, start_job/1]).
-export([init/1, job/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

-spec start_endpoint(map()) -> {ok, pid()} | {error, term()}.
start_endpoint(Args) ->
    supervisor:start_child(chappe_mrf_ep_sup, [Args]).

-spec start_conf(map()) -> {ok, pid()} | {error, term()}.
start_conf(Args) ->
    supervisor:start_child(chappe_mrf_conf_sup, [Args]).

%% Run Fun once, in a process of the jobs' pool (chappe_mrf_lib:later/1).
-spec start_job(fun(() -> term())) -> {ok, pid()} | {error, term()}.
start_job(Fun) ->
    supervisor:start_child(chappe_mrf_job_sup, [Fun]).

%% A job of the pool: Fun in a process linked to it. It traps exits, so
%% a stopping pool gives it its shutdown time to finish a cleanup rather
%% than killing it at once.
-spec job(fun(() -> term())) -> {ok, pid()}.
job(Fun) ->
    {ok,
        proc_lib:spawn_link(fun() ->
            process_flag(trap_exit, true),
            Fun()
        end)}.

init(top) ->
    %% the registry's table is the supervisor's: it outlives a restart of
    %% the registry (chappe_mrf_registry)
    ok = chappe_mrf_registry:new_table(),
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok,
        {Flags, [
            #{
                id => chappe_mrf_registry,
                start => {chappe_mrf_registry, start_link, []},
                shutdown => 5000
            },
            pool(chappe_mrf_job_sup, {?MODULE, job}),
            pool(chappe_mrf_ep_sup, {chappe_mrf_endpoint, start_link}),
            pool(chappe_mrf_conf_sup, {chappe_mrf_conf, start_link})
        ]}};
init({pool, {Mod, Fun}}) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    {ok,
        {Flags, [
            #{
                id => Mod,
                start => {Mod, Fun, []},
                restart => temporary,
                shutdown => 5000
            }
        ]}}.

pool(Name, Start) ->
    #{
        id => Name,
        start =>
            {supervisor, start_link, [{local, Name}, ?MODULE, {pool, Start}]},
        type => supervisor,
        shutdown => infinity
    }.
