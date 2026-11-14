%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Stack supervisor: the engine and everything whose state lives on
%% top of it. rest_for_one so an engine crash tears down in-flight call
%% state (request workers now; uac/dialog supervisors from M3/M4 on).
-module(chappe_sip_stack_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one, intensity => 10, period => 10},
    Children = [
        #{
            id => chappe_sip_engine,
            start => {chappe_sip_engine, start_link, []},
            restart => permanent,
            shutdown => 10000,
            type => worker,
            modules => [chappe_sip_engine]
        },
        #{
            id => chappe_sip_request_sup,
            start => {chappe_sip_request_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [chappe_sip_request_sup]
        },
        #{
            id => chappe_sip_dialog_sup,
            start => {chappe_sip_dialog_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [chappe_sip_dialog_sup]
        },
        #{
            id => chappe_sip_uac_sup,
            start => {chappe_sip_uac_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [chappe_sip_uac_sup]
        },
        #{
            id => chappe_sip_proxy_sup,
            start => {chappe_sip_proxy_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [chappe_sip_proxy_sup]
        }
    ],
    {ok, {SupFlags, Children}}.
