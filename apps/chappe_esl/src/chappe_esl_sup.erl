%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Root supervisor. Owns chappe_esl_outbound_sup (the per-channel handler pool for
%% accepted outbound connections). Outbound listeners are added as dynamic
%% children by chappe_esl:start_listener/3. Inbound connections are not
%% supervised here: chappe_esl:connect/1 links a fresh chappe_esl_conn to the caller.
%% The node registry (chappe_esl_nodes) starts here when the `nodes' app env
%% lists nodes, otherwise on the first chappe_esl:node_add/2.
-module(chappe_esl_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([start_listener/1, stop_listener/1, listener/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Add a listener as a dynamic child of the root supervisor.
-spec start_listener(map()) -> {ok, pid()} | {error, term()}.
start_listener(Opts) ->
    Ref = maps:get(ref, Opts),
    Child = #{
        id => {chappe_esl_listener, Ref},
        start => {chappe_esl_listener, start_link, [Opts]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [chappe_esl_listener]
    },
    supervisor:start_child(?MODULE, Child).

-spec stop_listener(term()) -> ok | {error, term()}.
stop_listener(Ref) ->
    Id = {chappe_esl_listener, Ref},
    case supervisor:terminate_child(?MODULE, Id) of
        ok -> supervisor:delete_child(?MODULE, Id);
        {error, _} = Error -> Error
    end.

%% The pid of a running listener.
-spec listener(term()) -> {ok, pid()} | error.
listener(Ref) ->
    Id = {chappe_esl_listener, Ref},
    case [P || {I, P, _, _} <- supervisor:which_children(?MODULE), I =:= Id] of
        [Pid] when is_pid(Pid) -> {ok, Pid};
        _ -> error
    end.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [
        #{
            id => chappe_esl_outbound_sup,
            start => {chappe_esl_outbound_sup, start_link, []},
            type => supervisor,
            shutdown => infinity
        }
    ],
    {ok, {SupFlags, Children ++ registry(env_nodes())}}.

registry([]) -> [];
registry(Nodes) -> [chappe_esl_nodes:child_spec(Nodes)].

%% `nodes' is a list of {Name, Opts} or a Name => Opts map.
env_nodes() ->
    case application:get_env(chappe_esl, nodes, []) of
        Nodes when is_map(Nodes) -> lists:sort(maps:to_list(Nodes));
        Nodes when is_list(Nodes) -> Nodes
    end.
