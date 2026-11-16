%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Where the location store keeps its bindings.
%%
%% chappe_sip_registry holds the registrar's rules (RFC 3261 10.3, RFC 3327,
%% RFC 5626); a backend holds the bindings of each AOR. The `cluster'
%% setting picks it:
%% - `none' (the default): chappe_sip_location_ets, a node-local table,
%%   every write serialized through the registry process;
%% - `chappe_cluster': chappe_sip_location_cluster, one value per AOR in
%%   the region's KV, written with compare-and-swap, read from the local
%%   replica.
%%
%% A write names the version its read returned; a backend refuses it with
%% `conflict' when the AOR changed in between, and the registry reads and
%% applies the request again.
-module(chappe_sip_location).

-include("chappe_sip_location.hrl").

-export([backend/0, read/2, write/4, aors/1, clear/1]).
-export_type([version/0]).

-type binding() :: #binding{}.
-type version() :: non_neg_integer().

%% The AOR's bindings, expired ones included, and their version (0: none).
-callback read(Aor :: binary()) ->
    {ok, [binding()], version()} | {error, no_quorum}.
%% Replace the AOR's bindings ([] removes the AOR) if it is still at
%% Version. `full': a new AOR past the store's bound; `too_large': the
%% value past the backend's size bound.
-callback write(Aor :: binary(), Version :: version(), [binding()]) ->
    ok | {error, conflict | no_quorum | too_large | full}.
%% Every AOR the store holds.
-callback aors() -> [binary()].
%% Drop everything this node can drop (tests, reconfiguration).
-callback clear() -> ok.

%% The backend calls, for the registry (bindings are #binding{} records,
%% chappe_sip_location.hrl).
-spec read(module(), binary()) ->
    {ok, [tuple()], version()} | {error, no_quorum}.
read(Store, Aor) ->
    Store:read(Aor).

-spec write(module(), binary(), version(), [tuple()]) ->
    ok | {error, conflict | no_quorum | too_large | full}.
write(Store, Aor, Version, Bs) ->
    Store:write(Aor, Version, Bs).

-spec aors(module()) -> [binary()].
aors(Store) ->
    Store:aors().

-spec clear(module()) -> ok.
clear(Store) ->
    Store:clear().

%% The backend the `cluster' setting names.
-spec backend() -> module().
backend() ->
    case chappe_sip_config:get(cluster) of
        chappe_cluster -> chappe_sip_location_cluster;
        _ -> chappe_sip_location_ets
    end.
