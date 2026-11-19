%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc What a dialog fsm puts on the wire: the in-dialog requests it
%% sends (BYE, re-INVITE, any other request) and the responses to its
%% re-INVITEs, the ACKs, and its answers to the peer's requests (directly,
%% or through the sender a claimed request's response object runs).
%%
%% Runs in the chappe_sip_dialog_fsm process, on its #data{}; the results
%% are gen_statem state function results.
-module(chappe_sip_dialog_out).

-export([respond/3, respond/4, respond/5, dialog_sender/2]).
-export([send/5, transact/4]).
-export([start_bye/3, start_reinvite/4, start_request/3, start_request/4]).
-export([reinvite_response/5, send_ack/1, send_delayed_ack/3]).
-export([indialog_request/4, raw/6]).

-export_type([headers/0]).

-include("chappe_sip_dialog_fsm.hrl").

-type headers() :: [{binary(), iodata()}].

%% ---- responses to the peer's requests ----

-spec respond(non_neg_integer(), 100..699, binary()) -> term().
respond(TxnH, Status, Reason) ->
    respond(TxnH, Status, Reason, [], <<>>).

-spec respond(non_neg_integer(), 100..699, binary(), headers()) -> term().
respond(TxnH, Status, Reason, Hdrs) ->
    respond(TxnH, Status, Reason, Hdrs, <<>>).

-spec respond(non_neg_integer(), 100..699, binary(), headers(), binary()) ->
    term().
respond(TxnH, Status, Reason, Hdrs, Body) ->
    chappe_sip_engine:dialog_respond(
        TxnH, Status, Reason, chappe_sip_hdr_io:join(Hdrs), Body, <<>>
    ).

%% runs in the owner: a 2xx carries the session timer headers (unless the
%% owner set its own) and re-arms the fsm's timers (St = keep: leaves them
%% alone, for a request that does not refresh the session). The fsm hears of the
%% final response before it goes on the wire, so a request the peer sends
%% once it has it finds the transaction settled.
-spec dialog_sender(headers(), term()) -> fun().
dialog_sender(StHdrs, St) ->
    Fsm = self(),
    fun(TxnH, Status, Opts) ->
        Reason = maps:get(reason, Opts, <<>>),
        Hdrs0 = maps:get(headers, Opts, []),
        Hdrs =
            case Status >= 200 andalso Status < 300 of
                true ->
                    _ = St =:= keep orelse (Fsm ! {st_refreshed, St}),
                    Hdrs0 ++
                        [H || {N, _} = H <- StHdrs, not has_hdr(N, Hdrs0)];
                false ->
                    Hdrs0
            end,
        Body = iolist_to_binary(maps:get(body, Opts, <<>>)),
        _ =
            Status >= 200 andalso
                (Fsm ! {chappe_sip_final, TxnH, Status, Body}),
        respond(TxnH, Status, Reason, Hdrs, Body)
    end.

-spec has_hdr(binary(), headers()) -> boolean().
has_hdr(Name, Headers) ->
    L = string:lowercase(Name),
    lists:any(fun({N, _}) -> string:lowercase(N) =:= L end, Headers).

%% ---- in-dialog requests ----

%% An in-dialog request of a dialog that has no fsm yet (a B2BUA's early
%% leg): Dlg names its parts, the result is the raw request and where to
%% send it.
-spec indialog_request(map(), binary(), headers(), binary()) ->
    {binary(), term()}.
indialog_request(Dlg, Method, Headers, Body) ->
    %% the fields a request does not read hold placeholders
    D = #data{
        leg = 0,
        local_tag = <<>>,
        owner = self(),
        owner_mon = make_ref(),
        on_owner_exit = continue,
        handled = [],
        remote_target = maps:get(remote_target, Dlg),
        local_addr = maps:get(local_addr, Dlg),
        remote_addr = maps:get(remote_addr, Dlg),
        call_id = maps:get(call_id, Dlg),
        route_set = maps:get(route_set, Dlg),
        local_contact = maps:get(local_contact, Dlg)
    },
    {build(D, Method, maps:get(cseq, Dlg), Headers, Body), route(D)}.

