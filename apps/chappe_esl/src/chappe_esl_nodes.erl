%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Registry of FreeSWITCH nodes. A supervisor of one chappe_esl_node per
%% node, plus the pg scope that carries their notices. It owns the
%% `chappe_esl_nodes' ETS table (created in init/1, so it lives as long as
%% the registry): each node writes its own row, readers (status, select,
%% api) read it without a call. The registry starts with the nodes of the
%% `nodes' app env, or on the first add/2; without nodes it does not run.
-module(chappe_esl_nodes).
-behaviour(supervisor).

-export([child_spec/1, start_link/1]).
-export([add/2, remove/1, list/0, status/1, select/1]).
-export([drain/1, resume/1, api/2, bgapi/2]).
-export([subscribe/1, events/1, events/2, unsubscribe/1]).
-export([notify/3]).
-export([init/1]).

-export_type([name/0, select_opts/0]).

-define(TAB, ?MODULE).
-define(SCOPE, chappe_esl_nodes_pg).

-type name() :: term().
-type select_opts() :: #{
    policy => least_sessions | idle_cpu | weighted,
    tags => [term()]
}.

%% The child spec under chappe_esl_sup, with the nodes to start with.
-spec child_spec([{name(), map()}]) -> supervisor:child_spec().
child_spec(Nodes) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [Nodes]},
        type => supervisor,
        shutdown => infinity
    }.

-spec start_link([{name(), map()}]) -> supervisor:startlink_ret().
start_link(Nodes) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Nodes).

