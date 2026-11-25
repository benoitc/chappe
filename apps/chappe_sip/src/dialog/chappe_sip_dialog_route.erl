%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The peer's in-dialog requests in a dialog fsm, in the order they
%% are checked: the CSeq (RFC 3261 12.2.2), Require (8.2.2.3), the
%% REFER subscription's requests (to chappe_sip_refer), BYE, a refreshing
%% SUBSCRIBE, request overlap (14, RFC 3311 5.2), the session interval
%% (RFC 4028 9), then the owner, which claims the request, or the dialog's
%% own answer.
%%
%% Runs in the chappe_sip_dialog_fsm process, on its #data{}.
-module(chappe_sip_dialog_route).

-export([handle_indialog/4]).
-ifdef(TEST).
-export([in_order/2, require_check/3]).
-endif.

-include("chappe_sip_dialog_fsm.hrl").

-spec handle_indialog(non_neg_integer(), map(), binary(), #data{}) ->
    gen_statem:event_handler_result(atom()).
handle_indialog(TxnH, _Meta, Raw, D) ->
    Req = chappe_sip_dialog_owner:parse_req(Raw, TxnH, D),
    case in_order(Req, D) of
        {ok, D1} ->
            require_check(TxnH, Req, D1);
        out_of_order ->
            %% RFC 3261 12.2.2: an in-dialog request with a CSeq lower than the
            %% highest seen is out of order and is rejected 500
            _ = chappe_sip_dialog_out:respond(
                TxnH, 500, <<"Server Internal Error">>
            ),
            {keep_state, D}
    end.

%% track the remote CSeq; a strictly lower number than the highest seen is out
%% of order (retransmits are absorbed at the transaction layer, so an equal
%% number reaching here is fine)
-spec in_order(chappe_sip_req:req(), #data{}) -> {ok, #data{}} | out_of_order.
in_order(Req, #data{remote_cseq = Prev} = D) ->
    case req_cseq(Req) of
        undefined -> {ok, D};
        N when N >= Prev -> {ok, D#data{remote_cseq = N}};
        _ -> out_of_order
    end.

req_cseq(Req) ->
    case chappe_sip_msg:cseq(chappe_sip_req:msg(Req)) of
        {ok, #{seq := N}} -> N;
        _ -> undefined
    end.

%% RFC 3261 8.2.2.3: an in-dialog request listing an option tag we do not
%% support in Require gets 420 with Unsupported. ACK and CANCEL never reach
%% here (and must be exempt).
-spec require_check(non_neg_integer(), chappe_sip_req:req(), #data{}) ->
    gen_statem:event_handler_result(atom()).
require_check(TxnH, Req, D) ->
    Supported = [
        chappe_sip_lib:lower(T)
     || T <- chappe_sip_config:get(supported_option_tags) ++ D#data.option_tags
    ],
    Msg = chappe_sip_req:msg(Req),
    case
        [
            T
         || T <- chappe_sip_msg:option_tags(<<"require">>, Msg),
            not lists:member(T, Supported)
        ]
    of
        [] ->
            route_indialog(TxnH, Req, D);
        Bad ->
            Hdrs = [
                {<<"Unsupported">>, iolist_to_binary(lists:join(<<", ">>, Bad))}
            ],
            _ = chappe_sip_dialog_out:respond(
                TxnH, 420, <<"Bad Extension">>, Hdrs
            ),
            {keep_state, D}
    end.

%% In an INVITE dialog, the SUBSCRIBEs and NOTIFYs of a REFER's implicit
%% subscription (RFC 3515) belong to chappe_sip_refer once it has handled a
%% REFER here; anything else goes on to the owner as before.
route_indialog(TxnH, Req, #data{sub = undefined} = D) ->
    Method = chappe_sip_req:method(Req),
    Routed =
        (Method =:= <<"SUBSCRIBE">> orelse Method =:= <<"NOTIFY">>) andalso
            chappe_sip_refer_notify:route(
                chappe_sip_dialog_owner:dialog(D),
                Req,
                %% neither method refreshes the session: its timer stays
                chappe_sip_res:new(
                    TxnH, chappe_sip_dialog_out:dialog_sender([], keep)
                )
            ),
    case Routed of
        handled -> {keep_state, D};
        _ -> by_method(chappe_sip_req:method(Req), TxnH, Req, D)
    end;
route_indialog(TxnH, Req, D) ->
    by_method(chappe_sip_req:method(Req), TxnH, Req, D).

by_method(<<"BYE">>, TxnH, Req, D) ->
    byed(TxnH, Req, D);
by_method(<<"SUBSCRIBE">>, TxnH, Req, #data{sub = Sub} = D) when
    Sub =/= undefined
->
    chappe_sip_dialog_sub:handle_refresh(TxnH, Req, D);
by_method(Method, TxnH, Req, D) ->
    case chappe_sip_dialog_offer:overlap(Method, chappe_sip_req:body(Req), D) of
        ok ->
            session_check(TxnH, Method, Req, D);
        {Status, Reason, Hdrs} ->
            _ = chappe_sip_dialog_out:respond(TxnH, Status, Reason, Hdrs),
            {keep_state, D}
    end.

%% RFC 3261 15.1.2: the requests still pending in the dialog get a 487
%% before the BYE its 200
byed(TxnH, Req, D) ->
    _ = [
        chappe_sip_dialog_out:respond(Pending, 487, <<"Request Terminated">>)
     || {Pending, _} <- [D#data.srv_invite, D#data.srv_update]
    ],
    %% and so does the INVITE of an early dialog of ours (the caller's BYE
    %% ends the early dialog, RFC 3261 15)
    _ = early_invite_terminated(D),
    early_byed(D),
    _ = chappe_sip_dialog_out:respond(TxnH, 200, <<"OK">>),
    chappe_sip_dialog_owner:notify_terminal_req(D, Req),
    {stop, normal, D}.

early_invite_terminated(#data{role = uas, index_state = early, txn = Txn}) when
    Txn =/= undefined
->
    chappe_sip_dialog_out:respond(Txn, 487, <<"Request Terminated">>);
early_invite_terminated(_D) ->
    ok.

%% the callee's BYE ended an early dialog of our INVITE: the INVITE still
%% completes with its final response, which no longer confirms this dialog
early_byed(#data{uac = Uac, remote_addr = RA}) when Uac =/= undefined ->
    Uac ! {chappe_sip_early_byed, chappe_sip_dialog_owner:addr_tag(RA)},
    ok;
early_byed(_D) ->
    ok.

%% RFC 4028 9: an INVITE or UPDATE refreshes the session; one below our
%% minimum interval gets 422
session_check(TxnH, Method, Req, D) ->
    case chappe_sip_dialog_st:st_incoming(Method, Req, D) of
        {ok, StHdrs, St} ->
            dispatch_indialog(TxnH, Method, Req, {StHdrs, St}, D);
        {reject, Min} ->
            Hdrs = [{<<"Min-SE">>, integer_to_binary(Min)}],
            _ = chappe_sip_dialog_out:respond(
                TxnH, 422, <<"Session Interval Too Small">>, Hdrs
            ),
            {keep_state, D}
    end.

%% StHdrs go on the 2xx; St is the session timer once the 2xx is sent (only
%% a 2xx refreshes the session, so an owner's sender reports it)
dispatch_indialog(TxnH, Method, Req, Timer, D0) ->
    Event = method_event(Method),
    D =
        case chappe_sip_dialog_offer:refresh_target(Method, Req) of
            undefined -> D0;
            Uri -> D0#data{refresh = (D0#data.refresh)#{TxnH => Uri}}
        end,
    case claimed(Event, D) of
        true -> claim(TxnH, Method, Event, Req, Timer, D);
        false -> auto_answer(TxnH, Method, Event, Req, Timer, D)
    end.

%% RFC 3261 12.2.2, RFC 3311 5.1: the 2xx to a target refresh carries our
%% Contact, the one of the dialog's other messages
claim(TxnH, Method, Event, Req, {StHdrs, St}, D) ->
    Hdrs = StHdrs ++ chappe_sip_dialog_offer:refresh_contact(Method, D),
    Res = chappe_sip_res:new(
        TxnH, chappe_sip_dialog_out:dialog_sender(Hdrs, St)
    ),
    chappe_sip_dialog_owner:notify(D, Event, Req, Res),
    {keep_state, chappe_sip_dialog_offer:track_claimed(Method, TxnH, Req, D)}.

auto_answer(TxnH, Method, Event, Req, {StHdrs, St}, D0) ->
    {Status, Reason, Hdrs0, Body, D1} = chappe_sip_dialog_offer:auto_answer(
        Event, Req, D0
    ),
    Ok = Status >= 200 andalso Status < 300,
    Hdrs = Hdrs0 ++ [H || Ok, H <- StHdrs],
    _ = chappe_sip_dialog_out:respond(TxnH, Status, Reason, Hdrs, Body),
    D2 = chappe_sip_dialog_offer:refreshed(TxnH, Status, D1),
    %% our 2xx to a re-INVITE waits for its ACK (RFC 3261 14.1)
    D3 =
        case Method of
            <<"INVITE">> -> D2#data{ack_wait = Ok};
            _ -> D2
        end,
    chappe_sip_dialog_owner:notify4(D3, {auto_answered, Event}, Req),
    D = chappe_sip_dialog_offer:session_event(Ok, Event, Req, D3),
    case Ok of
        true -> chappe_sip_dialog_st:st_apply(St, D);
        false -> {keep_state, D}
    end.

claimed(_Event, #data{handled = all}) ->
    true;
claimed(Event, #data{handled = List}) when is_list(List) ->
    lists:member(Event, List).

method_event(<<"INFO">>) -> info;
method_event(<<"NOTIFY">>) -> notify;
method_event(<<"UPDATE">>) -> update;
method_event(<<"OPTIONS">>) -> options;
method_event(<<"REFER">>) -> refer;
method_event(<<"MESSAGE">>) -> message;
method_event(<<"INVITE">>) -> modify;
method_event(<<"SUBSCRIBE">>) -> subscribe;
method_event(<<"PUBLISH">>) -> publish;
method_event(Other) -> {method, Other}.
