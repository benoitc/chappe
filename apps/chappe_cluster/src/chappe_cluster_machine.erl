%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The region's Ra machine: node liveness, leases and a KV with versions.
%%
%% No clock. The machine never reads a time, neither its own nor the
%% `system_time' Ra puts in a command's metadata: it applies results.
%%
%% - `{renew, Node, Epoch, LeaseMs, Items}' keeps the node live when Epoch
%%   is its current epoch, and counts the renew. Any other epoch (a delayed
%%   command from before a lapse) is refused with `{error, stale_epoch}'
%%   and changes nothing;
%% - `{incarnate, Node}' gives the node its next incarnation number (an
%%   app start asks for one before anything else);
%% - `{renew, Node, {new, Inc, Replace, Ref}, LeaseMs, Items}' asks for a
%%   new epoch (from a region-wide counter) for incarnation Inc. It is
%%   stale unless Inc is the node's latest incarnation, and it ends the
%%   current epoch only when that epoch is the one it names (Replace, the
%%   last epoch this incarnation knew) or was taken by an earlier
%%   incarnation. So a delayed request, from an attempt that timed out or
%%   from an earlier incarnation, never ends the epoch a later attempt got.
%%   Ref names the request: the agent keeps it across its retries until
%%   one succeeds, and the epoch keeps the Ref that created it. When the
%%   current epoch was created by this incarnation with this Ref (a
%%   timed-out try applied, then its retry), the request renews that epoch
%%   and returns it, instead of a stale that would cost the node a new
%%   incarnation;
%% - `{timeout, {expire, Node, Epoch, Count}}' ends the node's epoch and
%%   frees its keys, only when {Epoch, Count} is still the node's current
%%   epoch and renew count; otherwise it changes nothing;
%% - a claim succeeds on a free key only: every lease of an ended epoch is
%%   dropped when the epoch ends. A second claim by the same holder is
%%   refused, so a delayed try never takes over the lease of its retry.
%%
%% Replay and snapshots are deterministic by construction.
%%
%% Expiry is the leader's decision, on its own monotonic clock: each renew
%% the leader applies cancels the node's previous timer and starts
%% `{expire, Node, Epoch, Count}' of lease_ms, named after that renew; a
%% new leader starts one for every live node as it takes over
%% (state_enter/2). Ra runs these timers on the leader only, on erlang
%% timers (monotonic), and when one fires it appends `{timeout, Name}' to
%% the log (ra_server_proc:leader/3, `machine_timeout'). That entry can
%% land behind a renew whose commit stalled; the renew counts, so the
%% stale timer no longer names the current renew and ends nothing. A timer
%% of a deposed leader that still lands is dropped the same way.
%%
%% Fences: a lease's fence is `{Region, NodeEpoch, Seq}'. Seq comes from a
%% region-wide counter bumped on every grant, so it is strictly increasing
%% per key (and across the region). Compare fences by Seq.
%%
%% HLC: claims, releases and KV writes carry the writer's hybrid logical
%% clock stamp (chappe_cluster:now/0). The machine merges it with the
%% latest stamp it handed out: the stamp, when it is later, or that latest
%% one with its logical part ticked. The merged stamp goes in the lease,
%% the leases() rows, the watch events and the reply, and the caller moves
%% its own clock to it. So whatever the region applies after an event is
%% later than it in HLC order, whichever node's wall clock runs ahead: a
%% claim after a release gets a later stamp than the release. The machine
%% never orders any ownership decision by it.
%%
%% Holders are monitored through Ra's monitor effects, from the leader; a
%% holder's death releases its leases. A `noconnection' down keeps them:
%% the holder's node liveness decides, and its pids are monitored again on
%% `nodeup'.
-module(chappe_cluster_machine).
-behaviour(ra_machine).

-include_lib("hlc/include/hlc.hrl").

-export([init/1, apply/3, state_enter/2, overview/1]).
-export([
    expire_timer/2,
    incarnation/2,
    query_owner/2,
    query_get/2,
    query_keys/4,
    query_leases/1,
    leases/1,
    epochs/1
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
    %% node -> {its current epoch, its lease_ms, its renew count, the
    %% incarnation that took the epoch, the ref of the request that took it}
    nodes = #{} :: #{
        node() => {epoch(), pos_integer(), pos_integer(), term(), term()}
    },
    %% node -> its latest incarnation number
    incs = #{} :: #{node() => pos_integer()},
    last_epoch = 0 :: non_neg_integer(),
    leases = #{} :: #{key() => #held{}},
    %% holder pid -> its keys
    by_pid = #{} :: #{pid() => #{key() => true}},
    %% node -> number of leases it holds
    counts = #{} :: #{node() => pos_integer()},
    seq = 0 :: non_neg_integer(),
    %% key -> {Version, Value, HLC}
    kv = #{} :: #{binary() => {pos_integer(), term(), term()}},
    %% the KV's keys, ordered, so a prefix listing seeks to the prefix and
    %% reads only the keys under it; kept in step with kv by put and delete
    kv_index = gb_sets:empty() :: gb_sets:set(binary()),
    kv_seq = 0 :: non_neg_integer(),
    %% the index of the last release cursor
    cursor = 0 :: non_neg_integer(),
    %% the latest HLC the region handed out
    hlc = #timestamp{} :: #timestamp{}
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
    [{timer, {expire, N, E, C}, L} || N := {E, L, C, _, _} <- Nodes] ++
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
    renewed(renew(Node, Epoch, LeaseMs, S0), Node, Abandoned, S0);
do({incarnate, Node}, S = #cc{incs = Incs}) ->
    Inc = maps:get(Node, Incs, 0) + 1,
    {S#cc{incs = Incs#{Node => Inc}}, {ok, Inc}, []};
do({timeout, {expire, Node, Epoch, Count}}, S0 = #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {Epoch, _, Count, _, _}} ->
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
do({release, Key, Seq, Hlc}, S) ->
    release(Key, Seq, Hlc, S);
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
do({delete, Key, Version, Hlc}, S) ->
    delete_version(Key, Version, Hlc, S);
do({delete, Key, Hlc}, S0) ->
    {Stamp, S = #cc{kv = Kv}} = stamp(Hlc, S0),
    case maps:take(Key, Kv) of
        {{_, Value, _}, Kv1} ->
            {
                S#cc{kv = Kv1, kv_index = gb_sets:delete(Key, S#cc.kv_index)},
                {ok, Stamp},
                kv_events(delete, Key, Value, Stamp, S)
            };
        error ->
            {S, {ok, Stamp}, []}
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

renewed({ok, E, S1, Effs1}, Node, Abandoned, _S0) ->
    {S, Effs2} = abandon(Abandoned, Node, S1),
    {S, {ok, E}, Effs1 ++ Effs2};
renewed(stale, _Node, _Abandoned, S0) ->
    {S0, {error, stale_epoch}, []}.

%% A new epoch for the node's latest incarnation, replacing the epoch it
%% names or one an earlier incarnation took; the same request applied
%% again renews the epoch it took; anything else is stale.
renew(
    Node,
    {new, Inc, Replace, Ref},
    LeaseMs,
    S0 = #cc{nodes = Nodes, incs = Incs}
) ->
    case {maps:get(Node, Incs, 0), Nodes} of
        {Inc, #{Node := {Epoch, _, _, Inc, Ref}}} ->
            %% this request took the current epoch already: a timed-out
            %% try applied before its retry, or after it
            renew(Node, Epoch, LeaseMs, S0);
        {Inc, #{Node := {Replace, _, _, Inc, _}}} ->
            new_epoch(Node, {Inc, Ref}, LeaseMs, S0);
        {Inc, #{Node := {_, _, _, Inc, _}}} ->
            %% this incarnation already got a newer epoch: a delayed try
            stale;
        {Inc, _} ->
            %% none yet, or an earlier incarnation's
            new_epoch(Node, {Inc, Ref}, LeaseMs, S0);
        _ ->
            %% not the node's latest incarnation
            stale
    end;
%% The node's current epoch goes on, its renew is counted, and the leader's
%% timer moves to this renew. Any other epoch is stale.
renew(Node, Epoch, LeaseMs, S0 = #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {Epoch, _, C, Inc, Ref}} ->
            S = S0#cc{
                nodes = Nodes#{Node := {Epoch, LeaseMs, C + 1, Inc, Ref}}
            },
            Effs = [
                {timer, {expire, Node, Epoch, C}, infinity},
                {timer, {expire, Node, Epoch, C + 1}, LeaseMs}
            ],
            {ok, Epoch, S, Effs};
        _ ->
            stale
    end.

%% A new epoch for the node, taken by incarnation Inc with request Ref; the
%% current one (if any) ends.
new_epoch(
    Node, {Inc, Ref}, LeaseMs, S0 = #cc{nodes = Nodes, last_epoch = Last}
) ->
    New = Last + 1,
    {S1, Effs} =
        case Nodes of
            #{Node := {Old, _, C, _, _}} ->
                {SA, EA} = end_epoch(Node, Old, S0),
                {SA, [{timer, {expire, Node, Old, C}, infinity} | EA]};
            _ ->
                {S0, []}
        end,
    S = S1#cc{
        nodes = (S1#cc.nodes)#{Node => {New, LeaseMs, 1, Inc, Ref}},
        last_epoch = New
    },
    {ok, New, S, Effs ++ [{timer, {expire, Node, New, 1}, LeaseMs}]}.

live(Node, Epoch, #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {Epoch, _, _, _, _}} -> true;
        _ -> false
    end.

%% Drop every lease of the node's epoch, and tell its agent each key is
%% gone. Nothing depends on that message, which may be lost: the holders
%% gave up already, by their own deadline, before the leader's timer could
%% end the epoch (chappe_cluster_config:timing_ok/3); the agent's sweep and
%% the epoch checks of valid/1 cover its row. It only tidies up earlier.
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
        #{Key := H} ->
            %% owned, by another holder or by this one through another try:
            %% a delayed try never takes over the lease of its retry, so
            %% the abandon of one try drops only its own lease
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
            {Stamp, #cc{hlc = Latest}} = stamp(H0#held.hlc, S),
            H = H0#held{seq = Seq, hlc = Stamp},
            Keys = maps:get(Pid, ByPid, #{}),
            S1 = S#cc{
                hlc = Latest,
                leases = Leases#{Key => H},
                counts = Counts#{Node => Count + 1},
                by_pid = ByPid#{Pid => Keys#{Key => true}},
                seq = Seq
            },
            {S1, {ok, view(Key, H, S1)}, [{monitor, process, Pid}]}
    end.

release(Key, Seq, Hlc, S0 = #cc{leases = Leases}) ->
    {Stamp, S1} = stamp(Hlc, S0),
    case Leases of
        #{Key := #held{seq = Seq} = H} ->
            {S, Effs} = drop(Key, H, S1),
            {S, {ok, Stamp}, Effs};
        _ ->
            {S1, {ok, Stamp}, []}
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
            {Stamp, S0} = stamp(Hlc, S),
            S1 = S0#cc{
                kv = Kv#{Key => {V, Value, Stamp}},
                kv_index = gb_sets:add_element(Key, S0#cc.kv_index),
                kv_seq = V
            },
            {S1, {ok, V, Stamp}, kv_events(put, Key, Value, Stamp, S1)}
    end.

%% A delete only of the version the writer read: a late one, or one racing
%% a write, changes nothing.
delete_version(Key, Version, Hlc, S = #cc{kv = Kv}) ->
    case Kv of
        #{Key := {Version, _, _}} -> do({delete, Key, Hlc}, S);
        #{Key := {Cur, _, _}} -> {S, {error, {version, Cur}}, []};
        _ -> {S, {error, {version, 0}}, []}
    end.

%% The region's next stamp: the command's, when it is later than the latest
%% the region handed out, or that latest one ticked.
stamp(#timestamp{} = Hlc, S = #cc{hlc = Latest}) when Hlc > Latest ->
    {Hlc, S#cc{hlc = Hlc}};
stamp(_Hlc, S = #cc{hlc = Latest = #timestamp{logical = L}}) ->
    Next = Latest#timestamp{logical = L + 1},
    {Next, S#cc{hlc = Next}}.

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

%% At most Limit keys that start with Prefix, sorted, after Cursor (a key
%% a previous page returned, or `start'). The work is the page, not the
%% KV: the ordered index seeks to the prefix (or the cursor) and stops at
%% the first key past it. `{more, Last}' when keys remain: pass Last as
%% the next page's cursor.
-spec query_keys(binary(), binary() | start, pos_integer(), state()) ->
    {[binary()], done | {more, binary()}}.
query_keys(Prefix, Cursor, Limit, #cc{kv_index = Index}) ->
    From =
        case Cursor of
            start -> Prefix;
            _ -> max(Prefix, Cursor)
        end,
    page(gb_sets:iterator_from(From, Index), Prefix, Cursor, Limit, []).

page(It0, Prefix, Cursor, Left, Acc) ->
    N = byte_size(Prefix),
    case gb_sets:next(It0) of
        {Cursor, It} ->
            %% the cursor itself: the previous page's last key
            page(It, Prefix, Cursor, Left, Acc);
        {<<P:N/binary, _/binary>> = K, It} when P =:= Prefix, Left > 0 ->
            page(It, Prefix, Cursor, Left - 1, [K | Acc]);
        {<<P:N/binary, _/binary>>, _} when P =:= Prefix ->
            %% a key under the prefix past a full page
            {lists:reverse(Acc), {more, hd(Acc)}};
        _ ->
            {lists:reverse(Acc), done}
    end.

%% Every lease, with its owner, fence and HLC.
-spec query_leases(state()) -> [map()].
query_leases(S) ->
    leases(S).

-spec leases(state()) -> [map()].
leases(S = #cc{leases = Leases}) ->
    lists:sort([
        (owner_view(H, S))#{key => K, hlc => H#held.hlc}
     || K := H <- Leases
    ]).

-spec epochs(state()) -> #{node() => epoch()}.
epochs(#cc{nodes = Nodes}) ->
    #{N => E || N := {E, _, _, _, _} <- Nodes}.

%% The node's latest incarnation number, 0 before any.
-spec incarnation(node(), state()) -> non_neg_integer().
incarnation(Node, #cc{incs = Incs}) ->
    maps:get(Node, Incs, 0).

%% The name of the node's current expire timer.
-spec expire_timer(node(), state()) ->
    {expire, node(), epoch(), pos_integer()} | none.
expire_timer(Node, #cc{nodes = Nodes}) ->
    case Nodes of
        #{Node := {E, _, C, _, _}} -> {expire, Node, E, C};
        _ -> none
    end.
