%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The region's Ra machine: node liveness, leases and a KV with versions.
%%
%% Leases follow the epoch-lease model. Each node renews one liveness
%% record, `{Epoch, Expires}'; a lease taken at that epoch is valid while the
%% record is, so a node keeps every lease it holds with one write per renew
%% period. A renewal after the record expired starts a new epoch, from a
%% region-wide counter, and the leases of the old epoch are dead.
%%
%% Time is deterministic: every timestamp is the `system_time' the leader
%% stamped on the command when it appended it, never this process's clock,
%% so each replica applies the log to the same state.
%%
%% Fences: a lease's fence is `{Region, NodeEpoch, Seq}'. Seq comes from a
%% region-wide counter bumped on every grant, so it is strictly increasing
%% per key (and across the region). Compare fences by Seq: the node epoch of
%% a takeover may be lower than the previous holder's.
%%
%% Holders are monitored through Ra's monitor effects, from the leader; a
%% holder's death releases its leases. A `noconnection' down keeps them:
%% the holder's node liveness decides, and its pids are monitored again on
%% `nodeup'.
-module(chappe_cluster_machine).
-behaviour(ra_machine).

-export([init/1, apply/3, state_enter/2, overview/1]).
-export([
    query_owner/3,
    query_get/2,
    query_leases/2,
    query_node_leases/3,
    leases/2,
    counts/1
]).

-export_type([state/0, lease/0, fence/0, key/0]).

%% Take a snapshot after this many applied commands.
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
    seq := seq()
}.

-record(held, {
    node :: node(),
    pid :: pid(),
    epoch :: epoch(),
    seq :: seq(),
    cref :: reference()
}).

-record(cc, {
    region :: atom(),
    reap_ms :: pos_integer(),
    %% node -> {Epoch, Expires}
    nodes = #{} :: #{node() => {epoch(), integer()}},
    last_epoch = 0 :: non_neg_integer(),
    leases = #{} :: #{key() => #held{}},
    %% holder pid -> its keys
    by_pid = #{} :: #{pid() => #{key() => true}},
    %% node -> number of leases it holds
    counts = #{} :: #{node() => pos_integer()},
    seq = 0 :: non_neg_integer(),
    kv = #{} :: #{binary() => {pos_integer(), term()}},
    kv_seq = 0 :: non_neg_integer(),
    %% a node was renewed into a new epoch, or may have expired, since the
    %% last reap
    dirty = false :: boolean()
}).

-opaque state() :: #cc{}.

%% ---- ra_machine ----

-spec init(map()) -> state().
init(Conf) ->
    #cc{
        region = maps:get(region, Conf, default),
        reap_ms = maps:get(reap_ms, Conf, 2000)
    }.

-spec apply(ra_machine:command_meta_data(), term(), state()) ->
    {state(), term(), ra_machine:effects()}.
apply(#{index := Idx} = Meta, Cmd, S0) ->
    Now = maps:get(system_time, Meta),
    {S, Reply, Effs} = do(Cmd, Now, S0),
    case Idx rem ?SNAPSHOT_EVERY of
        0 -> {S, Reply, Effs ++ [{release_cursor, Idx, S}]};
        _ -> {S, Reply, Effs}
    end.

%% On a new leader: monitor every holder again and start the reap timer.
-spec state_enter(ra_server:ra_state() | eol, state()) -> ra_machine:effects().
state_enter(leader, #cc{by_pid = ByPid, reap_ms = Reap}) ->
    [{monitor, process, P} || P <- maps:keys(ByPid)] ++
        [{timer, reap, Reap}];
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

do({renew, Node, LeaseMs, Abandoned}, Now, S0) ->
    {Epoch, S1} = renew(Node, LeaseMs, Now, S0),
    {S, Effs} = abandon(Abandoned, Node, S1),
    {S, {ok, Epoch}, Effs};
do({claim, Key, Node, Epoch, Pid, CRef, MaxLeases}, Now, S) ->
    case live(Node, Epoch, Now, S) of
        true -> claim(Key, Node, Epoch, Pid, CRef, MaxLeases, Now, S);
        false -> {S, {error, stale_epoch}, []}
    end;
do({release, Key, Seq}, _Now, S0 = #cc{leases = Leases}) ->
    case Leases of
        #{Key := #held{seq = Seq} = H} ->
            {S, Effs} = drop(Key, H, S0),
            {S, ok, Effs};
        _ ->
            {S0, ok, []}
    end;
do({put, Key, Value, MaxKeys}, _Now, S) ->
    put(Key, Value, MaxKeys, S);
do({cas, Key, Version, Value, MaxKeys}, _Now, S = #cc{kv = Kv}) ->
    Cur =
        case Kv of
            #{Key := {V, _}} -> V;
            _ -> 0
        end,
    case Cur of
        Version -> put(Key, Value, MaxKeys, S);
        _ -> {S, {error, {version, Cur}}, []}
    end;
do({delete, Key}, _Now, S = #cc{kv = Kv}) ->
    case maps:take(Key, Kv) of
        {{_, Value}, Kv1} ->
            {S#cc{kv = Kv1}, ok, kv_events(delete, Key, Value, S)};
        error ->
            {S, ok, []}
    end;
do({down, Pid, noconnection}, _Now, S) ->
    {S, ok, [{monitor, node, node(Pid)}]};
do({down, Pid, _Reason}, _Now, S0 = #cc{by_pid = ByPid}) ->
    Keys = maps:keys(maps:get(Pid, ByPid, #{})),
    {S, Effs} = lists:foldl(
        fun(Key, {SA, EA}) ->
            #{Key := H} = SA#cc.leases,
            {SB, EB} = drop(Key, H, SA),
            {SB, EA ++ EB}
        end,
        {S0, []},
        Keys
    ),
    {S, ok, Effs};
do({nodeup, Node}, _Now, S = #cc{by_pid = ByPid}) ->
    {S, ok, [{monitor, process, P} || P <- maps:keys(ByPid), node(P) =:= Node]};
do({nodedown, _Node}, _Now, S) ->
    {S, ok, []};
do({timeout, reap}, Now, S0 = #cc{reap_ms = Reap}) ->
    {S, Effs} = reap(Now, S0),
    {S, ok, Effs ++ [{timer, reap, Reap}]};
do(_Unknown, _Now, S) ->
    {S, {error, unknown_command}, []}.

%% ---- liveness ----

renew(Node, LeaseMs, Now, S = #cc{nodes = Nodes, last_epoch = Last}) ->
    case Nodes of
        #{Node := {Epoch, Expires}} when Now < Expires ->
            {Epoch, S#cc{nodes = Nodes#{Node := {Epoch, Now + LeaseMs}}}};
        _ ->
            Epoch = Last + 1,
            Nodes1 = Nodes#{Node => {Epoch, Now + LeaseMs}},
            {Epoch, S#cc{nodes = Nodes1, last_epoch = Epoch, dirty = true}}
    end.

live(Node, Epoch, Now, #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {Epoch, Expires}} -> Now < Expires;
        _ -> false
    end.

valid(#held{node = N, epoch = E}, Now, S) ->
    live(N, E, Now, S).

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

claim(Key, Node, Epoch, Pid, CRef, Max, Now, S0 = #cc{leases = Leases}) ->
    case Leases of
        #{Key := #held{pid = Pid, node = Node} = H} when
            H#held.epoch =:= Epoch
        ->
            %% the holder claims again: a new seq, so a release or an
            %% abandon queued for the old claim leaves this one alone
            Seq = S0#cc.seq + 1,
            H1 = H#held{seq = Seq, cref = CRef},
            S = S0#cc{leases = Leases#{Key := H1}, seq = Seq},
            {S, {ok, view(Key, H1, S)}, []};
        #{Key := H} ->
            case valid(H, Now, S0) of
                true ->
                    {S0, {error, {owned, owner_view(H, S0)}}, []};
                false ->
                    {S1, Effs} = drop(Key, H, S0),
                    Taken = {
                        send_msg,
                        {chappe_cluster_node, H#held.node},
                        {chappe_cluster_taken, Key, H#held.seq}
                    },
                    grant(Key, Node, Epoch, Pid, CRef, Max, S1, Effs ++ [Taken])
            end;
        _ ->
            grant(Key, Node, Epoch, Pid, CRef, Max, S0, [])
    end.

grant(Key, Node, Epoch, Pid, CRef, Max, S, Effs) ->
    #cc{leases = Leases, counts = Counts, by_pid = ByPid, seq = Seq0} = S,
    Count = maps:get(Node, Counts, 0),
    case Count < Max of
        false ->
            %% a refused takeover still drops the dead lease
            {S, {error, max_leases}, Effs};
        true ->
            Seq = Seq0 + 1,
            H = #held{
                node = Node, pid = Pid, epoch = Epoch, seq = Seq, cref = CRef
            },
            Keys = maps:get(Pid, ByPid, #{}),
            S1 = S#cc{
                leases = Leases#{Key => H},
                counts = Counts#{Node => Count + 1},
                by_pid = ByPid#{Pid => Keys#{Key => true}},
                seq = Seq
            },
            {S1, {ok, view(Key, H, S1)}, Effs ++ [{monitor, process, Pid}]}
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

%% Drop every lease that is no longer valid, and the liveness records of
%% expired nodes that hold nothing. Only walks the leases when a node may
%% have expired or changed epoch since the last reap.
reap(Now, S0 = #cc{nodes = Nodes}) ->
    Expired = [N || N := {_, Exp} <- Nodes, Now >= Exp],
    case Expired =:= [] andalso not S0#cc.dirty of
        true ->
            {S0, []};
        false ->
            {S1, Effs} = maps:fold(
                fun(Key, H, {SA, EA}) ->
                    case valid(H, Now, SA) of
                        true ->
                            {SA, EA};
                        false ->
                            {SB, EB} = drop(Key, H, SA),
                            {SB, EA ++ EB}
                    end
                end,
                {S0, []},
                S0#cc.leases
            ),
            Counts = S1#cc.counts,
            Nodes1 = maps:filter(
                fun(N, {_, Exp}) ->
                    Now < Exp orelse maps:is_key(N, Counts)
                end,
                S1#cc.nodes
            ),
            {S1#cc{nodes = Nodes1, dirty = false}, Effs}
    end.

view(Key, #held{node = N, pid = P, epoch = E, seq = Seq}, #cc{region = R}) ->
    #{key => Key, region => R, node => N, pid => P, epoch => E, seq => Seq}.

owner_view(#held{node = N, pid = P, epoch = E, seq = Seq}, #cc{region = R}) ->
    #{node => N, pid => P, fence => {R, E, Seq}}.

%% ---- KV ----

put(Key, Value, MaxKeys, S = #cc{kv = Kv, kv_seq = V0}) ->
    case maps:is_key(Key, Kv) orelse map_size(Kv) < MaxKeys of
        false ->
            {S, {error, max_keys}, []};
        true ->
            V = V0 + 1,
            S1 = S#cc{kv = Kv#{Key => {V, Value}}, kv_seq = V},
            {S1, {ok, V}, kv_events(put, Key, Value, S1)}
    end.

%% One event per node with a liveness record, for the watch hub on that
%% node. With `local', a member hands it to the hub on its own node and the
%% leader to the nodes that run no member; a node without a hub drops it.
kv_events(Op, Key, Value, #cc{nodes = Nodes}) ->
    Msg = {chappe_cluster_kv, Op, Key, Value},
    [
        {send_msg, {chappe_cluster_watch, N}, Msg, [local]}
     || N <- lists:sort(maps:keys(Nodes))
    ].

%% ---- queries (run inside Ra, the state last) ----

-spec query_owner(key(), integer(), state()) ->
    {ok, #{node := node(), pid := pid(), fence := fence()}} | none.
query_owner(Key, Now, S = #cc{leases = Leases}) ->
    case Leases of
        #{Key := H} ->
            case valid(H, Now, S) of
                true -> {ok, owner_view(H, S)};
                false -> none
            end;
        _ ->
            none
    end.

-spec query_get(binary(), state()) -> {ok, term(), pos_integer()} | not_found.
query_get(Key, #cc{kv = Kv}) ->
    case Kv of
        #{Key := {V, Value}} -> {ok, Value, V};
        _ -> not_found
    end.

%% Every valid lease, with its owner and fence.
-spec query_leases(integer(), state()) -> [map()].
query_leases(Now, S) ->
    leases(Now, S).

%% The valid leases a node holds, as lease() values.
-spec query_node_leases(node(), integer(), state()) -> [lease()].
query_node_leases(Node, Now, S = #cc{leases = Leases}) ->
    [
        view(K, H, S)
     || K := #held{node = N} = H <- Leases, N =:= Node, valid(H, Now, S)
    ].

-spec leases(integer(), state()) -> [map()].
leases(Now, S = #cc{leases = Leases}) ->
    lists:sort([
        (owner_view(H, S))#{key => K}
     || K := H <- Leases, valid(H, Now, S)
    ]).

-spec counts(state()) -> #{node() => pos_integer()}.
counts(#cc{counts = C}) ->
    C.
