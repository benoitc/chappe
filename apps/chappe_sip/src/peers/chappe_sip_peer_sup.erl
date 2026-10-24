%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The peer processes (chappe_sip_peer), one per monitored peer.
-module(chappe_sip_peer_sup).
-behaviour(supervisor).

-export([start_link/0, start_peer/2, stop_peer/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_peer(term(), map()) -> {ok, pid()} | {error, term()}.
start_peer(Name, Opts) ->
    case supervisor:start_child(?MODULE, [Name, Opts]) of
        {ok, Pid} -> {ok, Pid};
        {error, _} = Err -> Err
    end.

-spec stop_peer(pid()) -> ok | {error, not_found}.
stop_peer(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

init([]) ->
    {ok,
        {#{strategy => simple_one_for_one, intensity => 10, period => 10}, [
            #{
                id => chappe_sip_peer,
                start => {chappe_sip_peer, start_link, []},
                %% a peer that crashes is dropped from the table; add it again
                restart => temporary,
                shutdown => 2000,
                type => worker,
                modules => [chappe_sip_peer]
            }
        ]}}.
