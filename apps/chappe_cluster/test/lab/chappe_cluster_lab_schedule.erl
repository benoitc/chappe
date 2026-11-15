%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The fault schedule of the cluster lab: a pure function of a seed, the run
%% length, the node names and the fault kinds the docker host supports, so
%% `SEED=... make interop-cluster' replays a failing run.
%%
%% A schedule is a list of {AtMs, Action}, sorted, where each fault is
%% followed by the action that heals it:
%%
%%     {isolate, Nodes}           docker network disconnect each node
%%     {split, Minority, Rest}    iptables drop between the two sides
%%     {kill, Nodes}              docker kill
%%     {delay, Node, Ms}          tc netem delay on the node's interface
%%     {heal, Fault}              undo Fault (reconnect, flush, start, clear)
%%
%% One fault holds at a time. Faults start after a settle period, so the
%% cluster forms first, and the last heal leaves `tail' ms before the end.
-module(chappe_cluster_lab_schedule).

-export([build/4, build/5, describe/1]).

-export_type([action/0]).

-type node_name() :: string().
-type fault() ::
    {isolate, [node_name()]}
    | {split, [node_name()], [node_name()]}
    | {kill, [node_name()]}
    | {delay, node_name(), pos_integer()}.
-type action() :: fault() | {heal, fault()}.
-type cap() :: isolate | split | kill | delay.

-define(DEFAULTS, #{
    %% the cluster forms and every node claims before the first fault
    start_ms => 10000,
    %% a fault holds for this long: shorter than a lease, and well past it
    hold_ms => {2000, 20000},
    %% time between a heal and the next fault
    settle_ms => {3000, 12000},
    %% kept free of faults at the end, so the nodes claim again
    tail_ms => 15000
}).

%% @doc The schedule with the default timings.
-spec build(integer(), pos_integer(), [node_name()], [cap()]) ->
    [{non_neg_integer(), action()}].
build(Seed, DurationMs, Nodes, Caps) ->
    build(Seed, DurationMs, Nodes, Caps, #{}).

-spec build(integer(), pos_integer(), [node_name()], [cap()], map()) ->
    [{non_neg_integer(), action()}].
build(Seed, DurationMs, Nodes, Caps, Opts0) when
    length(Nodes) >= 3, Caps =/= []
->
    Opts = maps:merge(?DEFAULTS, Opts0),
    S0 = rand:seed_s(exsss, Seed),
    #{start_ms := Start, tail_ms := Tail} = Opts,
    loop(
        Start,
        DurationMs - Tail,
        lists:sort(Nodes),
        lists:sort(Caps),
        Opts,
        S0,
        []
    ).

loop(T, End, Nodes, Caps, Opts, S0, Acc) ->
    {Hold, S1} = between(maps:get(hold_ms, Opts), S0),
    case T + Hold =< End of
        false ->
            lists:reverse(Acc);
        true ->
            {Fault, S2} = fault(Nodes, Caps, S1),
            {Settle, S3} = between(maps:get(settle_ms, Opts), S2),
            Acc1 = [{T + Hold, {heal, Fault}}, {T, Fault} | Acc],
            loop(T + Hold + Settle, End, Nodes, Caps, Opts, S3, Acc1)
    end.

fault(Nodes, Caps, S0) ->
    {Cap, S1} = pick(Caps, S0),
    N = length(Nodes),
    MaxMinority = (N - 1) div 2,
    case Cap of
        isolate ->
            %% a minority most of the time, a majority (no quorum) sometimes
            {Majority, S2} = chance(0.25, S1),
            Size =
                case Majority of
                    true -> N div 2 + 1;
                    false -> undefined
                end,
            {Picked, S3} = some(Nodes, Size, MaxMinority, S2),
            {{isolate, Picked}, S3};
        split ->
            {Minority, S2} = some(Nodes, undefined, MaxMinority, S1),
            {{split, Minority, Nodes -- Minority}, S2};
        kill ->
            {All, S2} = chance(0.1, S1),
            Size =
                case All of
                    true -> N div 2 + 1;
                    false -> undefined
                end,
            {Picked, S3} = some(Nodes, Size, MaxMinority, S2),
            {{kill, Picked}, S3};
        delay ->
            {Node, S2} = pick(Nodes, S1),
            {Ms, S3} = between({50, 400}, S2),
            {{delay, Node, Ms}, S3}
    end.

%% Size nodes, or 1 to Max when Size is undefined, in name order.
some(Nodes, undefined, Max, S0) ->
    {Size, S1} = between({1, Max}, S0),
    some(Nodes, Size, Max, S1);
some(Nodes, Size, _Max, S0) ->
    {Keyed, S1} = lists:mapfoldl(
        fun(Node, S) ->
            {R, S2} = rand:uniform_s(S),
            {{R, Node}, S2}
        end,
        S0,
        Nodes
    ),
    Picked = [Node || {_, Node} <- lists:sublist(lists:sort(Keyed), Size)],
    {lists:sort(Picked), S1}.

pick(List, S0) ->
    {I, S1} = rand:uniform_s(length(List), S0),
    {lists:nth(I, List), S1}.

between({Lo, Hi}, S0) ->
    {I, S1} = rand:uniform_s(Hi - Lo + 1, S0),
    {Lo + I - 1, S1}.

chance(P, S0) ->
    {R, S1} = rand:uniform_s(S0),
    {R < P, S1}.

%% @doc A schedule as text, one action per line.
-spec describe([{non_neg_integer(), action()}]) -> iolist().
describe(Schedule) ->
    [io_lib:format("  ~8.3f s  ~p~n", [At / 1000, A]) || {At, A} <- Schedule].
