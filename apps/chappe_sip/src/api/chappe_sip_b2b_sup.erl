%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The processes of B2BUA calls that outlive the function that
%% starts them: one chappe_sip_b2b_transfer per transfer a call carries
%% out. Children are temporary: a transfer that ends or crashes is not
%% restarted, and its call goes on.
-module(chappe_sip_b2b_sup).
-behaviour(supervisor).

-export([start_link/0, start_transfer/1]).
-export([init/1]).

-define(TRANSFERS, chappe_sip_b2b_transfers).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

%% A transfer of a call (chappe_sip_b2b_transfer:start_link/1).
-spec start_transfer(map()) -> {ok, pid()} | {error, term()}.
start_transfer(Args) ->
    supervisor:start_child(?TRANSFERS, [Args]).

init(top) ->
    Children = [
        #{
            id => ?TRANSFERS,
            start =>
                {supervisor, start_link, [{local, ?TRANSFERS}, ?MODULE, transfers]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [?MODULE]
        }
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}};
init(transfers) ->
    Child = #{
        id => chappe_sip_b2b_transfer,
        start => {chappe_sip_b2b_transfer, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [chappe_sip_b2b_transfer]
    },
    {ok,
        {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [
            Child
        ]}}.
