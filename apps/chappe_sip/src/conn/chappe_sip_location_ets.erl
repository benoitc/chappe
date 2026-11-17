%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The node-local location store: an ETS table owned by
%% chappe_sip_registry_keeper, so the bindings outlive a crash of the
%% registry. Writes come from the registry process only, one at a time,
%% so a version is not needed: it is always 0. registrar_max_aors bounds
%% the distinct AORs. Every binding is this node's: the registry sweeps
%% the expired ones itself, and there is no held index or edge route.
-module(chappe_sip_location_ets).
-behaviour(chappe_sip_location).

-export([read/2, write/3, aors/0, clear/0]).
-export([write_mode/0, start/0, stop/0, periodic/2, held/4, mine/0]).
-export([view/2, edge/1]).

-define(TAB, chappe_sip_registry).

read(Aor, _Mode) ->
    case ets:lookup(?TAB, Aor) of
        [{Aor, Bs}] -> {ok, Bs, 0};
        [] -> {ok, [], 0}
    end.

write(Aor, _Version, []) ->
    ets:delete(?TAB, Aor),
    ok;
write(Aor, _Version, Bs) ->
    NewAtCap =
        not ets:member(?TAB, Aor) andalso
            ets:info(?TAB, size) >= chappe_sip_config:get(registrar_max_aors),
    case NewAtCap of
        true ->
            {error, full};
        false ->
            ets:insert(?TAB, {Aor, Bs}),
            ok
    end.

aors() ->
    [Aor || {Aor, _} <- ets:tab2list(?TAB)].

clear() ->
    ets:delete_all_objects(?TAB),
    ok.

write_mode() ->
    serialized.

start() ->
    ok.

stop() ->
    ok.

%% the sweep, in the registry process
periodic(_Registry, Job) ->
    ok = chappe_sip_registry:sweep(fun() -> true end),
    Job.

held(_Aor, _Bs, _Drop, _Stamp) ->
    ok.

mine() ->
    aors().

%% one node: every binding is this node's, whatever it is called now
view(B, Now) ->
    [chappe_sip_registry_store:to_map(B, Now)].

edge(B) ->
    B.
