%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The client transactions of the WebSocket transport.
%%
%% A request chappe_sip_ws_transport originates on a flow (send_request)
%% gets our Via and a client transaction. This module sends it, delivers
%% its responses to the engine, runs Timer B/F and Timer C, holds a CANCEL
%% until a provisional arrived (RFC 3261 9.1) and ACKs a non-2xx final to
%% an INVITE with the INVITE's branch (17.1.1.3). It runs in the transport
%% process, on its #state{}.
-module(chappe_sip_ws_ctxn).

-include("chappe_sip_ws_transport.hrl").

-export([originate/5, response/6, cancel/3, timer_b/3, timer_c/3]).

%% CANCEL a client transaction (RFC 3261 9.1): not once a final came or a
%% CANCEL went out, and only after a provisional.
-spec cancel(integer(), binary(), #state{}) ->
    #state{}.
cancel(TxnH, Hdrs, S) ->
    case S#state.ctxn of
        #{TxnH := #{final := true}} ->
            S;
        #{TxnH := #{cancel := sent}} ->
            S;
        #{TxnH := #{prov := true} = Ct} ->
            send_cancel(TxnH, Ct, Hdrs, S);
        #{TxnH := Ct} ->
            %% RFC 3261 9.1: no CANCEL before a provisional arrived; hold it
            chappe_sip_ws_txn:put_ctxn(TxnH, Ct#{cancel => {pending, Hdrs}}, S);
        _ ->
            S
    end.

%% Timer B/F: no final arrived; fail the UAC leg and drop the client
%% transaction
-spec timer_b(integer(), {ok, map()} | stale, #state{}) ->
    #state{}.
timer_b(TxnH, {ok, _Ct}, S) ->
    chappe_sip_ws_txn:engine_event({op_failed, TxnH, timeout}),
    chappe_sip_ws_txn:drop_ctxn(TxnH, S);
timer_b(_TxnH, stale, S) ->
    S.

%% Timer C (RFC 3261 16.6 step 11): a provisional came but no final;
%% CANCEL, then give the final 64*T1 more (Timer B)
-spec timer_c(integer(), {ok, map()} | stale, #state{}) ->
    #state{}.
timer_c(TxnH, {ok, Ct}, S) ->
    Ct1 = Ct#{
        timer =>
            chappe_sip_ws_txn:start_timer(
                ws_client_txn_timeout_ms, {ctxn_b, TxnH}
            )
    },
    S1 = chappe_sip_ws_txn:put_ctxn(TxnH, Ct1, S),
    case maps:get(cancel, Ct1) of
        sent -> S1;
        _ -> send_cancel(TxnH, Ct1, <<>>, S1)
    end;
timer_c(_TxnH, stale, S) ->
    S.

%% A response to our request (matched by its branch), delivered to the UAC.
-spec response(
    integer(),
    map(),
    100..699,
    chappe_sip_msg:msg(),
    binary(),
    #state{}
) -> #state{}.
response(_TxnH, #{final := true}, Status, _Msg, _Raw, S) when
    Status < 200
->
    S;
response(TxnH, Ct, Status, _Msg, Raw, S) when Status < 200 ->
    chappe_sip_ws_txn:engine_event({response, TxnH, #{status => Status}, Raw}),
    Ct1 =
        case maps:get(method, Ct) of
            <<"INVITE">> ->
                %% a provisional stops Timer B and (re)starts Timer C
                chappe_sip_ws_txn:cancel_timer(maps:get(timer, Ct)),
                Ct#{
                    prov => true,
                    timer => chappe_sip_ws_txn:start_timer(
                        ws_timer_c_ms, {ctxn_c, TxnH}
                    )
                };
            _ ->
                Ct#{prov => true}
        end,
    S1 = chappe_sip_ws_txn:put_ctxn(TxnH, Ct1, S),
    case maps:get(cancel, Ct1) of
        {pending, Hdrs} -> send_cancel(TxnH, Ct1, Hdrs, S1);
        _ -> S1
    end;
response(TxnH, Ct, Status, Msg, Raw, S) ->
    %% RFC 3261 17.1.1.3: the client transaction ACKs a non-2xx final
    _ =
        case maps:get(method, Ct) of
            <<"INVITE">> when Status >= 300 ->
                send_ack(maps:get(flow, Ct), maps:get(req, Ct), Msg, S);
            _ ->
                ok
        end,
    case maps:get(final, Ct) of
        true when Status >= 300 ->
            %% a repeated non-2xx final: re-ACKed, already delivered
            S;
        _ ->
            chappe_sip_ws_txn:engine_event(
                {response, TxnH, #{status => Status}, Raw}
            ),
            chappe_sip_ws_txn:cancel_timer(maps:get(timer, Ct)),
            chappe_sip_ws_txn:put_ctxn(
                TxnH,
                Ct#{timer => undefined, final => true, cancel => sent},
                S
            )
    end.

%% Send Raw on Flow with our Via, as a new client transaction.
-spec originate(
    integer(), ws | wss, binary(), pid(), #state{}
) ->
    {{ok, integer()} | {error, term()}, #state{}}.
originate(Flow, Proto, Raw, Pid, S) ->
    {TxnH, S1} = chappe_sip_ws_txn:alloc(S),
    Branch = chappe_sip_ws_msg:new_branch(),
    Raw1 = chappe_sip_ws_msg:insert_via(Raw, Proto, Branch),
    case chappe_sip_ws_txn:send(Flow, Raw1, S1) of
        ok ->
            S2 = chappe_sip_ws_txn:add_ctxn(TxnH, Flow, Branch, Pid, Raw1, S1),
            chappe_sip_ws_txn:engine_event({op_ok, TxnH}),
            {{ok, TxnH}, S2};
        Err ->
            {Err, S1}
    end.

send_cancel(TxnH, #{flow := Flow, req := Req} = Ct, Hdrs, S) ->
    _ = send_built(Flow, chappe_sip_ws_msg:build_cancel(Req, Hdrs), S),
    chappe_sip_ws_txn:put_ctxn(TxnH, Ct#{cancel => sent}, S).

%% RFC 3261 17.1.1.3: the ACK of a non-2xx final, on the INVITE's branch
send_ack(Flow, Req, Resp, S) ->
    send_built(Flow, chappe_sip_ws_msg:build_ack(Req, Resp), S).

send_built(Flow, {ok, Raw}, S) -> chappe_sip_ws_txn:send(Flow, Raw, S);
send_built(_Flow, error, _S) -> ok.
