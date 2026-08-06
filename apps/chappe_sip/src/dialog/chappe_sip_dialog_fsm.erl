%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Dialog state machine (UAS side for M3).
%%
%% The fsm is the source of truth for the dialog: local tag, dialog
%% identity, remote target, and the local CSeq counter for requests it
%% originates. It owns the nta leg (LegH); in-dialog requests, acks and
%% cancels are routed here by chappe_sip_engine.
%%
%% States: setup (leg being confirmed) -> confirmed -> terminating ->
%% (stop). Owner receives {chappe_sip_dialog, Dialog, Event, Req[, Res]}.
-module(chappe_sip_dialog_fsm).
-behaviour(gen_statem).

-include("chappe_sip_dialog.hrl").
-include("chappe_sip.hrl").

-export([start_link/1]).
-export([init/1, callback_mode/0, terminate/3]).
-export([setup/3, confirmed/3, in_transaction/3, terminating/3]).

-record(data, {
    leg :: non_neg_integer(),
    txn :: non_neg_integer() | undefined,
    local_tag :: binary(),
    local_addr :: binary(),
    remote_addr :: binary(),
    remote_target :: binary(),
    %% RFC 3261 12: route set from Record-Route (UAS: request order; UAC:
    %% reversed 2xx). In-dialog requests loose-route through it as Route headers.
    route_set = [] :: [binary()],
    %% when set, in-dialog requests originate over this WS flow (a browser is
    %% reachable only via its flow, not by resolving its .invalid Contact)
    flow :: integer() | undefined,
    call_id :: binary(),
    owner :: pid(),
    owner_mon :: reference(),
    on_owner_exit :: destroy | continue,
    handled :: [atom()] | all,
    local_cseq = 1 :: pos_integer(),
    %% highest CSeq seen on an inbound in-dialog request (RFC 3261 12.2.2
    %% out-of-order rejection); 0 until the first one arrives
    remote_cseq = 0 :: non_neg_integer(),
    local_sdp = <<>> :: binary(),
    remote_sdp = <<>> :: binary(),
    on_hold = false :: boolean(),
    ready = false :: boolean(),
    await_from :: gen_statem:from() | undefined,
    %% in-flight outgoing in-dialog transaction:
    %% {From, TxnH, Kind} where Kind = bye | {reinvite, NewLocalSdp} | request
    txning ::
        {gen_statem:from() | undefined, non_neg_integer(), term()}
        | undefined,
    pending :: {gen_statem:from() | undefined, non_neg_integer()} | undefined
}).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> state_functions.

%% Args (both UAS and UAC): leg, call_id, local_addr (our From w/ tag),
%% remote_addr (peer To/From w/ tag), remote_target (peer Contact URI),
%% local_tag, owner, opts, cseq (initial local CSeq for our requests).
init(
    #{
        leg := LegH,
        call_id := CallId,
        local_addr := LocalAddr,
        remote_addr := RemoteAddr,
        remote_target := RTarget,
        local_tag := LocalTag,
        owner := Owner,
        opts := Opts
    } = Args
) ->
    MRef = erlang:monitor(process, Owner),
    Data = #data{
        leg = LegH,
        txn = maps:get(txn, Args, undefined),
        local_tag = LocalTag,
        local_addr = LocalAddr,
        remote_addr = RemoteAddr,
        remote_target = RTarget,
        flow = maps:get(flow, Args, undefined),
        route_set = maps:get(route_set, Args, []),
        call_id = CallId,
        owner = Owner,
        owner_mon = MRef,
        on_owner_exit = maps:get(on_owner_exit, Opts, destroy),
        handled = maps:get(handled_events, Opts, []),
        local_cseq = maps:get(cseq, Args, 1),
        local_sdp = maps:get(
            local_sdp,
            Args,
            maps:get(local_sdp, Opts, <<>>)
        ),
        remote_sdp = maps:get(remote_sdp, Args, <<>>)
    },
    %% Any dialog-forming response (UAS) is sent by chappe_sip_engine (sending
    %% it from here would re-enter chappe_sip_engine during our own start and
    %% deadlock). A UAC dialog has already been answered (2xx) before we
    %% start. A setup timeout bounds the wait for the leg op result, so a
    %% never-arriving op_ok/op_failed does not strand the fsm and its leg.
    {ok, setup, Data, [{state_timeout, 30000, setup_timeout}]}.

