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
-export([put/2, notify/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([name/0, opts/0, policy/0, info/0]).

-define(TAB, chappe_sip_peers).

%% subs: subscriber => monitor; procs: peer name => {pid, monitor}
-record(state, {
    subs = #{} :: #{pid() => reference()},
    procs = #{} :: #{term() => {pid(), reference()}}
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
    proxy => binary()
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

%% Start monitoring a peer.
-spec add(name(), opts()) -> ok | {error, already_exists | bad_uri | term()}.
add(Name, #{uri := Uri} = Opts) when is_binary(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, _} -> gen_server:call(?MODULE, {add, Name, Opts});
        _ -> {error, bad_uri}
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

handle_call({add, Name, Opts}, _From, #state{procs = P} = S) ->
    case maps:is_key(Name, P) of
        true ->
            {reply, {error, already_exists}, S};
        false ->
            case chappe_sip_peer_sup:start_peer(Name, Opts) of
                {ok, Pid} ->
                    MRef = erlang:monitor(process, Pid),
                    {reply, ok, S#state{procs = P#{Name => {Pid, MRef}}}};
                {error, _} = Err ->
                    {reply, Err, S}
            end
    end;
handle_call({remove, Name}, _From, #state{procs = P} = S) ->
    case maps:take(Name, P) of
        {{Pid, MRef}, P1} ->
            erlang:demonitor(MRef, [flush]),
            _ = chappe_sip_peer_sup:stop_peer(Pid),
            ets:delete(?TAB, {peer, Name}),
            {reply, ok, S#state{procs = P1}};
        error ->
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

handle_cast({notify, Event}, #state{subs = Subs} = S) ->
    _ = [Pid ! Event || Pid <- maps:keys(Subs)],
    {noreply, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

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
