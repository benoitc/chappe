%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_sip_b2b:relay_async/2: the relay loop of a call in a process
%% of its own. The process that ran create_b2bua/4 hands it both dialogs
%% and the call's rtpengine session, and the messages the dialogs sent
%% before they moved; the loop starts once it owns them.
-module(chappe_sip_b2b_async).

-export([run/2]).

-spec run(chappe_sip_b2b:legs(), map()) -> {ok, chappe_sip_b2b:b2b()}.
run(#{uas := A, uac := B, b2b := {_, Ref}} = Legs, Opts) ->
    Parent = self(),
    M = maps:get(media, Legs, #{}),
    Notify = maps:get(notify, Opts, maps:get(notify, M, undefined)),
    Pid = spawn(fun() ->
        receive
            {go, Parent} -> ok
        after 10000 -> exit(no_handover)
        end,
        %% this process serves the call (chappe_sip_call) until it ends
        ok = chappe_sip_call:join(
            maps:get(call_ref, Legs, undefined), b2b, {self(), Ref}
        ),
        Result = chappe_sip_b2b_relay:run(Legs, Opts),
        _ =
            is_pid(Notify) andalso
                (Notify ! {chappe_sip_b2b, Ref, {done, Result}}),
        ok
    end),
    _ = [handover(D, Pid) || D <- [A, B]],
    _ =
        case M of
            #{session := S} when S =/= undefined ->
                chappe_sip_media:set_owner(S, Pid);
            _ ->
                ok
        end,
    forward_stray(A, B, Pid),
    %% the relay process serves the call from now on, not this one
    ok = chappe_sip_call:leave(maps:get(call_ref, Legs, undefined), b2b),
    Pid ! {go, Parent},
    {ok, {Pid, Ref}}.

handover(D, Pid) ->
    try
        chappe_sip_dialog:set_owner(D, Pid)
    catch
        exit:_ -> ok
    end.

%% what the dialogs sent here before they moved goes to the new owner
forward_stray(A, B, Pid) ->
    receive
        {chappe_sip_dialog, D, _, _} = Msg when D =:= A; D =:= B ->
            Pid ! Msg,
            forward_stray(A, B, Pid);
        {chappe_sip_dialog, D, _, _, _} = Msg when D =:= A; D =:= B ->
            Pid ! Msg,
            forward_stray(A, B, Pid)
    after 0 ->
        ok
    end.
