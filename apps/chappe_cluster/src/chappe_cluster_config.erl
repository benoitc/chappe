%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The app's configuration: read from the application env once, at start,
%% validated, and kept in a persistent term (it changes only when the app
%% restarts). A bad value fails the start with `{error, badarg}' and a log
%% line that names the key.
%%
%% | key               | default            | meaning                           |
%% |-------------------|--------------------|-----------------------------------|
%% | region            | default            | the region this node belongs to   |
%% | voters            | [node()]           | the region's Ra members at boot   |
%% | data_dir          | "cluster_data"     | Ra's log and snapshots (per node) |
%% | lease_ms          | 6000               | how long a renewal keeps a node   |
%% | renew_ms          | 2000               | how often a node renews           |
%% | max_leases        | 100000             | leases one node may hold          |
%% | max_keys          | 100000             | keys in the region's KV           |
%% | max_value_bytes   | 65536              | one KV value, external size       |
%% | max_watch_mailbox | 10000              | a watcher's queue before overflow |
%% | command_timeout   | 5000               | a write's wait for the quorum     |
%% | directory         | chappe_cluster_directory_local | the directory backend |
-module(chappe_cluster_config).

-compile({no_auto_import, [get/1]}).

-export([load/0, get/1, server_id/0, server_id/1, server_name/0]).

-define(TERM, {?MODULE, config}).

-define(KEYS, [
    region,
    voters,
    data_dir,
    lease_ms,
    renew_ms,
    max_leases,
    max_keys,
    max_value_bytes,
    max_watch_mailbox,
    command_timeout,
    directory
]).

-spec load() -> ok | {error, badarg}.
load() ->
    try
        Conf = maps:from_list([{K, value(K)} || K <- ?KEYS]),
        ok = check_timing(Conf),
        persistent_term:put(?TERM, Conf#{server_name => name(Conf)})
    catch
        error:{badarg, Key} ->
            logger:error("chappe_cluster: bad value for ~p", [Key]),
            {error, badarg}
    end.

-spec get(atom()) -> term().
get(Key) ->
    #{Key := V} = persistent_term:get(?TERM),
    V.

%% The registered name of the region's Ra server on every member node.
-spec server_name() -> atom().
server_name() ->
    get(server_name).

-spec server_id() -> {atom(), node()}.
server_id() ->
    server_id(node()).

-spec server_id(node()) -> {atom(), node()}.
server_id(Node) ->
    {server_name(), Node}.

%% ---- validation ----

value(Key) ->
    V = env(Key),
    case valid(Key, V) of
        true -> V;
        false -> error({badarg, Key})
    end.

env(voters) ->
    application:get_env(chappe_cluster, voters, [node()]);
env(Key) ->
    application:get_env(chappe_cluster, Key, default(Key)).

default(region) -> default;
default(data_dir) -> "cluster_data";
default(lease_ms) -> 6000;
default(renew_ms) -> 2000;
default(max_leases) -> 100000;
default(max_keys) -> 100000;
default(max_value_bytes) -> 65536;
default(max_watch_mailbox) -> 10000;
default(command_timeout) -> 5000;
default(directory) -> chappe_cluster_directory_local.

valid(region, V) ->
    is_atom(V) andalso V =/= undefined;
valid(voters, V) ->
    is_list(V) andalso V =/= [] andalso lists:all(fun is_atom/1, V);
valid(data_dir, V) ->
    (is_list(V) andalso io_lib:printable_unicode_list(V)) orelse is_binary(V);
valid(directory, V) ->
    is_atom(V);
valid(_, V) ->
    is_integer(V) andalso V > 0.

%% A holder gives its lease up renew_ms / 2 before lease_ms runs out, and a
%% node must get two renewals in before that (each may take renew_ms).
check_timing(#{lease_ms := L, renew_ms := R}) when L >= 3 * R ->
    ok;
check_timing(_) ->
    error({badarg, lease_ms}).

name(#{region := R}) ->
    list_to_atom("chappe_cluster_" ++ atom_to_list(R)).
