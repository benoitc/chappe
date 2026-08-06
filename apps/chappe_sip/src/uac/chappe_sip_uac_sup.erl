%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for UAC transaction fsms (temporary).
-module(chappe_sip_uac_sup).
-behaviour(supervisor).

-export([start_link/0, start_uac/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_uac(map()) -> {ok, pid()} | {error, term()}.
start_uac(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 10
    },
    Child = #{
        id => chappe_sip_uac_fsm,
        start => {chappe_sip_uac_fsm, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_uac_fsm]
    },
    {ok, {SupFlags, [Child]}}.
