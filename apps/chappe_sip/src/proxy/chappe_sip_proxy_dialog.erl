%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc In-dialog forwarding of a record-routing proxy.
%%
%% A request that comes back through our Record-Route (a BYE, a re-INVITE,
%% a 2xx ACK) is forwarded to the far end by its next Route, its
%% Request-URI, or the WS leg its flow tokens name, and the responses are
%% relayed back. A CANCEL of a transit re-INVITE goes to its branch, and
%% Timer C bounds an INVITE that rings. When media anchoring pinned the
%% call, the SDP of re-INVITE offers and their answers goes through it.
-module(chappe_sip_proxy_dialog).

-export([forward_indialog/2, forward_indialog_ack/2]).
-export([anchor_request/2, answer_sdp/3]).

%% ---- in-dialog forwarding (record-route) ----

%% Forward one in-dialog transit request (BYE, re-INVITE, INFO, ...) that a
%% record-routing proxy received on its default leg, and relay the responses
%% back upstream. Runs as the request worker's handler, so it marks Res final
%% to keep the worker's exit from sending a spurious 500. A strict router
%% upstream may have put our Record-Route in the Request-URI (16.4).
-spec forward_indialog(chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
forward_indialog(Req, Res) ->
    ServerTxn = chappe_sip_req:txn(Req),
    Msg0 = chappe_sip_req:msg(Req),
    Edge = chappe_sip_flow:edge_flow(Msg0),
    {NextHop, Flows, Msg1a} = pop_route(Msg0),
    Msg1 = edge_record_route(Edge, Msg0, Msg1a),
    Arrived = chappe_sip_flow:arrival_flow(chappe_sip_req:meta(Req)),
    Route = indialog_route(Arrived, NextHop, Flows),
    IsInvite = chappe_sip_msg:method(Msg1) =:= <<"INVITE">>,
    IsInvite andalso chappe_sip_engine:mark_proxied(ServerTxn),
    %% the BYE of a call we record-routed ends its call record
    _ =
        chappe_sip_msg:method(Msg1) =:= <<"BYE">> andalso
            chappe_sip_cdr:proxy_bye(chappe_sip_msg:call_id(Msg1)),
    %% Anchor is `none' unless media is configured and this call is pinned, so a
    %% plain proxy (or an unanchored call) runs the original path untouched.
    Anchor = indialog_anchor(Msg1),
    Msg1b = indialog_offer(Anchor, Msg1),
    case chappe_sip_msg:decr_max_forwards(Msg1b) of
        {ok, Msg2} ->
            Raw = iolist_to_binary(chappe_sip_msg:encode(Msg2)),
            case chappe_sip_engine:send_request(Route, Raw, self()) of
                {ok, OutTxn} ->
                    TimerC = chappe_sip_config:get(timer_c_ms),
                    relay_indialog(#{
                        server => ServerTxn,
                        out => OutTxn,
                        timer_c => TimerC,
                        deadline => erlang:monotonic_time(millisecond) + TimerC,
                        anchor => Anchor,
                        cancelled => false,
                        edge => Edge
                    }),
                    indialog_release(Anchor, Msg1);
                {error, Reason} ->
                    logger:warning(
                        "chappe_sip_proxy: in-dialog forward failed: ~p",
                        [Reason]
                    ),
                    _ = forward_failed(ServerTxn, Edge, Reason)
            end;
        {error, loop_detected} ->
            _ = respond(ServerTxn, 483, <<"Too Many Hops">>)
    end,
    chappe_sip_res:mark_final(Res),
    ok.

relay_indialog(#{server := ServerTxn, out := OutTxn} = R) ->
    receive
        {chappe_sip_response, OutTxn, #{status := Status}, Raw} ->
            case lost_flow(Status, maps:get(edge, R, none)) of
                {lost, Flow} ->
                    ok = chappe_sip_registry:remove_flow(Flow),
                    _ = respond(ServerTxn, 430, <<"Flow Failed">>),
                    chappe_sip_engine:finish_txn(OutTxn);
                live ->
                    relay_response(R, Status, Raw)
            end;
        {chappe_sip_cancel, ServerTxn, _CancelReq} ->
            %% 16.10: a CANCEL for a transit re-INVITE goes to its branch;
            %% the downstream 487 comes back through the loop above
            _ =
                case maps:get(cancelled, R) of
                    false -> chappe_sip_engine:cancel_txn(OutTxn);
                    true -> ok
                end,
            relay_indialog(R#{cancelled := true});
        {chappe_sip_op, OutTxn, {error, Reason}} ->
            logger:warning("chappe_sip_proxy: in-dialog branch error: ~p", [
                Reason
            ]),
            _ = forward_failed(ServerTxn, maps:get(edge, R, none), Reason),
            chappe_sip_engine:finish_txn(OutTxn);
        {chappe_sip_op, OutTxn, ok} ->
            relay_indialog(R)
    after remaining(maps:get(deadline, R)) ->
        _ = chappe_sip_engine:cancel_txn(OutTxn),
        _ = respond(ServerTxn, 408, <<"Request Timeout">>),
        chappe_sip_engine:finish_txn(OutTxn)
    end.

relay_response(
    #{server := ServerTxn, out := OutTxn, anchor := Anchor} = R, Status, Raw
) ->
    Raw2 = indialog_answer(Anchor, Status, Raw),
    _ = relay(ServerTxn, Status, chappe_sip_route:strip_via(Raw2)),
    case Status of
        _ when Status >= 200 ->
            chappe_sip_engine:finish_txn(OutTxn);
        100 ->
            relay_indialog(R);
        _ ->
            %% Timer C restarts on each provisional (16.7 step 2)
            relay_indialog(R#{
                deadline :=
                    erlang:monotonic_time(millisecond) + maps:get(timer_c, R)
            })
    end.

%% A 503 on an edge forward over a connection that closed is the stack's
%% own transport failure, not the UA's answer (the connection went as the
%% request left): the flow is lost. Any other answer is the UA's.
lost_flow(503, {ok, {conn, Id} = Flow, _Transport}) ->
    case chappe_sip_engine_conns:conn_closed(Id) of
        true -> {lost, Flow};
        false -> live
    end;
lost_flow(_Status, _Edge) ->
    live.

%% RFC 5626 5.3: the flow an edge route names no longer exists. The UA is
%% unreachable until it registers again: 430 Flow Failed, and its bindings
%% on that flow go (chappe_sip_registry retries the removal while the
%% region has no quorum). Any other failure (the engine or the WS
%% transport busy, a full transaction table) says nothing of the flow: a
%% 500, and the binding stays.
forward_failed(ServerTxn, {ok, Flow, _Transport}, Reason) ->
    case flow_gone(Reason) of
        true ->
            ok = chappe_sip_registry:remove_flow(Flow),
            respond(ServerTxn, 430, <<"Flow Failed">>);
        false ->
            respond(ServerTxn, 500, <<"Server Internal Error">>)
    end;
forward_failed(ServerTxn, none, _Reason) ->
    respond(ServerTxn, 500, <<"Server Internal Error">>).

%% the native stack has no such connection, or the WS transport no such
%% flow
flow_gone(<<"unknown flow">>) -> true;
flow_gone(no_flow) -> true;
flow_gone(_) -> false.

remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% ---- in-dialog media anchor (engine-driven path, gated on the pin) ----

%% The in-dialog transit path has no app option, so it self-determines: anchor
%% only when media is configured and this Call-ID is already pinned. `none'
%% otherwise, so the original path is unchanged.
indialog_anchor(Msg) ->
    case chappe_sip_media:anchor_active() of
        false ->
            none;
        true ->
            CallId = chappe_sip_msg:call_id(Msg),
            case chappe_sip_media:anchor_pinned(CallId) of
                true ->
                    #{
                        call_id => CallId,
                        from_tag => chappe_sip_msg:from_tag(Msg)
                    };
                false ->
                    none
            end
    end.

