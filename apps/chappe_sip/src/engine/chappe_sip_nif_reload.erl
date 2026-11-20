%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Delete, purge and load chappe_sip_nif, for chappe_sip_nif:replace/0,
%% which has reserved the engine slot.
%%
%% It lives outside chappe_sip_nif so that the process running it holds no
%% frame of the module it purges. What a failure leaves, and what you do
%% then (docs/design/engine.md, "Upgrading the NIF"):
%%
%% - {error, old_code_in_use} before the delete: nothing changed and the
%%   slot is released. A process runs old code of the module; once it is
%%   done (or code:purge/1 killed it), call replace/0 again.
%% - {error, not_deleted}: nothing changed and the slot is released.
%% - {error, old_code_in_use} after the delete: there is no current
%%   chappe_sip_nif. code:purge/1 (which kills that process) then
%%   code:load_file/1 finish the job.
%% - an error from code:load_file/1: there is no current chappe_sip_nif.
%%   Fix the cause (a missing or bad file) and call code:load_file/1.
%%
%% After the delete the module has no code left to release the slot from:
%% the next load of the library frees it.
-module(chappe_sip_nif_reload).

-export([run/1]).

-spec run(module()) -> {module, module()} | {error, term()}.
run(Mod) ->
    case code:soft_purge(Mod) of
        true ->
            case code:delete(Mod) of
                true -> purge_load(Mod);
                false -> released(not_deleted)
            end;
        false ->
            released(old_code_in_use)
    end.

purge_load(Mod) ->
    case code:soft_purge(Mod) of
        true -> code:load_file(Mod);
        false -> {error, old_code_in_use}
    end.

%% the module is still current: give the slot back
released(Why) ->
    ok = chappe_sip_nif:release_slot(),
    {error, Why}.
