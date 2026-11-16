%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Moving a cluster room's members to the room that owns its name next.
%%
%% Two cases, one way to move:
%%   - handoff: this node stops cleanly (an application stop, init:stop,
%%     docker stop). chappe_mrf's prep_stop/1 drains every room before
%%     the dialogs' owners die: each room gives its lease back, a room of
%%     the same name opens on a live node, and the members whose calls run
%%     on other nodes move there (transfer/3: the call is re-anchored to
%%     the new mixer, the caller sees no re-INVITE, a short audio gap).
%%     Members whose calls run on this node end with it.
%%   - rehome: the room lost its lease while its node runs (a lost
%%     quorum, a pause). A helper of the room opens the room where the
%%     region lets it (the majority side, or here once the quorum is
%%     back) and moves every member there, retrying until rehome_ms.
%%
%% fs rooms do not move: the conference is FreeSWITCH's, each member a
%% channel driven through the outbound socket the stopping node holds,
%% and the endpoint that owns the channel hangs it up when it stops. A
%% clean stop gives the name back at once, so the next caller opens the
%% room on a live node; the members in it end with the node.
-module(chappe_mrf_conf_move).

-export([drain/1, handoff/2, rehome/4]).

%% each room's own bound inside drain/1's
-define(OPEN_MS, 5000).

%% Hand every cluster room of this node off, within Ms in all.
-spec drain(non_neg_integer()) -> ok.
drain(Ms) ->
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    Rooms = [C || {{conf, _}, C} <- chappe_mrf_registry:select({conf, '_'})],
    Jobs = [spawn_monitor(fun() -> handoff(C, Deadline) end) || C <- Rooms],
    wait(Jobs, Deadline).

wait([], _Deadline) ->
    ok;
wait([{Pid, Mon} | Rest], Deadline) ->
    receive
        {'DOWN', Mon, process, Pid, _} -> wait(Rest, Deadline)
    after left(Deadline) ->
        exit(Pid, kill),
        wait(Rest, Deadline)
    end.

%% One room: it gives its lease back and its name up, then its members
%% with calls on other nodes move to the room that opens elsewhere.
-spec handoff(pid(), integer()) -> ok | {error, term()}.
handoff(Conf, Deadline) ->
    case
        chappe_mrf_conf:call(Conf, {transfer, move, handoff}, left(Deadline))
    of
        #{backend := native, name := Name, opts := Opts, members := Ids} when
            Ids =/= []
        ->
            move(Conf, Name, Opts, Ids, region(), Deadline);
        #{} ->
            ok;
        {error, _} = Err ->
            Err
    end.

%% The room lost its lease: move its members (Ids) to the room the region
%% lets open, from this node or another, until Deadline. Runs in a helper
%% the room starts.
-spec rehome(pid(), binary(), map(), integer()) -> ok | {error, term()}.
rehome(Conf, Name, Opts, Deadline) ->
    case chappe_mrf_conf:call(Conf, {transfer, move, ids}, left(Deadline)) of
        [] ->
            ok;
        Ids when is_list(Ids) ->
            case move(Conf, Name, Opts, Ids, [node() | region()], Deadline) of
                ok ->
                    ok;
                {error, _} ->
                    timer:sleep(min(1000, left(Deadline))),
                    retry(Conf, Name, Opts, Deadline)
            end;
        {error, _} = Err ->
            Err
    end.

retry(Conf, Name, Opts, Deadline) ->
    case left(Deadline) of
        0 -> {error, timeout};
        _ -> rehome(Conf, Name, Opts, Deadline)
    end.

move(Conf, Name, Opts, Ids, Nodes, Deadline) ->
    case open(Name, Opts, Nodes, Conf, Deadline) of
        {ok, New} ->
            Jobs = [
                spawn_monitor(fun() ->
                    chappe_mrf_conf:transfer(Conf, Id, New)
                end)
             || Id <- Ids
            ],
            wait(Jobs, Deadline);
        {error, _} = Err ->
            Err
    end.

%% The room of Name on the first node of Nodes that opens or finds one
%% other than Conf.
open(_Name, _Opts, [], _Conf, _Deadline) ->
    {error, no_room};
open(Name, Opts, [N | Rest], Conf, Deadline) ->
    T = min(?OPEN_MS, left(Deadline)),
    try erpc:call(N, chappe_mrf, conference, [Name, Opts], max(T, 1)) of
        {ok, New} when New =/= Conf -> {ok, New};
        _ -> open(Name, Opts, Rest, Conf, Deadline)
    catch
        _:_ -> open(Name, Opts, Rest, Conf, Deadline)
    end.

left(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

%% The other nodes of the region this node reaches: a room opens only
%% where the same cluster owns its name.
region() ->
    Here = node(),
    Up = nodes(),
    #{members := Members} = chappe_cluster:status(),
    [N || {_, N} <- Members, N =/= Here, lists:member(N, Up)].
