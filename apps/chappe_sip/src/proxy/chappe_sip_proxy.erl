%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Stateful forking proxy.
%%
%% proxy_request forwards an incoming request to one or more destinations
%% and relays responses back upstream. It runs in the request worker.
%% Forking is sequential (try in order until a 2xx) or parallel (all at
%% once, first 2xx wins and the rest are CANCELled). Provisionals are
%% relayed; the best final is relayed if no branch answers 2xx.
%%
%% The first 2xx is relayed on the server transaction (nta completes it on
%% the first final). A genuinely forked second 2xx from a different endpoint
%% arrives after the server transaction is gone, so it is forwarded
%% statelessly upstream via chappe_sip_engine:forward_response/1 (nta_msg_tsend).
-module(chappe_sip_proxy).

-export([proxy_request/3, forward_indialog/2, forward_indialog_ack/2]).

-record(px, {
    server :: non_neg_integer(),
    pending = #{} :: #{non_neg_integer() => binary()},
    remaining = [] :: [binary()],
    fwd :: binary(),
    opts :: map(),
    mode :: sequential | parallel,
    got_2xx = false :: boolean(),
    best :: {100..699, binary()} | undefined,
    responses = [] :: [100..699],
    %% absolute deadline (monotonic ms) for the pre-final wait, so a stream of
    %% provisionals cannot keep the branch (and worker) alive forever
    deadline :: integer() | undefined
}).

-spec proxy_request(
    chappe_sip_req:req(),
    binary()
    | {ws, integer()}
    | [binary() | {ws, integer()}],
    map()
) ->
    {ok, #{
        final_status := 100..699,
        final_response := binary(),
        responses := [100..699]
    }}
    | {error, term()}.
proxy_request(Req, Dest, Opts) when is_binary(Dest) ->
    proxy_request(Req, [Dest], Opts);
proxy_request(Req, {ws, _} = Dest, Opts) ->
    proxy_request(Req, [Dest], Opts);
proxy_request(_Req, [], _Opts) ->
    {error, no_destination};
proxy_request(Req, Dests, Opts) ->
    ServerTxn = chappe_sip_req:txn(Req),
    Result =
        case build_forward(Req, Opts, ws_flow(Req, Dests)) of
            {ok, Fwd} ->
                Mode = maps:get(forking, Opts, sequential),
                Deadline = erlang:monotonic_time(millisecond) + 32000,
                start(
                    #px{
                        server = ServerTxn,
                        fwd = Fwd,
                        opts = Opts,
                        mode = Mode,
                        deadline = Deadline
                    },
                    Dests
                );
            {error, {media, _} = MErr} ->
                %% media anchor (offer) failed: fail-closed, do not forward
                _ = respond(ServerTxn, 500, <<"Server Internal Error">>),
                {error, MErr};
            {error, loop_detected} ->
                _ = respond(ServerTxn, 483, <<"Too Many Hops">>),
                {error, loop_detected}
        end,
    %% the proxy completed the server transaction itself; stop the worker
    %% exit from sending a spurious 500
    case get(chappe_sip_current_res) of
        undefined -> ok;
        Res -> chappe_sip_res:mark_final(Res)
    end,
    Result.

