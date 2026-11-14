%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The streams a recording server of this node receives
%% (chappe_sip_siprec_rtp), one temporary child each: a stream that
%% crashes is not restarted, and the other streams and the session go on.
-module(chappe_sip_siprec_rtp_sup).
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
                    id => chappe_sip_siprec_rtp,
                    start => {chappe_sip_siprec_rtp, start_link, []},
                    restart => temporary,
                    shutdown => 5000,
                    type => worker,
                    modules => [chappe_sip_siprec_rtp]
                }
            ]
        }}.
