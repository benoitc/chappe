%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A Ra command that never outlives its deadline. ra:process_command/3 with
%% a member list tries each member with a fresh full timeout, and follows a
%% redirect with another, so one hung member can make a call last several
%% times its timeout. Here the last known leader goes first, each member
%% gets only what is left of the budget, and a helper runs the walk so the
%% caller can kill it at the deadline, wherever it is.
-module(chappe_cluster_ra).

-export([command/2]).

%% Run `Cmd' on the region within `Timeout' ms.
-dialyzer({nowarn_function, command/2}).
-spec command(term(), non_neg_integer()) -> {ok, term()} | {error, no_quorum}.
command(Cmd, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Order = order(chappe_cluster_tab:members(), chappe_cluster_tab:leader()),
    {Pid, Mon} = spawn_monitor(fun() ->
        exit({ra_result, walk(Order, Cmd, Deadline)})
    end),
    receive
        {'DOWN', Mon, process, Pid, {ra_result, Result}} -> Result;
        {'DOWN', Mon, process, Pid, _} -> {error, no_quorum}
    after Timeout ->
        exit(Pid, kill),
        receive
            {'DOWN', Mon, process, Pid, _} -> ok
        after 1000 -> ok
        end,
        {error, no_quorum}
    end.

order(Members, Leader) ->
    case lists:member(Leader, Members) of
        true -> [Leader | lists:delete(Leader, Members)];
        false -> Members
    end.

walk([], _Cmd, _Deadline) ->
    {error, no_quorum};
walk([M | Ms], Cmd, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left =< 0 ->
            {error, no_quorum};
        Left ->
            case ra:process_command(M, Cmd, #{timeout => Left}) of
                {ok, Reply, Leader} ->
                    ok = chappe_cluster_tab:set_leader(Leader),
                    {ok, Reply};
                _TimeoutOrError ->
                    walk(Ms, Cmd, Deadline)
            end
    end.
