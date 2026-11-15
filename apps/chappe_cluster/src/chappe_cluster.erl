%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_cluster: one owner per key across a region, on Ra.
%%
%% Leases: claim/2 gives a key one holder in the region, fenced, until the
%% holder releases it, dies, or its node's liveness lapses. The holder is
%% told `{chappe_cluster, Lease, lost}' when its node lapses or its key is
%% taken over. A claim never waits past its timeout: without a quorum it
%% returns `{error, no_quorum}'.
%%
%% KV: a small map with versions, replicated with the leases. Keys are
%% binaries; watch/1 streams changes under a prefix.
%%
%% Singletons: singleton/2 runs a child on one node of the region.
%%
%% Every write goes through the region's Raft log; reads come from the local
%% replica unless `consistent' is asked. Arguments are checked here, in the
%% caller's process: a bad one returns `{error, badarg}'.
-module(chappe_cluster).

-compile({no_auto_import, [get/1, put/2]}).

-export([
    claim/2,
    release/1,
    owner/1,
    owner/2,
    fence/1,
    valid/1,
    leases/0,
    get/1,
    put/2,
    delete/1,
    cas/3,
    watch/1,
    unwatch/1,
    singleton/2,
    stop_singleton/1,
    whereis_singleton/1,
    singleton_fence/1,
    home/1,
    join/1,
    leave/1,
    status/0
]).

-export_type([lease/0, fence/0, owner/0]).

-type lease() :: chappe_cluster_machine:lease().
-type fence() :: {
    Region :: atom(), NodeEpoch :: pos_integer(), Seq :: pos_integer()
}.
-type owner() :: #{node := node(), pid := pid(), fence := fence()}.

-define(M, chappe_cluster_machine).
-define(SYSTEM, chappe_cluster).

%% ---- leases ----

