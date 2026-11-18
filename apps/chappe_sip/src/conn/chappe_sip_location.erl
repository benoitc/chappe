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
%%
%% The backend also says how the registry runs on it, so the registry
%% never names one: whether its writes go through the registry process
%% (serialized) or from the caller (cas), what the registry does every
%% registrar_sweep_ms (periodic/3), what it starts and stops with the
%% registry, the index of the AORs this node holds bindings of, and how a
%% binding looks from this node.
-module(chappe_sip_location).

-include("chappe_sip_location.hrl").

-export([backend/0, read/2, read/3, write/4, aors/1, clear/1]).
-export([write_mode/1, start/1, stop/1, periodic/3, held/5, mine/1]).
-export([view/3, edge/2]).
-export_type([version/0, drop/0]).

-type binding() :: #binding{}.
-type version() :: non_neg_integer().
%% what an index update may drop: entries made before T0, or nothing
-type drop() :: {before, integer()} | keep.

%% The AOR's bindings, expired ones included, and their version (0: none).
%% local: this node's view (on a cluster, its replica, which may lag);
%% consistent: the latest the store holds (on a cluster, the leader's).
-callback read(Aor :: binary(), local | consistent) ->
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
%% serialized: every write goes through the registry process, one at a
%% time; cas: the caller writes, ordered by compare-and-swap.
-callback write_mode() -> serialized | cas.
%% Started and stopped with the registry (a singleton sweep, say).
-callback start() -> ok.
-callback stop() -> ok.
%% Run every registrar_sweep_ms in the registry process, with the job the
%% last run left (undefined for none); the new job, a monitor reference
%% the registry clears on its DOWN, or undefined.
-callback periodic(Registry :: pid(), Job :: reference() | undefined) ->
    reference() | undefined.
%% Index that this node holds bindings of the AOR (or no longer does)
%% after a write or a read, as chappe_sip_registry_store:held/5 says.
-callback held(Aor :: binary(), [binding()], drop(), Stamp :: integer()) -> ok.
%% The AORs that may hold a binding this node took.
-callback mine() -> [binary()].
%% A binding as this node shows it (bindings/1 maps), [] to leave it out.
-callback view(binding(), Now :: integer()) -> [map()].
%% A new binding as it is stored: with the route other nodes reach it
%% through, on a store they share.
-callback edge(binding()) -> binding().

%% The backend calls, for the registry (bindings are #binding{} records,
%% chappe_sip_location.hrl).
-spec read(module(), binary()) ->
    {ok, [tuple()], version()} | {error, no_quorum}.
read(Store, Aor) ->
    read(Store, Aor, local).

-spec read(module(), binary(), local | consistent) ->
    {ok, [tuple()], version()} | {error, no_quorum}.
read(Store, Aor, Mode) ->
    Store:read(Aor, Mode).

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

-spec write_mode(module()) -> serialized | cas.
write_mode(Store) ->
    Store:write_mode().

-spec start(module()) -> ok.
start(Store) ->
    Store:start().

-spec stop(module()) -> ok.
stop(Store) ->
    Store:stop().

-spec periodic(module(), pid(), reference() | undefined) ->
    reference() | undefined.
periodic(Store, Registry, Job) ->
    Store:periodic(Registry, Job).

-spec held(module(), binary(), [tuple()], drop(), integer()) -> ok.
held(Store, Aor, Bs, Drop, Stamp) ->
    Store:held(Aor, Bs, Drop, Stamp).

-spec mine(module()) -> [binary()].
mine(Store) ->
    Store:mine().

-spec view(module(), tuple(), integer()) -> [map()].
view(Store, B, Now) ->
    Store:view(B, Now).

-spec edge(module(), tuple()) -> tuple().
edge(Store, B) ->
    Store:edge(B).

%% The backend the `cluster' setting names.
-spec backend() -> module().
backend() ->
    case chappe_sip_config:get(cluster) of
        chappe_cluster -> chappe_sip_location_cluster;
        _ -> chappe_sip_location_ets
    end.
