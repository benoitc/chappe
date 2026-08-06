%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Node registry with health tracking, load-based selection, and call
%% pinning.
%%
%% Reads happen in the calling process against ETS (selection, pin
%% lookups, load counters); the gen_server only serializes writes and
%% health transitions, so per-call work never queues behind it.
%%
%% Health: a periodic ping per node, plus timeout reports from the
%% facade. down_after consecutive failures mark a node down; a
%% successful ping (or command) brings it back up. Every down-to-up
%% transition bumps the node's generation. rtpengine loses all
%% sessions on restart while answering health pings as if nothing
%% happened, so a generation mismatch is how sessions pinned before
%% the flap learn their media is gone. The pool never re-offers on
%% its own; subscribers decide what to do with the notification.
-module(chappe_rtpengine_pool).
-behaviour(gen_server).

-export([start_link/0]).
-export([add_node/2, remove_node/1, list_nodes/0, node_info/1]).
-export([select/0, pin/1, pin_to/2, unpin/1, pinned/1]).
-export([subscribe/0, unsubscribe/0]).
-export([is_managed/1, track_start/1, track_end/1, report/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include_lib("kernel/include/logger.hrl").

%% {Name, Status :: up | down, Generation}
-define(NODES, chappe_rtpengine_pool_nodes).
%% {Name, InFlight, Pinned}
-define(COUNTERS, chappe_rtpengine_pool_counters).
%% {CallId, Name, Generation}
-define(PINS, chappe_rtpengine_pool_pins).

-define(DEFAULT_HEALTH_INTERVAL, 5000).
-define(DEFAULT_DOWN_AFTER, 2).
-define(CALL_TIMEOUT, 5000).

-record(node, {
    name :: atom(),
    health_interval :: pos_integer(),
    down_after :: pos_integer(),
    status = up :: up | down,
    generation = 1 :: pos_integer(),
    consec_failures = 0 :: non_neg_integer()
}).

-record(state, {
    nodes = #{} :: #{atom() => #node{}},
    subscribers = #{} :: #{pid() => reference()}
}).

-type state() :: #state{}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Opts: host and port plus the client options, and the pool options
%% health_interval (ms between health pings, default 5000) and
%% down_after (consecutive failures before down, default 2).
-spec add_node(atom(), map()) -> ok | {error, term()}.
add_node(Name, Opts) ->
    gen_server:call(?MODULE, {add_node, Name, Opts}, ?CALL_TIMEOUT).

-spec remove_node(atom()) -> ok | {error, term()}.
remove_node(Name) ->
    gen_server:call(?MODULE, {remove_node, Name}, ?CALL_TIMEOUT).

-spec list_nodes() -> [map()].
list_nodes() ->
    [node_info_row(Row) || Row <- ets:tab2list(?NODES)].

-spec node_info(atom()) -> map() | {error, not_found}.
node_info(Name) ->
    case ets:lookup(?NODES, Name) of
        [Row] -> node_info_row(Row);
        [] -> {error, not_found}
    end.

%% Pick the healthy node with the least load (in-flight requests plus
%% pinned calls).
-spec select() -> {ok, atom()} | {error, no_nodes}.
select() ->
    Up =
        try
            ets:select(?NODES, [{{'$1', up, '_'}, [], ['$1']}])
        catch
            error:badarg -> []
        end,
    case Up of
        [] -> {error, no_nodes};
        Nodes -> {ok, least_loaded(Nodes)}
    end.

%% Select a node and pin the call to it.
-spec pin(binary()) -> {ok, atom(), pos_integer()} | {error, no_nodes}.
pin(CallId) ->
    case select() of
        {ok, Node} -> pin_to(CallId, Node);
        {error, _} = Error -> Error
    end.

-spec pin_to(binary(), atom()) ->
    {ok, atom(), pos_integer()} | {error, not_managed}.
pin_to(CallId, Node) ->
    case
        try
            ets:lookup(?NODES, Node)
        catch
            error:badarg -> []
        end
    of
        [{_, _, Gen}] ->
            ets:insert(?PINS, {CallId, Node, Gen}),
            bump_counter(Node, 3, 1),
            {ok, Node, Gen};
        [] ->
            {error, not_managed}
    end.

-spec unpin(binary()) -> ok.
unpin(CallId) ->
    case
        try
            ets:take(?PINS, CallId)
        catch
            error:badarg -> []
        end
    of
        [{_, Node, _Gen}] -> bump_counter(Node, 3, -1);
        [] -> ok
    end.

-spec pinned(binary()) -> {ok, atom(), pos_integer()} | error.
pinned(CallId) ->
    case ets:lookup(?PINS, CallId) of
        [{_, Node, Gen}] -> {ok, Node, Gen};
        [] -> error
    end.

%% The calling process receives {chappe_rtpengine_pool, Event} messages:
%%   {node_down, Name}
%%   {node_up, Name, Generation}   generation bumped on recovery
-spec subscribe() -> ok.
subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}, ?CALL_TIMEOUT).

