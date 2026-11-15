%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node's agent in its region. One per node, registered locally. It:
%%
%% - starts the Ra system and, when this node is a voter, the region's Ra
%%   server, in a helper so a slow disk never blocks it;
%% - renews the node's liveness every renew_ms, in a monitored helper with
%%   one budget of renew_ms for the whole renewal;
%% - refreshes the region's members, off the renewal path;
%% - hands the region's takeovers to the holders, and drops the rows of
%%   holders that died.
%%
%% The holders, the pending releases and the node's liveness live in
%% `chappe_cluster_tab', which outlives this process; the lapse itself is
%% chappe_cluster_lapse's job, so a crash or a full mailbox here never
%% delays a `lost'.
%%
%% The local deadline: a renewal sent at T keeps the node live until the
%% leader's timer runs out, lease_ms after the leader applied it (later
%% than T) or after it became leader, on the leader's monotonic clock. The
%% node gives every lease up at T + lease_ms - renew_ms / 2 on its own
%% monotonic clock; chappe_cluster_config:timing_ok/3 checks that this
%% comes first under the max_drift bound. No wall clock is read.
-module(chappe_cluster_node).
-behaviour(gen_server).

-export([
    start_link/0,
    live/0,
    live_gen/0,
    members/0,
    has_member/0,
    untrack/1,
    abandon/2,
    start_member/1,
    stop_member/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SYSTEM, chappe_cluster).
%% how long a member operation (start, restart, stop) may take
-define(MEMBER_MS, 10000).

-record(state, {
    %% the renewal in flight: helper monitor, its send time, what it carries
    renew :: undefined | {reference(), integer(), list(), tuple()},
    %% the members refresh in flight
    refresh :: undefined | reference(),
    %% member operations in flight: helper monitor -> caller (or init)
    ops = #{} :: #{reference() => {gen_server:from() | init, reference()}}
}).

-type state() :: #state{}.

%% ---- API ----

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The node's epoch while its liveness holds, from the local deadline.
-spec live() -> {ok, pos_integer()} | not_live.
live() ->
    chappe_cluster_tab:live().

-spec live_gen() -> {ok, pos_integer(), non_neg_integer()} | not_live.
live_gen() ->
    chappe_cluster_tab:live_gen().

%% The region's Ra members as this node last saw them.
-spec members() -> [{atom(), node()}].
members() ->
    chappe_cluster_tab:members().

%% Whether this node runs a member of the region.
-spec has_member() -> boolean().
has_member() ->
    whereis(chappe_cluster_config:server_name()) =/= undefined.

%% Forget a lease held through `Node' (release/1 from another node).
-spec untrack(map()) -> ok.
untrack(#{node := Node, key := Key, seq := Seq}) ->
    gen_server:cast({?MODULE, Node}, {untrack, Key, Seq}).

%% Queue a release for the next renewal of `Node'.
-spec abandon(
    node(), {claim, term(), reference()} | {seq, term(), pos_integer()}
) ->
    ok.
abandon(Node, Item) when Node =:= node() ->
    chappe_cluster_tab:queue(Item);
abandon(Node, Item) ->
    gen_server:cast({?MODULE, Node}, {abandon, Item}).

%% Start this node's member with the region's members (join/1 calls it).
-spec start_member([{atom(), node()}]) -> ok | {error, term()}.
start_member(Ids) ->
    gen_server:call(?MODULE, {start_member, Ids}, ?MEMBER_MS + 1000).

%% Stop and delete this node's member (leave/1 calls it).
-spec stop_member() -> ok | {error, term()}.
stop_member() ->
    gen_server:call(?MODULE, stop_member, ?MEMBER_MS + 1000).

%% ---- gen_server ----

-spec init([]) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    Voters = chappe_cluster_config:get(voters),
    Ids = [chappe_cluster_config:server_id(N) || N <- Voters],
    case members() of
        [] -> chappe_cluster_tab:set_members(Ids);
        _ -> ok
    end,
    ok = start_system(),
    St =
        case lists:member(node(), Voters) of
            true -> member_op(fun() -> member(Ids, Voters) end, init, #state{});
            false -> #state{}
        end,
    self() ! tick,
    {ok, St}.

handle_call({start_member, Ids}, From, St) ->
    ok = chappe_cluster_tab:set_members(Ids),
    {noreply, member_op(fun() -> member(Ids, []) end, From, St)};
handle_call(stop_member, From, St) ->
    Id = chappe_cluster_config:server_id(),
    Stop = fun() ->
        _ = ra:stop_server(?SYSTEM, Id),
        _ = ra:force_delete_server(?SYSTEM, Id),
        ok
    end,
    {noreply, member_op(Stop, From, St)};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({untrack, Key, Seq}, St) ->
    ok = chappe_cluster_tab:unhold(Key, Seq),
    {noreply, St};
handle_cast({abandon, {seq, Key, Seq} = Item}, St) ->
    ok = chappe_cluster_tab:unhold(Key, Seq),
    ok = chappe_cluster_tab:queue(Item),
    {noreply, St};
handle_cast({abandon, Item}, St) ->
    ok = chappe_cluster_tab:queue(Item),
    {noreply, St};
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info(tick, St) ->
    erlang:send_after(chappe_cluster_config:get(renew_ms), self(), tick),
    ok = chappe_cluster_tab:sweep(),
    {noreply, start_refresh(start_renew(St))};
handle_info(
    {'DOWN', Ref, process, _, Result},
    St = #state{renew = {Ref, Sent, Items, Cmd}}
) ->
    renewed(Result, Sent, Items, Cmd),
    {noreply, St#state{renew = undefined}};
handle_info({'DOWN', Ref, process, _, Result}, St = #state{refresh = Ref}) ->
    refreshed(Result),
    {noreply, St#state{refresh = undefined}};
handle_info({'DOWN', Ref, process, _, Result}, St = #state{ops = Ops}) ->
    case maps:take(Ref, Ops) of
        {{From, TRef}, Ops1} ->
            _ = erlang:cancel_timer(TRef),
            op_done(From, Result),
            {noreply, St#state{ops = Ops1}};
        error ->
            {noreply, St}
    end;
handle_info({member_op_timeout, Ref}, St = #state{ops = Ops}) ->
    case maps:take(Ref, Ops) of
        {{From, _}, Ops1} ->
            erlang:demonitor(Ref, [flush]),
            op_done(From, {member, {error, timeout}}),
            {noreply, St#state{ops = Ops1}};
        error ->
            {noreply, St}
    end;
handle_info({chappe_cluster_taken, Key, Seq}, St) ->
    ok = chappe_cluster_tab:taken(Key, Seq),
    {noreply, St};
handle_info({'EXIT', _, _}, St) ->
    {noreply, St};
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

%% Run a member operation in a helper; its caller hears back when it ends,
%% or after ?MEMBER_MS. The helper's exit carries the result.
-dialyzer({nowarn_function, member_op/3}).
member_op(Fun, From, St = #state{ops = Ops}) ->
    {_, Ref} = spawn_monitor(fun() -> exit({member, Fun()}) end),
    TRef = erlang:send_after(?MEMBER_MS, self(), {member_op_timeout, Ref}),
    St#state{ops = Ops#{Ref => {From, TRef}}}.

op_done(init, {member, ok}) ->
    ok;
op_done(init, Result) ->
    logger:warning("chappe_cluster_node: member start: ~0p", [Result]);
op_done(From, {member, Reply}) ->
    gen_server:reply(From, Reply);
op_done(From, Other) ->
    gen_server:reply(From, {error, Other}).

%% Restart this node's member, or start it the first time. `Voters' is the
%% boot list: on a fresh region its first voter starts the first election.
member(Ids, Voters) ->
    Id = chappe_cluster_config:server_id(),
    case ra:restart_server(?SYSTEM, Id) of
        ok ->
            ok;
        {error, {already_started, _}} ->
            ok;
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
                        region => chappe_cluster_config:get(region)
                    }}
            },
            case ra:start_server(?SYSTEM, Conf) of
                ok -> maybe_elect(Voters, Id);
                {error, _} = E -> E
            end
    end.

maybe_elect([_ | _] = Voters, Id) ->
    case lists:min(Voters) =:= node() of
        true -> ra:trigger_election(Id);
        false -> ok
    end;
maybe_elect([], _Id) ->
    ok.

stop_local() ->
    _ = ra:stop_server(?SYSTEM, chappe_cluster_config:server_id()),
    _ = ra_system:stop(?SYSTEM),
    ok.

%% ---- renewal ----

%% The helper's exit carries the result: exit/1 is not a crash, nothing
%% gets logged.
-dialyzer({nowarn_function, start_renew/1}).
start_renew(St = #state{renew = undefined}) ->
    Items = chappe_cluster_tab:pending(),
    LeaseMs = chappe_cluster_config:get(lease_ms),
    Budget = chappe_cluster_config:get(renew_ms),
    Sent = erlang:monotonic_time(millisecond),
    Cmd =
        case {chappe_cluster_tab:incarnation(), live()} of
            {undefined, _} ->
                %% an app start: the region numbers this incarnation first
                {incarnate, node()};
            {_, {ok, E}} ->
                {renew, node(), E, LeaseMs, Items};
            {Inc, not_live} ->
                %% after a lapse, or at start: a new epoch, replacing the
                %% last one this incarnation knew
                Known = chappe_cluster_tab:known_epoch(),
                {renew, node(), {new, Inc, Known}, LeaseMs, Items}
        end,
    {_, Ref} = spawn_monitor(fun() ->
        exit({renewed, chappe_cluster_ra:command(Cmd, Budget)})
    end),
    St#state{renew = {Ref, Sent, Items, Cmd}};
start_renew(St) ->
    St.

renewed({renewed, {ok, {ok, Inc}}}, _Sent, _Items, {incarnate, _}) ->
    chappe_cluster_tab:set_incarnation(Inc);
renewed({renewed, {ok, {ok, Epoch}}}, Sent, Items, _Cmd) ->
    LeaseMs = chappe_cluster_config:get(lease_ms),
    RenewMs = chappe_cluster_config:get(renew_ms),
    Deadline = Sent + LeaseMs - RenewMs div 2,
    ok = chappe_cluster_tab:sent(Items),
    ok = chappe_cluster_tab:set_known_epoch(Epoch),
    case erlang:monotonic_time(millisecond) < Deadline of
        true ->
            ok = chappe_cluster_tab:lose_epochs(Epoch),
            ok = chappe_cluster_tab:renewed(Epoch, Deadline),
            chappe_cluster_lapse:arm(Deadline);
        false ->
            %% it came back too late to keep anything
            ok
    end;
renewed({renewed, {ok, {error, stale_epoch}}}, _Sent, _Items, Cmd) ->
    %% the region ended the epoch this node renews, or this incarnation is
    %% not the node's latest: the holders lose their leases now, and the
    %% next renewal asks for a new epoch (after a new incarnation)
    case Cmd of
        {renew, _, {new, _, _}, _, _} ->
            chappe_cluster_tab:set_incarnation(undefined);
        _ ->
            ok
    end,
    chappe_cluster_tab:lapse();
renewed(_Failed, _Sent, _Items, _Cmd) ->
    %% no quorum: the lapse timer decides
    ok.

%% The members, from a member's view, off the renewal path.
-dialyzer({nowarn_function, start_refresh/1}).
start_refresh(St = #state{refresh = undefined}) ->
    Members = members(),
    Budget = chappe_cluster_config:get(renew_ms),
    {_, Ref} = spawn_monitor(fun() ->
        exit({members, ra:members(Members, Budget)})
    end),
    St#state{refresh = Ref};
start_refresh(St) ->
    St.

refreshed({members, {ok, [_ | _] = Ms, Leader}}) ->
    ok = chappe_cluster_tab:set_leader(Leader),
    chappe_cluster_tab:set_members(Ms);
refreshed(_) ->
    ok.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) -> L.
