%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIP-over-WebSocket transport and transaction layer (Erlang).
%%
%% Terminates RFC 7118 WS connections (via chappe_sip_ws_conn) and gives them the
%% same engine event contract the sofia NIF uses, so all TU logic runs over
%% WS unchanged. WS is a reliable transport (RFC 7118 5), so the RFC 3261
%% timers for reliable transports apply: no retransmissions (Timer A/E/G),
%% Timer I/J/K are zero, and only the timeouts remain. Server transactions
%% match by {Flow, Branch, Method} (17.2.3), client transactions by our
%% branch, dialog legs by Call-ID + tags.
%%
%% Server side: a retransmitted request gets the last response again; a
%% non-2xx final to an INVITE keeps the transaction until its ACK or Timer H
%% (64*T1); a 2xx ends it and arms an ACK wait on the dialog (13.3.1.4) that
%% fires {ack_timeout, LegH} so the dialog sends a BYE. A CANCEL of an INVITE
%% still proceeding answers the INVITE 487, as nta does. Reliable
%% provisionals (RFC 3262) carry RSeq and are matched to their PRACK; they
%% are never retransmitted, the transport being reliable. An INVITE left
%% ringing still sends its last non-100 provisional again every
%% ws_progress_ms (60 s) until the final, so a proxy on the path does not
%% cancel it (RFC 3261 13.3.1.1), as nta does on its own transports.
%%
%% Client side: Timer B/F bound the wait for a response; a provisional to an
%% INVITE stops Timer B and starts Timer C (refreshed by each provisional),
%% whose expiry CANCELs. A CANCEL is held until a provisional arrived (9.1)
%% and a non-2xx final to an INVITE is ACKed here with the INVITE's branch
%% (17.1.1.3).
%%
%% Handles are allocated in the WS range (chappe_sip_ws:base()) so chappe_sip_engine can
%% multiplex operations back to this process by handle.
%%
%% This module keeps the state, handles the messages and runs the server
%% side. The transaction tables, their timers and the outputs (to a flow,
%% to the engine) are in chappe_sip_ws_txn, the client transactions in
%% chappe_sip_ws_ctxn, and the message parsing and building, which has no
%% state, in chappe_sip_ws_msg.
-module(chappe_sip_ws_transport).
-behaviour(gen_server).

