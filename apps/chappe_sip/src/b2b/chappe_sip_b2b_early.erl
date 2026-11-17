%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc UPDATE in the early dialogs of a B2BUA call (RFC 3311 5.1).
%%
%% While B rings, A and B each have an early dialog with us: A's is formed
%% by the provisionals we relay under A's To tag, B's by B's provisionals.
%% An UPDATE in either goes to the other early dialog, and its answer (or
%% failure) comes back, through the call's SDP path (chappe_sip_b2b_media).
%% A's early dialog has no dialog fsm before the 2xx, so its requests come
%% on the early leg (chappe_sip_engine:early_leg/2), the UPDATE to A is
%% built here, and the CSeq numbers used carry over to A's dialog once it
%% is created. One UPDATE at a time: a second while one is pending gets
%% 500 with Retry-After (RFC 3311 5.2). An offer in a PRACK is not carried
%% (chappe_sip_b2b answers it 488).
-module(chappe_sip_b2b_early).

-export([leg/1, a_request/3, b_update/3, result/3, a_response/4]).

%% The early leg of A, once the first provisional went out under A's tag.
%% A WebSocket caller keeps the earlier behaviour (no early leg).
-spec leg(map()) -> map().
leg(#{aleg := _} = W) ->
    W;
leg(#{req := Req, atag := ATag} = W) ->
    case chappe_sip_ws:is_ws(chappe_sip_req:txn(Req)) of
        true ->
            W#{aleg => none};
        false ->
            case chappe_sip_engine:early_leg(Req, ATag) of
                {ok, LegH} -> W#{aleg => LegH, acseq => 0};
                {error, _} -> W#{aleg => none}
            end
    end.

%% A request in A's early dialog.
-spec a_request(non_neg_integer(), binary(), map()) -> map().
a_request(TxnH, Raw, W) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case {chappe_sip_msg:method(Msg), chappe_sip_msg:body(Msg)} of
        {<<"UPDATE">>, <<>>} ->
            respond_a(TxnH, 200, <<"OK">>, <<>>),
            W;
        {<<"UPDATE">>, _} when map_get(early_up, W) =/= undefined ->
            retry_a(TxnH),
            W;
        {<<"UPDATE">>, _} when map_get(bearly, W) =:= undefined ->
            retry_a(TxnH),
            W;
        {<<"UPDATE">>, Offer} ->
            relay_to_b(TxnH, Offer, W);
        {<<"ACK">>, _} ->
            W;
        _ ->
            %% the early dialog takes nothing else from A
            _ = chappe_sip_engine:dialog_respond(
                TxnH,
                481,
                <<"Call/Transaction Does Not Exist">>,
                <<>>,
                <<>>,
                <<>>
            ),
            W
    end.

relay_to_b(TxnH, Offer, #{media := M, bearly := BEarly} = W) ->
    case chappe_sip_b2b_media:offer(a, Offer, M) of
        {ok, Sdp, M1} ->
            Parent = self(),
            Ref = make_ref(),
            _ = spawn(fun() ->
                Parent ! {chappe_sip_b2b_early, Ref, update(BEarly, Sdp)}
            end),
            W#{media := M1, early_up := #{ref => Ref, a_txn => TxnH}};
        {reject, Code} ->
            respond_a(TxnH, Code, <<>>, <<>>),
            W
    end.

update(Dialog, Sdp) ->
    try
        chappe_sip_dialog:request(Dialog, #{
            method => <<"UPDATE">>,
            content_type => <<"application/sdp">>,
            body => Sdp
        })
    catch
        exit:Why -> {error, Why}
    end.

%% B answered the UPDATE we relayed from A.
-spec result(reference(), term(), map()) -> map().
result(Ref, Result, #{early_up := #{ref := Ref, a_txn := TxnH}} = W0) ->
    W = W0#{early_up := undefined},
    case Result of
        {ok, Msg} ->
            case chappe_sip_msg:status(Msg) of
                St when St >= 200, St < 300 ->
                    answered_by_b(TxnH, chappe_sip_msg:body(Msg), W);
                St ->
                    respond_a(TxnH, St, <<>>, <<>>),
                    restore(b, W)
            end;
        _ ->
            respond_a(TxnH, 500, <<"Server Internal Error">>, <<>>),
            restore(b, W)
    end;
result(_Ref, _Result, W) ->
    W.

answered_by_b(TxnH, Answer, #{media := M} = W) ->
    case chappe_sip_b2b_media:answer(b, Answer, M) of
        {ok, Out, M1} ->
            respond_a(TxnH, 200, <<"OK">>, Out),
            W#{media := M1};
        {reject, Code} ->
            respond_a(TxnH, Code, <<>>, <<>>),
            W
    end.

%% An UPDATE in B's early dialog, for A.
-spec b_update(chappe_sip_req:req(), chappe_sip_res:res(), map()) -> map().
b_update(Req, Res, W) ->
    case {chappe_sip_req:body(Req), maps:get(aleg, W, none)} of
        {<<>>, _} ->
            _ = chappe_sip_res:send(Res, 200, #{reason => <<"OK">>}),
            W;
        {_, none} ->
            retry(Res),
            W;
        {_, _} when map_get(early_up, W) =/= undefined ->
            retry(Res),
            W;
        {Offer, _} ->
            relay_to_a(Offer, Res, W)
    end.

relay_to_a(Offer, Res, #{media := M} = W) ->
    case chappe_sip_b2b_media:offer(b, Offer, M) of
        {ok, Sdp, M1} ->
            send_to_a(Sdp, Res, W#{media := M1});
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            W
    end.

send_to_a(Sdp, Res, #{req := Req, atag := ATag, acseq := N} = W) ->
    Msg = chappe_sip_req:msg(Req),
    Dlg = #{
        remote_target => chappe_sip_hdr:name_addr_uri(
            chappe_sip_msg:get(<<"contact">>, Msg)
        ),
        local_addr => <<
            (chappe_sip_msg:get(<<"to">>, Msg))/binary, ";tag=", ATag/binary
        >>,
        remote_addr => chappe_sip_msg:get(<<"from">>, Msg),
        call_id => chappe_sip_msg:call_id(Msg),
        route_set => chappe_sip_msg:get_all(<<"record-route">>, Msg),
        local_contact => contact(),
        cseq => N + 1
    },
    {Raw, Route} = chappe_sip_dialog_fsm:indialog_request(
        Dlg, <<"UPDATE">>, [{<<"Content-Type">>, <<"application/sdp">>}], Sdp
    ),
    case chappe_sip_engine:send_request(Route, Raw, self()) of
        {ok, TxnH} ->
            W#{acseq := N + 1, early_up := #{txn => TxnH, res => Res}};
        {error, _} ->
            _ = chappe_sip_res:send(Res, 500, #{}),
            W#{acseq := N + 1}
    end.

%% A's response to the UPDATE we sent it for B.
-spec a_response(non_neg_integer(), 100..699, binary(), map()) -> map().
a_response(TxnH, St, _Raw, #{early_up := #{txn := TxnH}} = W) when St < 200 ->
    W;
a_response(TxnH, St, Raw, #{early_up := #{txn := TxnH, res := Res}} = W0) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    W = W0#{early_up := undefined},
    case St >= 200 andalso St < 300 of
        true ->
            {ok, Msg} = chappe_sip_msg:parse(Raw),
            answered_by_a(chappe_sip_msg:body(Msg), Res, W);
        false ->
            _ = chappe_sip_res:send(Res, St, #{}),
            restore(a, W)
    end;
a_response(_TxnH, _St, _Raw, W) ->
    W.

answered_by_a(Answer, Res, #{media := M} = W) ->
    case chappe_sip_b2b_media:answer(a, Answer, M) of
        {ok, Out, M1} ->
            _ = chappe_sip_res:send(Res, 200, sdp_reply(Out)),
            W#{media := M1};
        {reject, Code} ->
            _ = chappe_sip_res:send(Res, Code, #{}),
            W
    end.

%% the refusing leg's last SDP back into rtpengine (chappe_sip_b2b_media)
restore(a, #{media := M, req := Req} = W) ->
    W#{media := chappe_sip_b2b_media:rejected(a, chappe_sip_req:body(Req), M)};
restore(b, #{media := M, b_sdp := Sdp} = W) ->
    W#{media := chappe_sip_b2b_media:rejected(b, Sdp, M)}.

respond_a(TxnH, St, Reason, Body) ->
    Hdrs =
        [{<<"Content-Type">>, <<"application/sdp">>} || Body =/= <<>>] ++
            [{<<"Contact">>, contact()} || St >= 200, St < 300],
    _ = chappe_sip_engine:dialog_respond(
        TxnH, St, Reason, chappe_sip_hdr_io:join(Hdrs), Body, <<>>
    ),
    ok.

retry_a(TxnH) ->
    RA = integer_to_binary(rand:uniform(11) - 1),
    _ = chappe_sip_engine:dialog_respond(
        TxnH,
        500,
        <<"Server Internal Error">>,
        chappe_sip_hdr_io:join([{<<"Retry-After">>, RA}]),
        <<>>,
        <<>>
    ),
    ok.

retry(Res) ->
    RA = integer_to_binary(rand:uniform(11) - 1),
    _ = chappe_sip_res:send(Res, 500, #{
        reason => <<"Server Internal Error">>,
        headers => [{<<"Retry-After">>, RA}]
    }),
    ok.

sdp_reply(Sdp) ->
    #{
        reason => <<"OK">>,
        headers => [{<<"Content-Type">>, <<"application/sdp">>}],
        body => Sdp
    }.

contact() ->
    chappe_sip_b2b:contact().
