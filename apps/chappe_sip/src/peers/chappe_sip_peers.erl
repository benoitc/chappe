%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIP peers kept alive with OPTIONS (trunks, gateways, media
%% servers).
%%
%% A peer is a named SIP URI in a group. One process per peer
%% (chappe_sip_peer) sends it an OPTIONS every interval_ms and counts the
%% answers: up after up_after answered probes in a row, down after
%% down_after failed ones. Any final response is an answer except 408 and
%% 503 (the rule of Kamailio's dispatcher), unless alive_codes lists the
%% statuses that are; no response within timeout_ms is a failure.
%%
%% The peers' state is kept in a public ETS table owned by this server, so
%% peers/0, status/1 and select/2 read it without a call. select/2 picks
%% an up peer of a group: the best priority (lowest number), the next one
%% in turn (round_robin), or at random by weight (weighted). candidates/2
%% lists the group's up peers in the order a B2BUA tries them
%% (chappe_sip_b2b's {peer_group, G} target).
%%
%% Subscribers get {chappe_sip_peer, Name, up | down} on each change, and
%% {chappe_sip_qualify, Aor, Contact, unreachable} when the registrar's
%% keepalive drops a binding (chappe_sip_qualify).
%%
%% Peers also come from the `peers' application setting, a list of
%% {Name, Opts}, added when the application starts.
%%
%% probe => all_nodes (the default): each node that adds the peer pings
%% it. probe => singleton, with the `cluster' setting chappe_cluster: one
%% node of the region pings it (a chappe_cluster singleton, moved to
%% another node when its node stops) and puts the peer's state in the
%% region's KV, fenced; every node that added it watches the KV and keeps
%% its own table, and its subscribers, in step. Add the peer on every
%% node that may ping it, with the same options.
-module(chappe_sip_peers).
-behaviour(gen_server).

-export([start_link/0, load_env/0]).
-export([
    add/2,
    remove/1,
    peers/0,
    status/1,
    select/2,
    candidates/2,
    subscribe/1,
    unsubscribe/1
]).
%% for chappe_sip_peer and chappe_sip_qualify
-export([put/2, notify/1, kv_key/1, singleton/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, opts/0, policy/0, info/0]).

-define(TAB, chappe_sip_peers).
-define(KV_PREFIX, "chappe_sip/peer/").
%% how often the singleton-probed peers are read back from the KV: the
%% region sends watch events to the nodes it holds live, so a node that
%% was not yet live, or lost an event, catches up within this
-define(RESYNC_MS, 5000).

%% subs: subscriber => monitor; procs: peer name => {pid, monitor};
%% singles: the probe => singleton peers, by name, with the greatest
%% fence Seq seen in the KV for each; watching: the KV prefix is watched
-record(state, {
    subs = #{} :: #{pid() => reference()},
    procs = #{} :: #{term() => {pid(), reference()}},
    singles = #{} :: #{term() => non_neg_integer()},
    watching = false :: boolean()
}).
-type state() :: #state{}.

-type name() :: term().
-type policy() :: priority | round_robin | weighted.
-type opts() :: #{
    uri := binary(),
    group => term(),
    priority => integer(),
    weight => pos_integer(),
    interval_ms => pos_integer(),
    timeout_ms => pos_integer(),
    up_after => pos_integer(),
    down_after => pos_integer(),
    alive_codes => [100..699],
    from => binary(),
    proxy => binary(),
    probe => all_nodes | singleton
}.
%% state: unknown until the first probe settles it; last_status: the
%% status of the last probe (timeout when none came); rtt_ms: how long
%% the last answered probe took; since: when the state last changed
%% (erlang:system_time(millisecond)).
-type info() :: #{
    uri := binary(),
    group := term(),
    priority := integer(),
    weight := pos_integer(),
    state := unknown | up | down,
    last_status := 100..699 | timeout | undefined,
    rtt_ms := non_neg_integer() | undefined,
    since := integer()
}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The peers of the `peers' setting; a supervisor child start that does
%% its work and returns ignore.
-spec load_env() -> ignore.
load_env() ->
    lists:foreach(
        fun({Name, Opts}) ->
            case add(Name, Opts) of
                ok ->
                    ok;
                {error, Why} ->
                    logger:warning("chappe_sip_peers: peer ~p not added: ~p", [
                        Name, Why
                    ])
            end
        end,
        env_peers(chappe_sip_config:get(peers))
    ),
    ignore.

env_peers(Peers) when is_map(Peers) -> maps:to_list(Peers);
env_peers(Peers) when is_list(Peers) -> Peers;
env_peers(_) -> [].

%% Start monitoring a peer. probe => singleton needs the `cluster'
%% setting chappe_cluster ({error, no_cluster} otherwise).
-spec add(name(), opts()) ->
    ok | {error, already_exists | bad_uri | no_cluster | term()}.