-export([start_link/0]).
%% connection lifecycle (called by chappe_sip_ws_conn)
-export([connect/2, connect/3, disconnect/1, incoming/2]).
%% engine op surface (called by chappe_sip_engine for WS handles)
-export([
    respond/6,
    reliable_respond/6,
    relay/3,
    leg_create/4,
    leg_destroy/1,
    finish_txn/1
]).
%% outbound-to-WS: originate a request/ACK to a registered WS UA over a flow
-export([send_request/3, send_stateless/2, cancel/1, cancel/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("chappe_sip_ws_transport.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A new WS connection; returns its Flow id, or refuses at the connection cap.
-spec connect(pid(), term()) ->
    {ok, integer()} | {error, too_many_connections}.
connect(Conn, Peer) ->
    connect(Conn, Peer, ws).

%% Proto is the Via transport of the flow: ws, or wss over TLS.
-spec connect(pid(), term(), ws | wss) ->
    {ok, integer()} | {error, too_many_connections}.
connect(Conn, Peer, Proto) ->
    gen_server:call(?MODULE, {connect, Conn, Peer, Proto}).

-spec disconnect(integer()) -> ok.
disconnect(Flow) ->
    gen_server:cast(?MODULE, {disconnect, Flow}).

%% A SIP message (a text or binary frame) arrived on Flow.
-spec incoming(integer(), binary()) -> ok.
incoming(Flow, Raw) ->
    gen_server:cast(?MODULE, {incoming, Flow, Raw}).

%% ---- engine op surface (mirrors the chappe_sip_nif shapes, minus Engine) ----

-spec respond(integer(), 100..699, binary(), iodata(), binary(), binary()) ->
    ok | {error, term()}.
respond(TxnH, Status, Reason, Headers, Body, ToTag) ->
    gen_server:call(
        ?MODULE, {respond, TxnH, Status, Reason, Headers, Body, ToTag, false}
    ).

%% A reliable provisional (RFC 3262): RSeq + Require: 100rel when the
%% caller offered 100rel, a plain provisional otherwise. The PRACK reaches
%% the INVITE's owner as {prack, TxnH, Raw} (or {prack, TxnH, Raw, PrackH}
%% when it carries an offer the app answers).
-spec reliable_respond(
    integer(), 100..699, binary(), iodata(), binary(), binary()
) ->
    ok | {error, term()}.
reliable_respond(TxnH, Status, Reason, Headers, Body, ToTag) ->
    gen_server:call(
        ?MODULE, {respond, TxnH, Status, Reason, Headers, Body, ToTag, true}
    ).

%% proxy: forward a complete downstream response upstream on the WS txn
-spec relay(integer(), 100..699, binary()) -> ok | {error, term()}.
relay(TxnH, Status, Raw) ->
    gen_server:call(?MODULE, {relay, TxnH, Status, Raw}).

-spec leg_create(binary(), binary(), binary(), integer()) ->
    {ok, integer()} | {error, term()}.
leg_create(CallId, LocalAddr, RemoteAddr, Flow) ->
    gen_server:call(?MODULE, {leg_create, CallId, LocalAddr, RemoteAddr, Flow}).

-spec leg_destroy(integer()) -> ok.
leg_destroy(LegH) ->
    gen_server:cast(?MODULE, {leg_destroy, LegH}).

-spec finish_txn(integer()) -> ok.
finish_txn(TxnH) ->
    gen_server:cast(?MODULE, {finish_txn, TxnH}).

%% Originate a request to a registered WS UA over its Flow. We add the top
%% Via (no nta here to do it) and match the response by our branch. Returns
%% a WS-range client transaction handle; {op_ok, TxnH} follows.
-spec send_request(integer(), binary(), pid()) ->
    {ok, integer()} | {error, term()}.
send_request(Flow, Raw, Pid) ->
    gen_server:call(?MODULE, {send_request, Flow, Raw, Pid}).

%% Fire-and-forget send over a Flow (ACK to a 2xx). No response expected.
-spec send_stateless(integer(), binary()) -> ok.
send_stateless(Flow, Raw) ->
    gen_server:cast(?MODULE, {send_stateless, Flow, Raw}).

%% CANCEL an outstanding WS client INVITE transaction.
-spec cancel(integer()) -> ok.
cancel(TxnH) ->
    cancel(TxnH, <<>>).

%% Headers: a CRLF-joined blob added to the CANCEL (a Reason, RFC 3326).
-spec cancel(integer(), binary()) -> ok.
cancel(TxnH, Headers) ->
    gen_server:cast(?MODULE, {cancel, TxnH, Headers}).

%% ---- gen_server ----

-spec init([]) -> {ok, #state{}}.
init([]) ->
    {ok, #state{counter = counter_ref()}}.

%% A VM-global monotonic counter so a transport restart never reuses a handle
%% that still lingers in the engine's (surviving) handle map.
counter_ref() ->
    case persistent_term:get({?MODULE, counter}, undefined) of
        undefined ->
            Ref = atomics:new(1, [{signed, false}]),
            persistent_term:put({?MODULE, counter}, Ref),
            Ref;
        Ref ->
            Ref
    end.

-spec handle_call(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}}.
handle_call({connect, Conn, Peer, Proto}, _From, S) ->
    case map_size(S#state.conns) >= chappe_sip_config:get(max_ws_connections) of
        true ->
            {reply, {error, too_many_connections}, S};
        false ->
            {Flow, S1} = chappe_sip_ws_txn:alloc(S),
            Ref = erlang:monitor(process, Conn),
            {reply, {ok, Flow}, S1#state{
                conns = (S1#state.conns)#{Flow => {Conn, Peer, Proto}},
                mons = (S1#state.mons)#{Ref => Flow}
            }}
    end;
handle_call({respond, TxnH, Status, Reason, Hdrs, Body, ToTag, Rel}, _From, S) ->
    case chappe_sip_ws_txn:proceeding(TxnH, S) of
        {ok, T} ->
            {Reply, S1} = respond_txn(
                TxnH, T, {Status, Reason, Hdrs, Body, ToTag, Rel}, S
            ),
            {reply, Reply, S1};
        Err ->
            {reply, Err, S}
    end;
handle_call({relay, TxnH, Status, Raw}, _From, S) ->
    case chappe_sip_ws_txn:proceeding(TxnH, S) of
        {ok, #{flow := Flow} = T} ->
            case chappe_sip_ws_txn:send(Flow, Raw, S) of
                ok -> {reply, ok, sent(TxnH, T, Status, Raw, false, S)};
                Err -> {reply, Err, S}
            end;
        Err ->
            {reply, Err, S}
    end;
handle_call({send_request, Flow, Raw, Pid}, _From, S) ->
    case chappe_sip_ws_txn:conn(Flow, S) of
        {_Conn, _Peer, Proto} ->
            {Reply, S1} = chappe_sip_ws_ctxn:originate(
                Flow, Proto, Raw, Pid, S
            ),
            {reply, Reply, S1};
        undefined ->
            {reply, {error, no_flow}, S}
    end;
handle_call({leg_create, CallId, LocalAddr, RemoteAddr, Flow}, _From, S) ->
    {LegH, S1} = chappe_sip_ws_txn:add_leg(
        CallId, LocalAddr, RemoteAddr, Flow, S
    ),
    %% confirm asynchronously, like the NIF's {op_ok, LegH}
    chappe_sip_ws_txn:engine_event({op_ok, LegH}),
    {reply, {ok, LegH}, S1};
handle_call(_Req, _From, S) ->
    {reply, {error, badcall}, S}.

-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.
handle_cast({incoming, Flow, Raw}, S) ->
    case drop_incoming(Raw) of
        true ->
            % oversize frame or transport saturated: drop
            {noreply, S};
        false ->
            {noreply, ingest(Flow, Raw, S)}
    end;
handle_cast({finish_txn, TxnH}, S) ->
    %% the owner is done with the handle. A completed INVITE server
    %% transaction still absorbs its ACK and retransmissions until Timer H.
    S1 =
        case S#state.stxn of
            #{TxnH := #{state := completed}} -> S;
            _ -> chappe_sip_ws_txn:drop_stxn(TxnH, S)
        end,
    {noreply, chappe_sip_ws_txn:drop_ctxn(TxnH, S1)};
handle_cast({send_stateless, Flow, Raw}, S) ->
    %% A UAC-built request (e.g. a 2xx ACK) carries no Via; the transport adds
    %% it, as send_request does. A forwarded request already has one - leave it.
    _ = chappe_sip_ws_txn:send(
        Flow,
        chappe_sip_ws_msg:ensure_via(Raw, chappe_sip_ws_txn:proto_of(Flow, S)),
        S
    ),
    {noreply, S};
handle_cast({cancel, TxnH, Hdrs}, S) ->
    {noreply, chappe_sip_ws_ctxn:cancel(TxnH, Hdrs, S)};
handle_cast({leg_destroy, LegH}, S) ->
    {noreply, chappe_sip_ws_txn:drop_leg(LegH, S)};
handle_cast({disconnect, Flow}, S) ->
    {noreply, drop_flow(Flow, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.
handle_info({timeout, TRef, {ctxn_b, TxnH}}, S) ->
    Fired = chappe_sip_ws_txn:fired(TxnH, timer, TRef, S#state.ctxn),
    {noreply, chappe_sip_ws_ctxn:timer_b(TxnH, Fired, S)};
handle_info({timeout, TRef, {ctxn_c, TxnH}}, S) ->
    Fired = chappe_sip_ws_txn:fired(TxnH, timer, TRef, S#state.ctxn),
    {noreply, chappe_sip_ws_ctxn:timer_c(TxnH, Fired, S)};
handle_info({timeout, TRef, {stxn, TxnH}}, S) ->
    Fired = chappe_sip_ws_txn:fired(TxnH, timer, TRef, S#state.stxn),
    {noreply, timer_stxn(TxnH, Fired, S)};
handle_info({timeout, TRef, {progress, TxnH}}, S) ->
    Fired = chappe_sip_ws_txn:fired(TxnH, progress, TRef, S#state.stxn),
    {noreply, timer_progress(TxnH, Fired, S)};
handle_info({timeout, TRef, {ack_wait, Key}}, S) ->
    Fired = chappe_sip_ws_txn:ack_wait_fired(Key, TRef, S),
    {noreply, timer_ack_wait(Key, Fired, S)};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, S) ->
    case maps:take(Ref, S#state.mons) of
        {Flow, Mons1} -> {noreply, drop_flow(Flow, S#state{mons = Mons1})};
        error -> {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%% ---- timers ----

timer_stxn(TxnH, {ok, #{state := proceeding} = T}, S) ->
    reap(TxnH, T, S);
timer_stxn(TxnH, {ok, _T}, S) ->
    %% Timer H: the ACK of our non-2xx final never came
    chappe_sip_ws_txn:drop_stxn(TxnH, S);
timer_stxn(_TxnH, stale, S) ->
    S.

timer_progress(TxnH, {ok, #{state := proceeding, flow := Flow} = T}, S) ->
    %% RFC 3261 13.3.1.1: the last non-100 provisional, once more
    _ = chappe_sip_ws_txn:send(Flow, maps:get(last, T), S),
    chappe_sip_ws_txn:put_stxn(
        TxnH, chappe_sip_ws_txn:arm_progress(TxnH, T), S
    );
timer_progress(_TxnH, _Fired, S) ->
    S.

timer_ack_wait(Key, {ok, S1}, _S) ->
    %% RFC 3261 13.3.1.4: our 2xx was never ACKed; the dialog BYEs
    case maps:get(Key, S1#state.leg_ix, undefined) of
        undefined -> ok;
        LegH -> chappe_sip_ws_txn:engine_event({ack_timeout, LegH})
    end,
    S1;
timer_ack_wait(_Key, stale, S) ->
    S.

%% ---- inbound routing ----

%% Shed an inbound frame that is oversize, or has arrived while the transport
%% mailbox is already saturated (a flood of frames must not grow it without
%% bound). The mailbox check is cheap and covers all pending messages.
drop_incoming(Raw) ->
    byte_size(Raw) > chappe_sip_config:get(max_message_size) orelse
        mailbox_saturated().

mailbox_saturated() ->
    {message_queue_len, N} = process_info(self(), message_queue_len),
    N >= chappe_sip_config:get(ws_transport_max_mailbox).

%% Parse and route one inbound frame. A malformed or unroutable frame never
%% takes the (singleton) transport down: an unauthenticated peer must not be
%% able to crash it and close every other WS session. A request that cannot
%% be processed (a mandatory header missing, a bad Content-Length) is
%% answered 400; a bad response is dropped. The try/catch backstops any other
%% parse/build failure.
ingest(Flow, <<"\r\n\r\n">>, S) ->
    %% RFC 5626 4.4.1 keepalive ping: answer the pong
    _ = chappe_sip_ws_txn:send(Flow, <<"\r\n">>, S),
    S;
ingest(_Flow, <<"\r\n">>, S) ->
    %% a keepalive pong
    S;
ingest(Flow, Raw, S) ->
    chappe_sip_ws_txn:capture(in, Flow, Raw, S),
    try
        case chappe_sip_msg:parse(Raw) of
            {ok, Msg} -> check_in(Flow, Msg, Raw, S);
            {error, _} -> S
        end
    catch
        Class:Reason:St ->
            logger:warning(
                "chappe_sip_ws: dropped bad frame on flow ~p: ~p:~p~n~p",
                [Flow, Class, Reason, St]
            ),
            S
    end.

check_in(Flow, Msg, Raw, S) ->
    Problem =
        case chappe_sip_msg:validate(Msg) of
            ok -> chappe_sip_ws_msg:content_length(Msg);
            {error, _} -> <<"Missing Mandatory Header">>
        end,
    case {Problem, chappe_sip_msg:type(Msg)} of
        {ok, _} ->
            route_in(Flow, Msg, Raw, S);
        {Why, request} ->
            %% RFC 3261 8.2.2 / 18.3: answer what cannot be processed
            reply(Flow, Msg, 400, Why, S),
            S;
        {_, response} ->
            S
    end.

route_in(Flow, Msg, Raw, S) ->
    case chappe_sip_msg:type(Msg) of
        request -> route_request(Flow, Msg, Raw, S);
        response -> route_response(Msg, Raw, S)
    end.

%% a response to a request we originated over WS: match our Via branch to
%% the client transaction and deliver it to the UAC.
route_response(Msg, Raw, S) ->
    Branch = chappe_sip_ws_msg:via_branch(Msg),
    case maps:get(Branch, S#state.cbranch_ix, undefined) of
        undefined ->
            S;
        TxnH ->
            case {S#state.ctxn, chappe_sip_ws_msg:cseq_method(Msg)} of
                {_, <<"CANCEL">>} ->
                    %% the answer to our CANCEL (same branch): ours to absorb
                    S;
                {#{TxnH := Ct}, _} ->
                    Status = chappe_sip_msg:status(Msg),
                    chappe_sip_ws_ctxn:response(TxnH, Ct, Status, Msg, Raw, S);
                _ ->
                    S
            end
    end.

route_request(Flow, Msg, Raw, S) ->
    Branch = chappe_sip_ws_msg:via_branch(Msg),
    case chappe_sip_msg:method(Msg) of
        <<"ACK">> ->
            route_ack(Flow, Msg, Raw, Branch, S);
        <<"CANCEL">> ->
            route_cancel(Flow, Msg, Branch, S);
        Method ->
            case
                maps:get({Flow, Branch, Method}, S#state.branch_ix, undefined)
            of
                undefined when Method =:= <<"PRACK">> ->
                    route_prack(Flow, Msg, Raw, Branch, S);
                undefined ->
                    new_server_txn(Flow, Msg, Raw, Branch, Method, S);
                TxnH ->
                    retransmission(TxnH, S)
            end
    end.

%% RFC 3261 17.2.1 / 17.2.2: a retransmitted request gets the last response
%% sent on its transaction again (nothing when none went out yet).
retransmission(TxnH, S) ->
    case S#state.stxn of
        #{TxnH := #{flow := Flow, last := Last}} when is_binary(Last) ->
            _ = chappe_sip_ws_txn:send(Flow, Last, S),
            S;
        _ ->
            S
    end.

new_server_txn(Flow, Msg, Raw, Branch, Method, S) ->
    LegH = chappe_sip_ws_txn:match_leg(Msg, S),
    {TxnH, S1} = chappe_sip_ws_txn:add_stxn(Flow, Msg, Branch, Method, S),
    S2 =
        case Method of
            <<"INVITE">> ->
                %% RFC 3261 17.2.1: 100 Trying for a new INVITE transaction
                T = maps:get(TxnH, S1#state.stxn),
                {_, S3} = respond_txn(
                    TxnH, T, {100, <<>>, <<>>, <<>>, <<>>, false}, S1
                ),
                S3;
            _ ->
                S1
        end,
    %% transport as the native engine names it (<<"ws">> or <<"wss">>),
    %% for what decides on the transport a request came over
    Meta = #{
        method => Method,
        flow => Flow,
        peer => chappe_sip_ws_txn:peer_of(Flow, S2),
        transport => atom_to_binary(chappe_sip_ws_txn:proto_of(Flow, S2))
    },
    chappe_sip_ws_txn:engine_event({request, TxnH, LegH, Meta, Raw}),
    S2.

%% The ACK of a non-2xx final shares the INVITE's branch and ends its
%% transaction (Timer I is zero on a reliable transport). Any other ACK is
%% for a 2xx: it ends the ACK wait and goes to the dialog leg, or, with no
%% leg, up tagged with the arrival Flow so the engine's proxy ACK handler can
%% forward a record-routed ACK over WS.
route_ack(Flow, Msg, Raw, Branch, S) ->
    case maps:get({Flow, Branch, <<"INVITE">>}, S#state.branch_ix, undefined) of
        undefined ->
            Key = {
                chappe_sip_msg:call_id(Msg),
                chappe_sip_msg:to_tag(Msg),
                chappe_sip_msg:from_tag(Msg)
            },
            S1 = chappe_sip_ws_txn:end_ack_wait(Key, S),
            case chappe_sip_ws_txn:match_leg(Msg, S1) of
                undefined -> chappe_sip_ws_txn:engine_event({ack, Flow, Raw});
                LegH -> chappe_sip_ws_txn:engine_event({ack, LegH, Raw})
            end,
            S1;
        TxnH ->
            case S#state.stxn of
                #{TxnH := #{state := completed}} ->
                    chappe_sip_ws_txn:drop_stxn(TxnH, S);
                _ ->
                    S
            end
    end.

%% RFC 3261 9.2: a CANCEL matching a transaction is answered 200; an INVITE
%% still proceeding is then answered 487 here, as nta does, and its owner is
%% told so it stops. A CANCEL matching nothing gets 481.
route_cancel(Flow, Msg, Branch, S) ->
    case chappe_sip_ws_txn:find_cancelled(Flow, Branch, S) of
        undefined ->
            reply(Flow, Msg, 481, <<>>, S),
            S;
        {InvTxnH, #{method := <<"INVITE">>, state := proceeding} = T} ->
            %% 9.2: the 200 and the 487 carry the same To-tag
            {Tag, T1} = chappe_sip_ws_txn:local_tag(<<>>, 487, T),
            reply(Flow, Msg, 200, <<>>, Tag, S),
            chappe_sip_ws_txn:engine_event(
                {cancel, InvTxnH, iolist_to_binary(chappe_sip_msg:encode(Msg))}
            ),
            {_, S1} = respond_txn(
                InvTxnH, T1, {487, <<>>, <<>>, <<>>, Tag, false}, S
            ),
            S1;
        {_TxnH, T} ->
            %% a final already went out (or not an INVITE): no effect
            reply(Flow, Msg, 200, <<>>, maps:get(tag, T, <<>>), S),
            S
    end.

%% RFC 3262 4: a PRACK matches the reliable provisional its RAck names (the
%% RSeq, and the CSeq of the INVITE). A PRACK for nothing outstanding gets
%% 481; one without RAck, 400.
route_prack(Flow, Msg, Raw, Branch, S) ->
    case chappe_sip_ws_msg:rack(Msg) of
        {ok, RSeq, CSeq} ->
            CallId = chappe_sip_msg:call_id(Msg),
            case chappe_sip_ws_txn:find_rel(Flow, CallId, CSeq, RSeq, S) of
                {ok, InvH, T} ->
                    prack_matched(Flow, Msg, Raw, Branch, InvH, T, RSeq, S);
                error ->
                    reply(Flow, Msg, 481, <<>>, S),
                    S
            end;
        error ->
            reply(Flow, Msg, 400, <<"Missing RAck">>, S),
            S
    end.

prack_matched(Flow, Msg, Raw, Branch, InvH, T, RSeq, S) ->
    HasBody = chappe_sip_msg:body(Msg) =/= <<>>,
    Offer = maps:get(rel_offer, T, 0),
    T1 = T#{rel_acked => RSeq},
    S1 = chappe_sip_ws_txn:put_stxn(InvH, T1, S),
    case HasBody andalso Offer =/= 1 of
        true ->
            %% an offer in the PRACK (RFC 3262 5): the INVITE's owner answers
            %% it on the PRACK's own transaction
            {PrackH, S2} = chappe_sip_ws_txn:add_stxn(
                Flow, Msg, Branch, <<"PRACK">>, S1
            ),
            chappe_sip_ws_txn:engine_event({prack, InvH, Raw, PrackH}),
            S2;
        false ->
            %% the answer to the offer of our reliable 1xx, or no body
            reply(Flow, Msg, 200, <<>>, S1),
            T2 =
                case HasBody of
                    true -> T1#{rel_offer => 2};
                    false -> T1
                end,
            chappe_sip_ws_txn:engine_event({prack, InvH, Raw}),
            chappe_sip_ws_txn:put_stxn(InvH, T2, S1)
    end.

%% ---- server transaction responses ----

respond_txn(TxnH, T, {Status, Reason, Hdrs, Body, ToTag0, Rel}, S) ->
    #{flow := Flow, msg := Msg} = T,
    {Tag, T1} = chappe_sip_ws_txn:local_tag(ToTag0, Status, T),
    case chappe_sip_ws_txn:reliable(Rel, Status, Body, T1) of
        {error, _} = Err ->
            {Err, S};
        {Extra, T2} ->
            Raw = chappe_sip_ws_msg:build_response(
                Msg,
                Status,
                Reason,
                [Hdrs, Extra],
                Body,
                Tag,
                chappe_sip_ws_txn:peer_of(Flow, S)
            ),
            case chappe_sip_ws_txn:send(Flow, Raw, S) of
                ok -> {ok, sent(TxnH, T2, Status, Raw, true, S)};
                Err -> {Err, S}
            end
    end.

%% The transaction after a response went out. A provisional is kept as the
%% answer to a retransmission. A non-2xx final to an INVITE waits for its
%% ACK (Timer H, 64*T1); a 2xx ends the INVITE transaction (RFC 3261
%% 17.2.1) and, for our own 2xx (AckWait), the dialog waits for the ACK
%% (13.3.1.4). A final to anything else ends it (Timer J is zero).
sent(TxnH, #{method := <<"INVITE">>} = T, Status, Raw, _AckWait, S) when
    Status > 100, Status < 200
->
    chappe_sip_ws_txn:put_stxn(
        TxnH, chappe_sip_ws_txn:arm_progress(TxnH, T#{last => Raw}), S
    );
sent(TxnH, T, Status, Raw, _AckWait, S) when Status < 200 ->
    chappe_sip_ws_txn:put_stxn(TxnH, T#{last => Raw}, S);
sent(TxnH, #{method := <<"INVITE">>} = T, Status, Raw, _AckWait, S) when
    Status >= 300
->
    chappe_sip_ws_txn:cancel_timer(maps:get(timer, T)),
    chappe_sip_ws_txn:cancel_timer(maps:get(progress, T, undefined)),
    TRef = chappe_sip_ws_txn:start_timer(ws_ack_timeout_ms, {stxn, TxnH}),
    T1 = maps:remove(progress, T#{
        state => completed, last => Raw, timer => TRef
    }),
    chappe_sip_ws_txn:put_stxn(TxnH, T1, S);
sent(TxnH, #{method := <<"INVITE">>, msg := Msg} = T, _Status, _Raw, true, S) ->
    chappe_sip_ws_txn:arm_ack_wait(
        Msg, maps:get(tag, T, undefined), chappe_sip_ws_txn:drop_stxn(TxnH, S)
    );
sent(TxnH, _T, _Status, _Raw, _AckWait, S) ->
    chappe_sip_ws_txn:drop_stxn(TxnH, S).

%% A server transaction the app never answered: 408 to an INVITE (its
%% client gives up at Timer C), 500 to anything else, rather than leave the
%% client to time out.
reap(TxnH, #{method := Method} = T, S) ->
    logger:info("chappe_sip_ws: server transaction ~p timed out", [TxnH]),
    Status =
        case Method of
            <<"INVITE">> -> 408;
            _ -> 500
        end,
    case respond_txn(TxnH, T, {Status, <<>>, <<>>, <<>>, <<>>, false}, S) of
        {ok, S1} -> S1;
        {_, S1} -> chappe_sip_ws_txn:drop_stxn(TxnH, S1)
    end.

%% a stateless answer to a request that gets no transaction (400, 481, the
%% 200 to a CANCEL or a PRACK)
reply(Flow, Msg, Status, Reason, S) ->
    reply(Flow, Msg, Status, Reason, <<>>, S).

reply(Flow, Msg, Status, Reason, Tag, S) ->
    Raw = chappe_sip_ws_msg:build_response(
        Msg, Status, Reason, <<>>, <<>>, Tag, chappe_sip_ws_txn:peer_of(Flow, S)
    ),
    _ = chappe_sip_ws_txn:send(Flow, Raw, S),
    ok.

%% ---- connections ----

drop_flow(Flow, S) ->
    %% the flow is the only path to a WS UA (RFC 5626): drop its registration
    chappe_sip_registry:remove_flow(Flow),
    {Lost, S1} = chappe_sip_ws_txn:drop_flow(Flow, S),
    %% the dialogs of these legs can no longer reach their peer
    _ =
        case Lost of
            [] -> ok;
            _ -> chappe_sip_ws_txn:engine_event({flow_lost, Lost})
        end,
    S1.
