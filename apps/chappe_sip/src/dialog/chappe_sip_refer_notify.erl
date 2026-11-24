%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The SUBSCRIBEs and NOTIFYs of the refer package (RFC 3515 2.4.4 to
%% 2.4.7) that reach the two sides of chappe_sip_refer: in a dialog,
%% route/3 (called by chappe_sip_dialog_fsm) hands a SUBSCRIBE to the
%% subscription of a REFER accepted there and a NOTIFY to the owner of a
%% REFER sent there; outside a dialog, handle_notify/2 (called by the
%% stack's NOTIFY router) takes the NOTIFYs of a REFER sent outside one.
-module(chappe_sip_refer_notify).

-export([route/3, handle_notify/2, notify_handler/0]).

%% Answer a NOTIFY received outside any dialog when it belongs to a REFER
%% sent by send/3 outside a dialog. pass when it does not (another package,
%% or no REFER of ours): the caller answers it.
-spec handle_notify(chappe_sip_req:req(), chappe_sip_res:res()) ->
    handled | pass.
handle_notify(Req, Res) ->
    Msg = chappe_sip_req:msg(Req),
    case {refer_event(Req), chappe_sip_msg:to_tag(Msg)} of
        {{ok, IdParam}, Tag} when is_binary(Tag) ->
            case chappe_sip_refer_registry:rows(subscriber, {tag, Tag}) of
                [] -> pass;
                Rows -> deliver(match(IdParam, Rows), Req, Res)
            end;
        _ ->
            pass
    end.

%% A NOTIFY handler for chappe_sip:notify/1: REFER NOTIFYs go to their
%% owner, anything else is answered 481 (RFC 6665 4.1.3).
-spec notify_handler() ->
    fun((chappe_sip_req:req(), chappe_sip_res:res()) -> ok).
notify_handler() ->
    fun(Req, Res) ->
        case handle_notify(Req, Res) of
            handled -> ok;
            pass -> no_subscription_481(Res)
        end
    end.

%% A SUBSCRIBE or NOTIFY of the refer package in a dialog where this module
%% accepted (SUBSCRIBE) or sent (NOTIFY) a REFER: answered here, or passed
%% to the dialog's owner when the dialog never used the package.
-spec route(
    chappe_sip_dialog:dialog(), chappe_sip_req:req(), chappe_sip_res:res()
) ->
    handled | pass.
route(D, Req, Res) ->
    DPid = chappe_sip_dialog:pid(D),
    case {chappe_sip_req:method(Req), refer_event(Req)} of
        {<<"SUBSCRIBE">>, {ok, IdParam}} ->
            route_subscribe(DPid, IdParam, Req, Res);
        {<<"NOTIFY">>, {ok, IdParam}} ->
            case chappe_sip_refer_registry:count(sent, DPid) of
                0 ->
                    pass;
                _ ->
                    Rows = chappe_sip_refer_registry:rows(
                        subscriber, {dialog, DPid}
                    ),
                    deliver(match(IdParam, Rows), Req, Res)
            end;
        _ ->
            pass
    end.

%% RFC 3515 2.4.4: a SUBSCRIBE to refer that names no existing subscription
%% (a wrong id, or one that has ended) is refused 403
route_subscribe(DPid, IdParam, Req, Res) ->
    case chappe_sip_refer_registry:count(received, DPid) of
        0 ->
            pass;
        _ ->
            Rows = chappe_sip_refer_registry:rows(notifier, {dialog, DPid}),
            case [P || {_, _, _, P, #{id := I}} <- Rows, I =:= IdParam] of
                [Pid | _] ->
                    Pid ! {subscribe, Req, Res},
                    handled;
                [] ->
                    _ = chappe_sip_res:send(Res, 403, #{
                        reason => <<"Forbidden">>
                    }),
                    handled
            end
    end.

refer_event(Req) ->
    case chappe_sip_hdr:event(chappe_sip_req:get(<<"event">>, Req)) of
        {ok, #{type := <<"refer">>, id := Id}} -> {ok, Id};
        _ -> error
    end.

%% RFC 3515 2.4.6: id=<CSeq> names the REFER; no id names the first REFER
%% sent in the dialog. A REFER still waiting for its response (its CSeq
%% not known yet) takes a NOTIFY that beats the response.
match(IdParam, Rows) ->
    Pick =
        case IdParam of
            undefined ->
                [R || {_, _, _, _, #{first := true}} = R <- Rows];
            _ ->
                [
                    R
                 || {_, _, _, _, #{cseq := C}} = R <- Rows, same_seq(C, IdParam)
                ] ++
                    [R || {_, _, _, _, #{cseq := C}} = R <- Rows, C =:= pending]
        end,
    case {Pick, Rows} of
        {[Row | _], _} -> {ok, Row};
        {[], [{_, _, {tag, _}, _, _} = Row]} -> {ok, Row};
        _ -> error
    end.

same_seq(any, _IdParam) -> true;
same_seq(C, IdParam) when is_integer(C) -> integer_to_binary(C) =:= IdParam;
same_seq(_, _) -> false.

%% answer the NOTIFY and tell the owner what the referenced request did
deliver(error, _Req, Res) ->
    no_subscription_481(Res),
    handled;
deliver({ok, {Id, _, _, Owner, _}}, Req, Res) ->
    case chappe_sip_sipfrag:parse(chappe_sip_req:body(Req)) of
        {ok, #{status := Status}} ->
            _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
            case terminated(Req) of
                true ->
                    ok = chappe_sip_refer_registry:delete(Id),
                    Owner ! {refer_done, Id, Status};
                false ->
                    Owner ! {refer_progress, Id, Status}
            end,
            handled;
        _ ->
            %% RFC 3515 2.4.5: every NOTIFY starts with a status line
            _ = chappe_sip_res:send(Res, 400, #{reason => <<"Bad Request">>}),
            handled
    end.

terminated(Req) ->
    case
        chappe_sip_hdr:subscription_state(
            chappe_sip_req:get(<<"subscription-state">>, Req)
        )
    of
        {ok, #{state := terminated}} -> true;
        _ -> false
    end.

no_subscription_481(Res) ->
    _ = chappe_sip_res:send(Res, 481, #{
        reason => <<"Subscription Does Not Exist">>
    }),
    ok.
