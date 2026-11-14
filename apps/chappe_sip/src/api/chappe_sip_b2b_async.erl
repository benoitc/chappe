%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc chappe_sip_b2b:relay_async/2: the relay loop of a call in a process
%% of its own, a temporary child of chappe_sip_b2b_sup (it is not
%% restarted: a relay that dies takes its call with it, as its dialogs see
%% their owner go). The process that ran create_b2bua/4 hands it both
%% dialogs and the call's rtpengine session, and the messages the dialogs
%% sent before they moved; the loop starts once it owns them.
%%
%% Its owner (relay_async/2's owner option, default the notify process)
%% is monitored: when it dies the call is hung up, both legs get a BYE
%% and the rtpengine session goes. Without an owner the call runs until a
%% leg ends it.
-module(chappe_sip_b2b_async).

-export([run/2, start_link/1, init/1]).

-define(HANDOVER, 10000).

-spec run(chappe_sip_b2b:legs(), map()) ->
    {ok, chappe_sip_b2b:b2b()} | {error, term()}.
run(#{uas := A, uac := B, b2b := {_, Ref}} = Legs, Opts) ->
    M = maps:get(media, Legs, #{}),
    Notify = maps:get(notify, Opts, maps:get(notify, M, undefined)),
    Owner = maps:get(owner, Opts, Notify),
    Args = #{
        legs => Legs,
        opts => maps:without([owner], Opts),
        notify => Notify,
        owner => Owner,
        parent => self()
    },
    case chappe_sip_b2b_sup:start_relay(Args) of
        {ok, Pid} ->
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
            Pid ! {go, self()},
            {ok, {Pid, Ref}};
        {error, _} = Err ->
            Err
    end.

%% chappe_sip_b2b_sup's child.
-spec start_link(map()) -> {ok, pid()}.
start_link(Args) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Args])}.

-spec init(map()) -> ok.
init(#{legs := Legs, opts := Opts, notify := Notify, owner := Owner} = Args) ->
    #{parent := Parent} = Args,
    #{b2b := {_, Ref}} = Legs,
    receive
        {go, Parent} -> ok
    after ?HANDOVER -> exit(no_handover)
    end,
    %% this process serves the call (chappe_sip_call) until it ends
    ok = chappe_sip_call:join(
        maps:get(call_ref, Legs, undefined), b2b, {self(), Ref}
    ),
    OwnerMon =
        case Owner of
            P when is_pid(P) -> erlang:monitor(process, P);
            _ -> undefined
        end,
    Result = chappe_sip_b2b_relay:run(Legs, Opts#{owner_mon => OwnerMon}),
    _ =
        is_pid(Notify) andalso
            (Notify ! {chappe_sip_b2b, Ref, {done, Result}}),
    ok.

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
