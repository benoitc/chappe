%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node's agent in its region. One per node, registered locally. It:
%%
%% - starts the Ra system and, when this node is a voter, the region's Ra
%%   server;
%% - renews the node's liveness every renew_ms, in a monitored helper so a
%%   slow quorum never blocks it;
%% - keeps the leases claimed through this node, monitors their holders,
%%   and tells each holder `{chappe_cluster, Lease, lost}' when the node's
%%   liveness lapses, its epoch changes or its key is taken over;
%% - queues what could not reach the quorum (an abandoned claim, a release,
%%   a lost lease) and sends it with the next renewal.
%%
%% The local deadline: a renewal sent at T keeps the node live, in the
%% leader's view, until at least T + lease_ms. The agent gives every lease
%% up at T + lease_ms - renew_ms / 2, so a holder stops before another node
%% can take its key, with renew_ms / 2 of margin for clock skew between the
%% leaders.
%%
%% Its ETS table (protected, read by the facade without a call) holds the
%% region's members and the node's epoch with its deadline.
-module(chappe_cluster_node).
-behaviour(gen_server).

-export([
    start_link/0,
    live/0,
    members/0,
    has_member/0,
    track/1,
    untrack/1,
    abandon/2,
    start_member/1,
    stop_member/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, ?MODULE).
-define(SYSTEM, chappe_cluster).

-record(state, {
    epoch :: undefined | pos_integer(),
    lapse :: undefined | reference(),
    %% the renewal in flight: helper monitor, its send time, what it carries
    renew :: undefined | {reference(), integer(), list()},
    %% key -> {Lease, holder monitor}
    tracked = #{} :: #{term() => {map(), reference()}},
    mons = #{} :: #{reference() => term()},
    pending = [] :: list(),
    %% fetch this node's leases on the next renewal (after a restart)
    retrack = true :: boolean()
}).

-type state() :: #state{}.

%% ---- API ----

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The node's epoch while its liveness holds, from the local deadline.
-spec live() -> {ok, pos_integer()} | not_live.
live() ->
    try ets:lookup(?TAB, live) of
        [{live, Epoch, Deadline}] when is_integer(Epoch) ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> {ok, Epoch};
                false -> not_live
            end;
        _ ->
            not_live
    catch
        error:badarg -> not_live
    end.

%% The region's Ra members as this node last saw them.
-spec members() -> [{atom(), node()}].
members() ->
    try ets:lookup(?TAB, members) of
        [{members, Ms}] -> Ms;
        [] -> []
    catch
        error:badarg -> []
    end.

%% Whether this node runs a member of the region.
-spec has_member() -> boolean().
has_member() ->
    whereis(chappe_cluster_config:server_name()) =/= undefined.

-spec track(map()) -> ok.
track(#{node := Node} = Lease) ->
    gen_server:cast({?MODULE, Node}, {track, Lease}).

-spec untrack(map()) -> ok.
untrack(#{node := Node, key := Key, seq := Seq}) ->
    gen_server:cast({?MODULE, Node}, {untrack, Key, Seq}).

%% Queue a release for the next renewal of `Node'.
-spec abandon(
    node(), {claim, term(), reference()} | {seq, term(), pos_integer()}
) ->
    ok.
abandon(Node, Item) ->
    gen_server:cast({?MODULE, Node}, {abandon, Item}).

%% Start this node's member with the region's members (join/1 calls it).
-spec start_member([{atom(), node()}]) -> ok | {error, term()}.
start_member(Ids) ->
    gen_server:call(?MODULE, {start_member, Ids}, infinity).

%% Stop and delete this node's member (leave/1 calls it).
-spec stop_member() -> ok.
stop_member() ->
    gen_server:call(?MODULE, stop_member, infinity).

%% ---- gen_server ----

