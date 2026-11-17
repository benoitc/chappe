%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The location store's sweep on a cluster: one per region.
%%
%% With `cluster => chappe_cluster', every chappe_sip node registers this
%% process as the chappe_cluster singleton `chappe_sip_registry_sweep'
%% (chappe_sip_registry), so it runs on one node, under
%% chappe_cluster_singleton_sup, and moves to another node when that one
%% stops or loses its lease. Every registrar_sweep_ms it deletes the
%% expired bindings of every AOR, checking that it still holds the lease
%% first; each delete is a compare-and-swap, so a sweep racing a REGISTER
%% never removes the new binding. Reads already leave expired bindings
%% out; the sweep only keeps the region's keys bounded.
%%
%% Its only messages are its own ticks. A sweep visits every AOR, as many
%% as chappe_cluster's max_keys allows.
-module(chappe_sip_registry_sweep).
-behaviour(gen_server).

-export([start_link/0, name/0, child_spec/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(NAME, chappe_sip_registry_sweep).

-record(state, {}).
-type state() :: #state{}.

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% The singleton's name.
-spec name() -> atom().
name() ->
    ?NAME.

%% The child spec the registry registers as a singleton.
-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?NAME, start => {?MODULE, start_link, []}}.

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, schedule(#state{})}.

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(sweep, S) ->
    _ =
        chappe_cluster:singleton_valid(?NAME) andalso
            chappe_sip_registry:sweep(fun() ->
                chappe_cluster:singleton_valid(?NAME)
            end),
    {noreply, schedule(S)};
handle_info(_Info, S) ->
    {noreply, S}.

schedule(S) ->
    erlang:send_after(chappe_sip_config:get(registrar_sweep_ms), self(), sweep),
    S.