-spec unsubscribe() -> ok.
unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}, ?CALL_TIMEOUT).

-spec is_managed(atom()) -> boolean().
is_managed(Name) ->
    try
        ets:member(?NODES, Name)
    catch
        error:badarg -> false
    end.

-spec track_start(atom()) -> ok.
track_start(Name) ->
    bump_counter(Name, 2, 1).

-spec track_end(atom()) -> ok.
track_end(Name) ->
    bump_counter(Name, 2, -1).

%% Health signal from the facade: ok for any reply from the node,
%% timeout when all attempts went unanswered.
-spec report(atom(), ok | timeout) -> ok.
report(Name, Result) ->
    gen_server:cast(?MODULE, {report, Name, Result}).

%% gen_server callbacks

init([]) ->
    ?NODES = ets:new(?NODES, [
        named_table, set, protected, {read_concurrency, true}
    ]),
    ?COUNTERS = public_table(?COUNTERS),
    ?PINS = public_table(?PINS),
    {ok, #state{}}.

public_table(Name) ->
    ets:new(Name, [named_table, set, public, {write_concurrency, true}]).

handle_call({add_node, Name, Opts}, _From, State) ->
    case maps:is_key(Name, State#state.nodes) of
        true ->
            {reply, {error, already_added}, State};
        false ->
            {PoolOpts, ClientOpts} = split_opts(Opts),
            case
                supervisor:start_child(chappe_rtpengine_client_sup, [
                    Name, ClientOpts
                ])
            of
                {ok, _Pid} ->
                    Node = #node{
                        name = Name,
                        health_interval =
                            maps:get(health_interval, PoolOpts),
                        down_after = maps:get(down_after, PoolOpts)
                    },
                    ets:insert(?NODES, {Name, up, Node#node.generation}),
                    ets:insert(?COUNTERS, {Name, 0, 0}),
                    schedule_health(Node),
                    Nodes = maps:put(Name, Node, State#state.nodes),
                    {reply, ok, State#state{nodes = Nodes}};
                {error, {already_started, _}} ->
                    {reply, {error, already_added}, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;
handle_call({remove_node, Name}, _From, State) ->
    case maps:take(Name, State#state.nodes) of
        {_Node, Nodes} ->
            case whereis(Name) of
                undefined ->
                    ok;
                Pid ->
                    supervisor:terminate_child(chappe_rtpengine_client_sup, Pid)
            end,
            ets:delete(?NODES, Name),
            ets:delete(?COUNTERS, Name),
            ets:match_delete(?PINS, {'_', Name, '_'}),
            {reply, ok, State#state{nodes = Nodes}};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({subscribe, Pid}, _From, State) ->
    case maps:is_key(Pid, State#state.subscribers) of
        true ->
            {reply, ok, State};
        false ->
            Mon = erlang:monitor(process, Pid),
            Subs = maps:put(Pid, Mon, State#state.subscribers),
            {reply, ok, State#state{subscribers = Subs}}
    end;
handle_call({unsubscribe, Pid}, _From, State) ->
    {reply, ok, drop_subscriber(Pid, State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({report, Name, ok}, State) ->
    {noreply, note_success(Name, State)};
handle_cast({report, Name, timeout}, State) ->
    {noreply, note_failure(Name, State)};
handle_cast({ping_result, Name, ok}, State) ->
    {noreply, note_success(Name, State)};
handle_cast({ping_result, Name, failure}, State) ->
    {noreply, note_failure(Name, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({health, Name}, State) ->
    case maps:find(Name, State#state.nodes) of
        {ok, Node} ->
            spawn_health_ping(Name),
            schedule_health(Node);
        error ->
            ok
    end,
    {noreply, State};
handle_info({'DOWN', _Mon, process, Pid, _Reason}, State) ->
    {noreply, drop_subscriber(Pid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

%% internal

split_opts(Opts) ->
    Defaults = #{
        health_interval => ?DEFAULT_HEALTH_INTERVAL,
        down_after => ?DEFAULT_DOWN_AFTER
    },
    PoolOpts = maps:merge(Defaults, maps:with(maps:keys(Defaults), Opts)),
    ClientOpts = maps:without(maps:keys(Defaults), Opts),
    {PoolOpts, ClientOpts}.

schedule_health(#node{name = Name, health_interval = Interval}) ->
    _ = erlang:send_after(Interval, self(), {health, Name}),
    ok.

spawn_health_ping(Name) ->
    Pool = self(),
    _ = spawn(fun() ->
        Result =
            try chappe_rtpengine_client:cmd(Name, ping) of
                {ok, _} -> ok;
                _ -> failure
            catch
                exit:_ -> failure
            end,
        gen_server:cast(Pool, {ping_result, Name, Result})
    end),
    ok.

-spec note_success(atom(), state()) -> state().
note_success(Name, State) ->
    case maps:find(Name, State#state.nodes) of
        {ok, #node{status = up} = Node} ->
            update_node(Node#node{consec_failures = 0}, State);
        {ok, #node{status = down} = Node0} ->
            Gen = Node0#node.generation + 1,
            Node = Node0#node{
                status = up, generation = Gen, consec_failures = 0
            },
            ets:insert(?NODES, {Name, up, Gen}),
            ?LOG_NOTICE("chappe_rtpengine_pool: node ~p up, generation ~p", [
                Name, Gen
            ]),
            notify({node_up, Name, Gen}, State),
            update_node(Node, State);
        error ->
            State
    end.

note_failure(Name, State) ->
    case maps:find(Name, State#state.nodes) of
        {ok, #node{status = up} = Node0} ->
            Fails = Node0#node.consec_failures + 1,
            Node = Node0#node{consec_failures = Fails},
            case Fails >= Node#node.down_after of
                true ->
                    ets:insert(?NODES, {
                        Name, down, Node#node.generation
                    }),
                    ?LOG_WARNING("chappe_rtpengine_pool: node ~p down", [Name]),
                    notify({node_down, Name}, State),
                    update_node(Node#node{status = down}, State);
                false ->
                    update_node(Node, State)
            end;
        {ok, #node{status = down} = Node} ->
            update_node(
                Node#node{
                    consec_failures = Node#node.consec_failures + 1
                },
                State
            );
        error ->
            State
    end.

update_node(Node, State) ->
    Nodes = maps:put(Node#node.name, Node, State#state.nodes),
    State#state{nodes = Nodes}.

notify(Event, #state{subscribers = Subs}) ->
    maps:foreach(
        fun(Pid, _Mon) -> Pid ! {chappe_rtpengine_pool, Event} end,
        Subs
    ).

drop_subscriber(Pid, State) ->
    case maps:take(Pid, State#state.subscribers) of
        {Mon, Subs} ->
            erlang:demonitor(Mon, [flush]),
            State#state{subscribers = Subs};
        error ->
            State
    end.

least_loaded(Nodes) ->
    {_, First} = hd(lists:keysort(1, [{load(N), N} || N <- Nodes])),
    First.

load(Name) ->
    case ets:lookup(?COUNTERS, Name) of
        [{_, InFlight, Pinned}] -> InFlight + Pinned;
        [] -> 0
    end.

bump_counter(Name, Pos, Incr) ->
    try
        _ = ets:update_counter(?COUNTERS, Name, {Pos, Incr}),
        ok
    catch
        error:badarg -> ok
    end.

node_info_row({Name, Status, Gen}) ->
    {InFlight, Pinned} =
        case ets:lookup(?COUNTERS, Name) of
            [{_, I, P}] -> {I, P};
            [] -> {0, 0}
        end,
    #{
        name => Name,
        status => Status,
        generation => Gen,
        in_flight => InFlight,
        pinned => Pinned
    }.