-spec init(term()) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    ?TAB = ets:new(?TAB, [named_table, protected, set, {read_concurrency, true}]),
    Voters = chappe_cluster_config:get(voters),
    Ids = [chappe_cluster_config:server_id(N) || N <- Voters],
    true = ets:insert(?TAB, [{members, Ids}, {live, undefined, 0}]),
    ok = start_system(),
    case lists:member(node(), Voters) of
        true ->
            case member(Ids) of
                {ok, fresh} -> maybe_elect(Voters);
                {ok, restarted} -> ok
            end;
        false ->
            ok
    end,
    self() ! tick,
    {ok, #state{}}.

handle_call({start_member, Ids}, _From, St) ->
    true = ets:insert(?TAB, {members, Ids}),
    case member(Ids) of
        {ok, _} -> {reply, ok, St};
        {error, _} = E -> {reply, E, St}
    end;
handle_call(stop_member, _From, St) ->
    Id = chappe_cluster_config:server_id(),
    _ = ra:stop_server(?SYSTEM, Id),
    _ = ra:force_delete_server(?SYSTEM, Id),
    {reply, ok, St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({track, Lease}, St) ->
    {noreply, do_track(Lease, St)};
handle_cast({untrack, Key, Seq}, St) ->
    {noreply, forget(Key, Seq, St)};
handle_cast({abandon, {seq, Key, Seq} = Item}, St) ->
    {noreply, queue(Item, forget(Key, Seq, St))};
handle_cast({abandon, Item}, St) ->
    {noreply, queue(Item, St)};
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(tick, St) ->
    erlang:send_after(chappe_cluster_config:get(renew_ms), self(), tick),
    {noreply, start_renew(St)};
handle_info(
    {'DOWN', Ref, process, _, Result}, St = #state{renew = {Ref, Sent, Items}}
) ->
    {noreply, renewed(Result, Sent, Items, St#state{renew = undefined})};
handle_info({'DOWN', Ref, process, _, _}, St = #state{mons = Mons}) ->
    case maps:take(Ref, Mons) of
        {Key, Mons1} ->
            {noreply, St#state{
                mons = Mons1, tracked = maps:remove(Key, St#state.tracked)
            }};
        error ->
            {noreply, St}
    end;
handle_info({timeout, Ref, lapse}, St = #state{lapse = Ref}) ->
    true = ets:insert(?TAB, {live, undefined, 0}),
    {noreply, lose_all(St#state{lapse = undefined, epoch = undefined})};
handle_info({chappe_cluster_taken, Key, Seq}, St = #state{tracked = T}) ->
    case T of
        #{Key := {#{seq := Seq} = Lease, _}} ->
            lost(Lease),
            {noreply, forget(Key, Seq, St)};
        _ ->
            {noreply, St}
    end;
handle_info(Msg, St) ->
    logger:notice("chappe_cluster_node: unexpected ~0p", [Msg]),
    {noreply, St}.

terminate(shutdown, _St) ->
    stop_local();
terminate({shutdown, _}, _St) ->
    stop_local();
terminate(_Reason, _St) ->
    ok.

%% ---- Ra system and member ----

start_system() ->
    Dir = filename:join(
        to_list(chappe_cluster_config:get(data_dir)), atom_to_list(node())
    ),
    ok = filelib:ensure_path(Dir),
    Conf = (ra_system:default_config())#{
        name => ?SYSTEM,
        data_dir => Dir,
        wal_data_dir => Dir,
        names => ra_system:derive_names(?SYSTEM)
    },
    case ra_system:start(Conf) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

member(Ids) ->
    Id = chappe_cluster_config:server_id(),
    case ra:restart_server(?SYSTEM, Id) of
        ok ->
            {ok, restarted};
        {error, {already_started, _}} ->
            {ok, restarted};
        {error, _NotStartedBefore} ->
            Name = chappe_cluster_config:server_name(),
            UId = ra:new_uid(atom_to_binary(Name)),
            Conf = #{
                id => Id,
                uid => UId,
                cluster_name => Name,
                initial_members => Ids,
                log_init_args => #{uid => UId},
                machine =>
                    {module, chappe_cluster_machine, #{
                        region => chappe_cluster_config:get(region),
                        reap_ms => chappe_cluster_config:get(renew_ms)
                    }}
            },
            case ra:start_server(?SYSTEM, Conf) of
                ok -> {ok, fresh};
                {error, _} = E -> E
            end
    end.

%% A fresh region: the first voter starts the first election rather than
%% wait for its election timeout.
maybe_elect(Voters) ->
    case lists:min(Voters) =:= node() of
        true -> ra:trigger_election(chappe_cluster_config:server_id());
        false -> ok
    end.

stop_local() ->
    _ = ra:stop_server(?SYSTEM, chappe_cluster_config:server_id()),
    _ = ra_system:stop(?SYSTEM),
    ok.

%% ---- renewal ----

%% The helper's exit carries the result: exit/1 is not a crash, nothing
%% gets logged.
-dialyzer({nowarn_function, start_renew/1}).
start_renew(
    St = #state{renew = undefined, pending = Pending, retrack = Retrack}
) ->
    Members = members(),
    LeaseMs = chappe_cluster_config:get(lease_ms),
    Timeout = chappe_cluster_config:get(renew_ms),
    Sent = erlang:monotonic_time(millisecond),
    {_, Ref} = spawn_monitor(fun() ->
        exit({renewed, renew(Members, LeaseMs, Timeout, Pending, Retrack)})
    end),
    St#state{renew = {Ref, Sent, Pending}};
start_renew(St) ->
    St.

renew(Members, LeaseMs, Timeout, Items, Retrack) ->
    Cmd = {renew, node(), LeaseMs, Items},
    case ra:process_command(Members, Cmd, #{timeout => Timeout}) of
        {ok, {ok, Epoch}, Leader} ->
            Ms =
                case ra:members(Leader, Timeout) of
                    {ok, M, _} -> M;
                    _ -> Members
                end,
            {ok, Epoch, Ms, node_leases(Retrack, Leader, Timeout)};
        Other ->
            {error, Other}
    end.

node_leases(false, _, _) ->
    [];
node_leases(true, Leader, Timeout) ->
    Now = erlang:system_time(millisecond),
    Q = {chappe_cluster_machine, query_node_leases, [node(), Now]},
    case ra:leader_query(Leader, Q, Timeout) of
        {ok, {_, Leases}, _} -> Leases;
        _ -> retry
    end.

renewed({renewed, {ok, Epoch, Members, Leases}}, Sent, Items, St0) ->
    true = ets:insert(?TAB, {members, Members}),
    St1 =
        case St0#state.epoch of
            Epoch -> St0;
            _ -> lose_other_epochs(Epoch, St0)
        end,
    LeaseMs = chappe_cluster_config:get(lease_ms),
    RenewMs = chappe_cluster_config:get(renew_ms),
    Deadline = Sent + LeaseMs - RenewMs div 2,
    cancel(St1#state.lapse),
    Lapse = erlang:start_timer(Deadline, self(), lapse, [{abs, true}]),
    true = ets:insert(?TAB, {live, Epoch, Deadline}),
    St2 = St1#state{
        epoch = Epoch,
        lapse = Lapse,
        pending = St1#state.pending -- Items
    },
    retracked(Leases, St2);
renewed(_Failed, _Sent, _Items, St) ->
    %% no quorum: the lapse timer decides
    St.

retracked(retry, St) ->
    St;
retracked(Leases, St = #state{retrack = true}) ->
    lists:foldl(fun do_track/2, St#state{retrack = false}, Leases);
retracked(_, St) ->
    St.

cancel(undefined) ->
    ok;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

%% ---- tracked leases ----

do_track(#{key := Key, epoch := E, seq := Seq, pid := Pid} = Lease, St) ->
    case St#state.epoch =:= E andalso live() =:= {ok, E} of
        true ->
            St1 = forget(Key, any, St),
            Ref = erlang:monitor(process, Pid),
            St1#state{
                tracked = (St1#state.tracked)#{Key => {Lease, Ref}},
                mons = (St1#state.mons)#{Ref => Key}
            };
        false ->
            %% the node lapsed between the grant and now
            lost(Lease),
            queue({seq, Key, Seq}, St)
    end.

forget(Key, Seq, St = #state{tracked = T, mons = Mons}) ->
    case T of
        #{Key := {#{seq := S}, Ref}} when Seq =:= any; Seq =:= S ->
            erlang:demonitor(Ref, [flush]),
            St#state{
                tracked = maps:remove(Key, T), mons = maps:remove(Ref, Mons)
            };
        _ ->
            St
    end.

lose_all(St = #state{tracked = T}) ->
    lose(maps:keys(T), St).

lose_other_epochs(Epoch, St = #state{tracked = T}) ->
    lose([K || K := {#{epoch := E}, _} <- T, E =/= Epoch], St).

%% Tell each holder, and queue the release so the region frees the key as
%% soon as this node reaches it again.
lose(Keys, St0) ->
    lists:foldl(
        fun(Key, St) ->
            #{Key := {#{seq := Seq} = Lease, _}} = St#state.tracked,
            lost(Lease),
            queue({seq, Key, Seq}, forget(Key, Seq, St))
        end,
        St0,
        Keys
    ).

lost(#{pid := Pid} = Lease) ->
    Pid ! {chappe_cluster, Lease, lost},
    ok.

%% Bounded by max_leases: past it, the oldest item goes (its lease still
%% ends with the holder or the node).
queue(Item, St = #state{pending = P}) ->
    Max = chappe_cluster_config:get(max_leases),
    P1 = [Item | P],
    case length(P1) > Max of
        true -> St#state{pending = lists:sublist(P1, Max)};
        false -> St#state{pending = P1}
    end.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.