%% Build an in-dialog request (From=local, To=remote). RFC 3261 12.2.1.1:
%% behind a loose router (;lr) the Request-URI is the remote target and the
%% route set goes in Route; behind a strict router the first route is the
%% Request-URI and the remote target ends the Route list.
-spec build(#data{}, binary(), pos_integer(), headers(), binary()) ->
    binary().
build(
    #data{
        remote_target = Target,
        local_addr = LocalAddr,
        remote_addr = RemoteAddr,
        call_id = CallId,
        route_set = RouteSet0,
        local_contact = Contact
    },
    Method,
    CSeq,
    Headers,
    Body
) ->
    HdrBin = chappe_sip_hdr_io:join(
        with_supported(Method, with_contact(Method, Contact, Headers))
    ),
    raw(
        Method,
        CSeq,
        {Target, RouteSet0},
        {LocalAddr, RemoteAddr, CallId},
        HdrBin,
        Body
    ).

%% The bytes of a request inside a dialog, shared with the UAC fsm's ACK,
%% BYE and PRACK: the Request-URI and Route headers from the remote target
%% and the route set (RFC 3261 12.2.1.1, strict routers take the
%% Request-URI), then From, To, Call-ID, CSeq, Max-Forwards, the headers
%% (already joined) and the body.
-spec raw(
    binary(),
    pos_integer(),
    {binary(), [binary()]},
    {binary(), binary(), binary()},
    binary(),
    binary()
) -> binary().
raw(Method, CSeq, {Target, RouteSet0}, {From, To, CallId}, HdrBin, Body) ->
    {RURI, RouteSet} = chappe_sip_route:request_target(Target, RouteSet0),
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n",
        (route_headers(RouteSet))/binary, "From: ", From/binary, "\r\n", "To: ",
        To/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n", "CSeq: ",
        (integer_to_binary(CSeq))/binary, " ", Method/binary, "\r\n",
        "Max-Forwards: 70\r\n", HdrBin/binary, "Content-Length: ",
        (integer_to_binary(byte_size(Body)))/binary, "\r\n\r\n", Body/binary>>.

%% Target refresh requests carry our Contact (RFC 3261 12.2.1.1 for
%% re-INVITE and UPDATE, RFC 6665 4.1.2.2 and 4.2.2 for SUBSCRIBE and
%% NOTIFY, RFC 3515 for REFER), unless the caller supplied one.
with_contact(_Method, undefined, Headers) ->
    Headers;
with_contact(Method, Contact, Headers) ->
    Refresh = lists:member(Method, [
        <<"INVITE">>, <<"UPDATE">>, <<"NOTIFY">>, <<"SUBSCRIBE">>, <<"REFER">>
    ]),
    case Refresh andalso not has_hdr(<<"contact">>, Headers) of
        true -> [{<<"Contact">>, Contact} | Headers];
        false -> Headers
    end.

%% RFC 4028 7.1: every request but ACK lists timer in Supported
with_supported(<<"ACK">>, Headers) ->
    Headers;
with_supported(_Method, Headers) ->
    Headers ++ chappe_sip_session_timer:supported(Headers).

route_headers([]) ->
    <<>>;
route_headers(RouteSet) ->
    iolist_to_binary([[<<"Route: ">>, R, <<"\r\n">>] || R <- RouteSet]).

