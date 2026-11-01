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
%% the WS frame type a SIP message goes out in (RFC 7118 4.2)
-export([frame/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(s, {
    % persistent monotonic handle source
    counter :: term(),
    % Flow => {Conn, Peer, ws | wss}
    conns = #{} :: #{integer() => {pid(), term(), ws | wss}},
    % Conn monitor => Flow
    mons = #{} :: #{reference() => integer()},
    % ServerTxnH => #{flow,branch,method,msg,state,timer,last,tag,...}
    stxn = #{} :: #{integer() => map()},
    %% {Flow, Branch, Method} => ServerTxnH (a branch is unique only within
    %% a flow, and the method is part of the match, RFC 3261 17.2.3)
    branch_ix = #{} :: #{{integer(), binary(), binary()} => integer()},
    % ClientTxnH => #{flow,branch,pid,req,method,timer,prov,final,cancel}
    ctxn = #{} :: #{integer() => map()},
    % our Via branch => ClientTxnH
    cbranch_ix = #{} :: #{binary() => integer()},
    % LegH => #{flow,call_id,ltag,rtag}
    legs = #{} :: #{integer() => map()},
    % {CallId,LTag,RTag} => LegH
    leg_ix = #{} :: #{term() => integer()},
    %% {CallId,LTag,RTag} => TRef: our 2xx to an INVITE waiting for its ACK
    ackw = #{} :: #{term() => reference()}
}).

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

%% RFC 7118 4.2: a SIP message goes out in a text frame when it is valid
%% UTF-8 and in a binary frame otherwise (a binary body, say).
-spec frame(binary()) -> {text | binary, binary()}.
frame(Raw) ->
    case unicode:characters_to_binary(Raw) of
        Raw -> {text, Raw};
        _ -> {binary, Raw}
    end.

%% ---- gen_server ----

init([]) ->
    {ok, #s{counter = counter_ref()}}.

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

handle_call({connect, Conn, Peer, Proto}, _From, S) ->
    case map_size(S#s.conns) >= chappe_sip_config:get(max_ws_connections) of
        true ->
            {reply, {error, too_many_connections}, S};
        false ->
            {Flow, S1} = alloc(S),
            Ref = erlang:monitor(process, Conn),
            {reply, {ok, Flow}, S1#s{
                conns = (S1#s.conns)#{Flow => {Conn, Peer, Proto}},
                mons = (S1#s.mons)#{Ref => Flow}
            }}
    end;
handle_call({respond, TxnH, Status, Reason, Hdrs, Body, ToTag, Rel}, _From, S) ->
    case S#s.stxn of
        #{TxnH := #{state := proceeding} = T} ->
            {Reply, S1} = respond_txn(
                TxnH, T, {Status, Reason, Hdrs, Body, ToTag, Rel}, S
            ),
            {reply, Reply, S1};
        #{TxnH := _} ->
            {reply, {error, transaction_completed}, S};
        _ ->
            {reply, {error, unknown_transaction}, S}
    end;
handle_call({relay, TxnH, Status, Raw}, _From, S) ->
    case S#s.stxn of
        #{TxnH := #{state := proceeding, flow := Flow} = T} ->
            case send(Flow, Raw, S) of
                ok -> {reply, ok, sent(TxnH, T, Status, Raw, false, S)};
                Err -> {reply, Err, S}
            end;
        #{TxnH := _} ->
            {reply, {error, transaction_completed}, S};
        _ ->
            {reply, {error, unknown_transaction}, S}
    end;
handle_call({send_request, Flow, Raw, Pid}, _From, S) ->
    case S#s.conns of
        #{Flow := {_Conn, _Peer, Proto}} ->
            originate(Flow, Proto, Raw, Pid, S);
        _ ->
            {reply, {error, no_flow}, S}
    end;
handle_call({leg_create, CallId, LocalAddr, RemoteAddr, Flow}, _From, S) ->
    {LegH, S1} = alloc(S),
    LTag = tag_of(LocalAddr),
    RTag = tag_of(RemoteAddr),
    Leg = #{flow => Flow, call_id => CallId, ltag => LTag, rtag => RTag},
    S2 = S1#s{
        legs = (S1#s.legs)#{LegH => Leg},
        leg_ix = (S1#s.leg_ix)#{{CallId, LTag, RTag} => LegH}
    },
    %% confirm asynchronously, like the NIF's {op_ok, LegH}
    engine_event({op_ok, LegH}),
    {reply, {ok, LegH}, S2};
handle_call(_Req, _From, S) ->
    {reply, {error, badcall}, S}.

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
        case S#s.stxn of
            #{TxnH := #{state := completed}} -> S;
            _ -> drop_stxn(TxnH, S)
        end,
    {noreply, drop_ctxn(TxnH, S1)};
handle_cast({send_stateless, Flow, Raw}, S) ->
    %% A UAC-built request (e.g. a 2xx ACK) carries no Via; the transport adds
    %% it, as send_request does. A forwarded request already has one - leave it.
    _ = send(Flow, ensure_via(Raw, proto_of(Flow, S)), S),
    {noreply, S};
handle_cast({cancel, TxnH, Hdrs}, S) ->
    case S#s.ctxn of
        #{TxnH := #{final := true}} ->
            {noreply, S};
        #{TxnH := #{cancel := sent}} ->
            {noreply, S};
        #{TxnH := #{prov := true} = Ct} ->
            {noreply, send_cancel(TxnH, Ct, Hdrs, S)};
        #{TxnH := Ct} ->
            %% RFC 3261 9.1: no CANCEL before a provisional arrived; hold it
            {noreply, put_ctxn(TxnH, Ct#{cancel => {pending, Hdrs}}, S)};
        _ ->
            {noreply, S}
    end;
handle_cast({leg_destroy, LegH}, S) ->
    {noreply, drop_leg(LegH, S)};
handle_cast({disconnect, Flow}, S) ->
    {noreply, drop_flow(Flow, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({timeout, TRef, {ctxn_b, TxnH}}, S) ->
    case S#s.ctxn of
        #{TxnH := #{timer := TRef}} ->
            %% Timer B/F: no final arrived; fail the UAC leg and drop the
            %% client transaction
            engine_event({op_failed, TxnH, timeout}),
            {noreply, drop_ctxn(TxnH, S)};
        _ ->
            {noreply, S}
    end;
handle_info({timeout, TRef, {ctxn_c, TxnH}}, S) ->
    case S#s.ctxn of
        #{TxnH := #{timer := TRef} = Ct} ->
            %% Timer C (RFC 3261 16.6 step 11): a provisional came but no
            %% final; CANCEL, then give the final 64*T1 more (Timer B)
            Ct1 = Ct#{
                timer => start_timer(ws_client_txn_timeout_ms, {ctxn_b, TxnH})
            },
            S1 = put_ctxn(TxnH, Ct1, S),
            case maps:get(cancel, Ct1) of
                sent -> {noreply, S1};
                _ -> {noreply, send_cancel(TxnH, Ct1, <<>>, S1)}
            end;
        _ ->
            {noreply, S}
    end;
handle_info({timeout, TRef, {stxn, TxnH}}, S) ->
    case S#s.stxn of
        #{TxnH := #{timer := TRef, state := proceeding} = T} ->
            {noreply, reap(TxnH, T, S)};
        #{TxnH := #{timer := TRef}} ->
            %% Timer H: the ACK of our non-2xx final never came
            {noreply, drop_stxn(TxnH, S)};
        _ ->
            {noreply, S}
    end;
handle_info({timeout, TRef, {progress, TxnH}}, S) ->
    case S#s.stxn of
        #{TxnH := #{progress := TRef, state := proceeding, flow := Flow} = T} ->
            %% RFC 3261 13.3.1.1: the last non-100 provisional, once more
            _ = send(Flow, maps:get(last, T), S),
            {noreply, put_stxn(TxnH, arm_progress(TxnH, T), S)};
        _ ->
            {noreply, S}
    end;
handle_info({timeout, TRef, {ack_wait, Key}}, S) ->
    case S#s.ackw of
        #{Key := TRef} ->
            S1 = S#s{ackw = maps:remove(Key, S#s.ackw)},
            %% RFC 3261 13.3.1.4: our 2xx was never ACKed; the dialog BYEs
            case maps:get(Key, S1#s.leg_ix, undefined) of
                undefined -> ok;
                LegH -> engine_event({ack_timeout, LegH})
            end,
            {noreply, S1};
        _ ->
            {noreply, S}
    end;
handle_info({'DOWN', Ref, process, _Pid, _Reason}, S) ->
    case maps:take(Ref, S#s.mons) of
        {Flow, Mons1} -> {noreply, drop_flow(Flow, S#s{mons = Mons1})};
        error -> {noreply, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

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
    _ = send(Flow, <<"\r\n">>, S),
    S;
ingest(_Flow, <<"\r\n">>, S) ->
    %% a keepalive pong
    S;
ingest(Flow, Raw, S) ->
    capture(in, Flow, Raw, S),
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
            ok -> content_length(Msg);
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

%% RFC 3261 18.3 / 20.14: the body is what Content-Length says. A WS message
%% frames the SIP message, so the header may be absent; when present it is
%% one non-negative integer equal to the body size.
content_length(Msg) ->
    Size = byte_size(chappe_sip_msg:body(Msg)),
    case chappe_sip_msg:get_all(<<"content-length">>, Msg) of
        [] ->
            ok;
        [V] ->
            case string:to_integer(string:trim(V)) of
                {Size, <<>>} -> ok;
                _ -> <<"Bad Content-Length">>
            end;
        _ ->
            <<"Bad Content-Length">>
    end.

route_in(Flow, Msg, Raw, S) ->
    case chappe_sip_msg:type(Msg) of
        request -> route_request(Flow, Msg, Raw, S);
        response -> route_response(Msg, Raw, S)
    end.

%% a response to a request we originated over WS: match our Via branch to
%% the client transaction and deliver it to the UAC.
route_response(Msg, Raw, S) ->
    case maps:get(via_branch(Msg), S#s.cbranch_ix, undefined) of
        undefined ->
            S;
        TxnH ->
            case {S#s.ctxn, cseq_method(Msg)} of
                {_, <<"CANCEL">>} ->
                    %% the answer to our CANCEL (same branch): ours to absorb
                    S;
                {#{TxnH := Ct}, _} ->
                    Status = chappe_sip_msg:status(Msg),
                    client_response(TxnH, Ct, Status, Msg, Raw, S);
                _ ->
                    S
            end
    end.

client_response(_TxnH, #{final := true}, Status, _Msg, _Raw, S) when
    Status < 200
->
    S;
client_response(TxnH, Ct, Status, _Msg, Raw, S) when Status < 200 ->
    engine_event({response, TxnH, #{status => Status}, Raw}),
    Ct1 =
        case maps:get(method, Ct) of
            <<"INVITE">> ->
                %% a provisional stops Timer B and (re)starts Timer C
                cancel_timer(maps:get(timer, Ct)),
                Ct#{
                    prov => true,
                    timer => start_timer(ws_timer_c_ms, {ctxn_c, TxnH})
                };
            _ ->
                Ct#{prov => true}
        end,
    S1 = put_ctxn(TxnH, Ct1, S),
    case maps:get(cancel, Ct1) of
        {pending, Hdrs} -> send_cancel(TxnH, Ct1, Hdrs, S1);
        _ -> S1
    end;
client_response(TxnH, Ct, Status, Msg, Raw, S) ->
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
            engine_event({response, TxnH, #{status => Status}, Raw}),
            cancel_timer(maps:get(timer, Ct)),
            put_ctxn(
                TxnH,
                Ct#{timer => undefined, final => true, cancel => sent},
                S
            )
    end.

route_request(Flow, Msg, Raw, S) ->
    Branch = via_branch(Msg),
    case chappe_sip_msg:method(Msg) of
        <<"ACK">> ->
            route_ack(Flow, Msg, Raw, Branch, S);
        <<"CANCEL">> ->
            route_cancel(Flow, Msg, Branch, S);
        Method ->
            case maps:get({Flow, Branch, Method}, S#s.branch_ix, undefined) of
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
    case S#s.stxn of
        #{TxnH := #{flow := Flow, last := Last}} when is_binary(Last) ->
            _ = send(Flow, Last, S),
            S;
        _ ->
            S
    end.

new_server_txn(Flow, Msg, Raw, Branch, Method, S) ->
    LegH = match_leg(Msg, S),
    {TxnH, S1} = add_stxn(Flow, Msg, Branch, Method, S),
    S2 =
        case Method of
            <<"INVITE">> ->
                %% RFC 3261 17.2.1: 100 Trying for a new INVITE transaction
                T = maps:get(TxnH, S1#s.stxn),
                {_, S3} = respond_txn(
                    TxnH, T, {100, <<>>, <<>>, <<>>, <<>>, false}, S1
                ),
                S3;
            _ ->
                S1
        end,
    Meta = #{method => Method, flow => Flow, peer => peer_of(Flow, S2)},
    engine_event({request, TxnH, LegH, Meta, Raw}),
    S2.

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
            <<>> -> S1#s.branch_ix;
            _ -> (S1#s.branch_ix)#{{Flow, Branch, Method} => TxnH}
        end,
    {TxnH, S1#s{stxn = (S1#s.stxn)#{TxnH => Txn}, branch_ix = Ix}}.

%% The ACK of a non-2xx final shares the INVITE's branch and ends its
%% transaction (Timer I is zero on a reliable transport). Any other ACK is
%% for a 2xx: it ends the ACK wait and goes to the dialog leg, or, with no
%% leg, up tagged with the arrival Flow so the engine's proxy ACK handler can
%% forward a record-routed ACK over WS.
route_ack(Flow, Msg, Raw, Branch, S) ->
    case maps:get({Flow, Branch, <<"INVITE">>}, S#s.branch_ix, undefined) of
        undefined ->
            Key = {
                chappe_sip_msg:call_id(Msg),
                chappe_sip_msg:to_tag(Msg),
                chappe_sip_msg:from_tag(Msg)
            },
            S1 =
                case maps:take(Key, S#s.ackw) of
                    {TRef, AckW} ->
                        cancel_timer(TRef),
                        S#s{ackw = AckW};
                    error ->
                        S
                end,
            case match_leg(Msg, S1) of
                undefined -> engine_event({ack, Flow, Raw});
                LegH -> engine_event({ack, LegH, Raw})
            end,
            S1;
        TxnH ->
            case S#s.stxn of
                #{TxnH := #{state := completed}} -> drop_stxn(TxnH, S);
                _ -> S
            end
    end.

%% RFC 3261 9.2: a CANCEL matching a transaction is answered 200; an INVITE
%% still proceeding is then answered 487 here, as nta does, and its owner is
%% told so it stops. A CANCEL matching nothing gets 481.
route_cancel(Flow, Msg, Branch, S) ->
    case find_cancelled(Flow, Branch, S) of
        undefined ->
            reply(Flow, Msg, 481, <<>>, S),
            S;
        {InvTxnH, #{method := <<"INVITE">>, state := proceeding} = T} ->
            %% 9.2: the 200 and the 487 carry the same To-tag
            {Tag, T1} = local_tag(<<>>, 487, T),
            reply(Flow, Msg, 200, <<>>, Tag, S),
            engine_event(
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

find_cancelled(_Flow, <<>>, _S) ->
    undefined;
find_cancelled(Flow, Branch, S) ->
    case maps:get({Flow, Branch, <<"INVITE">>}, S#s.branch_ix, undefined) of
        undefined ->
            Other = [
                H
             || {{F, B, _M}, H} <- maps:to_list(S#s.branch_ix),
                F =:= Flow,
                B =:= Branch
            ],
            case Other of
                [H | _] -> {H, maps:get(H, S#s.stxn)};
                [] -> undefined
            end;
        H ->
            {H, maps:get(H, S#s.stxn)}
    end.

%% RFC 3262 4: a PRACK matches the reliable provisional its RAck names (the
%% RSeq, and the CSeq of the INVITE). A PRACK for nothing outstanding gets
%% 481; one without RAck, 400.
route_prack(Flow, Msg, Raw, Branch, S) ->
    case rack(Msg) of
        {ok, RSeq, CSeq} ->
            CallId = chappe_sip_msg:call_id(Msg),
            case find_rel(Flow, CallId, CSeq, RSeq, S) of
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
    S1 = S#s{stxn = (S#s.stxn)#{InvH => T1}},
    case HasBody andalso Offer =/= 1 of
        true ->
            %% an offer in the PRACK (RFC 3262 5): the INVITE's owner answers
            %% it on the PRACK's own transaction
            {PrackH, S2} = add_stxn(Flow, Msg, Branch, <<"PRACK">>, S1),
            engine_event({prack, InvH, Raw, PrackH}),
            S2;
        false ->
            %% the answer to the offer of our reliable 1xx, or no body
            reply(Flow, Msg, 200, <<>>, S1),
            T2 =
                case HasBody of
                    true -> T1#{rel_offer => 2};
                    false -> T1
                end,
            engine_event({prack, InvH, Raw}),
            S1#s{stxn = (S1#s.stxn)#{InvH => T2}}
    end.

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
            } = T} <- maps:to_list(S#s.stxn),
        F =:= Flow,
        RSeq =< Sent,
        RSeq > maps:get(rel_acked, T, 0),
        chappe_sip_msg:call_id(M) =:= CallId,
        req_seq(M) =:= CSeq
    ],
    case Found of
        [{H, T} | _] -> {ok, H, T};
        [] -> error
    end.

rack(Msg) ->
    case chappe_sip_msg:get(<<"rack">>, Msg) of
        undefined ->
            error;
        V ->
            case
                binary:split(string:trim(V), [<<" ">>, <<"\t">>], [
                    global, trim_all
                ])
            of
                [R, C, _Method] ->
                    try
                        {ok, binary_to_integer(R), binary_to_integer(C)}
                    catch
                        _:_ -> error
                    end;
                _ ->
                    error
            end
    end.

match_leg(Msg, S) ->
    case chappe_sip_msg:to_tag(Msg) of
        undefined ->
            undefined;
        ToTag ->
            CallId = chappe_sip_msg:call_id(Msg),
            FromTag = chappe_sip_msg:from_tag(Msg),
            maps:get({CallId, ToTag, FromTag}, S#s.leg_ix, undefined)
    end.

%% ---- server transaction responses ----

respond_txn(TxnH, T, {Status, Reason, Hdrs, Body, ToTag0, Rel}, S) ->
    #{flow := Flow, msg := Msg} = T,
    {Tag, T1} = local_tag(ToTag0, Status, T),
    case reliable(Rel, Status, Body, T1) of
        {error, _} = Err ->
            {Err, S};
        {Extra, T2} ->
            Raw = build_response(
                Msg, Status, Reason, [Hdrs, Extra], Body, Tag, peer_of(Flow, S)
            ),
            case send(Flow, Raw, S) of
                ok -> {ok, sent(TxnH, T2, Status, Raw, true, S)};
                Err -> {Err, S}
            end
    end.

%% RFC 3261 8.2.6.2: every response of a transaction but the 100 carries the
%% same To-tag; one is minted on the first that needs it unless the caller
%% names it.
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
reliable(true, Status, Body, #{method := <<"INVITE">>, msg := Msg} = T) when
    Status > 100, Status < 200
->
    case peer_100rel(Msg) of
        false ->
            {<<>>, T};
        true ->
            Offerless =
                maps:get(rel_offer, T, 0) =:= 0 andalso
                    chappe_sip_msg:body(Msg) =:= <<>>,
            case Offerless andalso Body =:= <<>> of
                true ->
                    {error, reliable_1xx_needs_offer};
                false ->
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
                    Extra = [
                        <<"Require: 100rel\r\nRSeq: ">>,
                        integer_to_binary(N),
                        <<"\r\n">>
                    ],
                    {Extra, T#{rseq => N, rel_offer => Offer}}
            end
    end;
reliable(_Rel, _Status, _Body, T) ->
    {<<>>, T}.

peer_100rel(Msg) ->
    Tokens = [
        string:lowercase(string:trim(Tok))
     || H <- [<<"supported">>, <<"require">>],
        V <- chappe_sip_msg:get_all(H, Msg),
        Tok <- binary:split(V, <<",">>, [global])
    ],
    lists:member(<<"100rel">>, Tokens).

%% The transaction after a response went out. A provisional is kept as the
%% answer to a retransmission. A non-2xx final to an INVITE waits for its
%% ACK (Timer H, 64*T1); a 2xx ends the INVITE transaction (RFC 3261
%% 17.2.1) and, for our own 2xx (AckWait), the dialog waits for the ACK
%% (13.3.1.4). A final to anything else ends it (Timer J is zero).
sent(TxnH, #{method := <<"INVITE">>} = T, Status, Raw, _AckWait, S) when
    Status > 100, Status < 200
->
    put_stxn(TxnH, arm_progress(TxnH, T#{last => Raw}), S);
sent(TxnH, T, Status, Raw, _AckWait, S) when Status < 200 ->
    put_stxn(TxnH, T#{last => Raw}, S);
sent(TxnH, #{method := <<"INVITE">>} = T, Status, Raw, _AckWait, S) when
    Status >= 300
->
    cancel_timer(maps:get(timer, T)),
    cancel_timer(maps:get(progress, T, undefined)),
    TRef = start_timer(ws_ack_timeout_ms, {stxn, TxnH}),
    T1 = maps:remove(progress, T#{
        state => completed, last => Raw, timer => TRef
    }),
    put_stxn(TxnH, T1, S);
sent(TxnH, #{method := <<"INVITE">>, msg := Msg} = T, _Status, _Raw, true, S) ->
    arm_ack_wait(Msg, maps:get(tag, T, undefined), drop_stxn(TxnH, S));
sent(TxnH, _T, _Status, _Raw, _AckWait, S) ->
    drop_stxn(TxnH, S).

%% (Re)start the 13.3.1.1 resend of the last provisional.
arm_progress(TxnH, T) ->
    cancel_timer(maps:get(progress, T, undefined)),
    case chappe_sip_config:get(ws_progress_ms) of
        infinity ->
            maps:remove(progress, T);
        Ms ->
            T#{progress => erlang:start_timer(Ms, self(), {progress, TxnH})}
    end.

put_stxn(TxnH, T, S) ->
    S#s{stxn = (S#s.stxn)#{TxnH => T}}.

arm_ack_wait(Msg, Tag, S) ->
    LTag =
        case chappe_sip_msg:to_tag(Msg) of
            undefined -> Tag;
            InDialog -> InDialog
        end,
    Key = {chappe_sip_msg:call_id(Msg), LTag, chappe_sip_msg:from_tag(Msg)},
    cancel_timer(maps:get(Key, S#s.ackw, undefined)),
    TRef = start_timer(ws_ack_timeout_ms, {ack_wait, Key}),
    S#s{ackw = (S#s.ackw)#{Key => TRef}}.

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
        {_, S1} -> drop_stxn(TxnH, S1)
    end.

%% a stateless answer to a request that gets no transaction (400, 481, the
%% 200 to a CANCEL or a PRACK)
reply(Flow, Msg, Status, Reason, S) ->
    reply(Flow, Msg, Status, Reason, <<>>, S).

reply(Flow, Msg, Status, Reason, Tag, S) ->
    Raw = build_response(
        Msg, Status, Reason, <<>>, <<>>, Tag, peer_of(Flow, S)
    ),
    _ = send(Flow, Raw, S),
    ok.

%% ---- client transactions ----

originate(Flow, Proto, Raw, Pid, S) ->
    {TxnH, S1} = alloc(S),
    Branch = new_branch(),
    Raw1 = insert_via(Raw, Proto, Branch),
    case send(Flow, Raw1, S1) of
        ok ->
            %% Timer B/F: no sofia timers here, so bound the wait for a
            %% response; an unanswered UAC leg (a browser that never
            %% replies) is cleaned up
            TRef = start_timer(ws_client_txn_timeout_ms, {ctxn_b, TxnH}),
            Ct = #{
                flow => Flow,
                branch => Branch,
                pid => Pid,
                req => Raw1,
                method => request_method(Raw1),
                timer => TRef,
                prov => false,
                final => false,
                cancel => none
            },
            S2 = S1#s{
                ctxn = (S1#s.ctxn)#{TxnH => Ct},
                cbranch_ix = (S1#s.cbranch_ix)#{Branch => TxnH}
            },
            engine_event({op_ok, TxnH}),
            {reply, {ok, TxnH}, S2};
        Err ->
            {reply, Err, S1}
    end.

put_ctxn(TxnH, Ct, S) ->
    S#s{ctxn = (S#s.ctxn)#{TxnH => Ct}}.

send_cancel(TxnH, #{flow := Flow, req := Req} = Ct, Hdrs, S) ->
    case build_cancel(Req, Hdrs) of
        {ok, Cancel} -> _ = send(Flow, Cancel, S);
        error -> ok
    end,
    put_ctxn(TxnH, Ct#{cancel => sent}, S).

%% RFC 3261 17.1.1.3: the ACK of a non-2xx final has the INVITE's Request-URI,
%% top Via (so its branch), From, Call-ID, CSeq number and Route, and the To
%% of the response.
send_ack(Flow, Req, Resp, S) ->
    case chappe_sip_msg:parse(Req) of
        {ok, M} ->
            Routes = [
                [<<"Route: ">>, R, <<"\r\n">>]
             || R <- chappe_sip_msg:get_all(<<"route">>, M)
            ],
            Ack = iolist_to_binary([
                <<"ACK ">>,
                chappe_sip_msg:uri(M),
                <<" SIP/2.0\r\nVia: ">>,
                chappe_sip_msg:get(<<"via">>, M),
                <<"\r\n">>,
                Routes,
                <<"Max-Forwards: 70\r\nFrom: ">>,
                chappe_sip_msg:get(<<"from">>, M),
                <<"\r\nTo: ">>,
                chappe_sip_msg:get(<<"to">>, Resp),
                <<"\r\nCall-ID: ">>,
                chappe_sip_msg:call_id(M),
                <<"\r\nCSeq: ">>,
                integer_to_binary(req_seq(M)),
                <<" ACK\r\nContent-Length: 0\r\n\r\n">>
            ]),
            send(Flow, Ack, S);
        {error, _} ->
            ok
    end.

%% ---- response building ----

%% Headers the request lacks are left out, so a request missing one can
%% still be answered 400 (RFC 3261 8.2.2).
build_response(ReqMsg, Status, Reason, Headers, Body, ToTag, Peer) ->
    Vias = chappe_sip_msg:get_all(<<"via">>, ReqMsg),
    To0 = chappe_sip_msg:get(<<"to">>, ReqMsg),
    %% RFC 3261 8.2.6.2: every response except 100 carries a To-tag. If the
    %% caller gave none (an error final via shed), mint one, as nta does on UDP.
    To =
        case chappe_sip_msg:to_tag(ReqMsg) of
            undefined when Status > 100, is_binary(To0) ->
                Tag =
                    case ToTag of
                        <<>> -> chappe_sip_dialog:gen_tag();
                        _ -> ToTag
                    end,
                <<To0/binary, ";tag=", Tag/binary>>;
            _ ->
                To0
        end,
    R =
        case Reason of
            <<>> -> reason(Status);
            _ -> Reason
        end,
    %% RFC 3261 18.2.1 / RFC 7118: stamp received/rport on the top Via
    ViaLines =
        case Vias of
            [Top | Rest] ->
                [
                    [<<"Via: ">>, add_received(Top, Peer), <<"\r\n">>]
                    | [[<<"Via: ">>, V, <<"\r\n">>] || V <- Rest]
                ];
            [] ->
                []
        end,
    iolist_to_binary(
        [
            <<"SIP/2.0 ">>,
            integer_to_binary(Status),
            <<" ">>,
            R,
            <<"\r\n">>,
            ViaLines,
            record_route(Status, ReqMsg, Headers),
            hdr(<<"From">>, chappe_sip_msg:get(<<"from">>, ReqMsg)),
            hdr(<<"To">>, To),
            hdr(<<"Call-ID">>, chappe_sip_msg:call_id(ReqMsg)),
            hdr(<<"CSeq">>, chappe_sip_msg:get(<<"cseq">>, ReqMsg)),
            Headers,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(Body)),
            <<"\r\n\r\n">>,
            Body
        ]
    ).

hdr(_Name, undefined) -> [];
hdr(Name, Value) -> [Name, <<": ">>, Value, <<"\r\n">>].

%% RFC 3261 12.1.1: a UAS copies the request's Record-Route into the
%% responses that can make a dialog (101-299), unless the caller already
%% put them in its headers.
record_route(Status, ReqMsg, Headers) when Status > 100, Status < 300 ->
    case
        binary:match(
            string:lowercase(iolist_to_binary(Headers)), <<"record-route:">>
        )
    of
        nomatch ->
            [
                [<<"Record-Route: ">>, RR, <<"\r\n">>]
             || RR <- chappe_sip_msg:get_all(<<"record-route">>, ReqMsg)
            ];
        _ ->
            []
    end;
record_route(_Status, _ReqMsg, _Headers) ->
    [].

%% ---- helpers ----

alloc(#s{counter = C} = S) ->
    N = atomics:add_get(C, 1, 1),
    {chappe_sip_ws:base() + N, S}.

%% Send one SIP message in one WS message (RFC 7118 5), refusing one past
%% max_message_size: the peer would refuse it, and it should not leave.
send(Flow, Raw, S) ->
    case S#s.conns of
        #{Flow := {Conn, Peer, Proto}} ->
            case byte_size(Raw) > chappe_sip_config:get(max_message_size) of
                true ->
                    {error, too_large};
                false ->
                    ws:send(Conn, frame(Raw)),
                    chappe_sip_hep:capture(out, Proto, Peer, Raw)
            end;
        _ ->
            {error, no_flow}
    end.

%% HEP capture of a message received on Flow (a no-op while capture is off)
capture(Dir, Flow, Raw, S) ->
    case S#s.conns of
        #{Flow := {_Conn, Peer, Proto}} ->
            chappe_sip_hep:capture(Dir, Proto, Peer, Raw);
        _ ->
            ok
    end.

peer_of(Flow, S) ->
    case S#s.conns of
        #{Flow := {_Conn, Peer, _Proto}} -> Peer;
        _ -> undefined
    end.

proto_of(Flow, S) ->
    case S#s.conns of
        #{Flow := {_Conn, _Peer, Proto}} -> Proto;
        _ -> ws
    end.

start_timer(Key, Msg) ->
    erlang:start_timer(chappe_sip_config:get(Key), self(), Msg).

drop_stxn(TxnH, S) ->
    case S#s.stxn of
        #{TxnH := #{flow := Flow, branch := Br, method := M} = T} ->
            cancel_timer(maps:get(timer, T, undefined)),
            cancel_timer(maps:get(progress, T, undefined)),
            S#s{
                stxn = maps:remove(TxnH, S#s.stxn),
                branch_ix = drop_ix({Flow, Br, M}, TxnH, S#s.branch_ix)
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

cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) ->
    ok.

drop_leg(LegH, S) ->
    case S#s.legs of
        #{LegH := #{call_id := C, ltag := L, rtag := R}} ->
            {TRef, AckW} =
                case maps:take({C, L, R}, S#s.ackw) of
                    error -> {undefined, S#s.ackw};
                    Taken -> Taken
                end,
            cancel_timer(TRef),
            S#s{
                legs = maps:remove(LegH, S#s.legs),
                leg_ix = maps:remove({C, L, R}, S#s.leg_ix),
                ackw = AckW
            };
        _ ->
            S
    end.

drop_flow(Flow, S) ->
    %% the flow is the only path to a WS UA (RFC 5626): drop its registration
    chappe_sip_registry:remove_flow(Flow),
    %% cancel the transaction timers of everything on this flow
    _ = [
        cancel_timer(maps:get(K, T, undefined))
     || T <- maps:values(S#s.stxn) ++ maps:values(S#s.ctxn),
        K <- [timer, progress],
        maps:get(flow, T, undefined) =:= Flow
    ],
    STxn = maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, S#s.stxn),
    CTxn = maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, S#s.ctxn),
    KeptCBranches = [B || #{branch := B} <- maps:values(CTxn)],
    Legs = maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, S#s.legs),
    %% the dialogs of these legs can no longer reach their peer
    _ =
        case maps:keys(S#s.legs) -- maps:keys(Legs) of
            [] -> ok;
            Lost -> engine_event({flow_lost, Lost})
        end,
    LegKeys = [
        {C, L, R}
     || #{call_id := C, ltag := L, rtag := R} <-
            maps:values(Legs)
    ],
    S#s{
        conns = maps:remove(Flow, S#s.conns),
        stxn = STxn,
        branch_ix = maps:filter(
            fun({F, _, _}, _) -> F =/= Flow end,
            S#s.branch_ix
        ),
        ctxn = CTxn,
        cbranch_ix = maps:with(KeptCBranches, S#s.cbranch_ix),
        legs = Legs,
        leg_ix = maps:with(LegKeys, S#s.leg_ix)
    }.

%% deliver an engine event as the NIF would ({chappe_sip_engine, ws, Event}).
%% Tolerate a briefly-absent engine (mid-restart): the registered-name send
%% would otherwise raise badarg and crash this transport, losing all WS state.
engine_event(Event) ->
    case whereis(chappe_sip_engine) of
        undefined ->
            ok;
        Pid ->
            Pid ! {chappe_sip_engine, ws, Event},
            ok
    end.

via_branch(Msg) ->
    case chappe_sip_msg:get(<<"via">>, Msg) of
        undefined ->
            <<>>;
        V ->
            case
                re:run(
                    V,
                    <<"branch=([^;\\s,]+)">>,
                    [{capture, [1], binary}]
                )
            of
                {match, [B]} -> B;
                _ -> <<>>
            end
    end.

cseq_method(Msg) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{method := M}} -> M;
        _ -> undefined
    end.

req_seq(Msg) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> N;
        _ -> 1
    end.

request_method(Raw) ->
    case binary:split(Raw, <<" ">>) of
        [Method, _] -> Method;
        _ -> <<>>
    end.

%% RFC 3261 18.2.1: add received when the sent-by host is not the source
%% address (a WS client's is a .invalid name, so in practice always); RFC
%% 3581 4: fill in rport, and add received, when the client asked with a
%% bare rport. An rport the client did not ask for is not added, and a
%% received or rport value it put there itself is replaced, never repeated.
add_received(Via, {IP, Port}) when is_tuple(IP), is_integer(Port) ->
    IPb = list_to_binary(inet:ntoa(IP)),
    [SentBy | Params] = binary:split(Via, <<";">>, [global]),
    Names = [param_name(P) || P <- Params],
    WantsRport = lists:member(<<"rport">>, Names),
    Kept = [
        P
     || P <- Params,
        not lists:member(param_name(P), [<<"received">>, <<"rport">>])
    ],
    Received =
        case WantsRport orelse sent_by_host(SentBy) =/= IPb of
            true -> [<<"received=", IPb/binary>>];
            false -> []
        end,
    Rport =
        case WantsRport of
            true -> [<<"rport=", (integer_to_binary(Port))/binary>>];
            false -> []
        end,
    iolist_to_binary(lists:join(<<";">>, [SentBy | Kept ++ Received ++ Rport]));
add_received(Via, _Peer) ->
    Via.

param_name(P) ->
    [Name | _] = binary:split(P, <<"=">>),
    string:lowercase(string:trim(Name)).

%% the host of "SIP/2.0/WS host[:port]" (an IPv6 reference keeps no brackets)
sent_by_host(SentBy) ->
    case
        binary:split(string:trim(SentBy), [<<" ">>, <<"\t">>], [
            global, trim_all
        ])
    of
        [_Proto, HostPort | _] ->
            case HostPort of
                <<"[", Rest/binary>> ->
                    hd(binary:split(Rest, <<"]">>));
                _ ->
                    hd(binary:split(HostPort, <<":">>))
            end;
        _ ->
            <<>>
    end.

%% CANCEL built from the original request: same top Via/branch, R-URI,
%% From, To (no to-tag), Call-ID, Route, CSeq number with method CANCEL.
build_cancel(Raw, Hdrs) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} ->
            RURI = chappe_sip_msg:uri(M),
            Via = chappe_sip_msg:get(<<"via">>, M),
            From = chappe_sip_msg:get(<<"from">>, M),
            To = chappe_sip_msg:get(<<"to">>, M),
            Call = chappe_sip_msg:call_id(M),
            Seq = integer_to_binary(req_seq(M)),
            Routes = iolist_to_binary([
                [<<"Route: ">>, R, <<"\r\n">>]
             || R <- chappe_sip_msg:get_all(<<"route">>, M)
            ]),
            {ok,
                <<"CANCEL ", RURI/binary, " SIP/2.0\r\n", "Via: ", Via/binary,
                    "\r\n", Routes/binary, "Max-Forwards: 70\r\n", "From: ",
                    From/binary, "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ",
                    Call/binary, "\r\n", "CSeq: ", Seq/binary, " CANCEL\r\n",
                    Hdrs/binary, "Content-Length: 0\r\n\r\n">>};
        {error, _} ->
            error
    end.

drop_ctxn(TxnH, S) ->
    case S#s.ctxn of
        #{TxnH := #{branch := Br} = Ct} ->
            cancel_timer(maps:get(timer, Ct, undefined)),
            S#s{
                ctxn = maps:remove(TxnH, S#s.ctxn),
                cbranch_ix = maps:remove(Br, S#s.cbranch_ix)
            };
        _ ->
            S
    end.

%% a stable-ish node identifier for our WS Via sent-by (RFC 7118 allows a
%% .invalid name; responses route by the connection, not by resolving it)
node_id() ->
    <<"chappe.invalid">>.

hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).

new_branch() ->
    <<"z9hG4bK", (hex(6))/binary>>.

%% Add a Via with a fresh branch after the request line, unless one is
%% already present. Used for UAC-built stateless requests (e.g. a 2xx ACK).
ensure_via(Raw, Proto) ->
    case binary:match(Raw, <<"\r\nVia:">>) of
        nomatch -> insert_via(Raw, Proto, new_branch());
        _ -> Raw
    end.

insert_via(Raw, Proto, Branch) ->
    T =
        case Proto of
            wss -> <<"WSS">>;
            _ -> <<"WS">>
        end,
    Via =
        <<"Via: SIP/2.0/", T/binary, " ", (node_id())/binary, ";branch=",
            Branch/binary, "\r\n">>,
    case binary:split(Raw, <<"\r\n">>) of
        [ReqLine, Rest] -> <<ReqLine/binary, "\r\n", Via/binary, Rest/binary>>;
        [_] -> <<Via/binary, Raw/binary>>
    end.

tag_of(NameAddr) ->
    case chappe_sip_hdr:name_addr(NameAddr) of
        {ok, #{params := P}} -> maps:get(<<"tag">>, P, <<>>);
        _ -> <<>>
    end.

reason(100) -> <<"Trying">>;
reason(180) -> <<"Ringing">>;
reason(183) -> <<"Session Progress">>;
reason(200) -> <<"OK">>;
reason(202) -> <<"Accepted">>;
reason(400) -> <<"Bad Request">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(408) -> <<"Request Timeout">>;
reason(481) -> <<"Call/Transaction Does Not Exist">>;
reason(486) -> <<"Busy Here">>;
reason(487) -> <<"Request Terminated">>;
reason(500) -> <<"Server Internal Error">>;
reason(503) -> <<"Service Unavailable">>;
reason(_) -> <<"OK">>.
