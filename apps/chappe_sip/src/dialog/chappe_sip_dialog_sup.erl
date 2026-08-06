%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Supervisor for dialog fsms (temporary: a dialog is not restarted;
%% its state lives only in the running SIP session).
-module(chappe_sip_dialog_sup).
-behaviour(supervisor).

-export([start_link/0, start_dialog/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_dialog(map()) -> {ok, pid()} | {error, term()}.
start_dialog(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 10
    },
    Child = #{
        id => chappe_sip_dialog_fsm,
        start => {chappe_sip_dialog_fsm, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_dialog_fsm]
    },
    {ok, {SupFlags, [Child]}}.
