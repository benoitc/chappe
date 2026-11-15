%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The client each cluster lab node runs: a log writer and a few workers
%% that claim keys at random, use the fence while they hold one, and log
%% each step for chappe_cluster_lab_checker. Started by
%% chappe_cluster_lab_node; the controller stops it through stop/0 before
%% it collects the logs.
-module(chappe_cluster_lab_client).
-behaviour(supervisor).

-export([start/1, stop/0, stats/0]).
-export([init/1]).

-type opts() :: #{
    log_dir := file:filename(),
    workers := pos_integer(),
    keys := pos_integer(),
    hold_ms := {pos_integer(), pos_integer()},
    beat_ms := pos_integer()
}.

%% @doc Start the client, unlinked from the caller.
-spec start(opts()) -> {ok, pid()}.
start(Opts) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, Opts),
    true = unlink(Sup),
    {ok, Sup}.

%% @doc Release what the workers hold, log it, and flush the log.
-spec stop() -> ok.
stop() ->
    Workers = [
        Pid
     || {{worker, _}, Pid, _, _} <- supervisor:which_children(?MODULE),
        is_pid(Pid)
    ],
    [ok = chappe_cluster_lab_worker:stop(Pid) || Pid <- Workers],
    chappe_cluster_lab_log:sync().

%% @doc Events logged so far, by kind.
-spec stats() -> #{atom() => non_neg_integer()}.
stats() ->
    chappe_cluster_lab_log:stats().

init(#{workers := N} = Opts) ->
    Boot = os:system_time(millisecond),
    Log = #{
        id => log,
        start => {chappe_cluster_lab_log, start_link, [Opts, Boot]}
    },
    Workers = [
        #{
            id => {worker, I},
            start => {chappe_cluster_lab_worker, start_link, [Opts, Boot, I]},
            %% a stopped worker stays stopped
            restart => transient
        }
     || I <- lists:seq(1, N)
    ],
    Flags = #{strategy => one_for_one, intensity => 50, period => 10},
    {ok, {Flags, [Log | Workers]}}.
