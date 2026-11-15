%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The node's KV watch hub, registered locally. The region's machine sends
%% it `{chappe_cluster_kv, put | delete, Key, Value}' for each change, in
%% log order; the hub hands it to every local watcher whose prefix matches,
%% as `{chappe_cluster, watch, {put | delete, Key, Value}}'.
%%
%% The watchers are members of the pg group `{chappe_cluster_watch, Prefix}'
%% in the `chappe_cluster' scope, so the hub keeps no state: a restart of
%% the hub loses no watch, and a watcher's death drops its watches.
%%
%% The bound: a watcher whose mailbox already holds max_watch_mailbox
%% messages gets `{chappe_cluster, watch, overflow}' once, and its watches
%% are dropped. It reads what it needs with get/1 and watches again.
%%
%% Delivery is at least once: a member that replays its log after a restart
%% may hand an event again.
-module(chappe_cluster_watch).
-behaviour(gen_server).

-export([start_link/0, watch/2, unwatch/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SCOPE, chappe_cluster).

-record(state, {}).

-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Join `Pid' (local) to the prefix's group, once.
-spec watch(pid(), binary()) -> ok.
watch(Pid, Prefix) ->
    Group = group(Prefix),
    case lists:member(Pid, pg:get_local_members(?SCOPE, Group)) of
        true -> ok;
        false -> pg:join(?SCOPE, Group, Pid)
    end.

-spec unwatch(pid(), binary()) -> ok.
unwatch(Pid, Prefix) ->
    _ = pg:leave(?SCOPE, group(Prefix), Pid),
    ok.

-spec init(term()) -> {ok, state()}.
init([]) ->
    {ok, #state{}}.

handle_call(_Req, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({chappe_cluster_kv, Op, Key, Value}, St) ->
    Max = chappe_cluster_config:get(max_watch_mailbox),
    Watchers = lists:usort(
        lists:append([
            pg:get_local_members(?SCOPE, G)
         || {chappe_cluster_watch, P} = G <- pg:which_groups(?SCOPE),
            prefix(P, Key)
        ])
    ),
    lists:foreach(
        fun(Pid) -> deliver(Pid, {Op, Key, Value}, Max) end, Watchers
    ),
    {noreply, St};
handle_info(Msg, St) ->
    logger:notice("chappe_cluster_watch: unexpected ~0p", [Msg]),
    {noreply, St}.

group(Prefix) ->
    {chappe_cluster_watch, Prefix}.

deliver(Pid, Event, Max) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N < Max ->
            Pid ! {chappe_cluster, watch, Event},
            ok;
        {message_queue_len, _} ->
            Pid ! {chappe_cluster, watch, overflow},
            leave_all(Pid);
        undefined ->
            ok
    end.

leave_all(Pid) ->
    lists:foreach(
        fun
            ({chappe_cluster_watch, _} = G) -> pg:leave(?SCOPE, G, Pid);
            (_) -> ok
        end,
        pg:which_groups(?SCOPE)
    ).

prefix(P, Key) when is_binary(Key) ->
    binary:longest_common_prefix([P, Key]) =:= byte_size(P);
prefix(_, _) ->
    false.
