%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Delete, purge and load chappe_sip_nif, for chappe_sip_nif:replace/0.
%%
%% It lives outside chappe_sip_nif so that the process running it holds no
%% frame of the module it purges. {error, old_code_in_use} after the delete
%% means a process still runs the module's code: the module is then
%% deleted, and code:purge/1 (which kills that process) then
%% code:load_file/1 finish the job.
-module(chappe_sip_nif_reload).

-export([run/1]).

-spec run(module()) -> {module, module()} | {error, term()}.
run(Mod) ->
    case code:soft_purge(Mod) of
        true ->
            true = code:delete(Mod),
            case code:soft_purge(Mod) of
                true -> code:load_file(Mod);
                false -> {error, old_code_in_use}
            end;
        false ->
            {error, old_code_in_use}
    end.
