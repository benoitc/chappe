%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The `local' directory backend: entries live in the region's KV, under
%% `chappe_cluster/directory/' and the key's external term format, so only
%% this region sees them.
-module(chappe_cluster_directory_local).
-behaviour(chappe_cluster_directory).

-export([publish/3, resolve/1]).

-define(PREFIX, "chappe_cluster/directory/").

-spec publish(term(), atom(), map()) -> ok | {error, term()}.
publish(Key, Region, Info) ->
    case chappe_cluster:put(kv_key(Key), #{region => Region, info => Info}) of
        {ok, _} -> ok;
        {error, _} = E -> E
    end.

-spec resolve(term()) ->
    {ok, #{region := atom(), info := map()}} | not_found | {error, term()}.
resolve(Key) ->
    case chappe_cluster:get(kv_key(Key)) of
        {ok, Entry, _Version} -> {ok, Entry};
        not_found -> not_found;
        {error, _} = E -> E
    end.

kv_key(Key) ->
    <<?PREFIX, (term_to_binary(Key))/binary>>.
