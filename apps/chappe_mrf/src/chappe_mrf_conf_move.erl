%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Moving a cluster room's members to the room that owns its name next.
%%
%% Two cases, one way to move:
%%   - handoff: this node stops cleanly (an application stop, init:stop,
%%     docker stop). chappe_mrf's prep_stop/1 marks the node draining, so
%%     no room opens here any more (start/2 opens it on a live node), then
%%     drains every room before the dialogs' owners die: each room gives
%%     its lease back, a room of the same name opens on a live node, and
%%     the members whose calls run on other nodes move there (transfer/3:
%%     the call is re-anchored to the new mixer, the caller sees no
%%     re-INVITE, a short audio gap). Members whose calls run on this node
%%     end with it.
%%   - rehome: the room lost its lease while its node runs (a lost
%%     quorum, a pause). A helper linked to the room opens the room where
%%     the region lets it (the majority side, or here once the quorum is
%%     back) and moves every member there, round after round until
%%     rehome_ms.
%%
%% Every move has a deadline, past which the mover stops waiting. A
%% transfer job is never cut: one cut halfway through its join could
%% leave its member in both rooms. Each runs to its own end (transfer/3
%% hands the member back to its room when the join fails), monitored, not
%% linked, so neither its crash nor its mover's end takes the other down;
%% a member still on its way is skipped by the next round.
%%
%% fs rooms do not move: the conference is FreeSWITCH's, each member a
%% channel driven through the outbound socket the stopping node holds,
%% and the endpoint that owns the channel hangs it up when it stops. A
%% clean stop gives the name back at once, so the next caller opens the
%% room on a live node; the members in it end with the node.
-module(chappe_mrf_conf_move).

-export([drain/1, handoff/2, rehome/4, transfer_all/4]).
-export([draining/0, draining/1, open/5, region/0, job/4]).

%% each room's own bound inside drain/1's
-define(OPEN_MS, 5000).
%% one round of a rehome
-define(ROUND_MS, 10000).
%% how long a crashed move waits for New to settle its join (100 x 200 ms)
-define(SETTLE_TRIES, 100).
-define(SETTLE_MS, 200).
%% what drain/1 gives a handoff past the deadline to hand its members
%% back before it is killed
-define(GRACE_MS, 1000).
-define(DRAINING, {chappe_mrf, draining}).

%% Whether this node is draining: start/2 then opens no room here.
-spec draining() -> boolean().
draining() ->
    persistent_term:get(?DRAINING, false).

-spec draining(boolean()) -> ok.
draining(true) ->
    persistent_term:put(?DRAINING, true);
draining(false) ->
    _ = persistent_term:erase(?DRAINING),
    ok.

%% Hand every cluster room of this node off, within Ms in all.
-spec drain(non_neg_integer()) -> ok.
drain(Ms) ->
    ok = draining(true),
    Deadline = erlang:monotonic_time(millisecond) + Ms,
    Rooms = [C || {{conf, _}, C} <- chappe_mrf_registry:select({conf, '_'})],
    Jobs = [spawn_monitor(fun() -> handoff(C, Deadline) end) || C <- Rooms],
    wait_handoffs(Jobs, Deadline + ?GRACE_MS).

%% a handoff past its own deadline and the grace is killed; its transfer
%% jobs run on to their end
wait_handoffs([], _Deadline) ->
    ok;
wait_handoffs([{Pid, Mon} | Rest], Deadline) ->
    receive
        {'DOWN', Mon, process, Pid, _} -> wait_handoffs(Rest, Deadline)
    after left(Deadline) ->
        exit(Pid, kill),
        wait_handoffs(Rest, Deadline)
    end.

%% One room: it gives its lease back and its name up, then its members
%% with calls on other nodes move to the room that opens elsewhere.
-spec handoff(pid(), integer()) -> ok | {error, term()}.
handoff(Conf, Deadline) ->
    case
        chappe_mrf_conf:call(
            Conf, {transfer, move, handoff}, max(1, left(Deadline))
        )
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

%% The room lost its lease: move its members to the room the region lets
%% open, from this node or another, round after round until Deadline.
%% Runs in a helper linked to the room; a room gone ends it.
-spec rehome(pid(), binary(), map(), integer()) -> ok | {error, term()}.
rehome(Conf, Name, Opts, Deadline) ->
    Round = min(Deadline, erlang:monotonic_time(millisecond) + ?ROUND_MS),
    case
        chappe_mrf_conf:call(Conf, {transfer, move, ids}, max(1, left(Round)))
    of
        [] ->
            ok;
        Ids when is_list(Ids) ->
            case move(Conf, Name, Opts, Ids, [node() | region()], Round) of
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
        {ok, New} -> transfer_all(Conf, Ids, New, Deadline);
        {error, _} = Err -> Err
    end.

%% Move each of Ids from Conf to New, at once, waiting until Deadline.
%% ok once every move ended, {error, timeout} when some still run (they
%% go on: see above).
-spec transfer_all(pid(), [binary()], pid(), integer()) ->
    ok | {error, timeout}.