%% Claim `Key' for `pid' (default the caller). Options: `pid', a process on
%% this node (the lease follows this node's liveness), and `timeout' in ms
%% (default command_timeout). Claiming a key you already hold returns a new
%% lease with a greater fence. A grant that comes back after this node lost
%% its liveness is given back and returns no_quorum.
-spec claim(term(), map()) ->
    {ok, lease()}
    | {error, {owned, owner()}}
    | {error, no_quorum}
    | {error, max_leases}
    | {error, badarg}.
claim(Key, Opts) when is_map(Opts) ->
    Pid = maps:get(pid, Opts, self()),
    Timeout = maps:get(timeout, Opts, cfg(command_timeout)),
    case is_pid(Pid) andalso node(Pid) =:= node() andalso is_timeout(Timeout) of
        true -> do_claim(Key, Pid, Timeout);
        false -> {error, badarg}
    end;
claim(_, _) ->
    {error, badarg}.

do_claim(Key, Pid, Timeout) ->
    case chappe_cluster_node:live_gen() of
        {ok, Epoch, Gen} ->
            CRef = make_ref(),
            Cmd = {claim, Key, node(), Epoch, Pid, CRef, cfg(max_leases)},
            claimed(command(Cmd, Timeout), Key, CRef, {Epoch, Gen});
        not_live ->
            {error, no_quorum}
    end.

claimed({ok, {ok, Lease}}, _Key, _CRef, {Epoch, Gen}) ->
    %% still live, at the epoch and with no lapse since the claim left
    case chappe_cluster_tab:hold(Lease, Epoch, Gen) of
        ok -> {ok, Lease};
        lapsed -> {error, no_quorum}
    end;
claimed({ok, {error, stale_epoch}}, _Key, _CRef, _) ->
    %% the leader saw this node lapse before this node did
    {error, no_quorum};
claimed({ok, {error, _} = E}, _Key, _CRef, _) ->
    E;
claimed({error, no_quorum}, Key, CRef, _) ->
    %% the claim may still be applied: have the next renewal undo it
    ok = chappe_cluster_node:abandon(node(), {claim, Key, CRef}),
    {error, no_quorum}.

%% Give a lease back. Without a quorum the release goes with the node's
%% next renewal; it returns ok either way.
-spec release(lease()) -> ok | {error, badarg}.
release(#{key := Key, seq := Seq, node := Node} = Lease) ->
    ok =
        case Node =:= node() of
            true -> chappe_cluster_tab:unhold(Key, Seq);
            false -> chappe_cluster_node:untrack(Lease)
        end,
    case command({release, Key, Seq}, cfg(command_timeout)) of
        {ok, ok} -> ok;
        {error, no_quorum} -> chappe_cluster_node:abandon(Node, {seq, Key, Seq})
    end;
release(_) ->
    {error, badarg}.

%% The key's current owner, from the local replica (or the leader when this
%% node runs no member).
-spec owner(term()) -> {ok, owner()} | none | {error, no_quorum}.
owner(Key) ->
    query({?M, query_owner, [Key, now_ms()]}).

%% The same, read through the leader.
-spec owner(term(), consistent) -> {ok, owner()} | none | {error, no_quorum}.
owner(Key, consistent) ->
    consistent({?M, query_owner, [Key, now_ms()]});
owner(_, _) ->
    {error, badarg}.

%% The fence a side effect carries: compare fences by Seq, which grows
%% strictly per key.
-spec fence(lease()) -> fence().
fence(#{region := R, epoch := E, seq := S}) ->
    {R, E, S}.

%% Whether the lease still holds on this node: its node is live at its
%% epoch, before the local deadline, and it was not lost, released or
%% taken over. Check it before each side effect, and carry the fence.
%% False on any other node than the lease's.
-spec valid(term()) -> boolean().
valid(#{node := Node, key := _, seq := _, epoch := _} = Lease) when
    Node =:= node()
->
    chappe_cluster_tab:valid(Lease);
valid(_) ->
    false.

%% Every valid lease in the region, from the local replica.
-spec leases() ->
    [#{key := term(), node := node(), pid := pid(), fence := fence()}].
leases() ->
    case query({?M, query_leases, [now_ms()]}) of
        L when is_list(L) -> L;
        {error, no_quorum} -> []
    end.

%% ---- KV ----

-spec get(binary()) ->
    {ok, term(), pos_integer()} | not_found | {error, term()}.
get(Key) when is_binary(Key) ->
    query({?M, query_get, [Key]});
get(_) ->
    {error, badarg}.

-spec put(binary(), term()) ->
    {ok, pos_integer()} | {error, no_quorum | max_keys | too_large | badarg}.
put(Key, Value) when is_binary(Key) ->
    write(Value, {put, Key, Value, cfg(max_keys)});
put(_, _) ->
    {error, badarg}.

-spec delete(binary()) -> ok | {error, no_quorum | badarg}.
delete(Key) when is_binary(Key) ->
    case command({delete, Key}, cfg(command_timeout)) of
        {ok, ok} -> ok;
        {error, _} = E -> E
    end;
delete(_) ->
    {error, badarg}.

%% Write `Value' when the key's version is `Version' (0: the key is absent).
-spec cas(binary(), non_neg_integer(), term()) ->
    {ok, pos_integer()}
    | {error, {version, non_neg_integer()}}
    | {error, no_quorum | max_keys | too_large | badarg}.
cas(Key, Version, Value) when
    is_binary(Key), is_integer(Version), Version >= 0
->
    write(Value, {cas, Key, Version, Value, cfg(max_keys)});
cas(_, _, _) ->
    {error, badarg}.

write(Value, Cmd) ->
    case erlang:external_size(Value) > cfg(max_value_bytes) of
        true ->
            {error, too_large};
        false ->
            case command(Cmd, cfg(command_timeout)) of
                {ok, Reply} -> Reply;
                {error, _} = E -> E
            end
    end.

%% The caller gets `{chappe_cluster, watch, {put | delete, Key, Value}}'
%% for each change under `Prefix' (`<<>>' for all), or `{chappe_cluster,
%% watch, overflow}' once when its mailbox is full, which ends its watches.
-spec watch(binary()) -> ok | {error, badarg}.
watch(Prefix) when is_binary(Prefix) ->
    chappe_cluster_watch:watch(self(), Prefix);
watch(_) ->
    {error, badarg}.

-spec unwatch(binary()) -> ok | {error, badarg}.
unwatch(Prefix) when is_binary(Prefix) ->
    chappe_cluster_watch:unwatch(self(), Prefix);
unwatch(_) ->
    {error, badarg}.

%% ---- singletons ----

%% Contend for `Name' from this node: the node that holds its lease runs
%% `ChildSpec' (a map child spec; its restart is forced to temporary), and
%% another node takes over when it stops. Call it on every node that may
%% run it.
-spec singleton(term(), supervisor:child_spec()) ->
    ok | {error, already_started | badarg | term()}.
singleton(Name, #{id := _, start := {M, F, A}} = Spec) when
    is_atom(M), is_atom(F), is_list(A)
->
    Contender = #{
        id => Name,
        start => {chappe_cluster_singleton, start_link, [Name, Spec]},
        restart => transient,
        shutdown => 10000
    },
    case supervisor:start_child(chappe_cluster_singleton_sup, Contender) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> {error, already_started};
        {error, already_present} -> {error, already_started};
        {error, _} = E -> E
    end;
singleton(_, _) ->
    {error, badarg}.

%% Stop contending for `Name' from this node (and stop it if it runs here).
-spec stop_singleton(term()) -> ok | {error, not_found}.
stop_singleton(Name) ->
    case supervisor:terminate_child(chappe_cluster_singleton_sup, Name) of
        ok -> supervisor:delete_child(chappe_cluster_singleton_sup, Name);
        {error, _} = E -> E
    end.

%% The running singleton's pid, on whichever node runs it (pg).
-spec whereis_singleton(term()) -> {ok, pid()} | none.
whereis_singleton(Name) ->
    case pg:get_members(chappe_cluster, chappe_cluster_singleton:group(Name)) of
        [Pid | _] -> {ok, Pid};
        [] -> none
    end.

%% The fence of `Name' when this node runs it.
-spec singleton_fence(term()) -> {ok, fence()} | none.
singleton_fence(Name) ->
    Children = supervisor:which_children(chappe_cluster_singleton_sup),
    case lists:keyfind(Name, 1, Children) of
        {Name, Pid, _, _} when is_pid(Pid) ->
            chappe_cluster_singleton:fence(Pid);
        _ ->
            none
    end.

%% ---- regions ----

%% The region that owns `Key': this node's region in this release.
-spec home(term()) -> atom().
home(_Key) ->
    cfg(region).

%% ---- membership ----

%% Add `Node' to the region's voters, then start its member. Ra changes
%% membership one node at a time: a join during another change returns an
%% error; retry it.
-spec join(node()) -> ok | {error, term()}.
join(Node) when is_atom(Node) ->
    Id = chappe_cluster_config:server_id(Node),
    Timeout = cfg(command_timeout),
    case ra:add_member(chappe_cluster_node:members(), Id, Timeout) of
        {ok, _, Leader} -> start_remote(Node, Leader, Timeout);
        {error, already_member} -> ok;
        {timeout, _} -> {error, no_quorum};
        {error, _} = E -> E
    end;
join(_) ->
    {error, badarg}.

start_remote(Node, Leader, Timeout) ->
    case ra:members(Leader, Timeout) of
        {ok, Ids, _} -> start_remote_member(Node, Ids, Timeout);
        {timeout, _} -> {error, no_quorum};
        {error, _} = E -> E
    end.

start_remote_member(Node, Ids, Timeout) ->
    try
        erpc:call(
            Node, chappe_cluster_node, start_member, [Ids], Timeout + 12000
        )
    of
        ok -> ok;
        {error, _} = E -> E
    catch
        error:{erpc, Reason} -> {error, Reason};
        exit:Reason -> {error, Reason}
    end.

%% Remove `Node' from the region's voters, then stop and delete its member
%% when the node is reachable.
-spec leave(node()) -> ok | {error, term()}.
leave(Node) when is_atom(Node) ->
    Id = chappe_cluster_config:server_id(Node),
    Timeout = cfg(command_timeout),
    Members = [M || M <- chappe_cluster_node:members(), M =/= Id],
    case ra:remove_member(Members, Id, Timeout) of
        {ok, _, _} ->
            stop_remote(Node, Timeout);
        {error, not_member} ->
            ok;
        {timeout, _} ->
            {error, no_quorum};
        {error, _} = E ->
            E
    end;
leave(_) ->
    {error, badarg}.

%% A node that is down keeps its data; it is no longer a member either way.
stop_remote(Node, Timeout) ->
    try erpc:call(Node, chappe_cluster_node, stop_member, [], Timeout) of
        ok -> ok
    catch
        error:{erpc, _} -> ok;
        exit:_ -> ok
    end.

%% This node's view: its region, epoch, whether it is live, the members
%% and the leader.
-spec status() -> map().
status() ->
    Members = chappe_cluster_node:members(),
    {Live, Epoch} =
        case chappe_cluster_node:live() of
            {ok, E} -> {true, E};
            not_live -> {false, undefined}
        end,
    Leader =
        case ra:members(Members, 1000) of
            {ok, _, L} -> L;
            _ -> undefined
        end,
    #{
        region => cfg(region),
        node => node(),
        live => Live,
        epoch => Epoch,
        members => Members,
        leader => Leader
    }.

%% ---- internals ----

command(Cmd, Timeout) ->
    case
        ra:process_command(chappe_cluster_node:members(), Cmd, #{
            timeout => Timeout
        })
    of
        {ok, Reply, _Leader} -> {ok, Reply};
        {timeout, _} -> {error, no_quorum};
        {error, _} -> {error, no_quorum}
    end.

query(Q) ->
    Timeout = cfg(command_timeout),
    Result =
        case chappe_cluster_node:has_member() of
            true ->
                ra:local_query(chappe_cluster_config:server_id(), Q, Timeout);
            false ->
                ra:leader_query(chappe_cluster_node:members(), Q, Timeout)
        end,
    case Result of
        {ok, {_IdxTerm, Reply}, _} -> Reply;
        _ -> {error, no_quorum}
    end.

consistent(Q) ->
    case
        ra:consistent_query(
            chappe_cluster_node:members(), Q, cfg(command_timeout)
        )
    of
        {ok, Reply, _} -> Reply;
        _ -> {error, no_quorum}
    end.

cfg(Key) ->
    chappe_cluster_config:get(Key).

now_ms() ->
    erlang:system_time(millisecond).

is_timeout(T) -> is_integer(T) andalso T >= 0.
