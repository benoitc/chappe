%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node's lapse timer, registered locally. It does one thing: when the
%% node's local deadline passes without a renewal, it marks the node not
%% live and tells every holder `{chappe_cluster, Lease, lost}'. It is its
%% own process so nothing else in its mailbox can delay that: it only ever
%% receives the deadline the agent arms after each renewal.
%%
%% The holders and the node's liveness live in `chappe_cluster_tab', which
%% the app's supervisor owns, so they outlive this process and the agent.
%% When this process starts (the app starts, or it restarted after a crash
%% and its timer is gone) it cannot know the deadline, so it tells every
%% holder its lease is lost before anything else.
-module(chappe_cluster_lapse).
-behaviour(gen_server).

-export([start_link/0, arm/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {timer :: undefined | reference()}).

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
    ok = chappe_cluster_tab:lapse(),
    {ok, #state{}}.

handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({arm, Deadline}, St = #state{timer = Old}) ->
    cancel(Old),
    Ref = erlang:start_timer(Deadline, self(), lapse, [{abs, true}]),
    {noreply, St#state{timer = Ref}};
handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({timeout, Ref, lapse}, St = #state{timer = Ref}) ->
    case chappe_cluster_tab:lapse_if_due() of
        ok ->
            {noreply, St#state{timer = undefined}};
        {later, Deadline} ->
            %% renewed meanwhile, the arm is on its way
            Ref1 = erlang:start_timer(Deadline, self(), lapse, [{abs, true}]),
            {noreply, St#state{timer = Ref1}}
    end;
handle_info({timeout, _, lapse}, St) ->
    {noreply, St};
handle_info(Msg, St) ->
    logger:notice("chappe_cluster_lapse: unexpected ~0p", [Msg]),
    {noreply, St}.

cancel(undefined) ->
    ok;
cancel(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.
