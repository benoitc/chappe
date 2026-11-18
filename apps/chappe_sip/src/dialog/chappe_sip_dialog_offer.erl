%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The offer/answer state of a dialog fsm (RFC 3261 13 and 14, RFC
%% 3264, RFC 3311): request overlap and glare, the claimed re-INVITEs and
%% UPDATEs and their finals, target refresh, the answers the dialog gives
%% on its own, the re-INVITE held while an INVITE server transaction is
%% open, and the hold state of either side.
%%
%% Pure functions of the fsm's #data{}, except handle_ack/2, which tells
%% the owner of the ACK.
-module(chappe_sip_dialog_offer).

-export([derived/1, held/1, keep_sdp/2, early_sdp/2, glare_delay/1]).
-export([overlap/3, track_claimed/4, claimed_final/4, refreshed/3]).
-export([refresh_target/2, refresh_contact/2, new_target/2]).
-export([auto_answer/3, session_event/4, handle_ack/2, update_answered/4]).
-export([invite_server_open/1, held_modify/1]).

-export_type([answer/0]).

-include("chappe_sip.hrl").
-include("chappe_sip_dialog_fsm.hrl").

-type answer() :: {
    100..699, binary(), [{binary(), iodata()}], binary(), #data{}
}.

%% what the dialog's first SDP says: an answer due in the ACK, a peer on
%% hold
-spec derived(#data{}) -> #data{}.
derived(#data{remote_sdp = Remote} = D) ->
    D#data{ack_answer = answer_in_ack(D), remote_hold = held(Remote)}.

%% a UAS dialog formed by an offerless INVITE: our 2xx carries the offer and
%% the ACK the answer (RFC 3261 13.2.1)
answer_in_ack(#data{role = uas, sub = undefined, remote_sdp = <<>>} = D) ->
    D#data.local_sdp =/= <<>>;
answer_in_ack(_D) ->
    false.

-spec held(binary()) -> boolean().
held(<<>>) -> false;
held(Sdp) -> chappe_sip_sdp:on_hold(Sdp).

-spec keep_sdp(binary(), binary()) -> binary().
keep_sdp(<<>>, New) -> New;
keep_sdp(Mine, _New) -> Mine.

%% a later provisional of this early dialog carried the first SDP
-spec early_sdp(binary(), #data{}) -> #data{}.
early_sdp(Sdp, #data{remote_sdp = <<>>} = D) -> D#data{remote_sdp = Sdp};
early_sdp(_Sdp, D) -> D.

%% RFC 3261 14.1: the Call-ID owner (the dialog's UAC) waits 2.1 to 4 s,
%% the other side 0 to 2 s, in units of 10 ms
-spec glare_delay(#data{}) -> non_neg_integer().
glare_delay(#data{role = uac}) -> (209 + rand:uniform(191)) * 10;
glare_delay(#data{}) -> (rand:uniform(201) - 1) * 10.

%% ---- request overlap (RFC 3261 14, RFC 3311 5.2) ----

%% An INVITE while ours is in flight is glare (491); one while the previous
%% incoming INVITE is unanswered gets 500 + Retry-After. UPDATE: the same
%% 500 on overlap, 491 when its offer crosses one of ours, 500 when it
%% arrives on top of an offer we have not answered yet.
-spec overlap(binary(), binary(), #data{}) ->
    ok | {100..699, binary(), [{binary(), binary()}]}.
overlap(<<"INVITE">>, _Body, #data{txning = {_, _, {reinvite, _}}}) ->
    request_pending();
overlap(<<"INVITE">>, _Body, #data{txning = {_, _, {st_refresh, <<"INVITE">>}}}) ->
    request_pending();
overlap(<<"INVITE">>, _Body, #data{srv_invite = {_, _}}) ->
    retry_later();
overlap(<<"UPDATE">>, _Body, #data{srv_update = {_, _}}) ->
    retry_later();
overlap(<<"UPDATE">>, Offer, D) when Offer =/= <<>> ->
    case {offer_out(D), D#data.srv_invite} of
        {true, _} -> request_pending();
        {false, {_, InOffer}} when InOffer =/= <<>> -> retry_later();
        _ -> ok
    end;
overlap(_Method, _Body, _D) ->
    ok.

%% an offer of ours still waiting for its answer
offer_out(#data{txning = {_, _, {reinvite, Sdp}}}) ->
    Sdp =/= <<>>;
offer_out(#data{txning = {_, _, {update, _}}}) ->
    true;
offer_out(#data{txning = {_, _, {st_refresh, <<"INVITE">>}}} = D) ->
    D#data.local_sdp =/= <<>>;
offer_out(#data{uac = Uac, local_sdp = L, remote_sdp = <<>>}) when
    Uac =/= undefined, L =/= <<>>
->
    %% early: our INVITE's offer has no answer yet
    true;
offer_out(#data{ack_answer = Pending}) ->
    Pending.

request_pending() ->
    {491, <<"Request Pending">>, []}.

retry_later() ->
    RA = integer_to_binary(rand:uniform(11) - 1),
    {500, <<"Server Internal Error">>, [{<<"Retry-After">>, RA}]}.

%% ---- claimed requests ----

%% a claimed re-INVITE / UPDATE stays pending until the app answers it
-spec track_claimed(binary(), non_neg_integer(), chappe_sip_req:req(), #data{}) ->
    #data{}.
track_claimed(<<"INVITE">>, TxnH, Req, D) ->
    D#data{srv_invite = {TxnH, chappe_sip_req:body(Req)}};
track_claimed(<<"UPDATE">>, TxnH, Req, D) ->
    D#data{srv_update = {TxnH, chappe_sip_req:body(Req)}};
track_claimed(_Method, _TxnH, _Req, D) ->
    D.

%% the app sent the final response to a claimed request; a 2xx settles the
%% offer/answer exchange it carried
-spec claimed_final(non_neg_integer(), 100..699, binary(), #data{}) ->
    #data{}.
claimed_final(TxnH, Status, Body, D0) ->
    D = refreshed(TxnH, Status, D0),
    claimed_final_1(TxnH, Status, Body, D).

claimed_final_1(TxnH, Status, Body, #data{srv_invite = {TxnH, Offer}} = D) ->
    D1 = D#data{srv_invite = undefined, ack_wait = is_2xx(Status)},
    case Status of
        S when S >= 200, S < 300, Offer =/= <<>> ->
            answered(Offer, Body, D1);
        S when S >= 200, S < 300, Body =/= <<>> ->
            %% offerless re-INVITE: our 2xx is the offer, the ACK answers
            D1#data{local_sdp = Body, ack_answer = true};
        _ ->
            D1
    end;
claimed_final_1(TxnH, Status, Body, #data{srv_update = {TxnH, Offer}} = D) ->
    D1 = D#data{srv_update = undefined},
    case is_2xx(Status) andalso Offer =/= <<>> of
        true -> answered(Offer, Body, D1);
        false -> D1
    end;
claimed_final_1(_TxnH, _Status, _Body, D) ->
    D.

is_2xx(Status) -> Status >= 200 andalso Status < 300.

answered(Offer, <<>>, D) -> D#data{remote_sdp = Offer};
answered(Offer, Answer, D) -> D#data{remote_sdp = Offer, local_sdp = Answer}.

%% ---- target refresh (RFC 3261 12.2) ----

%% RFC 3261 12.2.2: a target refresh request we accept moves the remote
%% target to its Contact (a rejected one changes nothing, 8.2)
-spec refreshed(non_neg_integer(), 100..699, #data{}) -> #data{}.
refreshed(TxnH, Status, #data{refresh = R} = D) ->
    case maps:take(TxnH, R) of
        {Uri, R1} when Status >= 200, Status < 300 ->
            D#data{refresh = R1, remote_target = Uri};
        {_Uri, R1} when Status >= 200 ->
            D#data{refresh = R1};
        _ ->
            D
    end.

%% the Contact URI of a target refresh request, if it has one
-spec refresh_target(binary(), chappe_sip_req:req()) -> binary() | undefined.
refresh_target(Method, Req) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    contact_uri(chappe_sip_req:get(<<"contact">>, Req));
refresh_target(_Method, _Req) ->
    undefined.

%% the Contact of a 2xx to our target refresh request is the new remote
%% target (RFC 3261 12.2.1.2)
-spec new_target(chappe_sip_msg:msg(), #data{}) -> #data{}.
new_target(Msg, D) ->
    case contact_uri(chappe_sip_msg:get(<<"contact">>, Msg)) of
        undefined -> D;
        Uri -> D#data{remote_target = Uri}
    end.

contact_uri(undefined) ->
    undefined;
contact_uri(Contact) ->
    case chappe_sip_hdr:name_addr(Contact) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> undefined
    end.

%% target refresh responses carry our Contact (RFC 3261 12.2.2)
-spec refresh_contact(binary(), #data{}) -> [{binary(), binary()}].
refresh_contact(Method, D) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    contact_hdr(D);
refresh_contact(_Method, _D) ->
    [].

contact_hdr(#data{local_contact = undefined}) -> [];
contact_hdr(#data{local_contact = C}) -> [{<<"Contact">>, C}].

%% ---- the answers nobody claimed ----

%% The answer to an in-dialog request nobody claimed:
%% {Status, Reason, Headers, Body, Data}.
%% re-INVITE / UPDATE with an offer: answered with the current local SDP,
%% the session unchanged (488 without one). An offerless re-INVITE gets our
%% SDP as the offer and the ACK carries the answer.
-spec auto_answer(term(), chappe_sip_req:req(), #data{}) -> answer().
auto_answer(modify, Req, D) ->
    case {chappe_sip_req:body(Req), D#data.local_sdp} of
        {_, <<>>} ->
            not_acceptable(D);
        {<<>>, Sdp} ->
            sdp_ok(Sdp, D#data{ack_answer = true});
        {Offer, Sdp} ->
            sdp_ok(Sdp, D#data{remote_sdp = Offer})
    end;
auto_answer(update, Req, D) ->
    case {chappe_sip_req:body(Req), D#data.local_sdp} of
        {<<>>, _} -> {200, <<"OK">>, contact_hdr(D), <<>>, D};
        {_, <<>>} -> not_acceptable(D);
        {Offer, Sdp} -> sdp_ok(Sdp, D#data{remote_sdp = Offer})
    end;
auto_answer(refer, _Req, D) ->
    %% nobody here will act on the transfer
    {603, <<"Declined">>, [], <<>>, D};
auto_answer(options, _Req, D) ->
    %% RFC 3261 11.2
    Hdrs = [
        {<<"Allow">>, ?ALLOW},
        {<<"Accept">>, <<"application/sdp">>},
        {<<"Supported">>, ?SUPPORTED}
    ],
    {200, <<"OK">>, Hdrs, <<>>, D};
auto_answer({method, <<"PRACK">>}, _Req, D) ->
    %% no reliable provisional of ours is pending in a confirmed dialog
    {481, <<"Call/Transaction Does Not Exist">>, [], <<>>, D};
auto_answer(publish, _Req, D) ->
    %% RFC 3261 8.2.1: known, not allowed here unless the owner takes it
    not_allowed(D);
auto_answer({method, <<"REGISTER">>}, _Req, D) ->
    %% RFC 3261 8.2.1: known, not allowed here
    not_allowed(D);
auto_answer({method, _}, _Req, D) ->
    %% RFC 3261 8.2.1: a method we do not recognise
    {501, <<"Not Implemented">>, [{<<"Allow">>, ?ALLOW}], <<>>, D};
auto_answer(_Event, _Req, D) ->
    {200, <<"OK">>, [], <<>>, D}.

sdp_ok(Sdp, D) ->
    Hdrs = [{<<"Content-Type">>, <<"application/sdp">>} | contact_hdr(D)],
    {200, <<"OK">>, Hdrs, Sdp, D}.

not_acceptable(D) ->
    Warn = {<<"Warning">>, <<"399 chappe \"no local session description\"">>},
    {488, <<"Not Acceptable Here">>, [Warn], <<>>, D}.

not_allowed(D) ->
    {405, <<"Method Not Allowed">>, [{<<"Allow">>, ?ALLOW}], <<>>, D}.

%% A re-INVITE or UPDATE the dialog answered itself, as the session moved:
%% the owner gets {chappe_sip_dialog, D, hold | unhold | refresh, Req}.
%% hold and unhold follow the peer's offer (chappe_sip_sdp:on_hold/1, RFC
%% 3264 8.4); an unchanged hold state, or no offer, is a refresh.
-spec session_event(boolean(), term(), chappe_sip_req:req(), #data{}) ->
    #data{}.
session_event(true, Event, Req, #data{remote_hold = Was} = D) when
    Event =:= modify; Event =:= update
->
    Now =
        case chappe_sip_req:body(Req) of
            <<>> -> Was;
            Offer -> held(Offer)
        end,
    Ev =
        case {Was, Now} of
            {false, true} -> hold;
            {true, false} -> unhold;
            _ -> refresh
        end,
    chappe_sip_dialog_owner:notify4(D, Ev, Req),
    D#data{remote_hold = Now};
session_event(_Ok, _Event, _Req, D) ->
    D.

%% the ACK completing an INVITE whose 2xx carried our offer holds the answer
-spec handle_ack(binary(), #data{}) -> #data{}.
handle_ack(Raw, #data{ack_answer = Pending} = D) ->
    AckReq = chappe_sip_dialog_owner:parse_req(Raw, undefined, D),
    chappe_sip_dialog_owner:notify(D, ack, AckReq, undefined),
    case {Pending, chappe_sip_req:body(AckReq)} of
        {true, Answer} when Answer =/= <<>> ->
            D#data{remote_sdp = Answer, ack_answer = false};
        _ ->
            D#data{ack_answer = false}
    end.

%% RFC 3311: our UPDATE offer is answered in its 2xx
-spec update_answered(term(), 100..699, chappe_sip_msg:msg(), #data{}) ->
    #data{}.
update_answered({update, Sdp}, Status, Msg, D0) when
    Status >= 200, Status < 300
->
    D = new_target(Msg, D0),
    case chappe_sip_msg:body(Msg) of
        <<>> -> D;
        Answer -> D#data{local_sdp = Sdp, remote_sdp = Answer}
    end;
update_answered(_Kind, _Status, _Msg, D) ->
    D.

%% ---- our re-INVITE waits for the INVITE server transaction ----

%% an INVITE server transaction of this dialog not yet confirmed: an
%% incoming re-INVITE unanswered, or our 2xx to an INVITE not yet ACKed
-spec invite_server_open(#data{}) -> boolean().
invite_server_open(#data{srv_invite = {_, _}}) -> true;
invite_server_open(#data{ack_wait = Wait}) -> Wait.

%% replay a held re-INVITE once the INVITE server transaction is done
-spec held_modify(#data{}) ->
    [{next_event, {call, gen_statem:from()}, tuple()}].
held_modify(#data{modify_wait = {From, Spec, Opts}} = D) ->
    case invite_server_open(D) of
        true -> [];
        false -> [{next_event, {call, From}, {modify, Spec, Opts}}]
    end;
held_modify(_D) ->
    [].