%% Re-anchor the offer on an in-dialog re-INVITE/UPDATE (best effort).
indialog_offer(none, Msg) ->
    Msg;
indialog_offer(Id, Msg) ->
    case has_sdp(Msg) of
        false ->
            Msg;
        true ->
            case
                chappe_sip_media:anchor_offer(Id, chappe_sip_msg:body(Msg), #{})
            of
                {ok, Sdp} ->
                    chappe_sip_msg:set_body(Sdp, Msg);
                {error, Reason} ->
                    logger:warning(
                        "chappe_sip_proxy: in-dialog offer failed: ~p",
                        [Reason]
                    ),
                    Msg
            end
    end.

indialog_answer(none, _Status, Raw) ->
    Raw;
indialog_answer(_Id, Status, Raw) when Status >= 100, Status < 300 ->
    rewrite_answer(#{}, Raw);
indialog_answer(_Id, _Status, Raw) ->
    Raw.

%% Release the rtpengine call when the dialog ends (BYE).
indialog_release(none, _Msg) ->
    ok;
indialog_release(Id, Msg) ->
    case chappe_sip_msg:method(Msg) of
        <<"BYE">> -> chappe_sip_media:anchor_release(Id);
        _ -> ok
    end.

%% Forward a 2xx ACK (no server transaction, no response) statelessly to the
%% next hop. Runs in a transient process spawned by chappe_sip_engine. ArrivedVia
%% is udp' or {ws, Flow}' - the transport the ACK came in on.
-spec forward_indialog_ack(binary(), udp | {ws, integer()}) -> ok.
forward_indialog_ack(Raw, ArrivedVia) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            {NextHop, Flows, Msg1} = pop_route(Msg),
            Arrived =
                case ArrivedVia of
                    {ws, Flow} -> Flow;
                    udp -> undefined
                end,
            Route = indialog_route(Arrived, NextHop, Flows),
            case chappe_sip_msg:decr_max_forwards(Msg1) of
                {ok, Msg2} ->
                    Out = iolist_to_binary(chappe_sip_msg:encode(Msg2)),
                    send_ack(Route, Out);
                {error, _} ->
                    ok
            end;
        {error, _} ->
            ok
    end.

%% Our route off the request: behind a strict router the Request-URI holds
%% it (16.4), else the top Route does.
pop_route(Msg) ->
    case chappe_sip_route:recover_strict(Msg) of
        {ok, Next, Flows, Msg1} -> {Next, Flows, Msg1};
        no -> chappe_sip_route:pop_self(Msg)
    end.

%% Direction of an in-dialog forward: from one WS leg to the other WS leg,
%% or by the next hop (the next Route, else the Request-URI) when the other
%% leg is not WS; from a non-WS transport to the WS leg the tokens name.
indialog_route(Arrived, NextHop, Flows) ->
    case chappe_sip_route:next_flow(Arrived, Flows) of
        next_hop -> NextHop;
        Route -> Route
    end.

%% RFC 5626 5.3: a new dialog-forming request that came through an edge
%% route (another node of the cluster sends to a binding this node holds)
%% is record-routed here, so the dialog's requests come back over the
%% flow. Two routes (RFC 5658): the one the far side uses names the flow,
%% the one the registered UA uses (over its own transport) names none, so
%% each direction is told by the route it arrives on.
edge_record_route({ok, Flow, Transport}, Msg0, Msg) ->
    case
        chappe_sip_msg:to_tag(Msg) =:= undefined andalso
            dialog_forming(chappe_sip_msg:method(Msg))
    of
        true ->
            [Top | _] = chappe_sip_route:routes(Msg0),
            Us = chappe_sip_hdr:name_addr_uri(Top),
            CallId = chappe_sip_msg:call_id(Msg),
            Far = chappe_sip_route:record_route(
                Us, {undefined, Flow}, CallId
            ),
            Near = chappe_sip_route:record_route(
                ua_side(Us, Transport),
                undefined,
                CallId,
                ua_transport(Transport)
            ),
            chappe_sip_msg:prepend(
                <<"Record-Route">>,
                Near,
                chappe_sip_msg:prepend(<<"Record-Route">>, Far, Msg)
            );
        false ->
            Msg
    end;
edge_record_route(none, _Msg0, Msg) ->
    Msg.

dialog_forming(<<"INVITE">>) -> true;
dialog_forming(<<"SUBSCRIBE">>) -> true;
dialog_forming(<<"REFER">>) -> true;
dialog_forming(_) -> false.

%% the address the registered UA reaches us at: our TLS contact for a TLS
%% flow, else the edge route's own host and port
ua_side(Us, <<"tls">>) ->
    case chappe_sip_binds:contact_or_primary(undefined, true) of
        Tls when is_binary(Tls) -> Tls;
        _ -> Us
    end;
ua_side(Us, _Transport) ->
    Us.

ua_transport(<<"tcp">>) -> #{transport => <<"tcp">>};
ua_transport(<<"ws">>) -> #{transport => <<"ws">>};
ua_transport(<<"wss">>) -> #{transport => <<"wss">>};
ua_transport(_) -> #{}.

send_ack(NextHop, Raw) ->
    try chappe_sip_engine:send_stateless(NextHop, Raw, self()) of
        {ok, ws_ack} ->
            % WS send is synchronous, no op event
            ok;
        {ok, OpH} ->
            receive
                {chappe_sip_op, OpH, _} -> ok
            after 5000 -> ok
            end,
            %% drop the stateless-send handle so it does not accumulate
            chappe_sip_engine:finish_txn(OpH);
        {error, Reason} ->
            logger:warning("chappe_sip_proxy: ACK forward failed: ~p", [Reason])
    catch
        _:_ -> ok
    end.

rewrite_answer(Params, Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} ->
            case has_sdp(M) andalso chappe_sip_msg:to_tag(M) of
                ToTag when is_binary(ToTag) ->
                    Id = #{
                        call_id => chappe_sip_msg:call_id(M),
                        from_tag => chappe_sip_msg:from_tag(M),
                        to_tag => ToTag
                    },
                    anchor_reply(Id, Params, M, Raw);
                _ ->
                    Raw
            end;
        {error, _} ->
            Raw
    end.

anchor_reply(Id, Params, M, Raw) ->
    case chappe_sip_media:anchor_answer(Id, chappe_sip_msg:body(M), Params) of
        {ok, Sdp} ->
            iolist_to_binary(
                chappe_sip_msg:encode(chappe_sip_msg:set_body(Sdp, M))
            );
        {error, Reason} ->
            logger:warning("chappe_sip_proxy: media answer failed: ~p", [Reason]),
            Raw
    end.

has_sdp(M) ->
    case chappe_sip_msg:body(M) of
        <<>> -> false;
        <<_/binary>> -> is_sdp_ct(chappe_sip_msg:get(<<"content-type">>, M))
    end.

is_sdp_ct(undefined) ->
    false;
is_sdp_ct(CT) ->
    binary:match(string:lowercase(CT), <<"application/sdp">>) =/= nomatch.

%% ---- media anchor (opt-in via the `media' option) ----
%%
%% With no `media' option every clause below is a no-op and forwarding is
%% byte-identical to a plain proxy. When set, the request SDP is anchored
%% through rtpengine (offer) on the way out and the reply SDP (answer) on the
%% way back; rtpengine holds the call by Call-ID and the pool pins the node.

%% Rewrite the outgoing request SDP with the rtpengine offer.
-spec anchor_request(map(), chappe_sip_msg:msg()) ->
    {ok, chappe_sip_msg:msg()} | {error, {media, term()}}.
anchor_request(Opts, M) ->
    case maps:get(media, Opts, undefined) of
        undefined -> {ok, M};
        Media -> anchor_offer_body(Media, M)
    end.

anchor_offer_body(Media, M) ->
    case has_sdp(M) of
        false ->
            {ok, M};
        true ->
            Id = #{
                call_id => chappe_sip_msg:call_id(M),
                from_tag => chappe_sip_msg:from_tag(M)
            },
            Params = maps:get(offer_params, Media, #{}),
            case
                chappe_sip_media:anchor_offer(
                    Id, chappe_sip_msg:body(M), Params
                )
            of
                {ok, Sdp} -> {ok, chappe_sip_msg:set_body(Sdp, M)};
                {error, Reason} -> {error, {media, Reason}}
            end
    end.

%% Rewrite a provisional/2xx response SDP with the rtpengine answer. Best
%% effort: on failure the original response is relayed (never tear down a 2xx).
-spec answer_sdp(map(), 100..699, binary()) -> binary().
answer_sdp(Opts, Status, Raw) when
    Status >= 100, Status < 300
->
    case maps:get(media, Opts, undefined) of
        undefined ->
            Raw;
        Media ->
            rewrite_answer(
                maps:get(answer_params, Media, #{}), Raw
            )
    end;
answer_sdp(_Opts, _Status, Raw) ->
    Raw.

relay(ServerTxn, Status, Raw) ->
    chappe_sip_engine:relay_response(ServerTxn, Status, Raw).

respond(ServerTxn, Status, Reason) ->
    chappe_sip_engine:dialog_respond(
        ServerTxn, Status, Reason, <<>>, <<>>, <<>>
    ).