%% Add a node and start monitoring it.
-spec add(name(), map()) -> ok | {error, term()}.
add(Name, Opts) ->
    case chappe_esl_node:validate(Opts) of
        {ok, Config} ->
            ok = ensure_started(),
            case supervisor:start_child(?MODULE, node_spec(Name, Config)) of
                {ok, _Pid} -> ok;
                {error, {already_started, _}} -> {error, already_exists};
                {error, already_present} -> {error, already_exists};
                {error, Reason} -> {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

%% Stop monitoring a node and close its connection.
-spec remove(name()) -> ok | {error, not_found}.
remove(Name) ->
    case whereis(?MODULE) of
        undefined ->
            {error, not_found};
        _ ->
            case supervisor:terminate_child(?MODULE, {node, Name}) of
                ok ->
                    ok = supervisor:delete_child(?MODULE, {node, Name}),
                    ok;
                {error, not_found} ->
                    {error, not_found}
            end
    end.

%% Every node and its state, sorted by name.
-spec list() -> [{name(), chappe_esl_node:state()}].
list() ->
    lists:sort([{Name, maps:get(state, Row)} || {Name, Row} <- rows()]).

%% A node's state, configuration (without the password) and load.
-spec status(name()) -> {ok, map()} | {error, not_found}.
status(Name) ->
    case lookup(Name) of
        {ok, Row} -> {ok, public(Name, Row)};
        error -> {error, not_found}
    end.

%% Pick a node that is up, not draining and not full, carrying every tag
%% asked for. least_sessions (the default) takes the fewest sessions,
%% idle_cpu the most idle CPU, weighted a random node in proportion to its
%% weight. Ties go to the first name in term order.
-spec select(select_opts()) -> {ok, name()} | {error, none_up}.
select(Opts) ->
    Tags = maps:get(tags, Opts, []),
    Candidates = lists:sort([
        {Name, Row}
     || {Name, Row} <- rows(), selectable(Row, Tags)
    ]),
    case Candidates of
        [] -> {error, none_up};
        _ -> {ok, pick(maps:get(policy, Opts, least_sessions), Candidates)}
    end.

-spec drain(name()) -> ok | {error, not_found}.
drain(Name) ->
    call(Name, {drain, true}).

-spec resume(name()) -> ok | {error, not_found}.
resume(Name) ->
    call(Name, {drain, false}).

%% Run an api command on the node's own connection, in the caller.
-spec api(name(), iodata()) -> {ok, binary()} | {error, term()}.
api(Name, Cmd) ->
    with_conn(Name, fun(Conn) -> chappe_esl:api(Conn, Cmd) end).

%% Run a bgapi command on the node's connection. The BACKGROUND_JOB result
%% reaches the processes subscribed with events/1.
-spec bgapi(name(), iodata()) -> {ok, binary()} | {error, term()}.
bgapi(Name, Cmd) ->
    with_conn(Name, fun(Conn) -> chappe_esl:bgapi(Conn, Cmd) end).

%% Receive {chappe_esl_node, Name, up | down | draining | {load, Map}} for
%% one node, or for every node with `all'.
-spec subscribe(name() | all) -> ok.
subscribe(Name) ->
    join({state, Name}).

%% Receive {chappe_esl_node, Name, {event, Event}} for every event the node
%% connection gets (CHANNEL_CREATE, CHANNEL_HANGUP_COMPLETE, BACKGROUND_JOB,
%% HEARTBEAT and the node's extra `events').
-spec events(name() | all) -> ok.
events(Name) ->
    join({events, Name}).

%% events/1 for the events whose headers hold every value of Match. The
%% match is part of the group, so subscribers with the same one share it.
-spec events(name() | all, #{binary() => binary()}) -> ok | {error, badarg}.
events(Name, Match) when is_map(Match), map_size(Match) > 0 ->
    case
        lists:all(
            fun({K, V}) -> is_binary(K) andalso is_binary(V) end,
            maps:to_list(Match)
        )
    of
        true -> join({events, Name, Match});
        false -> {error, badarg}
    end;
events(_Name, _Match) ->
    {error, badarg}.

%% Leave both the state and the event groups of Name (or `all').
-spec unsubscribe(name() | all) -> ok.
unsubscribe(Name) ->
    case whereis(?SCOPE) of
        undefined ->
            ok;
        _ ->
            _ = pg:leave(?SCOPE, {state, Name}, self()),
            _ = pg:leave(?SCOPE, {events, Name}, self()),
            _ = [
                pg:leave(?SCOPE, G, self())
             || {events, N, _} = G <- pg:which_groups(?SCOPE), N =:= Name
            ],
            ok
    end.

%% Send a notice to the subscribers of Name and of `all' (called by the node).
-spec notify(state | events, name(), term()) -> ok.
notify(Group, Name, Msg) ->
    try
        pg:get_members(?SCOPE, {Group, Name}) ++
            pg:get_members(?SCOPE, {Group, all}) ++
            filtered(Group, Name, Msg)
    of
        Pids ->
            lists:foreach(
                fun(Pid) -> Pid ! {chappe_esl_node, Name, Msg} end,
                lists:usort(Pids)
            )
    catch
        %% the scope is gone (the registry is stopping)
        error:badarg -> ok
    end.

%% The subscribers of events/2 whose match an event meets.
filtered(events, Name, {event, Ev}) ->
    [
        Pid
     || {events, N, Match} = G <- pg:which_groups(?SCOPE),
        N =:= Name orelse N =:= all,
        matches(Match, Ev),
        Pid <- pg:get_members(?SCOPE, G)
    ];
filtered(_Group, _Name, _Msg) ->
    [].

matches(Match, Ev) ->
    lists:all(
        fun({K, V}) -> chappe_esl_event:header(K, Ev) =:= V end,
        maps:to_list(Match)
    ).

init(Nodes) ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    Specs = [node_spec(Name, valid(Name, Opts)) || {Name, Opts} <- Nodes],
    Pg = #{id => pg, start => {pg, start_link, [?SCOPE]}, type => worker},
    {ok,
        {#{strategy => one_for_one, intensity => 10, period => 10}, [Pg | Specs]}}.

%% internal

valid(Name, Opts) ->
    case chappe_esl_node:validate(Opts) of
        {ok, Config} -> Config;
        {error, Reason} -> error({bad_node, Name, Reason})
    end.

node_spec(Name, Config) ->
    #{
        id => {node, Name},
        start => {chappe_esl_node, start_link, [Name, Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [chappe_esl_node]
    }.

ensure_started() ->
    case supervisor:start_child(chappe_esl_sup, child_spec([])) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, already_present} -> restart_child()
    end.

%% A registry that stopped and was kept as a child spec.
restart_child() ->
    case supervisor:restart_child(chappe_esl_sup, ?MODULE) of
        {ok, _} -> ok;
        {error, running} -> ok
    end.

join(Group) ->
    ok = ensure_started(),
    pg:join(?SCOPE, Group, self()).

rows() ->
    try
        ets:tab2list(?TAB)
    catch
        error:badarg -> []
    end.

lookup(Name) ->
    try ets:lookup(?TAB, Name) of
        [{_, Row}] -> {ok, Row};
        [] -> error
    catch
        error:badarg -> error
    end.

call(Name, Msg) ->
    case lookup(Name) of
        {ok, #{pid := Pid}} ->
            try
                gen_statem:call(Pid, Msg, 5000)
            catch
                exit:_ -> {error, not_found}
            end;
        error ->
            {error, not_found}
    end.

with_conn(Name, Fun) ->
    case lookup(Name) of
        {ok, #{conn := Conn}} when is_pid(Conn) -> Fun(Conn);
        {ok, _} -> {error, down};
        error -> {error, not_found}
    end.

public(Name, Row) ->
    (maps:with(
        [state, host, port, tags, weight, max_sessions, sip_uri, load, since],
        Row
    ))#{
        name => Name
    }.

selectable(#{state := up, load := Load} = Row, Tags) ->
    has_tags(Tags, maps:get(tags, Row)) andalso not full(Row, Load);
selectable(_Row, _Tags) ->
    false.

has_tags(Want, Have) ->
    lists:all(fun(T) -> lists:member(T, Have) end, Want).

%% A node is full at the lower of its configured max_sessions and the
%% Max-Sessions it reports (integers sort before the atom infinity).
full(#{max_sessions := Cfg}, Load) ->
    Max = min(Cfg, maps:get(max_sessions, Load, infinity)),
    maps:get(sessions, Load, 0) >= Max.

pick(least_sessions, Candidates) ->
    best(fun(Load) -> maps:get(sessions, Load, 0) end, Candidates);
pick(idle_cpu, Candidates) ->
    best(fun(Load) -> -maps:get(idle_cpu, Load, 0.0) end, Candidates);
pick(weighted, Candidates) ->
    Weighted = [{Name, W} || {Name, #{weight := W}} <- Candidates, W > 0],
    case Weighted of
        [] -> element(1, hd(Candidates));
        _ -> roll(rand:uniform(lists:sum([W || {_, W} <- Weighted])), Weighted)
    end.

%% The candidate with the lowest key; the list is sorted by name, so a tie
%% keeps the first name.
best(Key, [{Name0, Row0} | Rest]) ->
    {Name, _} = lists:foldl(
        fun({Name, #{load := Load}}, {_, K0} = Acc) ->
            case Key(Load) of
                K when K < K0 -> {Name, K};
                _ -> Acc
            end
        end,
        {Name0, Key(maps:get(load, Row0))},
        Rest
    ),
    Name.

roll(N, [{Name, W} | _]) when N =< W -> Name;
roll(N, [{_, W} | Rest]) -> roll(N - W, Rest).
