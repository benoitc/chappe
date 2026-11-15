%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The directory: where a key lives, as `{home region, info}'. It is the
%% seam between regions. This release ships the `local' backend
%% (chappe_cluster_directory_local), which keeps the entries in the
%% region's KV; a cross-region backend implements the same two callbacks
%% and is picked with the `directory' env, with no change to callers.
-module(chappe_cluster_directory).

-export([publish/3, resolve/1]).

-callback publish(Key :: term(), Region :: atom(), Info :: map()) ->
    ok | {error, term()}.
-callback resolve(Key :: term()) ->
    {ok, #{region := atom(), info := map()}} | not_found | {error, term()}.

%% Record that `Key' is homed in `Region', with `Info' for whoever finds it.
-spec publish(term(), atom(), map()) -> ok | {error, term()}.
publish(Key, Region, Info) when is_atom(Region), is_map(Info) ->
    (backend()):publish(Key, Region, Info);
publish(_, _, _) ->
    {error, badarg}.

-spec resolve(term()) ->
    {ok, #{region := atom(), info := map()}} | not_found | {error, term()}.
resolve(Key) ->
    (backend()):resolve(Key).

backend() ->
    chappe_cluster_config:get(directory).
