%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The SIPREC recordings this node sends (chappe_sip_siprec), one
%% temporary child each: a recording that crashes is not restarted, its
%% owner sees it go down and its recording server gets the BYE of its
%% dialog. It sits after the SIP stack in the root supervisor, so it stops
%% first and each recording can still end its session with a BYE.
-module(chappe_sip_siprec_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child(map()) -> {ok, pid()} | {error, term()}.
start_child(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    {ok,
        {
            #{strategy => simple_one_for_one, intensity => 10, period => 10},
            [
                #{
                    id => chappe_sip_siprec,
                    start => {chappe_sip_siprec, start_link, []},
                    restart => temporary,
                    shutdown => 5000,
                    type => worker,
                    modules => [chappe_sip_siprec]
                }
            ]
        }}.
