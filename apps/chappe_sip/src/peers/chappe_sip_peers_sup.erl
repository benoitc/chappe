%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Peer monitoring: the peers table and its subscribers
%% (chappe_sip_peers), the peer processes (chappe_sip_peer_sup), the
%% registrar's keepalive (chappe_sip_qualify), then the peers of the
%% application setting. rest_for_one: the processes go with the table.
-module(chappe_sip_peers_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        worker(chappe_sip_peers, start_link, permanent),
        #{
            id => chappe_sip_peer_sup,
            start => {chappe_sip_peer_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [chappe_sip_peer_sup]
        },
        worker(chappe_sip_qualify, start_link, permanent),
        #{
            id => chappe_sip_peers_env,
            start => {chappe_sip_peers, load_env, []},
            restart => temporary,
            type => worker,
            modules => [chappe_sip_peers]
        }
    ],
    {ok, {#{strategy => rest_for_one, intensity => 10, period => 10}, Children}}.

worker(Mod, Fun, Restart) ->
    #{
        id => Mod,
        start => {Mod, Fun, []},
        restart => Restart,
        shutdown => 5000,
        type => worker,
        modules => [Mod]
    }.