%% ---- setup: waiting for the leg op result ----

setup({call, From}, await_ready, #data{ready = true, leg = LegH} = D) ->
    {next_state, confirmed, D, [{reply, From, {ok, LegH}}]};
setup({call, From}, await_ready, D) ->
    {keep_state, D#data{await_from = From}};
setup(
    info,
    {chappe_sip_op, LegH, ok},
    #data{leg = LegH, await_from = undefined} = D
) ->
    {keep_state, D#data{ready = true}};
setup(
    info, {chappe_sip_op, LegH, ok}, #data{leg = LegH, await_from = From} = D
) ->
    {next_state, confirmed, D#data{await_from = undefined}, [
        {reply, From, {ok, LegH}}
    ]};
setup(info, {chappe_sip_op, LegH, {error, Reason}}, #data{leg = LegH} = D) ->
    reply_await(D, {error, Reason}),
    {stop, normal, D};
setup(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy} = D
) ->
    %% owner died before the dialog was confirmed; drop the half-formed leg
    reply_await(D, {error, owner_down}),
    {stop, normal, D};
setup(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = continue} = D
) ->
    {keep_state, D};
setup(info, {chappe_sip_engine_restart, _}, D) ->
    reply_await(D, {error, engine_restart}),
    {stop, normal, D};
setup(state_timeout, setup_timeout, D) ->
    reply_await(D, {error, setup_timeout}),
    {stop, normal, D};
setup(info, _Other, D) ->
    {keep_state, D};
setup({call, From}, _Req, D) ->
    {keep_state, D, [{reply, From, {error, not_ready}}]}.

%% ---- confirmed ----

confirmed(info, {chappe_sip_ack, LegH, Raw}, #data{leg = LegH} = D) ->
    AckReq = parse_req(Raw, undefined),
    notify(D, ack, AckReq, undefined),
    {keep_state, D};
confirmed(
    info, {chappe_sip_indialog, LegH, TxnH, Meta, Raw}, #data{leg = LegH} = D
) ->
    handle_indialog(TxnH, Meta, Raw, D);
confirmed(info, {chappe_sip_cancel, _TxnH}, D) ->
    %% late CANCEL after the dialog was established; ignore
    {keep_state, D};
confirmed({call, From}, destroy, D) ->
    start_bye(From, D);
confirmed({call, From}, {modify, SdpSpec}, D) ->
    start_reinvite(From, SdpSpec, D);
confirmed({call, From}, {request, ReqSpec}, D) ->
    start_request(From, ReqSpec, D);
confirmed({call, From}, local_tag, #data{local_tag = T} = D) ->
    {keep_state, D, [{reply, From, T}]};
confirmed({call, From}, remote_tag, #data{remote_addr = RA} = D) ->
    {keep_state, D, [{reply, From, addr_tag(RA)}]};
confirmed({call, From}, call_id, #data{call_id = C} = D) ->
    {keep_state, D, [{reply, From, C}]};
confirmed({call, From}, remote_sdp, #data{remote_sdp = S} = D) ->
    {keep_state, D, [{reply, From, S}]};
confirmed({call, From}, {set_handled, Events}, D) ->
    {keep_state, D#data{handled = Events}, [{reply, From, ok}]};
confirmed(info, {chappe_sip_engine_restart, _}, D) ->
    notify_terminal(D, engine_restart),
    {stop, normal, D};
confirmed(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy} = D
) ->
    start_bye(undefined, D);
confirmed(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = continue} = D
) ->
    {keep_state, D};
confirmed(info, _Other, D) ->
    {keep_state, D}.

%% ---- in_transaction: one outgoing in-dialog request in flight ----
%% Competing outgoing operations are postponed (serialized). Incoming
%% in-dialog requests and acks are still handled.

in_transaction(
    info,
    {chappe_sip_response, TxnH, #{status := Status}, Raw},
    #data{txning = {From, TxnH, Kind}} = D
) ->
    %% release the client transaction on a final (else one handle leaks per
    %% in-dialog request for the life of the dialog)
    _ = Status >= 200 andalso chappe_sip_engine:finish_txn(TxnH),
    finish_txn_response(From, Kind, Status, Raw, D);
in_transaction(
    info,
    {chappe_sip_op, TxnH, {error, Reason}},
    #data{txning = {From, TxnH, _}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    reply(From, {error, Reason}),
    {next_state, confirmed, D#data{txning = undefined}};
in_transaction(info, {chappe_sip_op, _TxnH, _}, D) ->
    {keep_state, D};
in_transaction(info, {chappe_sip_ack, LegH, Raw}, #data{leg = LegH} = D) ->
    notify(D, ack, parse_req(Raw, undefined), undefined),
    {keep_state, D};
in_transaction(
    info,
    {chappe_sip_indialog, LegH, TxnH, Meta, Raw},
    #data{leg = LegH} = D
) ->
    %% a peer BYE during our transaction still terminates the dialog
    handle_indialog(TxnH, Meta, Raw, D);
in_transaction({call, _From}, Op, D) when
    element(1, Op) =:= modify;
    element(1, Op) =:= request;
    Op =:= destroy
->
    {keep_state, D, [postpone]};
in_transaction({call, From}, local_tag, #data{local_tag = T} = D) ->
    {keep_state, D, [{reply, From, T}]};
in_transaction({call, From}, call_id, #data{call_id = C} = D) ->
    {keep_state, D, [{reply, From, C}]};
in_transaction({call, From}, remote_sdp, #data{remote_sdp = S} = D) ->
    {keep_state, D, [{reply, From, S}]};
in_transaction(info, {chappe_sip_engine_restart, _}, D) ->
    reply(txning_from(D), {error, engine_restart}),
    notify_terminal(D, engine_restart),
    {stop, normal, D};
in_transaction(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy} = D
) ->
    %% owner died mid-transaction: abandon the in-flight txn and BYE
    reply(txning_from(D), {error, owner_down}),
    start_bye(undefined, D#data{txning = undefined});
in_transaction(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = continue} = D
) ->
    {keep_state, D};
in_transaction(info, _Other, D) ->
    {keep_state, D}.

txning_from(#data{txning = {From, _, _}}) -> From;
txning_from(_) -> undefined.

finish_txn_response(From, {reinvite, NewSdp}, Status, Raw, D) when
    Status >= 200, Status < 300
->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    _ = send_ack_indialog(D),
    RemoteSdp = chappe_sip_msg:body(Msg),
    reply(From, {ok, RemoteSdp}),
    {next_state, confirmed, D#data{
        txning = undefined,
        local_sdp = NewSdp,
        remote_sdp = RemoteSdp,
        local_cseq = D#data.local_cseq + 1
    }};
finish_txn_response(From, {reinvite, _}, Status, Raw, D) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    %% re-INVITE rejected: ACK the failure, dialog stays as it was
    _ = send_ack_indialog(D),
    reply(From, {error, chappe_sip_error(Status, Msg)}),
    {next_state, confirmed, D#data{
        txning = undefined, local_cseq = D#data.local_cseq + 1
    }};
finish_txn_response(From, request, Status, Raw, D) when Status >= 200 ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    reply(From, {ok, Msg}),
    {next_state, confirmed, D#data{
        txning = undefined, local_cseq = D#data.local_cseq + 1
    }};
finish_txn_response(_From, request, _Status, _Raw, D) ->
    %% provisional to a non-INVITE request: keep waiting
    {keep_state, D}.

%% ---- terminating: waiting for our BYE final response ----

terminating(
    info,
    {chappe_sip_response, TxnH, _Meta, _Raw},
    #data{pending = {From, TxnH}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    reply(From, ok),
    notify_terminal(D, byed),
    {stop, normal, D};
terminating(
    info,
    {chappe_sip_op, TxnH, {error, Reason}},
    #data{pending = {From, TxnH}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    reply(From, {error, Reason}),
    {stop, normal, D};
terminating(info, {chappe_sip_op, _TxnH, ok}, D) ->
    {keep_state, D};
terminating(
    info,
    {chappe_sip_indialog, LegH, TxnH, _Meta, _Raw},
    #data{leg = LegH} = D
) ->
    %% peer BYE crossing our BYE: answer 200 and finish
    _ = chappe_sip_engine:dialog_respond(TxnH, 200, <<"OK">>, <<>>, <<>>, <<>>),
    {keep_state, D};
terminating(info, {chappe_sip_engine_restart, _}, D) ->
    notify_terminal(D, engine_restart),
    {stop, normal, D};
terminating(info, _Other, D) ->
    {keep_state, D};
terminating({call, From}, _Req, D) ->
    {keep_state, D, [{reply, From, {error, terminating}}]}.

%% ---- in-dialog request handling ----

handle_indialog(TxnH, _Meta, Raw, D) ->
    Req = parse_req(Raw, TxnH),
    case in_order(Req, D) of
        {ok, D1} ->
            handle_indialog_1(TxnH, Req, D1);
        out_of_order ->
            %% RFC 3261 12.2.2: an in-dialog request with a CSeq lower than the
            %% highest seen is out of order and is rejected 500
            _ = chappe_sip_engine:dialog_respond(
                TxnH,
                500,
                <<"Server Internal Error">>,
                <<>>,
                <<>>,
                <<>>
            ),
            {keep_state, D}
    end.

%% track the remote CSeq; a strictly lower number than the highest seen is out
%% of order (retransmits are absorbed at the transaction layer, so an equal
%% number reaching here is fine)
in_order(Req, #data{remote_cseq = Prev} = D) ->
    case req_cseq(Req) of
        undefined -> {ok, D};
        N when N >= Prev -> {ok, D#data{remote_cseq = N}};
        _ -> out_of_order
    end.

req_cseq(Req) ->
    case chappe_sip_msg:cseq(chappe_sip_req:msg(Req)) of
        {ok, #{seq := N}} -> N;
        _ -> undefined
    end.

handle_indialog_1(TxnH, Req, D) ->
    Method = chappe_sip_req:method(Req),
    case Method of
        <<"BYE">> ->
            _ = chappe_sip_engine:dialog_respond(
                TxnH,
                200,
                <<"OK">>,
                <<>>,
                <<>>,
                <<>>
            ),
            notify_terminal_req(D, Req),
            {stop, normal, D};
        _ ->
            Event = method_event(Method),
            case claimed(Event, D) of
                true ->
                    Res = chappe_sip_res:new(TxnH, dialog_sender()),
                    notify(D, Event, Req, Res),
                    {keep_state, D};
                false ->
                    {Status, Reason} = auto_status(Event),
                    _ = chappe_sip_engine:dialog_respond(
                        TxnH,
                        Status,
                        Reason,
                        <<>>,
                        <<>>,
                        <<>>
                    ),
                    notify4(D, {auto_answered, Event}, Req),
                    {keep_state, D}
            end
    end.

%% ---- helpers ----

start_bye(From, #data{pending = undefined} = D) ->
    Raw = build_bye(D),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, terminating, D#data{pending = {From, TxnH}}};
        {error, Reason} ->
            reply(From, {error, Reason}),
            {stop, normal, D}
    end;
start_bye(From, D) ->
    %% BYE already in flight
    {keep_state, D, [{reply, From, ok}]}.

build_bye(#data{local_cseq = CSeq} = D) ->
    build_indialog(D, <<"BYE">>, CSeq, [], <<>>).

%% ---- re-INVITE / in-dialog request ----

start_reinvite(From, SdpSpec, #data{local_sdp = CurSdp, on_hold = Hold} = D) ->
    {NewSdp, NewHold} = resolve_sdp(SdpSpec, CurSdp, Hold),
    Seq = D#data.local_cseq + 1,
    % ACK must reuse this CSeq
    D1 = D#data{local_cseq = Seq},
    Headers = [{<<"Content-Type">>, <<"application/sdp">>}],
    Raw = build_indialog(D1, <<"INVITE">>, Seq, Headers, NewSdp),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, in_transaction, D1#data{
                on_hold = NewHold,
                txning = {From, TxnH, {reinvite, NewSdp}}
            }};
        {error, Reason} ->
            {keep_state, D, [{reply, From, {error, Reason}}]}
    end.

start_request(From, ReqSpec, #data{local_cseq = CSeq0} = D) ->
    Method = maps:get(method, ReqSpec),
    Seq = CSeq0 + 1,
    D1 = D#data{local_cseq = Seq},
    Body = iolist_to_binary(maps:get(body, ReqSpec, <<>>)),
    Headers =
        maps:get(headers, ReqSpec, []) ++
            ct_header(maps:get(content_type, ReqSpec, undefined), Body),
    Raw = build_indialog(D1, Method, Seq, Headers, Body),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, in_transaction, D1#data{
                txning = {From, TxnH, request}
            }};
        {error, Reason} ->
            {keep_state, D, [{reply, From, {error, Reason}}]}
    end.

ct_header(undefined, <<>>) -> [];
ct_header(undefined, _Body) -> [];
ct_header(CT, _Body) -> [{<<"Content-Type">>, CT}].

%% hold/unhold rewrite the stored local SDP direction attribute
resolve_sdp(hold, CurSdp, _Hold) ->
    {chappe_sip_sdp_hold(CurSdp, true), true};
resolve_sdp(unhold, CurSdp, _Hold) ->
    {chappe_sip_sdp_hold(CurSdp, false), false};
resolve_sdp(Sdp, _CurSdp, Hold) when is_binary(Sdp); is_list(Sdp) ->
    {iolist_to_binary(Sdp), Hold};
resolve_sdp(undefined, CurSdp, Hold) ->
    {CurSdp, Hold}.

chappe_sip_sdp_hold(Sdp, true) ->
    S1 = binary:replace(Sdp, <<"a=sendrecv">>, <<"a=sendonly">>, [global]),
    case S1 of
        % none present, append
        Sdp -> <<Sdp/binary, "a=sendonly\r\n">>;
        _ -> S1
    end;
chappe_sip_sdp_hold(Sdp, false) ->
    binary:replace(
        Sdp,
        [<<"a=sendonly">>, <<"a=inactive">>],
        <<"a=sendrecv">>,
        [global]
    ).

%% Build an in-dialog request (From=local, To=remote, RURI=remote target).
%% RFC 3261 12.2.1.1: with a route set it loose-routes, i.e. the route set
%% goes into Route headers and the Request-URI stays the remote target (we
%% assume loose-routing proxies, which put ;lr in their Record-Route).
build_indialog(
    #data{
        remote_target = RURI,
        local_addr = LocalAddr,
        remote_addr = RemoteAddr,
        call_id = CallId,
        route_set = RouteSet
    },
    Method,
    CSeq,
    Headers,
    Body
) ->
    Seq = integer_to_binary(CSeq),
    HdrBin = chappe_sip_hdr_io:join(Headers),
    CL = integer_to_binary(byte_size(Body)),
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n",
        (route_headers(RouteSet))/binary, "From: ", LocalAddr/binary, "\r\n",
        "To: ", RemoteAddr/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
        "CSeq: ", Seq/binary, " ", Method/binary, "\r\n",
        "Max-Forwards: 70\r\n", HdrBin/binary, "Content-Length: ", CL/binary,
        "\r\n\r\n", Body/binary>>.

route_headers([]) ->
    <<>>;
route_headers(RouteSet) ->
    iolist_to_binary([[<<"Route: ">>, R, <<"\r\n">>] || R <- RouteSet]).

%% ACK a re-INVITE 2xx (in-dialog, its own transaction; ACK reuses the
%% re-INVITE's CSeq number).
send_ack_indialog(#data{local_cseq = CSeq} = D) ->
    Raw = build_indialog(D, <<"ACK">>, CSeq, [], <<>>),
    chappe_sip_engine:send_stateless(route(D), Raw, self()).

%% in-dialog requests go over the dialog's WS flow when it has one, else the
%% sofia path routes by the Request-URI / Route set
%% Send destination: a WS flow wins (a browser is reached over its flow); else
%% with a route set (loose routing) the request goes to the first Route's URI
%% (RFC 3261 12.2.1.1), otherwise nta routes by the Request-URI.
route(#data{flow = Flow}) when Flow =/= undefined -> {ws, Flow};
route(#data{route_set = [First | _]}) ->
    case chappe_sip_hdr:name_addr(First) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> undefined
    end;
route(#data{}) ->
    undefined.

%% Peer dialog tag out of the stored remote address (a name-addr with ;tag=).
addr_tag(Addr) ->
    case chappe_sip_hdr:name_addr(Addr) of
        {ok, #{params := P}} ->
            case maps:get(<<"tag">>, P, undefined) of
                true -> undefined;
                V -> V
            end;
        _ ->
            undefined
    end.

chappe_sip_error(Status, Msg) ->
    #chappe_sip_error{
        status = Status,
        reason =
            case chappe_sip_msg:reason(Msg) of
                undefined -> <<>>;
                R -> R
            end,
        response = Msg
    }.

parse_req(Raw, TxnH) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> chappe_sip_req:new(Msg, TxnH, #{});
        {error, _} -> chappe_sip_req:new(empty_msg(), TxnH, #{})
    end.

empty_msg() ->
    {ok, M} = chappe_sip_msg:parse(<<"BYE sip:x SIP/2.0\r\n\r\n">>),
    M.

dialog_sender() ->
    fun(TxnH, Status, Opts) ->
        Reason = maps:get(reason, Opts, <<>>),
        Headers = chappe_sip_hdr_io:join(maps:get(headers, Opts, [])),
        Body = iolist_to_binary(maps:get(body, Opts, <<>>)),
        chappe_sip_engine:dialog_respond(
            TxnH,
            Status,
            Reason,
            Headers,
            Body,
            <<>>
        )
    end.

claimed(_Event, #data{handled = all}) ->
    true;
claimed(Event, #data{handled = List}) when is_list(List) ->
    lists:member(Event, List).

method_event(<<"INFO">>) -> info;
method_event(<<"NOTIFY">>) -> notify;
method_event(<<"UPDATE">>) -> update;
method_event(<<"OPTIONS">>) -> options;
method_event(<<"REFER">>) -> refer;
method_event(<<"MESSAGE">>) -> message;
method_event(<<"INVITE">>) -> modify;
method_event(<<"SUBSCRIBE">>) -> subscribe;
method_event(Other) -> {method, Other}.

auto_status(_) -> {200, <<"OK">>}.

%% claimed events and ack carry a Res slot (5-tuple)
notify(#data{owner = Owner} = D, Event, Req, Res) ->
    Owner ! {chappe_sip_dialog, dialog(D), Event, Req, Res},
    ok.

%% auto-answered notifications are informational (4-tuple, no Res)
notify4(#data{owner = Owner} = D, Event, Req) ->
    Owner ! {chappe_sip_dialog, dialog(D), Event, Req},
    ok.

notify_terminal_req(#data{owner = Owner} = D, Req) ->
    Owner ! {chappe_sip_dialog, dialog(D), destroy, Req},
    ok.

notify_terminal(#data{owner = Owner} = D, Reason) ->
    Owner ! {chappe_sip_dialog, dialog(D), destroy, Reason},
    ok.

dialog(#data{leg = LegH}) ->
    chappe_sip_dialog:make(self(), LegH).

reply_await(#data{await_from = undefined}, _) -> ok;
reply_await(#data{await_from = From}, Msg) -> gen_statem:reply(From, Msg).

reply(undefined, _) -> ok;
reply(From, Msg) -> gen_statem:reply(From, Msg).

terminate(_Reason, _State, #data{leg = LegH}) ->
    %% destroy_leg is a cast; unreg happens as part of it
    _ = chappe_sip_engine:destroy_leg(LegH),
    ok.
