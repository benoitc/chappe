%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The transaction tables of the WebSocket transport.
%%
%% chappe_sip_ws_transport keeps its server transactions, client
%% transactions, dialog legs and ACK waits in its #state{}; this module
%% adds, finds and removes them, keeps their indexes in step, and arms and
%% cancels their timers. It also holds the transport's two outputs: a SIP
%% message sent on a flow, and an event delivered to the engine.
-module(chappe_sip_ws_txn).

-include("chappe_sip_ws_transport.hrl").

-export([alloc/1, start_timer/2, cancel_timer/1, fired/4]).
-export([proceeding/2, add_stxn/5, put_stxn/3, drop_stxn/2]).
-export([local_tag/3, reliable/4, arm_progress/2]).
-export([find_cancelled/3, find_rel/5]).
-export([add_ctxn/6, put_ctxn/3, drop_ctxn/2]).
-export([add_leg/5, drop_leg/2, match_leg/2]).
-export([arm_ack_wait/3, end_ack_wait/2, ack_wait_fired/3]).
-export([drop_flow/2]).
-export([conn/2, send/3, capture/4, peer_of/2, proto_of/2, engine_event/1]).

%% A new handle in the WS range (chappe_sip_ws:base()).
-spec alloc(#state{}) -> {integer(), #state{}}.
alloc(#state{counter = C} = S) ->
    N = atomics:add_get(C, 1, 1),
    {chappe_sip_ws:base() + N, S}.

%% ---- timers ----

-spec start_timer(atom(), term()) -> reference().
start_timer(Key, Msg) ->
    erlang:start_timer(chappe_sip_config:get(Key), self(), Msg).

-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) ->
    ok.

%% The entry of Table a timer message names, while TRef is still the timer
%% its Field holds: a timer cancelled or replaced may still have its
%% message in the mailbox.
-spec fired(term(), atom(), reference(), map()) -> {ok, map()} | stale.
fired(Key, Field, TRef, Table) ->
    case Table of
        #{Key := #{Field := TRef} = V} -> {ok, V};
        _ -> stale
    end.

%% ---- server transactions ----

%% A server transaction that can still take a response.
-spec proceeding(integer(), #state{}) ->
    {ok, map()} | {error, transaction_completed | unknown_transaction}.
proceeding(TxnH, S) ->
    case S#state.stxn of
        #{TxnH := #{state := proceeding} = T} -> {ok, T};
        #{TxnH := _} -> {error, transaction_completed};
        _ -> {error, unknown_transaction}
    end.

-spec add_stxn(integer(), chappe_sip_msg:msg(), binary(), binary(), #state{}) ->
    {integer(), #state{}}.
add_stxn(Flow, Msg, Branch, Method, S) ->
    {TxnH, S1} = alloc(S),
    %% reap a server transaction the app never gives a final to
    TRef = start_timer(ws_server_txn_timeout_ms, {stxn, TxnH}),
    Txn = #{
        flow => Flow,
        branch => Branch,
        method => Method,
        msg => Msg,
        state => proceeding,
        timer => TRef,
        last => undefined
    },
    %% a request without a branch (pre-RFC 3261) cannot be matched to a
    %% retransmission; it is a transaction of its own and is not indexed
    Ix =
        case Branch of
            <<>> -> S1#state.branch_ix;
            _ -> (S1#state.branch_ix)#{{Flow, Branch, Method} => TxnH}
        end,
    {TxnH, S1#state{stxn = (S1#state.stxn)#{TxnH => Txn}, branch_ix = Ix}}.

-spec put_stxn(integer(), map(), #state{}) -> #state{}.
put_stxn(TxnH, T, S) ->
    S#state{stxn = (S#state.stxn)#{TxnH => T}}.

-spec drop_stxn(integer(), #state{}) -> #state{}.
drop_stxn(TxnH, S) ->
    case S#state.stxn of
        #{TxnH := #{flow := Flow, branch := Br, method := M} = T} ->
            cancel_timers(T),
            S#state{
                stxn = maps:remove(TxnH, S#state.stxn),
                branch_ix = drop_ix({Flow, Br, M}, TxnH, S#state.branch_ix)
            };
        _ ->
            S
    end.

%% remove an index entry only while it still names this transaction
drop_ix(Key, TxnH, Ix) ->
    case Ix of
        #{Key := TxnH} -> maps:remove(Key, Ix);
        _ -> Ix
    end.

cancel_timers(T) ->
    cancel_timer(maps:get(timer, T, undefined)),
    cancel_timer(maps:get(progress, T, undefined)).

%% RFC 3261 8.2.6.2: every response of a transaction but the 100 carries the
%% same To-tag; one is minted on the first that needs it unless the caller
%% names it.
-spec local_tag(binary(), 100..699, map()) -> {binary(), map()}.
local_tag(<<>>, Status, T) ->
    case maps:get(tag, T, undefined) of
        undefined when Status > 100 ->
            Tag = chappe_sip_dialog:gen_tag(),
            {Tag, T#{tag => Tag}};
        undefined ->
            {<<>>, T};
        Tag ->
            {Tag, T}
    end;
local_tag(ToTag, _Status, T) ->
    {ToTag, T#{tag => ToTag}}.

%% RFC 3262 3: a reliable provisional carries Require: 100rel and an RSeq one
%% above the previous one's, when the caller offered 100rel (else it goes out
%% as a plain provisional, 8.2.4 of RFC 3261). The first reliable 1xx to an
%% INVITE without an offer carries one (RFC 3262 5).
-spec reliable(boolean(), 100..699, binary(), map()) ->
    {iodata(), map()} | {error, reliable_1xx_needs_offer}.
reliable(true, Status, Body, #{method := <<"INVITE">>, msg := Msg} = T) when
    Status > 100, Status < 200
->
    case chappe_sip_ws_msg:peer_100rel(Msg) of
        false ->
            {<<>>, T};
        true ->
            Offerless =
                maps:get(rel_offer, T, 0) =:= 0 andalso
                    chappe_sip_msg:body(Msg) =:= <<>>,
            case Offerless andalso Body =:= <<>> of
                true -> {error, reliable_1xx_needs_offer};
                false -> next_rseq(Offerless, T)
            end
    end;
reliable(_Rel, _Status, _Body, T) ->
    {<<>>, T}.

next_rseq(Offerless, T) ->
    N =
        case maps:get(rseq, T, undefined) of
            undefined -> rand:uniform(16#FFFF);
            Prev -> Prev + 1
        end,
    Offer =
        case Offerless of
            true -> 1;
            false -> maps:get(rel_offer, T, 0)
        end,
    Extra = [<<"Require: 100rel\r\nRSeq: ">>, integer_to_binary(N), <<"\r\n">>],
    {Extra, T#{rseq => N, rel_offer => Offer}}.

%% (Re)start the 13.3.1.1 resend of the last provisional.
-spec arm_progress(integer(), map()) -> map().
arm_progress(TxnH, T) ->
    cancel_timer(maps:get(progress, T, undefined)),
    case chappe_sip_config:get(ws_progress_ms) of
        infinity ->
            maps:remove(progress, T);
        Ms ->
            T#{progress => erlang:start_timer(Ms, self(), {progress, TxnH})}
    end.

%% The transaction a CANCEL names: the INVITE of its branch, else any other
%% request of that branch on the flow.
-spec find_cancelled(integer(), binary(), #state{}) ->
    {integer(), map()} | undefined.
find_cancelled(_Flow, <<>>, _S) ->
    undefined;
find_cancelled(Flow, Branch, S) ->
    case maps:get({Flow, Branch, <<"INVITE">>}, S#state.branch_ix, undefined) of
        undefined ->
            Other = [
                H
             || {{F, B, _M}, H} <- maps:to_list(S#state.branch_ix),
                F =:= Flow,
                B =:= Branch
            ],
            case Other of
                [H | _] -> {H, maps:get(H, S#state.stxn)};
                [] -> undefined
            end;
        H ->
            {H, maps:get(H, S#state.stxn)}
    end.

%% The INVITE whose reliable provisional a PRACK's RAck names (RFC 3262 4).
-spec find_rel(integer(), binary(), integer(), integer(), #state{}) ->
    {ok, integer(), map()} | error.
find_rel(Flow, CallId, CSeq, RSeq, S) ->
    Found = [
        {H, T}
     || {H,
            #{
                flow := F,
                method := <<"INVITE">>,
                state := proceeding,
                msg := M,
                rseq := Sent
            } = T} <- maps:to_list(S#state.stxn),
        F =:= Flow,
        RSeq =< Sent,
        RSeq > maps:get(rel_acked, T, 0),
        chappe_sip_msg:call_id(M) =:= CallId,
        chappe_sip_ws_msg:req_seq(M) =:= CSeq
    ],
    case Found of
        [{H, T} | _] -> {ok, H, T};
        [] -> error
    end.

%% ---- client transactions ----

%% A client transaction for Req, sent on Flow with our Branch. Timer B/F:
%% no sofia timers here, so bound the wait for a response; an unanswered
%% UAC leg (a browser that never replies) is cleaned up.
-spec add_ctxn(integer(), integer(), binary(), pid(), binary(), #state{}) ->
    #state{}.
add_ctxn(TxnH, Flow, Branch, Pid, Req, S) ->
    TRef = start_timer(ws_client_txn_timeout_ms, {ctxn_b, TxnH}),
    Ct = #{
        flow => Flow,
        branch => Branch,
        pid => Pid,
        req => Req,
        method => chappe_sip_ws_msg:request_method(Req),
        timer => TRef,
        prov => false,
        final => false,
        cancel => none
    },
    S#state{
        ctxn = (S#state.ctxn)#{TxnH => Ct},
        cbranch_ix = (S#state.cbranch_ix)#{Branch => TxnH}
    }.

-spec put_ctxn(integer(), map(), #state{}) -> #state{}.
put_ctxn(TxnH, Ct, S) ->
    S#state{ctxn = (S#state.ctxn)#{TxnH => Ct}}.

-spec drop_ctxn(integer(), #state{}) -> #state{}.
drop_ctxn(TxnH, S) ->
    case S#state.ctxn of
        #{TxnH := #{branch := Br} = Ct} ->
            cancel_timer(maps:get(timer, Ct, undefined)),
            S#state{
                ctxn = maps:remove(TxnH, S#state.ctxn),
                cbranch_ix = maps:remove(Br, S#state.cbranch_ix)
            };
        _ ->
            S
    end.

%% ---- dialog legs and ACK waits ----

-spec add_leg(binary(), binary(), binary(), integer(), #state{}) ->
    {integer(), #state{}}.
add_leg(CallId, LocalAddr, RemoteAddr, Flow, S) ->
    {LegH, S1} = alloc(S),
    LTag = chappe_sip_ws_msg:tag_of(LocalAddr),
    RTag = chappe_sip_ws_msg:tag_of(RemoteAddr),
    Leg = #{flow => Flow, call_id => CallId, ltag => LTag, rtag => RTag},
    {LegH, S1#state{
        legs = (S1#state.legs)#{LegH => Leg},
        leg_ix = (S1#state.leg_ix)#{{CallId, LTag, RTag} => LegH}
    }}.

-spec drop_leg(integer(), #state{}) -> #state{}.
drop_leg(LegH, S) ->
    case S#state.legs of
        #{LegH := #{call_id := C, ltag := L, rtag := R}} ->
            S1 = end_ack_wait({C, L, R}, S),
            S1#state{
                legs = maps:remove(LegH, S1#state.legs),
                leg_ix = maps:remove({C, L, R}, S1#state.leg_ix)
            };
        _ ->
            S
    end.

%% The leg an in-dialog request belongs to (its To-tag is our tag).
-spec match_leg(chappe_sip_msg:msg(), #state{}) -> integer() | undefined.
match_leg(Msg, S) ->
    case chappe_sip_msg:to_tag(Msg) of
        undefined ->
            undefined;
        ToTag ->
            CallId = chappe_sip_msg:call_id(Msg),
            FromTag = chappe_sip_msg:from_tag(Msg),
            maps:get({CallId, ToTag, FromTag}, S#state.leg_ix, undefined)
    end.

%% Our 2xx to an INVITE (Msg) went out: wait for its ACK (RFC 3261 13.3.1.4).
-spec arm_ack_wait(chappe_sip_msg:msg(), binary() | undefined, #state{}) ->
    #state{}.
arm_ack_wait(Msg, Tag, S) ->
    LTag =
        case chappe_sip_msg:to_tag(Msg) of
            undefined -> Tag;
            InDialog -> InDialog
        end,
    Key = {chappe_sip_msg:call_id(Msg), LTag, chappe_sip_msg:from_tag(Msg)},
    cancel_timer(maps:get(Key, S#state.ackw, undefined)),
    TRef = start_timer(ws_ack_timeout_ms, {ack_wait, Key}),
    S#state{ackw = (S#state.ackw)#{Key => TRef}}.

%% The ACK came, or the leg is gone: stop waiting.
-spec end_ack_wait(term(), #state{}) -> #state{}.
end_ack_wait(Key, S) ->
    case maps:take(Key, S#state.ackw) of
        {TRef, AckW} ->
            cancel_timer(TRef),
            S#state{ackw = AckW};
        error ->
            S
    end.

%% The ACK wait timer TRef fired: the wait is over, if it was still armed.
-spec ack_wait_fired(term(), reference(), #state{}) -> {ok, #state{}} | stale.
ack_wait_fired(Key, TRef, S) ->
    case S#state.ackw of
        #{Key := TRef} -> {ok, S#state{ackw = maps:remove(Key, S#state.ackw)}};
        _ -> stale
    end.

%% ---- flows ----

%% Forget a closed Flow: its connection, the transactions on it (timers
%% cancelled) and its legs. Returns the legs lost, for flow_lost.
-spec drop_flow(integer(), #state{}) -> {[integer()], #state{}}.
drop_flow(Flow, S) ->
    _ = [
        cancel_timers(T)
     || T <- maps:values(S#state.stxn) ++ maps:values(S#state.ctxn),
        maps:get(flow, T, undefined) =:= Flow
    ],
    CTxn = off_flow(Flow, S#state.ctxn),
    Legs = off_flow(Flow, S#state.legs),
    KeptCBranches = [B || #{branch := B} <- maps:values(CTxn)],
    LegKeys = [
        {C, L, R}
     || #{call_id := C, ltag := L, rtag := R} <- maps:values(Legs)
    ],
    Lost = maps:keys(S#state.legs) -- maps:keys(Legs),
    {Lost, S#state{
        conns = maps:remove(Flow, S#state.conns),
        stxn = off_flow(Flow, S#state.stxn),
        branch_ix = maps:filter(
            fun({F, _, _}, _) -> F =/= Flow end,
            S#state.branch_ix
        ),
        ctxn = CTxn,
        cbranch_ix = maps:with(KeptCBranches, S#state.cbranch_ix),
        legs = Legs,
        leg_ix = maps:with(LegKeys, S#state.leg_ix)
    }}.

off_flow(Flow, Table) ->
    maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, Table).

%% ---- output ----

%% Send one SIP message in one WS message (RFC 7118 5), refusing one past
%% max_message_size: the peer would refuse it, and it should not leave.
-spec send(integer(), iodata(), #state{}) -> ok | {error, term()}.
send(Flow, Raw, S) ->
    case conn(Flow, S) of
        {Conn, Peer, Proto} ->
            case byte_size(Raw) > chappe_sip_config:get(max_message_size) of
                true ->
                    {error, too_large};
                false ->
                    ws:send(Conn, chappe_sip_ws_msg:frame(Raw)),
                    chappe_sip_hep:capture(out, Proto, Peer, Raw)
            end;
        undefined ->
            {error, no_flow}
    end.

%% HEP capture of a message received on Flow (a no-op while capture is off)
-spec capture(in | out, integer(), binary(), #state{}) -> ok.
capture(Dir, Flow, Raw, S) ->
    case conn(Flow, S) of
        {_Conn, Peer, Proto} -> chappe_sip_hep:capture(Dir, Proto, Peer, Raw);
        undefined -> ok
    end.

-spec peer_of(integer(), #state{}) -> term().
peer_of(Flow, S) ->
    case conn(Flow, S) of
        {_Conn, Peer, _Proto} -> Peer;
        undefined -> undefined
    end.

-spec proto_of(integer(), #state{}) -> ws | wss.
proto_of(Flow, S) ->
    case conn(Flow, S) of
        {_Conn, _Peer, Proto} -> Proto;
        undefined -> ws
    end.

%% The {Conn, Peer, Proto} of an open Flow.
-spec conn(integer(), #state{}) -> {pid(), term(), ws | wss} | undefined.
conn(Flow, S) ->
    maps:get(Flow, S#state.conns, undefined).

%% deliver an engine event as the NIF would ({chappe_sip_engine, ws, Event}).
%% Tolerate a briefly-absent engine (mid-restart): the registered-name send
%% would otherwise raise badarg and crash this transport, losing all WS state.
-spec engine_event(term()) -> ok.
engine_event(Event) ->
    case whereis(chappe_sip_engine) of
        undefined ->
            ok;
        Pid ->
            Pid ! {chappe_sip_engine, ws, Event},
            ok
    end.