start(#px{mode = parallel} = P, Dests) ->
    Pending = lists:foldl(
        fun(Dest, Acc) ->
            case launch(P, Dest) of
                {ok, TxnH} -> Acc#{TxnH => Dest};
                {error, _} -> Acc
            end
        end,
        #{},
        Dests
    ),
    case map_size(Pending) of
        % no branch launched: relay the best final (480)
        0 -> finish(P);
        _ -> loop(P#px{pending = Pending})
    end;
start(#px{mode = sequential} = P, []) ->
    %% every branch failed to launch (or none was given): relay the best final
    %% collected, else 480 - do not crash the worker
    finish(P);
start(#px{mode = sequential} = P, [Dest | Rest]) ->
    case launch(P, Dest) of
        {ok, TxnH} ->
            loop(P#px{pending = #{TxnH => Dest}, remaining = Rest});
        {error, _} ->
            start(P, Rest)
    end.

loop(#px{server = ServerTxn} = P) ->
    receive
        {chappe_sip_response, TxnH, #{status := Status}, Raw} ->
            on_response(P, TxnH, Status, Raw);
        {chappe_sip_op, TxnH, {error, _Reason}} ->
            %% branch send failed at nta layer; treat as a failed branch
            branch_done(P, TxnH, undefined);
        {chappe_sip_op, _TxnH, ok} ->
            loop(P);
        {chappe_sip_cancel, ServerTxn} ->
            cancel_all(P),
            loop(P)
    after remaining(P#px.deadline) ->
        cancel_all(P),
        _ = respond(ServerTxn, 408, <<"Request Timeout">>),
        {error, timeout}
    end.

remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

on_response(#px{server = ServerTxn} = P, _TxnH, Status, Raw) when
    Status >= 100, Status < 200
->
    case Status of
        % never relay 100 Trying
        100 -> ok;
        _ -> _ = relay_answered(ServerTxn, P, Status, Raw)
    end,
    loop(P);
on_response(
    #px{server = ServerTxn, got_2xx = false} = P, TxnH, Status, Raw
) when
    Status >= 200, Status < 300
->
    _ = relay_answered(ServerTxn, P, Status, Raw),
    _ = chappe_sip_engine:finish_txn(TxnH),
    P1 = P#px{
        pending = maps:remove(TxnH, P#px.pending),
        got_2xx = true,
        responses = [Status | P#px.responses]
    },
    cancel_all(P1),
    drain(P1, {Status, Raw});
%% NB: once the first 2xx is relayed we move to drain/2, which forwards any
%% further forked 2xx; on_response is never re-entered with got_2xx = true.
on_response(#px{server = ServerTxn} = P, TxnH, Status, Raw) when
    Status >= 600
->
    %% a 6xx is a global failure (RFC 3261 16.7 step 5): stop forking, cancel
    %% the other branches, and relay it upstream as the final answer
    _ = chappe_sip_engine:finish_txn(TxnH),
    P1 = P#px{
        pending = maps:remove(TxnH, P#px.pending),
        responses = [Status | P#px.responses]
    },
    cancel_all(P1),
    _ = relay(ServerTxn, Status, chappe_sip_route:strip_via(Raw)),
    {ok, #{
        final_status => Status,
        final_response => Raw,
        responses => lists:reverse(P1#px.responses)
    }};
on_response(P, TxnH, Status, Raw) when Status >= 300 ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    branch_done(record_best(P, Status, Raw), TxnH, {Status, Raw}).

%% a branch reached a non-2xx final (or failed to launch)
branch_done(#px{mode = sequential, remaining = [Next | Rest]} = P, TxnH, _) ->
    P1 = P#px{pending = maps:remove(TxnH, P#px.pending)},
    case launch(P1, Next) of
        {ok, NTxn} -> loop(P1#px{pending = #{NTxn => Next}, remaining = Rest});
        {error, _} -> branch_done(P1#px{remaining = Rest}, TxnH, undefined)
    end;
branch_done(#px{mode = sequential, remaining = []} = P, TxnH, _) ->
    finish(P#px{pending = maps:remove(TxnH, P#px.pending)});
branch_done(#px{mode = parallel} = P, TxnH, _) ->
    P1 = P#px{pending = maps:remove(TxnH, P#px.pending)},
    case map_size(P1#px.pending) of
        0 -> finish(P1);
        _ -> loop(P1)
    end.

%% after the winning 2xx, wait out any remaining branches: a second forked
%% 2xx (different endpoint) is forwarded upstream statelessly, a non-2xx
%% final (a CANCELled or busy branch) is just drained; then return.
drain(#px{pending = Pending} = P, Winner) when map_size(Pending) =:= 0 ->
    {Status, Raw} = Winner,
    {ok, #{
        final_status => Status,
        final_response => Raw,
        responses => lists:reverse(P#px.responses)
    }};
drain(P, Winner) ->
    receive
        {chappe_sip_response, TxnH, #{status := St}, Raw} when
            St >= 200, St < 300
        ->
            %% forked second 2xx: forward with the proxy's top Via intact
            _ = chappe_sip_engine:forward_response(Raw),
            _ = chappe_sip_engine:finish_txn(TxnH),
            drain(
                P#px{
                    pending = maps:remove(TxnH, P#px.pending),
                    responses = [St | P#px.responses]
                },
                Winner
            );
        {chappe_sip_response, TxnH, #{status := St}, _Raw} when St >= 300 ->
            _ = chappe_sip_engine:finish_txn(TxnH),
            drain(P#px{pending = maps:remove(TxnH, P#px.pending)}, Winner);
        {chappe_sip_response, _TxnH, _Meta, _Raw} ->
            drain(P, Winner);
        {chappe_sip_op, _TxnH, _} ->
            drain(P, Winner)
    after 5000 ->
        {Status, Raw} = Winner,
        {ok, #{
            final_status => Status,
            final_response => Raw,
            responses => lists:reverse(P#px.responses)
        }}
    end.

%% no 2xx: relay the best final upstream
finish(#px{best = undefined, server = ServerTxn} = P) ->
    _ = respond(ServerTxn, 480, <<"Temporarily Unavailable">>),
    {ok, #{
        final_status => 480,
        final_response => <<>>,
        responses => lists:reverse(P#px.responses)
    }};
finish(#px{best = {Status, Raw}, server = ServerTxn} = P) ->
    _ = relay(ServerTxn, Status, chappe_sip_route:strip_via(Raw)),
    {ok, #{
        final_status => Status,
        final_response => Raw,
        responses => lists:reverse(P#px.responses)
    }}.

%% ---- in-dialog forwarding (record-route) ----

%% Forward one in-dialog transit request (BYE, re-INVITE, INFO, ...) that a
%% record-routing proxy received on its default leg, and relay the responses
%% back upstream. Runs as the request worker's handler, so it marks Res final
%% to keep the worker's exit from sending a spurious 500.
-spec forward_indialog(chappe_sip_req:req(), chappe_sip_res:res()) -> ok.
forward_indialog(Req, Res) ->
    ServerTxn = chappe_sip_req:txn(Req),
    {NextHop, FTok, Msg1} = chappe_sip_route:pop_self(chappe_sip_req:msg(Req)),
    ArrivedWS = maps:is_key(flow, chappe_sip_req:meta(Req)),
    Route = indialog_route(ArrivedWS, NextHop, FTok),
    %% Anchor is `none' unless media is configured and this call is pinned, so a
    %% plain proxy (or an unanchored call) runs the original path untouched.
    Anchor = indialog_anchor(Msg1),
    Msg1b = indialog_offer(Anchor, Msg1),
    case chappe_sip_msg:decr_max_forwards(Msg1b) of
        {ok, Msg2} ->
            Raw = iolist_to_binary(chappe_sip_msg:encode(Msg2)),
            case chappe_sip_engine:send_request(Route, Raw, self()) of
                {ok, OutTxn} ->
                    Deadline = erlang:monotonic_time(millisecond) + 32000,
                    relay_indialog(ServerTxn, OutTxn, Deadline, Anchor),
                    indialog_release(Anchor, Msg1);
                {error, Reason} ->
                    logger:warning(
                        "chappe_sip_proxy: in-dialog forward failed: ~p",
                        [Reason]
                    ),
                    _ = respond(ServerTxn, 500, <<"Server Internal Error">>)
            end;
        {error, loop_detected} ->
            _ = respond(ServerTxn, 483, <<"Too Many Hops">>)
    end,
    chappe_sip_res:mark_final(Res),
    ok.

relay_indialog(ServerTxn, OutTxn, Deadline, Anchor) ->
    receive
        {chappe_sip_response, OutTxn, #{status := Status}, Raw} ->
            Raw2 = indialog_answer(Anchor, Status, Raw),
            _ = relay(ServerTxn, Status, chappe_sip_route:strip_via(Raw2)),
            case Status >= 200 of
                true -> chappe_sip_engine:finish_txn(OutTxn);
                false -> relay_indialog(ServerTxn, OutTxn, Deadline, Anchor)
            end;
        {chappe_sip_op, OutTxn, {error, Reason}} ->
            logger:warning("chappe_sip_proxy: in-dialog branch error: ~p", [
                Reason
            ]),
            _ = respond(ServerTxn, 500, <<"Server Internal Error">>),
            chappe_sip_engine:finish_txn(OutTxn);
        {chappe_sip_op, OutTxn, ok} ->
            relay_indialog(ServerTxn, OutTxn, Deadline, Anchor)
    after remaining(Deadline) ->
        _ = respond(ServerTxn, 408, <<"Request Timeout">>),
        chappe_sip_engine:finish_txn(OutTxn)
    end.

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
            {NextHop, FTok, Msg1} = chappe_sip_route:pop_self(Msg),
            Route = ack_route(ArrivedVia, NextHop, FTok),
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

%% Direction of an in-dialog forward across a WS<->UDP dialog: a request that
%% arrived over WS goes to the other (UDP) leg by Request-URI; one that
%% arrived over UDP goes to the WS leg named by the flow token.
indialog_route(true, NextHop, _FTok) -> NextHop;
indialog_route(false, NextHop, undefined) -> NextHop;
indialog_route(false, _NextHop, FTok) -> {ws, FTok}.

ack_route({ws, _}, NextHop, _FTok) -> NextHop;
ack_route(udp, NextHop, undefined) -> NextHop;
ack_route(udp, _NextHop, FTok) -> {ws, FTok}.

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

%% ---- helpers ----

launch(#px{fwd = Fwd}, Dest) ->
    chappe_sip_engine:send_request(dest_route(Dest), Fwd, self()).

cancel_all(#px{pending = Pending}) ->
    maps:foreach(
        fun(TxnH, _) -> chappe_sip_engine:cancel_txn(TxnH) end, Pending
    ).

%% Track the highest-priority non-2xx final (lowest status wins, 6xx
%% beats others per RFC ordering is simplified here to lowest-status).
record_best(#px{best = undefined} = P, Status, Raw) ->
    P#px{best = {Status, Raw}, responses = [Status | P#px.responses]};
record_best(#px{best = {Cur, _}} = P, Status, Raw) when Status < Cur ->
    P#px{best = {Status, Raw}, responses = [Status | P#px.responses]};
record_best(P, Status, _Raw) ->
    P#px{responses = [Status | P#px.responses]}.

build_forward(Req, Opts, WsFlow) ->
    Msg = chappe_sip_req:msg(Req),
    case chappe_sip_msg:decr_max_forwards(Msg) of
        {ok, M1} ->
            M2 =
                case
                    maps:get(
                        record_route,
                        Opts,
                        maps:get(remain_in_dialog, Opts, false)
                    )
                of
                    true ->
                        %% the flow token names the WS leg so the UDP peer's
                        %% in-dialog requests route back over that connection;
                        %% the marker MAC binds the flow + Call-ID
                        RR = chappe_sip_route:record_route(
                            chappe_sip_engine:contact(),
                            WsFlow,
                            chappe_sip_msg:call_id(Msg)
                        ),
                        chappe_sip_msg:prepend(<<"Record-Route">>, RR, M1);
                    false ->
                        M1
                end,
            case anchor_request(Opts, M2) of
                {ok, M3} -> {ok, iolist_to_binary(chappe_sip_msg:encode(M3))};
                {error, _} = Err -> Err
            end;
        {error, loop_detected} ->
            {error, loop_detected}
    end.

%% ---- media anchor (opt-in via the `media' option) ----
%%
%% With no `media' option every clause below is a no-op and forwarding is
%% byte-identical to a plain proxy. When set, the request SDP is anchored
%% through rtpengine (offer) on the way out and the reply SDP (answer) on the
%% way back; rtpengine holds the call by Call-ID and the pool pins the node.

%% Rewrite the outgoing request SDP with the rtpengine offer.
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
maybe_answer(#px{opts = Opts}, Status, Raw) when
    Status >= 100, Status < 300
->
    case maps:get(media, Opts, undefined) of
        undefined -> Raw;
        Media -> rewrite_answer(maps:get(answer_params, Media, #{}), Raw)
    end;
maybe_answer(_P, _Status, Raw) ->
    Raw.

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

%% the WS leg's flow for the record-route token: the inbound request's flow
%% (browser -> UDP) or a {ws, Flow} destination (UDP -> browser), else none.
ws_flow(Req, Dests) ->
    case maps:get(flow, chappe_sip_req:meta(Req), undefined) of
        Flow when is_integer(Flow) ->
            Flow;
        _ ->
            case [F || {ws, F} <- Dests] of
                [F | _] -> F;
                [] -> undefined
            end
    end.

% originate this branch over a WS flow
dest_route({ws, _Flow} = D) -> D;
dest_route(<<"sip:", _/binary>> = D) -> D;
dest_route(<<"sips:", _/binary>> = D) -> D;
dest_route(D) -> <<"sip:", D/binary>>.

%% Relay a response upstream, rewriting its SDP with the rtpengine answer first
%% when media anchoring is on for this proxy transaction.
relay_answered(ServerTxn, P, Status, Raw) ->
    relay(
        ServerTxn,
        Status,
        chappe_sip_route:strip_via(maybe_answer(P, Status, Raw))
    ).

relay(ServerTxn, Status, Raw) ->
    chappe_sip_engine:relay_response(ServerTxn, Status, Raw).

respond(ServerTxn, Status, Reason) ->
    chappe_sip_engine:dialog_respond(
        ServerTxn, Status, Reason, <<>>, <<>>, <<>>
    ).
