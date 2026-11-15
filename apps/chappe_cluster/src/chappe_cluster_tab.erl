%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node's cluster table, `chappe_cluster_tab'. The app's supervisor
%% creates and owns it, so it outlives the agent and the lapse timer: a
%% crash of either loses no holder. It is public: the facade writes a
%% holder from the caller's process, so that no message queue stands
%% between a grant and its registration. Rows:
%%
%% - `{live, Epoch | undefined, Deadline, Gen}': the node's epoch and local
%%   deadline (monotonic ms). Gen counts the lapses, so a claim sent before
%%   a lapse is refused after it even if the node renewed meanwhile;
%% - `{members, [ServerId]}': the region's Ra members as last seen;
%% - `{{holder, Key}, Seq, Lease}': a lease claimed through this node, and
%%   its holder to tell on lost;
%% - `{leader, ServerId}': the region's leader as last seen;
%% - `{{pending, Kind, Key}, Item}': what the next renewal carries back to
%%   the region (abandoned claims, leases given up), one per kind and key
%%   (only the latest matters: a key has one lease), and
%%   `{pending_count, N}', their number, for their own bound.
%%
%% Updates of `live' are compare-and-swap (ets:select_replace/2), so a
%% renewal and a lapse that race never lose each other's effect.
-module(chappe_cluster_tab).

-export([
    new/0,
    live/0,
    live_gen/0,
    remaining_ms/0,
    renewed/2,
    lapse/0,
    lapse_if_due/0,
    members/0,
    set_members/1,
    leader/0,
    set_leader/1,
    incarnation/0,
    set_incarnation/1,
    known_epoch/0,
    set_known_epoch/1,
    hold/3,
    valid/1,
    valid_lease/1,
    unhold/2,
    lose_epochs/1,
    taken/2,
    sweep/0,
    queue/1,
    pending/0,
    sent/1
]).

-define(TAB, ?MODULE).

-spec new() -> ok.
new() ->
    ?TAB = ets:new(?TAB, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
    true = ets:insert(?TAB, [{live, undefined, 0, 0}, {pending_count, 0}]),
    ok.

%% ---- liveness ----

-spec live() -> {ok, pos_integer()} | not_live.
live() ->
    case live_gen() of
        {ok, E, _} -> {ok, E};
        not_live -> not_live
    end.

-spec live_gen() -> {ok, pos_integer(), non_neg_integer()} | not_live.
live_gen() ->
    case lookup(live) of
        [{live, E, D, G}] when is_integer(E) ->
            case now_ms() < D of
                true -> {ok, E, G};
                false -> not_live
            end;
        _ ->
            not_live
    end.

%% What is left before the local deadline, 0 when not live.
-spec remaining_ms() -> non_neg_integer().
remaining_ms() ->
    case lookup(live) of
        [{live, E, D, _}] when is_integer(E) -> max(0, D - now_ms());
        _ -> 0
    end.

%% A renewal came back: the node is live at `Epoch' until `Deadline'.
-spec renewed(pos_integer(), integer()) -> ok.
renewed(Epoch, Deadline) ->
    swap(fun({live, _, _, G}) -> {live, Epoch, Deadline, G} end),
    ok.

%% The lapse timer starts: its deadline is unknown, every holder is lost.
-spec lapse() -> ok.
lapse() ->
    swap(fun down/1),
    lose(fun(_) -> true end).

%% The lapse timer fired: lapse if the deadline really passed.
-spec lapse_if_due() -> ok | {later, integer()}.
lapse_if_due() ->
    case ets:lookup(?TAB, live) of
        [{live, undefined, _, _}] -> ok;
        [{live, _, D, _} = Old] -> due(now_ms() >= D, Old, D)
    end.

due(false, _Old, D) ->
    {later, D};
due(true, Old, _D) ->
    case cas(Old, down(Old)) of
        true -> lose(fun(_) -> true end);
        false -> lapse_if_due()
    end.

down({live, _, _, G}) ->
    {live, undefined, 0, G + 1}.

%% Replace the live row with F(Row), retrying on a concurrent change.
swap(F) ->
    [Old] = ets:lookup(?TAB, live),
    case cas(Old, F(Old)) of
        true -> ok;
        false -> swap(F)
    end.

cas(Old, New) ->
    ets:select_replace(?TAB, [{Old, [], [{const, New}]}]) =:= 1.

%% ---- members ----

-spec members() -> [{atom(), node()}].
members() ->
    case lookup(members) of
        [{members, Ms}] -> Ms;
        _ -> []
    end.

-spec set_members([{atom(), node()}]) -> ok.
set_members(Ms) ->
    true = ets:insert(?TAB, {members, Ms}),
    ok.

%% This app start's incarnation number, from the region.
-spec incarnation() -> pos_integer() | undefined.
incarnation() ->
    case lookup(incarnation) of
        [{incarnation, I}] -> I;
        _ -> undefined
    end.

-spec set_incarnation(pos_integer() | undefined) -> ok.
set_incarnation(I) ->
    true = ets:insert(?TAB, {incarnation, I}),
    ok.

%% The last epoch the region gave this incarnation.
-spec known_epoch() -> pos_integer() | undefined.
known_epoch() ->
    case lookup(known_epoch) of
        [{known_epoch, E}] -> E;
        _ -> undefined
    end.

-spec set_known_epoch(pos_integer()) -> ok.
set_known_epoch(E) ->
    true = ets:insert(?TAB, {known_epoch, E}),
    ok.

