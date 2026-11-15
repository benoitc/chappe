%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The region's Ra machine: node liveness, leases and a KV with versions.
%%
%% No clock. The machine never reads a time, neither its own nor the
%% `system_time' Ra puts in a command's metadata: it applies results.
%%
%% - `{renew, Node, Epoch, LeaseMs, Items}' keeps the node live at Epoch
%%   when Epoch is its current epoch, or gives it a new one (from a
%%   region-wide counter) and ends the old one's leases;
%% - `{timeout, {expire, Node, Epoch}}' ends the node's epoch and frees its
%%   keys, only when Epoch is still current; otherwise it changes nothing;
%% - a claim succeeds on a free key only: every lease of an ended epoch is
%%   dropped when the epoch ends.
%%
%% Replay and snapshots are deterministic by construction.
%%
%% Expiry is the leader's decision, on its own monotonic clock: each renew
%% the leader applies (re)starts a Ra timer `{expire, Node, Epoch}' of
%% lease_ms, and a new leader starts one for every live node as it takes
%% over (state_enter/2). Ra runs these timers on the leader only, on
%% erlang timers (monotonic), and when one fires it appends
%% `{timeout, {expire, Node, Epoch}}' to the log. A timer of a deposed
%% leader that still lands is harmless: it ends only a node that missed its
%% renewals by that leader's count, and the epoch check drops it if the
%% node renewed into another epoch.
%%
%% Fences: a lease's fence is `{Region, NodeEpoch, Seq}'. Seq comes from a
%% region-wide counter bumped on every grant, so it is strictly increasing
%% per key (and across the region). Compare fences by Seq.
%%
%% HLC: claims and KV writes carry the writer's hybrid logical clock stamp
%% (chappe_cluster:now/0); the machine keeps it as a value, in the lease,
%% the leases() rows and the watch events. It never orders anything by it.
%%
%% Holders are monitored through Ra's monitor effects, from the leader; a
%% holder's death releases its leases. A `noconnection' down keeps them:
%% the holder's node liveness decides, and its pids are monitored again on
%% `nodeup'.
-module(chappe_cluster_machine).
-behaviour(ra_machine).

-export([init/1, apply/3, state_enter/2, overview/1]).
-export([
    query_owner/2,
    query_get/2,
    query_leases/1,
    query_node_leases/2,
    leases/1,
    epochs/1,
    counts/1
]).

-export_type([state/0, lease/0, fence/0, key/0, epoch/0]).

%% Take a snapshot once this many entries were applied since the last one.
-define(SNAPSHOT_EVERY, 4096).

-type key() :: term().
-type seq() :: pos_integer().
-type epoch() :: pos_integer().
-type fence() :: {atom(), epoch(), seq()}.
-type lease() :: #{
    key := key(),
    region := atom(),
    node := node(),
    pid := pid(),
    epoch := epoch(),
    seq := seq(),
    hlc := term()
}.

-record(held, {
    node :: node(),
    pid :: pid(),
    epoch :: epoch(),
    seq :: non_neg_integer(),
    cref :: reference(),
    hlc :: term()
}).

-record(cc, {
    region :: atom(),
    %% node -> {its current epoch, its lease_ms}
    nodes = #{} :: #{node() => {epoch(), pos_integer()}},
    last_epoch = 0 :: non_neg_integer(),
    leases = #{} :: #{key() => #held{}},
    %% holder pid -> its keys
    by_pid = #{} :: #{pid() => #{key() => true}},
    %% node -> number of leases it holds
    counts = #{} :: #{node() => pos_integer()},
    seq = 0 :: non_neg_integer(),
    %% key -> {Version, Value, HLC}
    kv = #{} :: #{binary() => {pos_integer(), term(), term()}},
    kv_seq = 0 :: non_neg_integer(),
    %% the index of the last release cursor
    cursor = 0 :: non_neg_integer()
}).

-opaque state() :: #cc{}.

%% ---- ra_machine ----

-spec init(map()) -> state().
init(Conf) ->
    #cc{region = maps:get(region, Conf, default)}.

-spec apply(ra_machine:command_meta_data(), term(), state()) ->
    {state(), term(), ra_machine:effects()}.
apply(#{index := Idx}, Cmd, S0) ->
    {S, Reply, Effs} = do(Cmd, S0),
    case Idx - S#cc.cursor >= ?SNAPSHOT_EVERY of
        true ->
            S1 = S#cc{cursor = Idx},
            {S1, Reply, Effs ++ [{release_cursor, Idx, S1}]};
        false ->
            {S, Reply, Effs}
    end.

%% On a new leader: every live node gets a full lease_ms from now, on this
%% leader's clock, and every holder is monitored again.
-spec state_enter(ra_server:ra_state() | eol, state()) -> ra_machine:effects().
state_enter(leader, #cc{nodes = Nodes, by_pid = ByPid}) ->
    [{timer, {expire, N, E}, L} || N := {E, L} <- Nodes] ++
        [{monitor, process, P} || P <- maps:keys(ByPid)];
state_enter(_, _) ->
    [].

-spec overview(state()) -> map().
overview(#cc{} = S) ->
    #{
        region => S#cc.region,
        nodes => S#cc.nodes,
        leases => map_size(S#cc.leases),
        keys => map_size(S#cc.kv)
    }.

%% ---- commands ----

do({renew, Node, Epoch, LeaseMs, Abandoned}, S0) ->
    {E, S1, Effs1} = renew(Node, Epoch, LeaseMs, S0),
    {S, Effs2} = abandon(Abandoned, Node, S1),
    {S, {ok, E}, Effs1 ++ Effs2};
do({timeout, {expire, Node, Epoch}}, S0 = #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {Epoch, _}} ->
            {S, Effs} = end_epoch(Node, Epoch, S0),
            {S#cc{nodes = maps:remove(Node, S#cc.nodes)}, ok, Effs};
        _ ->
            {S0, ok, []}
    end;
do({claim, Key, Node, Epoch, Pid, CRef, MaxLeases, Hlc}, S) ->
    case live(Node, Epoch, S) of
        true -> claim(Key, Node, Epoch, Pid, {CRef, MaxLeases, Hlc}, S);
        false -> {S, {error, stale_epoch}, []}
    end;
do({release, Key, Seq}, S0 = #cc{leases = Leases}) ->
    case Leases of
        #{Key := #held{seq = Seq} = H} ->
            {S, Effs} = drop(Key, H, S0),
            {S, ok, Effs};
        _ ->
            {S0, ok, []}
    end;
do({put, Key, Value, MaxKeys, Hlc}, S) ->
    put(Key, Value, MaxKeys, Hlc, S);
do({cas, Key, Version, Value, MaxKeys, Hlc}, S = #cc{kv = Kv}) ->
    Cur =
        case Kv of
            #{Key := {V, _, _}} -> V;
            _ -> 0
        end,
    case Cur of
        Version -> put(Key, Value, MaxKeys, Hlc, S);
        _ -> {S, {error, {version, Cur}}, []}
    end;
do({delete, Key, Hlc}, S = #cc{kv = Kv}) ->
    case maps:take(Key, Kv) of
        {{_, Value, _}, Kv1} ->
            {S#cc{kv = Kv1}, ok, kv_events(delete, Key, Value, Hlc, S)};
        error ->
            {S, ok, []}
    end;
do({down, Pid, noconnection}, S) ->
    {S, ok, [{monitor, node, node(Pid)}]};
do({down, Pid, _Reason}, S0) ->
    {S, Effs} = holder_down(Pid, S0),
    {S, ok, Effs};
do({nodeup, Node}, S = #cc{by_pid = ByPid}) ->
    {S, ok, [{monitor, process, P} || P <- maps:keys(ByPid), node(P) =:= Node]};
do({nodedown, _Node}, S) ->
    {S, ok, []};
do(_Unknown, S) ->
    {S, {error, unknown_command}, []}.

%% ---- liveness ----

%% The node's current epoch goes on, and the leader's timer restarts; any
%% other epoch it gives (a lapsed node, a restart, a stale one) starts a new
%% epoch and ends the current one.
renew(Node, Epoch, LeaseMs, S0 = #cc{nodes = Nodes, last_epoch = Last}) ->
    case Nodes of
        #{Node := {Epoch, _}} ->
            S = S0#cc{nodes = Nodes#{Node := {Epoch, LeaseMs}}},
            {Epoch, S, [{timer, {expire, Node, Epoch}, LeaseMs}]};
        _ ->
            New = Last + 1,
            {S1, Effs} =
                case Nodes of
                    #{Node := {Old, _}} ->
                        {SA, EA} = end_epoch(Node, Old, S0),
                        {SA, [{timer, {expire, Node, Old}, infinity} | EA]};
                    _ ->
                        {S0, []}
                end,
            S = S1#cc{
                nodes = (S1#cc.nodes)#{Node => {New, LeaseMs}},
                last_epoch = New
            },
            {New, S, Effs ++ [{timer, {expire, Node, New}, LeaseMs}]}
    end.

live(Node, Epoch, #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {Epoch, _}} -> true;
        _ -> false
    end.

%% Drop every lease of the node's epoch, and tell its agent each key is
%% gone (its holders were told already, by its own deadline).
end_epoch(Node, Epoch, S0 = #cc{leases = Leases}) ->
    maps:fold(
        fun
            (Key, #held{node = N, epoch = E, seq = Seq} = H, {SA, EA}) when
                N =:= Node, E =:= Epoch
            ->
                {SB, EB} = drop(Key, H, SA),
                Taken =
                    {send_msg, {chappe_cluster_node, Node},
                        {chappe_cluster_taken, Key, Seq}},
                {SB, EA ++ [Taken | EB]};
            (_, _, Acc) ->
                Acc
        end,
        {S0, []},
        Leases
    ).

holder_down(Pid, S0 = #cc{by_pid = ByPid}) ->
    Keys = maps:keys(maps:get(Pid, ByPid, #{})),
    lists:foldl(
        fun(Key, {SA, EA}) ->
            #{Key := H} = SA#cc.leases,
            {SB, EB} = drop(Key, H, SA),
            {SB, EA ++ EB}
        end,
        {S0, []},
        Keys
    ).

%% Release what a node gave up on: a claim its caller timed out on (by
%% claim ref), or a lease its holders were told was lost, or released
%% without a quorum (by seq). Only the lease that claim or seq names.
abandon(Abandoned, Node, S0) ->
    lists:foldl(
        fun(Item, {SA, EA}) ->
            case abandoned(Item, Node, SA#cc.leases) of
                {ok, Key, H} ->
                    {SB, EB} = drop(Key, H, SA),
                    {SB, EA ++ EB};
                none ->
                    {SA, EA}
            end
        end,
        {S0, []},
        Abandoned
    ).

abandoned({claim, Key, CRef}, Node, Leases) ->
    case Leases of
        #{Key := #held{node = Node, cref = CRef} = H} -> {ok, Key, H};
        _ -> none
    end;
abandoned({seq, Key, Seq}, Node, Leases) ->
    case Leases of
        #{Key := #held{node = Node, seq = Seq} = H} -> {ok, Key, H};
        _ -> none
    end;
abandoned(_, _, _) ->
    none.

%% ---- leases ----

claim(Key, Node, Epoch, Pid, {CRef, Max, Hlc}, S0 = #cc{leases = Leases}) ->
    case Leases of
        #{Key := #held{pid = Pid, node = Node, epoch = Epoch} = H} ->
            %% the holder claims again: a new seq, so a release or an
            %% abandon queued for the old claim leaves this one alone
            Seq = S0#cc.seq + 1,
            H1 = H#held{seq = Seq, cref = CRef, hlc = Hlc},
            S = S0#cc{leases = Leases#{Key := H1}, seq = Seq},
            {S, {ok, view(Key, H1, S)}, []};
        #{Key := H} ->
            {S0, {error, {owned, owner_view(H, S0)}}, []};
        _ ->
            grant(
                Key,
                #held{
                    node = Node,
                    pid = Pid,
                    epoch = Epoch,
                    seq = 0,
                    cref = CRef,
                    hlc = Hlc
                },
                Max,
                S0
            )
    end.

grant(Key, H0 = #held{node = Node, pid = Pid}, Max, S) ->
    #cc{leases = Leases, counts = Counts, by_pid = ByPid, seq = Seq0} = S,
    Count = maps:get(Node, Counts, 0),
    case Count < Max of
        false ->
            {S, {error, max_leases}, []};
        true ->
            Seq = Seq0 + 1,
            H = H0#held{seq = Seq},
            Keys = maps:get(Pid, ByPid, #{}),
            S1 = S#cc{
                leases = Leases#{Key => H},
                counts = Counts#{Node => Count + 1},
                by_pid = ByPid#{Pid => Keys#{Key => true}},
                seq = Seq
            },
            {S1, {ok, view(Key, H, S1)}, [{monitor, process, Pid}]}
    end.

%% Remove one lease; demonitor its holder when it holds nothing else.
drop(Key, #held{node = Node, pid = Pid}, S) ->
    #cc{leases = Leases, counts = Counts, by_pid = ByPid} = S,
    Counts1 =
        case maps:get(Node, Counts, 1) of
            1 -> maps:remove(Node, Counts);
            C -> Counts#{Node := C - 1}
        end,
    Keys = maps:remove(Key, maps:get(Pid, ByPid, #{})),
    {ByPid1, Effs} =
        case map_size(Keys) of
            0 -> {maps:remove(Pid, ByPid), [{demonitor, process, Pid}]};
            _ -> {ByPid#{Pid := Keys}, []}
        end,
    S1 = S#cc{
        leases = maps:remove(Key, Leases), counts = Counts1, by_pid = ByPid1
    },
    {S1, Effs}.

view(Key, #held{node = N, pid = P, epoch = E, seq = Seq, hlc = Hlc}, #cc{
    region = R
}) ->
    #{
        key => Key,
        region => R,
        node => N,
        pid => P,
        epoch => E,
        seq => Seq,
        hlc => Hlc
    }.

owner_view(#held{node = N, pid = P, epoch = E, seq = Seq}, #cc{region = R}) ->
    #{node => N, pid => P, fence => {R, E, Seq}}.

%% ---- KV ----

put(Key, Value, MaxKeys, Hlc, S = #cc{kv = Kv, kv_seq = V0}) ->
    case maps:is_key(Key, Kv) orelse map_size(Kv) < MaxKeys of
        false ->
            {S, {error, max_keys}, []};
        true ->
            V = V0 + 1,
            S1 = S#cc{kv = Kv#{Key => {V, Value, Hlc}}, kv_seq = V},
            {S1, {ok, V}, kv_events(put, Key, Value, Hlc, S1)}
    end.

%% One event per live node, for the watch hub on that node. With `local',
%% a member hands it to the hub on its own node and the leader to the nodes
%% that run no member; a node without a hub drops it.
kv_events(Op, Key, Value, Hlc, #cc{nodes = Nodes}) ->
    Msg = {chappe_cluster_kv, Op, Key, Value, Hlc},
    [
        {send_msg, {chappe_cluster_watch, N}, Msg, [local]}
     || N <- lists:sort(maps:keys(Nodes))
    ].

%% ---- queries (run inside Ra, the state last) ----

-spec query_owner(key(), state()) ->
    {ok, #{node := node(), pid := pid(), fence := fence()}} | none.
query_owner(Key, S = #cc{leases = Leases}) ->
    case Leases of
        #{Key := H} -> {ok, owner_view(H, S)};
        _ -> none
    end.

-spec query_get(binary(), state()) -> {ok, term(), pos_integer()} | not_found.
query_get(Key, #cc{kv = Kv}) ->
    case Kv of
        #{Key := {V, Value, _}} -> {ok, Value, V};
        _ -> not_found
    end.

%% Every lease, with its owner, fence and HLC.
-spec query_leases(state()) -> [map()].
query_leases(S) ->
    leases(S).

%% The leases a node holds, as lease() values.
-spec query_node_leases(node(), state()) -> [lease()].
query_node_leases(Node, S = #cc{leases = Leases}) ->
    [view(K, H, S) || K := #held{node = N} = H <- Leases, N =:= Node].

-spec leases(state()) -> [map()].
leases(S = #cc{leases = Leases}) ->
    lists:sort([
        (owner_view(H, S))#{key => K, hlc => H#held.hlc}
     || K := H <- Leases
    ]).

-spec epochs(state()) -> #{node() => epoch()}.
epochs(#cc{nodes = Nodes}) ->
    #{N => E || N := {E, _} <- Nodes}.

-spec counts(state()) -> #{node() => pos_integer()}.
counts(#cc{counts = C}) ->
    C.