add(Name, #{uri := Uri} = Opts) when is_binary(Uri) ->
    case {chappe_sip_uri:parse(Uri), probe(Opts)} of
        {{ok, _}, singleton} ->
            case chappe_sip_config:get(cluster) of
                chappe_cluster -> gen_server:call(?MODULE, {add, Name, Opts});
                _ -> {error, no_cluster}
            end;
        {{ok, _}, all_nodes} ->
            gen_server:call(?MODULE, {add, Name, Opts});
        {{ok, _}, bad} ->
            {error, {bad_option, probe}};
        _ ->
            {error, bad_uri}
    end;
add(_Name, _Opts) ->
    {error, bad_uri}.

%% Stop monitoring a peer.
-spec remove(name()) -> ok | {error, not_found}.
remove(Name) ->
    gen_server:call(?MODULE, {remove, Name}).

-spec peers() -> [{name(), info()}].
peers() ->
    lists:sort([{N, I} || {{peer, N}, I} <- tab()]).

-spec status(name()) -> {ok, info()} | {error, not_found}.
status(Name) ->
    case lookup({peer, Name}) of
        [{_, Info}] -> {ok, Info};
        [] -> {error, not_found}
    end.

%% An up peer of Group by Policy.
-spec select(term(), policy()) -> {ok, binary()} | {error, none_up}.
select(Group, Policy) ->
    case candidates(Group, Policy) of
        [Uri | _] -> {ok, Uri};
        [] -> {error, none_up}
    end.

%% The up peers of Group, the one Policy picks first, then the others by
%% priority: the order a call fails over in.
-spec candidates(term(), policy()) -> [binary()].
candidates(Group, Policy) ->
    Up = lists:sort(
        fun({_, A}, {_, B}) -> rank(A) =< rank(B) end,
        [
            {N, I}
         || {{peer, N}, #{group := G, state := up} = I} <- tab(), G =:= Group
        ]
    ),
    case first(Group, Policy, Up) of
        none ->
            [];
        {Name, Info} ->
            [
                maps:get(uri, Info)
                | [maps:get(uri, I) || {N, I} <- Up, N =/= Name]
            ]
    end.

rank(#{priority := P, uri := U}) -> {P, U}.

first(_Group, _Policy, []) ->
    none;
first(_Group, priority, [Best | _]) ->
    Best;
first(Group, round_robin, Up) ->
    N = ets:update_counter(?TAB, {rr, Group}, 1, {{rr, Group}, 0}),
    lists:nth(1 + (N rem length(Up)), Up);
first(_Group, weighted, Up) ->
    Total = lists:sum([maps:get(weight, I) || {_, I} <- Up]),
    pick_weight(rand:uniform(Total), Up).

pick_weight(R, [{_, #{weight := W}} = P | Rest]) ->
    case R =< W of
        true -> P;
        false -> pick_weight(R - W, Rest)
    end.

%% Pid gets {chappe_sip_peer, Name, up | down} (and the registrar's
%% {chappe_sip_qualify, Aor, Contact, unreachable}) until it exits or
%% unsubscribes.
-spec subscribe(pid()) -> ok.
subscribe(Pid) ->
    gen_server:call(?MODULE, {subscribe, Pid}).

-spec unsubscribe(pid()) -> ok.
unsubscribe(Pid) ->
    gen_server:call(?MODULE, {unsubscribe, Pid}).

%% A peer process writes its row.
-spec put(name(), info()) -> ok.
put(Name, Info) ->
    true = ets:insert(?TAB, {{peer, Name}, Info}),
    ok.

%% Tell the subscribers.
-spec notify(term()) -> ok.
notify(Event) ->
    gen_server:cast(?MODULE, {notify, Event}).

%% The region KV key of a singleton-probed peer's state.
-spec kv_key(name()) -> binary().
kv_key(Name) ->
    <<?KV_PREFIX, (term_to_binary(Name))/binary>>.

%% The chappe_cluster singleton that pings a singleton-probed peer.
-spec singleton(name()) -> {chappe_sip_peer, name()}.
singleton(Name) ->
    {chappe_sip_peer, Name}.

probe(#{probe := singleton}) -> singleton;
probe(#{probe := all_nodes}) -> all_nodes;
probe(#{probe := _}) -> bad;
probe(#{}) -> all_nodes.

tab() ->
    try
        ets:tab2list(?TAB)
    catch
        error:badarg -> []
    end.

lookup(Key) ->
    try
        ets:lookup(?TAB, Key)
    catch
        error:badarg -> []
    end.

%% gen_server

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({add, Name, Opts}, _From, #state{procs = P, singles = Sg} = S) ->
    case {maps:is_key(Name, P) orelse maps:is_key(Name, Sg), probe(Opts)} of
        {true, _} ->
            {reply, {error, already_exists}, S};
        {false, singleton} ->
            add_single(Name, Opts, S);
        {false, _} ->
            case chappe_sip_peer_sup:start_peer(Name, Opts) of
                {ok, Pid} ->
                    MRef = erlang:monitor(process, Pid),
                    {reply, ok, S#state{procs = P#{Name => {Pid, MRef}}}};
                {error, _} = Err ->
                    {reply, Err, S}
            end
    end;
handle_call({remove, Name}, _From, #state{procs = P, singles = Sg} = S) ->
    case {maps:take(Name, P), Sg} of
        {{{Pid, MRef}, P1}, _} ->
            erlang:demonitor(MRef, [flush]),
            _ = chappe_sip_peer_sup:stop_peer(Pid),
            ets:delete(?TAB, {peer, Name}),
            {reply, ok, S#state{procs = P1}};
        {error, #{Name := _}} ->
            _ = chappe_cluster:stop_singleton(singleton(Name)),
            ets:delete(?TAB, {peer, Name}),
            {reply, ok, S#state{singles = maps:remove(Name, Sg)}};
        {error, _} ->
            {reply, {error, not_found}, S}
    end;
handle_call({subscribe, Pid}, _From, #state{subs = Subs} = S) ->
    case maps:is_key(Pid, Subs) of
        true ->
            {reply, ok, S};
        false ->
            {reply, ok, S#state{
                subs = Subs#{Pid => erlang:monitor(process, Pid)}
            }}
    end;
handle_call({unsubscribe, Pid}, _From, #state{subs = Subs} = S) ->
    case maps:take(Pid, Subs) of
        {MRef, Subs1} ->
            erlang:demonitor(MRef, [flush]),
            {reply, ok, S#state{subs = Subs1}};
        error ->
            {reply, ok, S}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({notify, Event}, S) ->
    ok = notify_subs(Event, S),
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({chappe_cluster, watch, {put, Key, Value, _Hlc}}, S) ->
    {noreply, kv_put(Key, Value, S)};
handle_info({chappe_cluster, watch, {delete, _Key, _Old, _Hlc}}, S) ->
    {noreply, S};
handle_info({chappe_cluster, watch, overflow}, S) ->
    %% the watch ended: watch again, then read what may have been missed
    ok = chappe_cluster:watch(<<?KV_PREFIX>>),
    {noreply, resync(S)};
handle_info(kv_resync, S) ->
    _ = erlang:send_after(?RESYNC_MS, self(), kv_resync),
    {noreply, resync(S)};
handle_info(
    {'DOWN', MRef, process, Pid, _}, #state{subs = Subs, procs = P} = S
) ->
    case maps:take(Pid, Subs) of
        {MRef, Subs1} ->
            {noreply, S#state{subs = Subs1}};
        _ ->
            %% a peer process gone for good (its supervisor gave up)
            Gone = [
                N
             || {N, {Pd, R}} <- maps:to_list(P), Pd =:= Pid, R =:= MRef
            ],
            _ = [ets:delete(?TAB, {peer, N}) || N <- Gone],
            {noreply, S#state{procs = maps:without(Gone, P)}}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% ---- probe => singleton ----

%% The row starts unknown (or as the KV has it), then follows the KV; the
%% singleton runs the probe on one node of the region.
add_single(Name, Opts, S) ->
    %% started on first use, as the media apps are
    case application:ensure_all_started(chappe_cluster) of
        {ok, _} -> add_single_started(Name, Opts, S);
        {error, Why} -> {reply, {error, {cluster, Why}}, S}
    end.

add_single_started(Name, Opts, S0) ->
    ok = ?MODULE:put(Name, chappe_sip_peer:initial(Opts)),
    S1 = watch(S0),
    S2 = kv_read(Name, S1#state{singles = (S1#state.singles)#{Name => 0}}),
    Spec = #{
        id => singleton(Name),
        start => {chappe_sip_peer, start_link, [Name, Opts]},
        shutdown => 2000
    },
    case chappe_cluster:singleton(singleton(Name), Spec) of
        Ok when Ok =:= ok; Ok =:= {error, already_started} ->
            {reply, ok, S2};
        {error, _} = Err ->
            ets:delete(?TAB, {peer, Name}),
            {reply, Err, S2#state{
                singles = maps:remove(Name, S2#state.singles)
            }}
    end.

watch(#state{watching = true} = S) ->
    S;
watch(S) ->
    ok = chappe_cluster:watch(<<?KV_PREFIX>>),
    _ = erlang:send_after(?RESYNC_MS, self(), kv_resync),
    S#state{watching = true}.

resync(S) ->
    maps:fold(fun(N, _, Acc) -> kv_read(N, Acc) end, S, S#state.singles).

kv_read(Name, S) ->
    case chappe_cluster:get(kv_key(Name)) of
        {ok, Value, _Version} -> kv_apply(Name, Value, S);
        _ -> S
    end.

kv_put(<<?KV_PREFIX, Bin/binary>>, Value, S) ->
    try binary_to_term(Bin, [safe]) of
        Name -> kv_apply(Name, Value, S)
    catch
        error:badarg -> S
    end;
kv_put(_Key, _Value, S) ->
    S.

%% A state from the singleton: kept when its fence is not older than the
%% last one seen (a paused prober that wakes up cannot undo the new one's
%% word), and told to the subscribers when it changes the state.
kv_apply(Name, #{info := Info, fence := {_, _, Seq}}, #state{singles = Sg} = S) ->
    case Sg of
        #{Name := Last} when Seq >= Last ->
            Old =
                case lookup({peer, Name}) of
                    [{_, #{state := St}}] -> St;
                    [] -> unknown
                end,
            ok = ?MODULE:put(Name, Info),
            _ =
                case maps:get(state, Info) of
                    Old -> ok;
                    New -> notify_subs({chappe_sip_peer, Name, New}, S)
                end,
            S#state{singles = Sg#{Name := Seq}};
        _ ->
            S
    end;
kv_apply(_Name, _Value, S) ->
    S.

notify_subs(Event, #state{subs = Subs}) ->
    _ = [Pid ! Event || Pid <- maps:keys(Subs)],
    ok.