transfer_all(Conf, Ids, New, Deadline) ->
    Self = self(),
    Jobs = [
        {
            spawn_monitor(fun() ->
                Self ! {moved, self(), job(Conf, Id, New)}
            end),
            Id
        }
     || Id <- Ids
    ],
    wait_jobs(Jobs, Deadline, [], []).

%% One member's move. A crash in it is that member's failed move: when
%% the member never reached New, it is handed back to Conf for the next
%% round (settle/3).
job(Conf, Id, New) ->
    job(Conf, Id, New, fun chappe_mrf_conf:transfer/3).

-spec job(pid(), binary(), pid(), fun((pid(), binary(), pid()) -> term())) ->
    ok | {error, term()}.
job(Conf, Id, New, Transfer) ->
    try Transfer(Conf, Id, New) of
        {ok, _} -> ok;
        {error, _} = Err -> Err;
        Other -> {error, Other}
    catch
        Class:Why ->
            logger:notice("chappe_mrf_conf_move: move of ~s failed: ~0p", [
                Id, {Class, Why}
            ]),
            settle(Conf, Id, New)
    end.

%% Whether the member reached New is the member's call's to say: New is
%% asked about the call (its b2b, or its FreeSWITCH endpoint), never
%% about a name. While New is still joining it, wait; once New has it,
%% Conf loses it when the call's old leg ends; when New never got it,
%% Conf takes it back.
settle(Conf, Id, New) ->
    case chappe_mrf_conf:call(Conf, {transfer, handle_of, Id}, 5000) of
        {ok, Handle} -> settle(Conf, Id, New, Handle, ?SETTLE_TRIES);
        _ -> ok
    end.

settle(Conf, Id, _New, _Handle, 0) ->
    hand_back(Conf, Id),
    {error, handed_back};
settle(Conf, Id, New, Handle, Tries) ->
    case chappe_mrf_conf:call(New, {transfer, holds, Handle}, 5000) of
        member ->
            ok;
        no ->
            hand_back(Conf, Id),
            {error, handed_back};
        {error, noproc} ->
            hand_back(Conf, Id),
            {error, handed_back};
        _PendingOrSlow ->
            %% still joining there, or slow to say: ask again
            timer:sleep(?SETTLE_MS),
            settle(Conf, Id, New, Handle, Tries - 1)
    end.

hand_back(Conf, Id) ->
    _ = chappe_mrf_conf:call(Conf, {transfer, cancel, Id}, 5000),
    ok.

%% ok only when every move ended in New; {error, timeout} while one
%% still runs at the deadline (it goes on); else the members whose move
%% failed
wait_jobs([], _Deadline, [], []) ->
    ok;
wait_jobs([], _Deadline, _Failed, [_ | _]) ->
    {error, timeout};
wait_jobs([], _Deadline, Failed, []) ->
    {error, {failed, lists:reverse(Failed)}};
wait_jobs([{{Pid, Mon}, Id} | Rest], Deadline, Failed, Running) ->
    receive
        {moved, Pid, ok} ->
            demonitor(Mon, [flush]),
            wait_jobs(Rest, Deadline, Failed, Running);
        {moved, Pid, _Error} ->
            demonitor(Mon, [flush]),
            wait_jobs(Rest, Deadline, [Id | Failed], Running);
        {'DOWN', Mon, process, Pid, _} ->
            wait_jobs(Rest, Deadline, [Id | Failed], Running)
    after left(Deadline) ->
        demonitor(Mon, [flush]),
        wait_jobs(Rest, Deadline, Failed, [Id | Running])
    end.

%% The room of Name on the first node of Nodes that opens or finds one
%% other than Conf, and never one on a draining node.
-spec open(binary(), map(), [node()], pid() | none, integer()) ->
    {ok, pid()} | {error, no_room}.
open(_Name, _Opts, [], _Conf, _Deadline) ->
    {error, no_room};
open(Name, Opts, [N | Rest], Conf, Deadline) ->
    T = max(1, min(?OPEN_MS, left(Deadline))),
    try erpc:call(N, chappe_mrf, conference, [Name, Opts], T) of
        {ok, New} when New =/= Conf ->
            elsewhere(New, Name, Opts, Rest, Conf, Deadline);
        _ ->
            open(Name, Opts, Rest, Conf, Deadline)
    catch
        _:_ -> open(Name, Opts, Rest, Conf, Deadline)
    end.

elsewhere(New, Name, Opts, Rest, Conf, Deadline) ->
    case node(New) =:= node() andalso draining() of
        true -> open(Name, Opts, Rest, Conf, Deadline);
        false -> {ok, New}
    end.

left(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

%% The other nodes of the region this node reaches: a room opens only
%% where the same cluster owns its name.
-spec region() -> [node()].
region() ->
    Here = node(),
    Up = nodes(),
    #{members := Members} = chappe_cluster:status(),
    [N || {_, N} <- Members, N =/= Here, lists:member(N, Up)].
