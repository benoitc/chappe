%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Replacing leg B of an anchored B2BUA call (chappe_sip_b2b:replace_b/3).
%%
%% The relay gets rtpengine's offer for A's side of the session (an offer
%% from A's tag, with A's SDP), so A keeps the addresses it sends to and
%% sees no re-INVITE. call/4 then brings the new B in, off the relay
%% loop: a fresh INVITE to a URI, or a re-INVITE of a dialog the app made.
%% On its 2xx, swap/3 gives rtpengine the new B's answer under the new
%% B's To-tag and moves the relay onto the new dialog; the old B gets a
%% BYE. On a failure the relay hands rtpengine the old B's SDP back.
-module(chappe_sip_b2b_replace).

-export([call/4, swap/3, abort/3]).

%% options of create_b2bua/4 that also apply to the INVITE of a new B
-define(UAC_OPTS, [
    proxy, auth, flow, session_expires, min_se, session_refresher
]).

%% The new B answers Sdp (rtpengine's offer): {ok, Dialog, Answer} or
%% {error, _}. Relay owns the new dialog; Handled are its handled_events.
-spec call(
    binary() | {dialog, chappe_sip_dialog:dialog()},
    binary(),
    map(),
    pid()
) -> {ok, chappe_sip_dialog:dialog(), binary()} | {error, term()}.
call({dialog, D}, Sdp, #{handled := Handled}, Relay) ->
    try
        %% the relay carries the dialog from now on: its events go there
        ok = chappe_sip_dialog:set_owner(D, Relay),
        ok = chappe_sip_dialog:set_handled(D, Handled),
        case chappe_sip_dialog:modify(D, Sdp) of
            {ok, Answer} -> {ok, D, Answer};
            {error, _} = Err -> Err
        end
    catch
        exit:Why -> {error, Why}
    end;
call(Uri, Sdp, #{handled := Handled} = Opts, Relay) when is_binary(Uri) ->
    UacOpts = maps:merge(maps:with(?UAC_OPTS, Opts), #{
        local_sdp => Sdp,
        headers => maps:get(headers, Opts, []),
        owner => Relay,
        notify => self(),
        handled_events => Handled
    }),
    case chappe_sip_uac:start(Uri, UacOpts) of
        {ok, URef} ->
            Deadline =
                erlang:monotonic_time(millisecond) +
                    chappe_sip_b2b:timer_c(Opts),
            ring(URef, Deadline);
        Err ->
            Err
    end.

%% the new B rings until it answers, Timer C, or the relay ends (abort/3)
ring(URef, Deadline) ->
    receive
        {chappe_sip_uac, URef, {ok, D}} ->
            {ok, D, chappe_sip_dialog:remote_sdp(D)};
        {chappe_sip_uac, URef, {error, _} = Err} ->
            Err;
        {chappe_sip_uac, URef, _} ->
            ring(URef, Deadline);
        abort ->
            %% CANCEL it, BYE a 2xx that still comes
            ok = chappe_sip_uac:abandon(URef, #{}),
            {error, aborted}
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        ok = chappe_sip_uac:abandon(URef, #{why => timeout}),
        {error, timeout}
    end.

%% The call ended while the helper Pid (its result tagged Ref) brings a
%% new B in: the new INVITE is CANCELled at once, a new B that answered
%% meanwhile gets a BYE, and the replace_b/3 caller From gets {error,
%% call_ended}.
-spec abort(pid(), reference(), {pid(), term()}) -> ok.
abort(Pid, Ref, {Caller, Tag}) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! abort,
    receive
        {relay_result, Ref, {ok, D, _}} ->
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(D, []) end),
            ok;
        {relay_result, Ref, _} ->
            ok;
        {'DOWN', MRef, process, Pid, _} ->
            ok
    after 2000 ->
        exit(Pid, kill)
    end,
    erlang:demonitor(MRef, [flush]),
    Caller ! {Tag, {error, call_ended}},
    ok.

%% The new B answered: rtpengine takes its answer under its To-tag, and
%% the relay state S moves to it ({ok, S1}); the old B gets a BYE and the
%% notify process {replaced, b}. {error, _} when rtpengine refuses the
%% answer (the new B is then torn down).
-spec swap(chappe_sip_dialog:dialog(), binary(), map()) ->
    {ok, map()} | {error, term()}.
swap(NewB, Answer, #{media := M0, b := OldB, refs := {RefA, RefB}} = S) ->
    M = chappe_sip_b2b_media:set_tag(b, chappe_sip_b2b:remote_tag(NewB), M0),
    case chappe_sip_b2b_media:answer(b, Answer, M) of
        {ok, _ForA, M1} ->
            erlang:demonitor(RefB, [flush]),
            RefB1 = chappe_sip_dialog:monitor(NewB),
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(OldB, []) end),
            event({replaced, b}, M1),
            {ok, S#{b := NewB, refs := {RefA, RefB1}, media := M1}};
        {reject, Code} ->
            _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(NewB, []) end),
            {error, {rejected, Code}}
    end.

event(Ev, #{notify := Pid, ref := Ref}) when is_pid(Pid) ->
    Pid ! {chappe_sip_b2b, Ref, Ev},
    ok;
event(_Ev, _M) ->
    ok.
