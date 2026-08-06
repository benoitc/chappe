%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Per-channel handler pool for outbound connections. simple_one_for_one of
%% chappe_esl_conn processes started in outbound mode; each owns one accepted socket.
%% The listener calls start_conn/2 on accept, then transfers socket ownership
%% and activates the connection.
-module(chappe_esl_outbound_sup).
-behaviour(supervisor).

-export([start_link/0, start_conn/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_conn(module(), term()) -> {ok, pid()} | {error, term()}.
start_conn(Handler, Args) ->
    Opts = #{mode => outbound, handler => Handler, handler_args => Args},
    supervisor:start_child(?MODULE, [Opts]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Child = #{
        id => chappe_esl_conn,
        start => {chappe_esl_conn, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_esl_conn]
    },
    {ok, {SupFlags, [Child]}}.
