%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The refer event package: its registry and one
%% chappe_sip_refer_sub per accepted REFER (temporary: a subscription that
%% ends is not restarted).
-module(chappe_sip_refer_sup).
-behaviour(supervisor).

-export([start_link/0, start_sub/1]).
-export([init/1]).

-define(SUBS, chappe_sip_refer_subs).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

-spec start_sub(map()) -> {ok, pid()} | {error, term()}.
start_sub(Args) ->
    supervisor:start_child(?SUBS, [Args]).

init(top) ->
    %% the registry first: a subscription registers as it starts
    Children = [
        #{
            id => chappe_sip_refer_registry,
            start => {chappe_sip_refer_registry, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [chappe_sip_refer_registry]
        },
        #{
            id => ?SUBS,
            start => {supervisor, start_link, [{local, ?SUBS}, ?MODULE, subs]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [?MODULE]
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 10}, Children}};
init(subs) ->
    Child = #{
        id => chappe_sip_refer_sub,
        start => {chappe_sip_refer_sub, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_refer_sub]
    },
    {ok,
        {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [
            Child
        ]}}.
