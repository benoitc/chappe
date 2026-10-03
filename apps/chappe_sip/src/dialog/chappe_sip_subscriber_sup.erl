%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The subscriptions we hold (chappe_sip_subscriber), one temporary
%% process each, and the table that routes their NOTIFYs to them.
%%
%% The table is public and owned by this supervisor, so it outlives any
%% subscriber: {{CallId, LocalTag, RemoteTag | any}, Pid}. A subscriber
%% adds its rows as its dialog forms and deletes them as it ends; a row
%% whose process is gone is ignored and dropped by the router.
-module(chappe_sip_subscriber_sup).
-behaviour(supervisor).

-export([start_link/0, start_subscriber/1]).
-export([init/1]).

-define(TAB, chappe_sip_subscribers).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_subscriber(map()) -> {ok, pid()} | {error, term()}.
start_subscriber(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    Child = #{
        id => chappe_sip_subscriber,
        start => {chappe_sip_subscriber, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_subscriber]
    },
    {ok,
        {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [
            Child
        ]}}.
