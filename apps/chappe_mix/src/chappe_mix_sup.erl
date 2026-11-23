%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Top supervisor: one simple_one_for_one supervisor holding a temporary
%% child per conference. A conference that crashes is not restarted; its
%% owner sees it go and decides.
-module(chappe_mix_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

init(top) ->
    Confs = #{
        id => chappe_mix_conf_sup,
        start =>
            {supervisor, start_link, [
                {local, chappe_mix_conf_sup}, ?MODULE, confs
            ]},
        type => supervisor
    },
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Confs]}};
init(confs) ->
    Conf = #{
        id => chappe_mix_conf,
        start => {chappe_mix_conf, start_link, []},
        restart => temporary
    },
    {ok, {#{strategy => simple_one_for_one}, [Conf]}}.
