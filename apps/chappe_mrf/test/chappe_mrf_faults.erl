%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Faults for chappe_mrf_SUITE (on fakes) and chappe_mrf_live_SUITE (the
%% lab): kill the registry and wait for the next one, find the helpers
%% that run a native call's join, count a room's mixer legs, and wait
%% for a condition.
-module(chappe_mrf_faults).

-export([restart_registry/0, restart_registry/1, join_helpers/0]).
-export([mix_legs/1, eventually/2]).

%% kill the registry and wait for the next one
restart_registry() ->
    Reg = whereis(chappe_mrf_registry),
    exit(Reg, kill),
    restart_registry(Reg).

%% the registry Old is gone: wait for the next one, its init done
restart_registry(Old) ->
    true = eventually(
        fun() ->
            case whereis(chappe_mrf_registry) of
                New when is_pid(New), New =/= Old -> true;
                _ -> false
            end
        end,
        50
    ),
    _ = sys:get_state(chappe_mrf_registry),
    ok.

%% the processes running a native join: a call's (its replace_b/3), an
%% endpoint's (its media steps, chappe_mrf_conf_native_ep)
join_helpers() ->
    [
        P
     || P <- processes(),
        {current_stacktrace, Stack} <- [process_info(P, current_stacktrace)],
        lists:any(fun join_frame/1, Stack)
    ].

join_frame({chappe_mrf_conf_native, F, _, _}) ->
    lists:prefix("-join_b2b/", atom_to_list(F));
join_frame({chappe_mrf_conf_native_ep, F, _, _}) ->
    lists:prefix("-start/", atom_to_list(F));
join_frame(_Frame) ->
    false.

%% the legs of a chappe_sip_media_mix room (chappe_mix:legs/1), 0 before
%% its first join
mix_legs(Room) ->
    case element(6, sys:get_state(chappe_sip_media_mix)) of
        #{Room := R} -> length(chappe_mix:legs(element(2, R)));
        #{} -> 0
    end.

%% whether Fun() holds within N tries, 100 ms apart
eventually(Fun, 0) ->
    Fun();
eventually(Fun, N) ->
    Fun() orelse
        begin
            timer:sleep(100),
            eventually(Fun, N - 1)
        end.
