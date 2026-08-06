%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIP-over-WebSocket transport and transaction layer (Erlang).
%%
%% Terminates RFC 7118 WS connections (via chappe_sip_ws_conn) and gives them the
%% same engine event contract the sofia NIF uses, so all TU logic runs over
%% WS unchanged. WS is connection-oriented and TCP-reliable, so there are no
%% UDP-style retransmit timers: transaction matching is by branch (server
%% and client transactions) and by Call-ID + tags (dialog legs).
%%
%% Handles are allocated in the WS range (chappe_sip_ws:base()) so chappe_sip_engine can
%% multiplex operations back to this process by handle.
-module(chappe_sip_ws_transport).
-behaviour(gen_server).

-export([start_link/0]).
%% connection lifecycle (called by chappe_sip_ws_conn)
-export([connect/2, disconnect/1, incoming/2]).
%% engine op surface (called by chappe_sip_engine for WS handles)
-export([respond/6, relay/3, leg_create/4, leg_destroy/1, finish_txn/1]).
%% outbound-to-WS: originate a request/ACK to a registered WS UA over a flow
-export([send_request/3, send_stateless/2, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(s, {
    % persistent monotonic handle source
    counter :: term(),
    % Flow => {Conn, Peer}
    conns = #{} :: #{integer() => {pid(), term()}},
    % Conn monitor => Flow
    mons = #{} :: #{reference() => integer()},
    % ServerTxnH => #{flow,branch,method,msg}
    stxn = #{} :: #{integer() => map()},
    %% {Flow, Branch} => ServerTxnH (a branch is unique only within a flow)
    branch_ix = #{} :: #{{integer(), binary()} => integer()},
    % ClientTxnH => #{flow,branch,pid}
    ctxn = #{} :: #{integer() => map()},
    % our Via branch => ClientTxnH
    cbranch_ix = #{} :: #{binary() => integer()},
    % LegH => #{flow,call_id,ltag,rtag}
    legs = #{} :: #{integer() => map()},
    % {CallId,LTag,RTag} => LegH
    leg_ix = #{} :: #{term() => integer()}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% A new WS connection; returns its Flow id, or refuses at the connection cap.
-spec connect(pid(), term()) ->
    {ok, integer()} | {error, too_many_connections}.
connect(Conn, Peer) ->
    gen_server:call(?MODULE, {connect, Conn, Peer}).

-spec disconnect(integer()) -> ok.
disconnect(Flow) ->
    gen_server:cast(?MODULE, {disconnect, Flow}).

%% A SIP message text frame arrived on Flow.
-spec incoming(integer(), binary()) -> ok.
incoming(Flow, Raw) ->
    gen_server:cast(?MODULE, {incoming, Flow, Raw}).

%% ---- engine op surface (mirrors the chappe_sip_nif shapes, minus Engine) ----

-spec respond(integer(), 100..699, binary(), binary(), binary(), binary()) ->
    ok | {error, term()}.
respond(TxnH, Status, Reason, Headers, Body, ToTag) ->
    gen_server:call(
        ?MODULE, {respond, TxnH, Status, Reason, Headers, Body, ToTag}
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
    gen_server:cast(?MODULE, {cancel, TxnH}).

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

handle_call({connect, Conn, Peer}, _From, S) ->
    case map_size(S#s.conns) >= chappe_sip_config:get(max_ws_connections) of
        true ->
            {reply, {error, too_many_connections}, S};
        false ->
            {Flow, S1} = alloc(S),
            Ref = erlang:monitor(process, Conn),
            {reply, {ok, Flow}, S1#s{
                conns = (S1#s.conns)#{Flow => {Conn, Peer}},
                mons = (S1#s.mons)#{Ref => Flow}
            }}
    end;
handle_call({respond, TxnH, Status, Reason, Headers, Body, ToTag}, _From, S) ->
    case S#s.stxn of
        #{TxnH := #{flow := Flow, msg := Msg, branch := Br}} ->
            Raw = build_response(
                Msg,
                Status,
                Reason,
                Headers,
                Body,
                ToTag,
                peer_of(Flow, S)
            ),
            send(Flow, Raw, S),
            {reply, ok, maybe_drop_txn(Status, TxnH, Br, S)};
        _ ->
            {reply, {error, unknown_transaction}, S}
    end;
handle_call({relay, TxnH, Status, Raw}, _From, S) ->
    case S#s.stxn of
        #{TxnH := #{flow := Flow, branch := Br}} ->
            send(Flow, Raw, S),
            {reply, ok, maybe_drop_txn(Status, TxnH, Br, S)};
        _ ->
            {reply, {error, unknown_transaction}, S}
    end;
handle_call({send_request, Flow, Raw, Pid}, _From, S) ->
    case S#s.conns of
        #{Flow := {Conn, _Peer}} ->
            {TxnH, S1} = alloc(S),
            Branch = <<"z9hG4bK", (hex(6))/binary>>,
            Via =
                <<"Via: SIP/2.0/WS ", (node_id())/binary, ";branch=",
                    Branch/binary, "\r\n">>,
            %% insert our Via as the first header, after the request line
            Raw1 =
                case binary:split(Raw, <<"\r\n">>) of
                    [ReqLine, Rest] ->
                        <<ReqLine/binary, "\r\n", Via/binary, Rest/binary>>;
                    [_] ->
                        <<Via/binary, Raw/binary>>
                end,
            ws:send(Conn, {text, Raw1}),
            %% WS has no sofia Timer B/F: bound the wait for a response so an
            %% unanswered UAC leg (a browser that never replies) is cleaned up
            TRef = erlang:send_after(
                chappe_sip_config:get(ws_client_txn_timeout_ms),
                self(),
                {ctxn_timeout, TxnH}
            ),
            Ct = #{
                flow => Flow,
                branch => Branch,
                pid => Pid,
                req => Raw1,
                timer => TRef
            },
            S2 = S1#s{
                ctxn = (S1#s.ctxn)#{TxnH => Ct},
                cbranch_ix = (S1#s.cbranch_ix)#{Branch => TxnH}
            },
            engine_event({op_ok, TxnH}),
            {reply, {ok, TxnH}, S2};
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
    {noreply, drop_ctxn(TxnH, drop_stxn(TxnH, S))};
handle_cast({send_stateless, Flow, Raw}, S) ->
    %% A UAC-built request (e.g. a 2xx ACK) carries no Via; the transport adds
    %% it, as send_request does. A forwarded request already has one - leave it.
    send(Flow, ensure_via(Raw), S),
    {noreply, S};
handle_cast({cancel, TxnH}, S) ->
    case S#s.ctxn of
        #{TxnH := #{flow := Flow, req := Req}} ->
            case build_cancel(Req) of
                {ok, Cancel} -> send(Flow, Cancel, S);
                error -> ok
            end;
        _ ->
            ok
    end,
    {noreply, S};
handle_cast({leg_destroy, LegH}, S) ->
    {noreply, drop_leg(LegH, S)};
handle_cast({disconnect, Flow}, S) ->
    {noreply, drop_flow(Flow, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({ctxn_timeout, TxnH}, S) ->
    case S#s.ctxn of
        #{TxnH := _} ->
            %% no response arrived; fail the UAC leg and drop the client txn
            engine_event({op_failed, TxnH, timeout}),
            {noreply, drop_ctxn(TxnH, S)};
        _ ->
            {noreply, S}
    end;
handle_info({stxn_timeout, TxnH}, S) ->
    case S#s.stxn of
        #{TxnH := #{branch := Br}} ->
            logger:info("chappe_sip_ws: server transaction ~p timed out", [TxnH]),
            {noreply, drop_stxn(TxnH, Br, S)};
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

%% Parse and route one inbound frame. A malformed or unroutable frame is
%% dropped without taking the (singleton) transport down: an unauthenticated
%% peer must not be able to crash it and close every other WS session. Requests
%% missing a mandatory header are rejected before routing (build_response reads
%% them directly and would crash on undefined); the try/catch backstops any
%% other parse/build failure (e.g. non-UTF-8 header bytes).
%% Shed an inbound frame that is oversize, or has arrived while the transport
%% mailbox is already saturated (a flood of frames must not grow it without
%% bound). The mailbox check is cheap and covers all pending messages.
drop_incoming(Raw) ->
    byte_size(Raw) > chappe_sip_config:get(max_message_size) orelse
        mailbox_saturated().

mailbox_saturated() ->
    {message_queue_len, N} = process_info(self(), message_queue_len),
    N >= chappe_sip_config:get(ws_transport_max_mailbox).

ingest(Flow, Raw, S) ->
    try
        case chappe_sip_msg:parse(Raw) of
            {ok, Msg} ->
                %% a message missing a mandatory header cannot be routed or
                %% answered (build_response echoes them); drop it
                case chappe_sip_msg:validate(Msg) of
                    ok -> route_in(Flow, Msg, Raw, S);
                    {error, _} -> S
                end;
            {error, _} ->
                S
        end
    catch
        Class:Reason:St ->
            logger:warning(
                "chappe_sip_ws: dropped bad frame on flow ~p: ~p:~p~n~p",
                [Flow, Class, Reason, St]
            ),
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
    Branch = via_branch(Msg),
    case maps:get(Branch, S#s.cbranch_ix, undefined) of
        undefined ->
            S;
        TxnH ->
            case S#s.ctxn of
                #{TxnH := Ct} ->
                    Status = chappe_sip_msg:status(Msg),
                    engine_event({response, TxnH, #{status => Status}, Raw}),
                    %% a final response ends the client transaction timer
                    case Status >= 200 of
                        true ->
                            cancel_timer(maps:get(timer, Ct, undefined)),
                            S#s{
                                ctxn = (S#s.ctxn)#{
                                    TxnH => Ct#{timer => undefined}
                                }
                            };
                        false ->
                            S
                    end;
                _ ->
                    S
            end
    end.

route_request(Flow, Msg, Raw, S) ->
    Branch = via_branch(Msg),
    case chappe_sip_msg:method(Msg) of
        <<"ACK">> -> route_ack(Flow, Msg, Raw, Branch, S);
        <<"CANCEL">> -> route_cancel(Flow, Msg, Branch, S);
        Method -> new_server_txn(Flow, Msg, Raw, Branch, Method, S)
    end.

new_server_txn(Flow, Msg, Raw, Branch, Method, S) ->
    LegH = match_leg(Msg, S),
    {TxnH, S1} = alloc(S),
    %% RFC 3261 17.2.1: send 100 Trying for a new INVITE server transaction
    _ =
        case Method of
            <<"INVITE">> ->
                send(
                    Flow,
                    build_response(
                        Msg,
                        100,
                        <<>>,
                        <<>>,
                        <<>>,
                        <<>>,
                        peer_of(Flow, S1)
                    ),
                    S1
                );
            _ ->
                ok
        end,
    %% reap a server transaction the app never gives a final to
    TRef = erlang:send_after(
        chappe_sip_config:get(ws_server_txn_timeout_ms),
        self(),
        {stxn_timeout, TxnH}
    ),
    Txn = #{
        flow => Flow,
        branch => Branch,
        method => Method,
        msg => Msg,
        timer => TRef
    },
    %% key the server transaction on {Flow, Branch}: a branch is only unique
    %% within a connection, so two flows must not cross-match (F13)
    S2 = S1#s{
        stxn = (S1#s.stxn)#{TxnH => Txn},
        branch_ix = (S1#s.branch_ix)#{{Flow, Branch} => TxnH}
    },
    Meta = #{method => Method, flow => Flow, peer => peer_of(Flow, S2)},
    engine_event({request, TxnH, LegH, Meta, Raw}),
    S2.

%% 2xx ACK (new branch): matches a dialog leg -> ack event on the leg; else
%% emit an ack event tagged with the arrival Flow so the engine's proxy ACK
%% handler can forward a record-routed ACK over WS. Non-2xx ACK (INVITE
%% branch, still indexed) -> absorb.
route_ack(Flow, Msg, Raw, Branch, S) ->
    case maps:is_key({Flow, Branch}, S#s.branch_ix) of
        true ->
            % non-2xx ACK: absorb
            S;
        false ->
            case match_leg(Msg, S) of
                undefined ->
                    engine_event({ack, Flow, Raw}),
                    S;
                LegH ->
                    engine_event({ack, LegH, Raw}),
                    S
            end
    end.

%% CANCEL shares the INVITE branch. Answer the CANCEL 200 and signal the
%% INVITE server transaction so the app sends 487.
route_cancel(Flow, Msg, Branch, S) ->
    Peer = peer_of(Flow, S),
    case maps:get({Flow, Branch}, S#s.branch_ix, undefined) of
        undefined ->
            send(
                Flow, build_response(Msg, 481, <<>>, <<>>, <<>>, <<>>, Peer), S
            ),
            S;
        InvTxnH ->
            send(
                Flow, build_response(Msg, 200, <<>>, <<>>, <<>>, <<>>, Peer), S
            ),
            engine_event({cancel, InvTxnH}),
            S
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

%% ---- response building ----

build_response(ReqMsg, Status, Reason, Headers, Body, ToTag, Peer) ->
    Vias = chappe_sip_msg:get_all(<<"via">>, ReqMsg),
    From = chappe_sip_msg:get(<<"from">>, ReqMsg),
    To0 = chappe_sip_msg:get(<<"to">>, ReqMsg),
    %% RFC 3261 8.2.6.2: every response except 100 carries a To-tag. If the
    %% caller gave none (an error final via shed), mint one, as nta does on UDP.
    To =
        case chappe_sip_msg:to_tag(ReqMsg) of
            undefined when Status > 100 ->
                Tag =
                    case ToTag of
                        <<>> -> gen_tag();
                        _ -> ToTag
                    end,
                <<To0/binary, ";tag=", Tag/binary>>;
            _ ->
                To0
        end,
    Call = chappe_sip_msg:call_id(ReqMsg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, ReqMsg),
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
            <<"From: ">>,
            From,
            <<"\r\n">>,
            <<"To: ">>,
            To,
            <<"\r\n">>,
            <<"Call-ID: ">>,
            Call,
            <<"\r\n">>,
            <<"CSeq: ">>,
            CSeq,
            <<"\r\n">>,
            Headers,
            <<"Content-Length: ">>,
            integer_to_binary(byte_size(Body)),
            <<"\r\n\r\n">>,
            Body
        ]
    ).

%% ---- helpers ----

alloc(#s{counter = C} = S) ->
    N = atomics:add_get(C, 1, 1),
    {chappe_sip_ws:base() + N, S}.

send(Flow, Raw, S) ->
    case S#s.conns of
        #{Flow := {Conn, _Peer}} -> ws:send(Conn, {text, Raw});
        _ -> ok
    end.

peer_of(Flow, S) ->
    case S#s.conns of
        #{Flow := {_Conn, Peer}} -> Peer;
        _ -> undefined
    end.

maybe_drop_txn(Status, TxnH, Branch, S) when Status >= 200 ->
    drop_stxn(TxnH, Branch, S);
maybe_drop_txn(_Status, _TxnH, _Branch, S) ->
    S.

drop_stxn(TxnH, S) ->
    case S#s.stxn of
        #{TxnH := #{flow := Flow, branch := Br}} ->
            drop_stxn(TxnH, {Flow, Br}, S);
        _ ->
            S
    end.

drop_stxn(TxnH, Key, S) ->
    cancel_timer(txn_timer(S#s.stxn, TxnH)),
    S#s{
        stxn = maps:remove(TxnH, S#s.stxn),
        branch_ix = maps:remove(Key, S#s.branch_ix)
    }.

txn_timer(Map, TxnH) ->
    maps:get(timer, maps:get(TxnH, Map, #{}), undefined).

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

drop_leg(LegH, S) ->
    case S#s.legs of
        #{LegH := #{call_id := C, ltag := L, rtag := R}} ->
            S#s{
                legs = maps:remove(LegH, S#s.legs),
                leg_ix = maps:remove({C, L, R}, S#s.leg_ix)
            };
        _ ->
            S
    end.

drop_flow(Flow, S) ->
    %% the flow is the only path to a WS UA (RFC 5626): drop its registration
    chappe_sip_registry:remove_flow(Flow),
    %% cancel the transaction timers of everything on this flow
    _ = [
        cancel_timer(maps:get(timer, T, undefined))
     || T <- maps:values(S#s.stxn) ++ maps:values(S#s.ctxn),
        maps:get(flow, T, undefined) =:= Flow
    ],
    STxn = maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, S#s.stxn),
    CTxn = maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, S#s.ctxn),
    KeptCBranches = [B || #{branch := B} <- maps:values(CTxn)],
    Legs = maps:filter(fun(_, #{flow := F}) -> F =/= Flow end, S#s.legs),
    LegKeys = [
        {C, L, R}
     || #{call_id := C, ltag := L, rtag := R} <-
            maps:values(Legs)
    ],
    S#s{
        conns = maps:remove(Flow, S#s.conns),
        stxn = STxn,
        branch_ix = maps:filter(
            fun({F, _}, _) -> F =/= Flow end,
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
                    <<"branch=([^;\\s]+)">>,
                    [{capture, [1], binary}]
                )
            of
                {match, [B]} -> B;
                _ -> <<>>
            end
    end.

%% append ;received=<ip>;rport=<port> to a Via value, unless already present
add_received(Via, {IP, Port}) when is_tuple(IP), is_integer(Port) ->
    case binary:match(Via, <<";received=">>) of
        nomatch ->
            IPb = list_to_binary(inet:ntoa(IP)),
            <<Via/binary, ";received=", IPb/binary, ";rport=",
                (integer_to_binary(Port))/binary>>;
        _ ->
            Via
    end;
add_received(Via, _Peer) ->
    Via.

%% CANCEL built from the original request: same top Via/branch, R-URI,
%% From, To (no to-tag), Call-ID, CSeq number with method CANCEL.
build_cancel(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, M} ->
            RURI = chappe_sip_msg:uri(M),
            Via = chappe_sip_msg:get(<<"via">>, M),
            From = chappe_sip_msg:get(<<"from">>, M),
            To = chappe_sip_msg:get(<<"to">>, M),
            Call = chappe_sip_msg:call_id(M),
            Seq =
                case chappe_sip_msg:cseq(M) of
                    {ok, #{seq := N}} -> integer_to_binary(N);
                    _ -> <<"1">>
                end,
            {ok,
                <<"CANCEL ", RURI/binary, " SIP/2.0\r\n", "Via: ", Via/binary,
                    "\r\n", "Max-Forwards: 70\r\n", "From: ", From/binary,
                    "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ", Call/binary,
                    "\r\n", "CSeq: ", Seq/binary, " CANCEL\r\n",
                    "Content-Length: 0\r\n\r\n">>};
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
    <<"enki.invalid">>.

hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).

%% a fresh To-tag for a response we mint a tag for (RFC 3261 8.2.6.2)
gen_tag() ->
    hex(6).

%% Add a WS Via with a fresh branch after the request line, unless one is
%% already present. Used for UAC-built stateless requests (e.g. a 2xx ACK).
ensure_via(Raw) ->
    case binary:match(Raw, <<"\r\nVia:">>) of
        nomatch -> insert_via(Raw);
        _ -> Raw
    end.

insert_via(Raw) ->
    Branch = <<"z9hG4bK", (hex(6))/binary>>,
    Via =
        <<"Via: SIP/2.0/WS ", (node_id())/binary, ";branch=", Branch/binary,
            "\r\n">>,
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
