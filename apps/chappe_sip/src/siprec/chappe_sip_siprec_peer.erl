%% What the recording server (SRS) sends in a recording's dialog, for
%% chappe_sip_siprec: a snapshot request in an UPDATE (RFC 7866 9.2), a
%% re-INVITE (7.2), its BYE, and anything else, refused.
%%
%% The dialog and the UAC are two senders, so the SRS's first in-dialog
%% request (a re-INVITE, its ACK) can reach the recording before the UAC
%% tells it the dialog. Such events are held in the recording's state
%% (early) and replayed in order once the dialog is known (replay/1).
-module(chappe_sip_siprec_peer).

-export([handle/2, replay/1]).
-export_type([result/0]).

%% one message long in practice, so the bound is small: past it a request
%% is refused with 491 (RFC 3261 14.2, try again later), the rest dropped
-define(MAX_EARLY, 8).

-type result() ::
    {noreply, map()} | {snapshot, binary()} | bye.

-spec handle(tuple(), map()) -> result().
handle(Msg, #{state := inviting, dialog := undefined} = St) ->
    hold(Msg, St);
handle({chappe_sip_dialog, D, update, Req, Res}, #{dialog := D} = St) ->
    update(Req, Res, St);
handle({chappe_sip_dialog, D, modify, Req, Res}, #{dialog := D} = St) ->
    reinvite(Req, Res, St);
handle({chappe_sip_dialog, D, destroy, _}, #{dialog := D}) ->
    bye;
handle({chappe_sip_dialog, _D, _Ev, _}, St) ->
    {noreply, St};
%% an ACK carries no response to send
handle({chappe_sip_dialog, _D, _Ev, _Req, undefined}, St) ->
    {noreply, St};
handle({chappe_sip_dialog, _D, _Ev, _Req, Res}, St) ->
    _ = chappe_sip_res:send(Res, 405),
    {noreply, St}.

%% the held events, handled in the order they came
-spec replay([tuple()]) -> ok.
replay(Early) ->
    lists:foreach(fun(M) -> self() ! M end, lists:reverse(Early)).

hold(Msg, #{early := Early} = St) when length(Early) < ?MAX_EARLY ->
    {noreply, St#{early := [Msg | Early]}};
hold({chappe_sip_dialog, _D, _Ev, _Req, Res}, St) when Res =/= undefined ->
    _ = chappe_sip_res:send(Res, 491),
    {noreply, St};
hold(_Msg, St) ->
    {noreply, St}.

%% RFC 7866 9.2: an UPDATE with a snapshot request is answered 200, and
%% the recording sends the snapshot
update(Req, Res, St) ->
    Body = chappe_sip_req:body(Req),
    case
        chappe_sip_siprec_meta:snapshot_request(
            chappe_sip_req:get(<<"content-type">>, Req), Body
        )
    of
        {ok, Reason} ->
            _ = chappe_sip_res:send(Res, 200),
            {snapshot, Reason};
        no when Body =:= <<>> ->
            _ = chappe_sip_res:send(Res, 200),
            {noreply, St};
        no ->
            %% an offer from the SRS: the recorded streams stay as they are
            _ = chappe_sip_res:send(Res, 488),
            {noreply, St}
    end.

%% A re-INVITE of the SRS (RFC 7866 7.2: ready to record now, or a stream
%% it no longer takes): the recorded streams are answered as they are,
%% sendonly or, paused, inactive, and an m-line past them is refused with
%% port 0, so the answer has as many as the offer (RFC 3264 6); an offer
%% with fewer than the session has removed a stream (8) and gets 488. Its
%% offer reaches rtpengine.
reinvite(Req, Res, St) ->
    Offer = chappe_sip_req:body(Req),
    case Offer =/= <<>> andalso chappe_sip_siprec_body:reanswer(Offer, St) of
        {ok, Answer} ->
            _ = chappe_sip_res:send(Res, 200, #{
                body => Answer,
                headers => [{<<"Content-Type">>, <<"application/sdp">>}]
            }),
            _ = chappe_sip_siprec_tap:answer(Offer, St),
            {noreply, St};
        _ ->
            _ = chappe_sip_res:send(Res, 488),
            {noreply, St}
    end.