%% Send destination: a WS flow wins (a browser is reached over its flow); else
%% with a route set (loose routing) the request goes to the first Route's URI
%% (RFC 3261 12.2.1.1), otherwise nta routes by the Request-URI. A sip:
%% first route is reached as sips: when the remote target is SIPS (8.1.2).
-spec route(#data{}) -> term().
route(#data{flow = Flow}) when Flow =/= undefined ->
    chappe_sip_flow:flow_route(Flow);
route(#data{route_set = [First | _], remote_target = Target}) ->
    case chappe_sip_hdr:name_addr(First) of
        {ok, #{uri := Uri}} -> chappe_sip_route:secure_hop(Target, Uri);
        _ -> undefined
    end;
route(#data{}) ->
    undefined.

%% a request of the dialog, through its transaction layer
-spec send(binary(), pos_integer(), headers(), binary(), #data{}) ->
    {ok, non_neg_integer()} | {error, term()}.
send(Method, Seq, Headers, Body, D) ->
    Raw = build(D, Method, Seq, Headers, Body),
    chappe_sip_engine:send_request(route(D), Raw, self()).

%% the CSeq of our next request: an early dialog shares the INVITE's
%% counter with the PRACKs of the UAC fsm
-spec next_cseq(#data{}) -> {pos_integer(), #data{}}.
next_cseq(#data{cseq_ref = undefined, local_cseq = CSeq} = D) ->
    {CSeq + 1, D#data{local_cseq = CSeq + 1}};
next_cseq(#data{cseq_ref = Ref} = D) ->
    Seq = atomics:add_get(Ref, 1, 1),
    {Seq, D#data{local_cseq = Seq}}.

%% Our request Seq in flight: in_transaction until its final, Kind says
%% what it is; a request that cannot be sent leaves the dialog as it was.
-spec transact(
    gen_statem:from() | undefined,
    term(),
    {binary(), pos_integer(), headers(), binary()},
    #data{}
) -> gen_statem:event_handler_result(atom()).
transact(From, Kind, {Method, Seq, Headers, Body}, D) ->
    D1 = D#data{local_cseq = Seq},
    case send(Method, Seq, Headers, Body, D1) of
        {ok, TxnH} ->
            {next_state, in_transaction, D1#data{txning = {From, TxnH, Kind}}};
        {error, Reason} ->
            chappe_sip_dialog_owner:reply(From, {error, Reason}),
            {keep_state, D}
    end.

-spec start_bye(gen_statem:from() | undefined, headers(), #data{}) ->
    gen_statem:event_handler_result(atom()).
start_bye(From, Hdrs, #data{pending = undefined} = D0) ->
    Seq = D0#data.local_cseq + 1,
    D = D0#data{local_cseq = Seq},
    Raw = build(D, <<"BYE">>, Seq, Hdrs, <<>>),
    %% RFC 3891: a Replaces naming this dialog now gets 603. Marked before
    %% the BYE leaves, so a Replaces sent once the peer has it never finds
    %% the dialog still confirmed.
    chappe_sip_dialog_owner:set_index_state(D, terminated),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, terminating, D#data{pending = {From, TxnH}}};
        {error, Reason} ->
            chappe_sip_dialog_owner:unindex(D),
            chappe_sip_dialog_owner:reply(From, {error, Reason}),
            {stop, normal, D}
    end;
start_bye(From, _Hdrs, D) ->
    %% BYE already in flight
    {keep_state, D, [{reply, From, ok}]}.

%% ---- re-INVITE ----

%% Opts: retry_on_glare => true retries once after a 491 (RFC 3261 14.1);
%% ack => manual leaves the 2xx for the owner to ACK (ack/2). An offerless
%% re-INVITE (none) needs ack => manual: its 2xx carries the peer's offer
%% and only the owner has the answer. The hold state and local SDP change
%% only once the re-INVITE succeeds.
-spec start_reinvite(gen_statem:from() | undefined, term(), map(), #data{}) ->
    gen_statem:event_handler_result(atom()).
start_reinvite(From, none, #{ack := manual} = Opts, D) ->
    start_reinvite_1(From, none, Opts, D);
start_reinvite(From, none, _Opts, D) ->
    {keep_state, D, [{reply, From, {error, manual_ack_required}}]};
start_reinvite(From, SdpSpec, Opts, D) ->
    start_reinvite_1(From, SdpSpec, Opts, D).

start_reinvite_1(
    From, SdpSpec, Opts, #data{local_sdp = CurSdp, on_hold = Hold} = D
) ->
    {NewSdp, NewHold} = resolve_sdp(SdpSpec, CurSdp, Hold),
    Retry =
        case maps:get(retry_on_glare, Opts, false) of
            true -> {retry, SdpSpec};
            false -> undefined
        end,
    % ACK must reuse this CSeq
    Seq = D#data.local_cseq + 1,
    CT = maps:get(content_type, Opts, <<"application/sdp">>),
    Headers =
        [{<<"Content-Type">>, CT} || NewSdp =/= <<>>] ++
            chappe_sip_session_timer:refresh_headers(D#data.st),
    Req = {<<"INVITE">>, Seq, Headers, NewSdp},
    case transact(From, {reinvite, NewSdp}, Req, D) of
        {next_state, in_transaction, D1} ->
            {next_state, in_transaction, D1#data{
                pending_hold = NewHold,
                glare_retry = Retry,
                reinvite_ack = maps:get(ack, Opts, auto)
            }};
        Unsent ->
            Unsent
    end.

%% hold/unhold rewrite the stored local SDP direction attribute
resolve_sdp(hold, CurSdp, _Hold) ->
    {chappe_sip_sdp:next_version(chappe_sip_sdp:hold(CurSdp, true)), true};
resolve_sdp(unhold, CurSdp, _Hold) ->
    {chappe_sip_sdp:next_version(chappe_sip_sdp:hold(CurSdp, false)), false};
resolve_sdp(none, _CurSdp, Hold) ->
    {<<>>, Hold};
resolve_sdp(Sdp, _CurSdp, Hold) when is_binary(Sdp); is_list(Sdp) ->
    {iolist_to_binary(Sdp), Hold};
resolve_sdp(undefined, CurSdp, Hold) ->
    {chappe_sip_sdp:next_version(CurSdp), Hold}.

%% The response to our re-INVITE.
-spec reinvite_response(
    gen_statem:from() | undefined, term(), 100..699, binary(), #data{}
) -> gen_statem:event_handler_result(atom()).
reinvite_response(From, {reinvite, NewSdp}, Status, Raw, D) when
    Status >= 200, Status < 300
->
    reinvite_ok(From, NewSdp, Raw, D);
reinvite_response(
    From, _Kind, 491, _Raw, #data{glare_retry = {retry, Spec}} = D
) ->
    %% RFC 3261 14.1: glare; try once more after the randomized wait. The
    %% session is unchanged meanwhile. nta ACKs the 491 (17.1.1.3).
    {next_state, confirmed,
        D#data{
            txning = undefined,
            glare_retry = undefined,
            glare_wait = {From, Spec}
        },
        [
            {
                {timeout, glare_retry},
                chappe_sip_dialog_offer:glare_delay(D),
                retry
            }
        ]};
reinvite_response(From, _Kind, Status, Raw, D) when
    Status =:= 481; Status =:= 408
->
    %% RFC 3261 12.2.1.2: the peer has no such dialog, or never answered
    reply_error(From, Status, Raw),
    chappe_sip_dialog_owner:stop({request_failed, Status}, D);
reinvite_response(From, _Kind, Status, Raw, D) when Status >= 200 ->
    %% re-INVITE rejected: the dialog stays as it was. The INVITE client
    %% transaction ACKs a non-2xx itself (RFC 3261 17.1.1.3); a second ACK
    %% from here would be a stray 2xx-style one.
    reply_error(From, Status, Raw),
    {next_state, confirmed, D#data{
        txning = undefined,
        glare_retry = undefined
    }};
reinvite_response(_From, _Kind, _Status, _Raw, D) ->
    %% a provisional: the transaction stays open until its final response
    {keep_state, D}.

reinvite_ok(From, NewSdp, Raw, D0) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    D = chappe_sip_dialog_offer:new_target(Msg, D0),
    RemoteSdp = chappe_sip_msg:body(Msg),
    chappe_sip_dialog_owner:reply(From, {ok, RemoteSdp}),
    D1 = D#data{
        txning = undefined,
        remote_sdp = RemoteSdp,
        on_hold = D#data.pending_hold,
        glare_retry = undefined
    },
    case D#data.reinvite_ack of
        manual ->
            %% the owner ACKs with ack/2, carrying the answer when this 2xx
            %% holds the offer of our offerless re-INVITE (RFC 3261 14.1)
            Pending = #{cseq => D#data.local_cseq, headers => []},
            {next_state, confirmed, D1#data{
                pending_ack = Pending,
                local_sdp = chappe_sip_dialog_offer:keep_sdp(
                    NewSdp, D#data.local_sdp
                )
            }};
        auto ->
            _ = send_ack(D),
            {next_state, confirmed, D1#data{local_sdp = NewSdp}}
    end.

reply_error(From, Status, Raw) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_dialog_owner:reply(
        From, {error, chappe_sip_dialog_owner:sip_error(Status, Msg)}
    ).

%% ---- any other request ----

-spec start_request(gen_statem:from() | undefined, map(), #data{}) ->
    gen_statem:event_handler_result(atom()).
start_request(From, #{method := <<"UPDATE">>} = ReqSpec, D) ->
    %% an UPDATE with a body is an offer (RFC 3311), answered in its 2xx
    case iolist_to_binary(maps:get(body, ReqSpec, <<>>)) of
        <<>> -> start_request(From, ReqSpec, D, request);
        Sdp -> start_request(From, ReqSpec, D, {update, Sdp})
    end;
start_request(From, ReqSpec, D) ->
    start_request(From, ReqSpec, D, request).

-spec start_request(gen_statem:from() | undefined, map(), #data{}, term()) ->
    gen_statem:event_handler_result(atom()).
start_request(From, ReqSpec, D, Kind) ->
    Method = maps:get(method, ReqSpec),
    %% an early dialog's counter moves even when the request is not sent
    {Seq, _} = next_cseq(D),
    Body = iolist_to_binary(maps:get(body, ReqSpec, <<>>)),
    Headers0 = maps:get(headers, ReqSpec, []),
    Headers =
        Headers0 ++
            st_request_headers(Method, Headers0, D) ++
            chappe_sip_hdr_io:content_type(
                maps:get(content_type, ReqSpec, undefined), Body
            ),
    transact(From, Kind, {Method, Seq, Headers, Body}, D).

%% our INVITE or UPDATE carries the timer headers unless the caller set them
st_request_headers(Method, Supplied, #data{st = St}) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    [
        H
     || {N, _} = H <- chappe_sip_session_timer:refresh_headers(St),
        not has_hdr(N, Supplied)
    ];
st_request_headers(_Method, _Supplied, _D) ->
    [].

%% ---- ACK ----

%% ACK a re-INVITE 2xx (in-dialog, its own transaction; ACK reuses the
%% re-INVITE's CSeq number).
-spec send_ack(#data{}) -> {ok, term()} | {error, term()}.
send_ack(#data{local_cseq = CSeq} = D) ->
    Raw = build(D, <<"ACK">>, CSeq, [], <<>>),
    chappe_sip_engine:send_stateless(route(D), Raw, self()).

%% The ACK of a 2xx the UAC fsm left unacknowledged (no_ack, 3PCC): the
%% INVITE's CSeq number and credentials (RFC 3261 13.2.2.4), and the answer
%% to an offer the 2xx carried when Opts has one.
-spec send_delayed_ack(gen_statem:from(), map(), #data{}) ->
    gen_statem:event_handler_result(atom()).
send_delayed_ack(From, _Opts, #data{pending_ack = undefined} = D) ->
    {keep_state, D, [{reply, From, {error, no_pending_ack}}]};
send_delayed_ack(From, Opts, #data{pending_ack = #{cseq := CSeq} = P} = D) ->
    Body = iolist_to_binary(maps:get(local_sdp, Opts, <<>>)),
    Hdrs =
        maps:get(headers, P) ++
            [{<<"Content-Type">>, <<"application/sdp">>} || Body =/= <<>>],
    Raw = build(D, <<"ACK">>, CSeq, Hdrs, Body),
    case chappe_sip_engine:send_stateless(route(D), Raw, self()) of
        {ok, _} ->
            D1 =
                case Body of
                    <<>> -> D;
                    _ -> D#data{local_sdp = Body}
                end,
            {keep_state, D1#data{pending_ack = undefined}, [{reply, From, ok}]};
        Err ->
            {keep_state, D, [{reply, From, Err}]}
    end.
