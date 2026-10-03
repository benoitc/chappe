%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The event packages chappe serves and publishes: the ESC
%% (chappe_sip_esc), the presence and message-summary notifiers
%% (chappe_sip_notifier) and the publication agents (chappe_sip_publisher).
%%
%% rest_for_one: a notifier watches the ESC, so it restarts with it. The
%% notifiers are idle until chappe_sip_presence:serve/1 or
%% chappe_sip_mwi:serve/1 routes SUBSCRIBEs to them.
-module(chappe_sip_events_sup).
-behaviour(supervisor).

-export([start_link/0, start_publisher/1, start_notifier/0]).
-export([init/1]).

-define(PUBS, chappe_sip_publishers).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

-spec start_publisher(map()) -> {ok, pid()} | {error, term()}.
start_publisher(Args) ->
    supervisor:start_child(?PUBS, [Args]).

init(top) ->
    Children = [
        worker(chappe_sip_esc, {chappe_sip_esc, start_link, []}),
        worker(
            chappe_sip_presence_notifier,
            {chappe_sip_events_sup, start_notifier, []}
        ),
        worker(
            chappe_sip_mwi_notifier,
            {chappe_sip_notifier, start_link, [
                chappe_sip_mwi_notifier, chappe_sip_mwi, 1000
            ]}
        ),
        #{
            id => ?PUBS,
            start => {supervisor, start_link, [{local, ?PUBS}, ?MODULE, pubs]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [?MODULE]
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 10}, Children}};
init(pubs) ->
    Child = #{
        id => chappe_sip_publisher,
        start => {chappe_sip_publisher, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_publisher]
    },
    {ok,
        {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [
            Child
        ]}}.

%% the presence notifier hears of every change of presence state
start_notifier() ->
    Name = chappe_sip_presence_notifier,
    case chappe_sip_notifier:start_link(Name, chappe_sip_presence, 5000) of
        {ok, Pid} ->
            ok = chappe_sip_esc:watch(<<"presence">>, Pid),
            {ok, Pid};
        Err ->
            Err
    end.

worker(Id, Start) ->
    #{
        id => Id,
        start => Start,
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [element(1, Start)]
    }.