-spec leader() -> {atom(), node()} | undefined.
leader() ->
    case lookup(leader) of
        [{leader, L}] -> L;
        _ -> undefined
    end.

-spec set_leader({atom(), node()}) -> ok.
set_leader(L) ->
    true = ets:insert(?TAB, {leader, L}),
    ok.

%% ---- holders ----

%% Register a lease granted while the node was live at {Epoch, Gen}. The
%% row goes in first, then liveness is checked again: a lapse either sees
%% the row and tells the holder, or the check here sees the lapse.
-spec hold(map(), pos_integer(), non_neg_integer()) -> ok | lapsed.
hold(#{key := Key, seq := Seq} = Lease, Epoch, Gen) ->
    true = ets:insert(?TAB, {{holder, Key}, Seq, Lease}),
    case live_gen() of
        {ok, Epoch, Gen} ->
            ok;
        _ ->
            unhold(Key, Seq),
            queue({seq, Key, Seq}),
            lapsed
    end.

%% Valid: the row is there, at this seq, the node is live at the lease's
%% epoch, and the holder is alive (the region frees a dead holder's lease
%% at once, before any sweep here).
-spec valid(map()) -> boolean().
valid(#{key := Key, seq := Seq}) ->
    case lookup({holder, Key}) of
        [{_, Seq, Lease}] -> holds(Lease);
        _ -> false
    end.

holds(#{epoch := Epoch, pid := Pid}) ->
    live() =:= {ok, Epoch} andalso is_process_alive(Pid).

%% The lease held through this node for `Key', while it is valid.
-spec valid_lease(term()) -> {ok, map()} | none.
valid_lease(Key) ->
    case lookup({holder, Key}) of
        [{_, _, Lease}] ->
            case holds(Lease) of
                true -> {ok, Lease};
                false -> none
            end;
        _ ->
            none
    end.

-spec unhold(term(), pos_integer()) -> ok.
unhold(Key, Seq) ->
    _ = ets:select_delete(?TAB, [{{{holder, Key}, Seq, '_'}, [], [true]}]),
    ok.

%% The node renewed into `Epoch': the leases of any other epoch are lost.
-spec lose_epochs(pos_integer()) -> ok.
lose_epochs(Epoch) ->
    lose(fun(#{epoch := E}) -> E =/= Epoch end).

%% The region gave the key to another holder.
-spec taken(term(), pos_integer()) -> ok.
taken(Key, Seq) ->
    case lookup({holder, Key}) of
        [{_, Seq, Lease} = Row] ->
            lost(Lease),
            true = ets:delete_object(?TAB, Row),
            ok;
        _ ->
            ok
    end.

%% Drop the rows of holders that died (the region releases their leases on
%% its own).
-spec sweep() -> ok.
sweep() ->
    lists:foreach(
        fun({_, _, #{pid := Pid}} = Row) ->
            case is_process_alive(Pid) of
                true -> ok;
                false -> true = ets:delete_object(?TAB, Row)
            end
        end,
        ets:match_object(?TAB, {{holder, '_'}, '_', '_'})
    ).

%% Tell each holder that matches, and queue its release so the region
%% frees the key as soon as this node reaches it again.
lose(Pred) ->
    lists:foreach(
        fun({{holder, Key}, Seq, Lease} = Row) ->
            case Pred(Lease) of
                true ->
                    true = ets:delete_object(?TAB, Row),
                    lost(Lease),
                    queue({seq, Key, Seq});
                false ->
                    ok
            end
        end,
        ets:match_object(?TAB, {{holder, '_'}, '_', '_'})
    ).

lost(#{pid := Pid} = Lease) ->
    Pid ! {chappe_cluster, Lease, lost},
    ok.

%% ---- pending ----

%% One row per kind and key: a newer item replaces the older one. Bounded
%% on their own count: past three times max_leases a new key's item is
%% dropped (its lease still ends with its holder or its node).
-spec queue({claim | seq, term(), term()}) -> ok.
queue({Kind, Key, _} = Item) ->
    Row = {{pending, Kind, Key}, Item},
    case ets:insert_new(?TAB, Row) of
        true ->
            Max = 3 * chappe_cluster_config:get(max_leases),
            case ets:update_counter(?TAB, pending_count, 1) > Max of
                true ->
                    _ = ets:update_counter(?TAB, pending_count, -1),
                    true = ets:delete_object(?TAB, Row);
                false ->
                    true
            end;
        false ->
            true = ets:insert(?TAB, Row)
    end,
    ok.

-spec pending() -> list().
pending() ->
    [
        I
     || {{pending, _, _}, I} <- ets:match_object(?TAB, {
            {pending, '_', '_'}, '_'
        })
    ].

%% The renewal carried `Items': drop each one that was not replaced since.
-spec sent(list()) -> ok.
sent(Items) ->
    lists:foreach(
        fun({Kind, Key, _} = Item) ->
            Row = {{pending, Kind, Key}, Item},
            case ets:lookup(?TAB, {pending, Kind, Key}) of
                [Row] ->
                    true = ets:delete_object(?TAB, Row),
                    _ = ets:update_counter(?TAB, pending_count, -1),
                    ok;
                _ ->
                    ok
            end
        end,
        Items
    ).

%% ---- internals ----

lookup(Key) ->
    try
        ets:lookup(?TAB, Key)
    catch
        error:badarg -> []
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).
