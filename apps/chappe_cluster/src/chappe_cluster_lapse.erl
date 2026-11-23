%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The node's lapse timer, registered locally. It does one thing: when the
%% node's local deadline passes without a renewal, it marks the node not
%% live and tells every holder `{chappe_cluster, Lease, lost}'. It is its
%% own process so nothing else in its mailbox can delay that: it only ever
%% receives the deadline the agent arms after each renewal, and its own
%% tick.
%%
%% The holders and the node's liveness live in `chappe_cluster_tab', which
%% the app's supervisor owns, so they outlive this process and the agent.
%%
%% - When it starts (the app starts, or it restarted after a crash and its
%%   timer is gone) it cannot know the deadline, so it tells every holder
%%   its lease is lost before anything else.
%% - Every renew_ms / 4 it reads the deadline from the table and arms
%%   itself from it, so an arm that never came (the agent crashed between
%%   a renewal and its arm) costs at most that tick.
%% - When the app stops, it tells every holder lost before the table goes
%%   (it stops after the agent and the singletons). The next start finds no
%%   epoch, so its first renewal takes a new one and the region ends the
%%   old one's leases.
-module(chappe_cluster_lapse).
-behaviour(gen_server).

-export([start_link/0, arm/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    timer :: undefined | reference(),
    deadline :: undefined | integer()
}).

-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Fire at `Deadline' (monotonic ms) unless a later arm moves it.
-spec arm(integer()) -> ok.
arm(Deadline) ->
    gen_server:cast(?MODULE, {arm, Deadline}).

-spec init([]) -> {ok, state()}.
init([]) ->
    process_flag(trap_exit, true),
    ok = chappe_cluster_tab:lapse(),
    self() ! tick,
    {ok, #state{}}.

handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({arm, Deadline}, St) ->
    {noreply, set(Deadline, St)};
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({timeout, Ref, lapse}, St = #state{timer = Ref}) ->
    {noreply, check(St#state{timer = undefined, deadline = undefined})};
handle_info({timeout, _, lapse}, St) ->
    {noreply, St};
handle_info(tick, St) ->
    erlang:send_after(
        max(50, chappe_cluster_config:get(renew_ms) div 4), self(), tick
    ),
    {noreply, check(St)};
handle_info(Msg, St) ->
    logger:notice("chappe_cluster_lapse: unexpected ~0p", [Msg]),
    {noreply, St}.

terminate(_Reason, _St) ->
    chappe_cluster_tab:lapse().

%% Lapse when the deadline in the table passed, or arm at it.
check(St) ->
    case chappe_cluster_tab:lapse_if_due() of
        ok -> St;
        {later, Deadline} -> set(Deadline, St)
    end.

set(Deadline, St = #state{deadline = Deadline, timer = T}) when
    T =/= undefined
->
    St;
set(Deadline, St = #state{timer = Old}) ->
    cancel(Old),
    Ref = erlang:start_timer(Deadline, self(), lapse, [{abs, true}]),
    St#state{timer = Ref, deadline = Deadline}.

cancel(undefined) ->
    ok;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.
