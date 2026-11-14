%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The local half of an attended transfer (chappe_sip_b2b_transfer):
%% the call that holds the dialog a Replaces names lends its other leg to
%% the transfer, which joins it to its own call with a re-INVITE from
%% rtpengine. The lender waits for the outcome: taken, its relay ends;
%% given back, its call goes on as it was. Both calls may be on different
%% nodes: every step is a message to a pid.
-module(chappe_sip_b2b_join).

-export([lend/1, settle/2, detach/3]).

%% how long a call lends a leg to an attended join: the join's re-INVITE
%% and the replace_leg/4 call around it end well before
-define(LEND_WAIT, 200000).

%% The call that holds the named dialog (Info's dialog2, of the call
%% b2b2) lends its other leg to the calling process.
-spec lend(map()) ->
    {ok, chappe_sip_b2b:b2b(), chappe_sip_dialog:dialog()} | error.
lend(#{dialog2 := D2, b2b2 := B}) ->
    case chappe_sip_b2b:call(B, {detach, D2}) of
        {ok, Target} -> {ok, B, Target};
        _ -> error
    end.

%% Tell the lender whether its leg was taken (done) or comes back (back).
-spec settle(chappe_sip_b2b:b2b(), done | back) -> ok.
settle({Pid, Ref}, How) ->
    Pid ! {chappe_sip_b2b, Ref, {lent, self(), How}},
    ok.

%% The relay of the call that holds D, a leg of its, lends the other leg
%% (Keep) to the caller (From), a transfer joining it to its own call,
%% and waits for the outcome (lent/5): taken, D gets a BYE, the call's
%% rtpengine session goes and the relay ends; given back, the call goes
%% on as it was. {loop, S} when D is not one of its legs or an offer is
%% pending; the caller then gets an error.
-spec detach({pid(), term()}, chappe_sip_dialog:dialog(), map()) ->
    {done, transferred} | {loop, map()}.
detach(From, D, #{a := A, b := B, pending := undefined} = S) ->
    P = chappe_sip_dialog:pid(D),
    case {chappe_sip_dialog:pid(A), chappe_sip_dialog:pid(B)} of
        {P, _} -> lend_out(From, A, B, S);
        {_, P} -> lend_out(From, B, A, S);
        _ -> not_mine(From, S)
    end;
detach(From, _D, S) ->
    not_mine(From, S).

lend_out({Caller, Tag}, D, Keep, #{refs := {RefA, RefB}} = S) ->
    try chappe_sip_dialog:set_owner(Keep, Caller) of
        ok ->
            erlang:demonitor(RefA, [flush]),
            erlang:demonitor(RefB, [flush]),
            Caller ! {Tag, {ok, Keep}},
            lent(Caller, erlang:monitor(process, Caller), D, Keep, S)
    catch
        exit:_ ->
            Caller ! {Tag, {error, gone}},
            {loop, S}
    end.

%% While its leg Keep is lent, the call answers nothing of D but its
%% ACKs (500 with Retry-After, as for an offer under way) and no call to
%% its relay (busy). A borrower that dies, or gives no answer within
%% ?LEND_WAIT, keeps the leg: whoever owns Keep then carries it on (or
%% ends it), and this call ends.
lent(Caller, CMon, D, Keep, #{ref := Ref, media := M} = S) ->
    receive
        {chappe_sip_b2b, Ref, {lent, Caller, done}} ->
            erlang:demonitor(CMon, [flush]),
            handed_over(D, M);
        {chappe_sip_b2b, Ref, {lent, Caller, back}} ->
            erlang:demonitor(CMon, [flush]),
            {loop, take_back(Keep, S)};
        {'DOWN', CMon, process, Caller, _} ->
            handed_over(D, M);
        {chappe_sip_b2b, Ref, {call, {Pid, Tag}, _Req}} ->
            Pid ! {Tag, {error, busy}},
            lent(Caller, CMon, D, Keep, S);
        {chappe_sip_dialog, D, ack, _, _} ->
            lent(Caller, CMon, D, Keep, S);
        {chappe_sip_dialog, D, _Event, _Req, Res} ->
            ok = chappe_sip_b2b_relay:retry_later(Res),
            lent(Caller, CMon, D, Keep, S)
    after ?LEND_WAIT ->
        erlang:demonitor(CMon, [flush]),
        logger:warning("chappe_sip_b2b: lent leg not settled"),
        handed_over(D, M)
    end.

handed_over(D, M) ->
    _ = chappe_sip_b2b_media:stop(M),
    _ = spawn(fun() -> chappe_sip_b2b:destroy_quietly(D, []) end),
    {done, transferred}.

%% Keep comes back: its events come here again, with the requests this
%% call claims, and both legs are watched again (a leg that ended
%% meanwhile ends the call at once)
take_back(Keep, #{a := A, b := B} = S) ->
    _ =
        try
            ok = chappe_sip_dialog:set_owner(Keep, self()),
            chappe_sip_dialog:set_handled(Keep, handled(S))
        catch
            exit:_ -> ok
        end,
    S#{refs := {chappe_sip_dialog:monitor(A), chappe_sip_dialog:monitor(B)}}.

handled(#{requests := Requests, relay_info := RelayInfo, transfer := Mode}) ->
    chappe_sip_b2b_requests:handled(Requests, RelayInfo, Mode).

not_mine({Caller, Tag}, S) ->
    Caller ! {Tag, {error, not_found}},
    {loop, S}.
