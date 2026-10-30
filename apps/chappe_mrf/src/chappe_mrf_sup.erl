%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Root supervisor: the registry of the calls waiting for FreeSWITCH, then
%% one pool for endpoints and one for conferences (both temporary: an
%% endpoint or a conference that stops is not restarted, its owner hears
%% of it).
-module(chappe_mrf_sup).
-behaviour(supervisor).

-export([start_link/0, start_endpoint/1, start_conf/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

-spec start_endpoint(map()) -> {ok, pid()} | {error, term()}.
start_endpoint(Args) ->
    supervisor:start_child(chappe_mrf_ep_sup, [Args]).

-spec start_conf(map()) -> {ok, pid()} | {error, term()}.
start_conf(Args) ->
    supervisor:start_child(chappe_mrf_conf_sup, [Args]).

init(top) ->
    Flags = #{strategy => one_for_one, intensity => 5, period => 10},
    {ok,
        {Flags, [
            #{
                id => chappe_mrf_registry,
                start => {chappe_mrf_registry, start_link, []},
                shutdown => 5000
            },
            pool(chappe_mrf_ep_sup, chappe_mrf_endpoint),
            pool(chappe_mrf_conf_sup, chappe_mrf_conf)
        ]}};
init({pool, Mod}) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    {ok,
        {Flags, [
            #{
                id => Mod,
                start => {Mod, start_link, []},
                restart => temporary,
                shutdown => 5000
            }
        ]}}.

pool(Name, Mod) ->
    #{
        id => Name,
        start =>
            {supervisor, start_link, [{local, Name}, ?MODULE, {pool, Mod}]},
        type => supervisor,
        shutdown => infinity
    }.
