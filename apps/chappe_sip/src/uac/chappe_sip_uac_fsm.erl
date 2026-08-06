%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc UAC transaction state machine.
%%
%% One fsm per logical UAC request. It builds the request, sends it, and
%% drives responses: provisional fan-out, digest retry (401/407), redirect
%% following (3xx), a dialog + ACK on the first 2xx, and forked-2xx cleanup
%% (auto ACK + BYE for extra 2xx with a different To tag). request_sent is
%% reported only after the engine confirms the send (op_ok), never on mere
%% enqueue.
-module(chappe_sip_uac_fsm).
-behaviour(gen_statem).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").

-export([start_link/1]).
-export([init/1, callback_mode/0]).
-export([trying/3, established/3]).

-record(data, {
    uri :: binary(),
    method :: binary(),
    opts :: map(),
    ref :: reference(),
    notify :: pid(),
    owner :: pid(),
    call_id :: binary(),
    % From value incl. our tag
    from :: binary(),
    % To value (no tag on the initial request)
    to :: binary(),
    % our Contact URI
    contact :: binary(),
    local_tag :: binary(),
    cseq :: pos_integer(),
    proxy :: binary() | undefined,
    % when set, originate over this WS flow
    flow :: integer() | undefined,
    txn :: non_neg_integer() | undefined,
    auth_tried = false :: boolean(),
    redirects = 0 :: non_neg_integer(),
    winner_tag :: binary() | undefined,
    %% next available in-dialog CSeq (for PRACK); the INVITE keeps cseq
    next_cseq :: pos_integer(),
    prack_txns = [] :: [non_neg_integer()],
    % RSeqs already PRACKed (dedup retransmits)
    pracked = [] :: [binary()]
}).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> state_functions.

init(#{
    uri := Uri,
    opts := Opts,
    ref := Ref,
    notify := Notify,
    owner := Owner
}) ->
    Method = maps:get(method, Opts, <<"INVITE">>),
    Contact = default_contact(Opts),
    From = build_from(Opts, Contact),
    LocalTag = extract_tag(From),
    Data = #data{
        uri = Uri,
        method = Method,
        opts = Opts,
        ref = Ref,
        notify = Notify,
        owner = Owner,
        call_id = gen_call_id(),
        from = From,
        to = maps:get(to, Opts, <<"<", Uri/binary, ">">>),
        contact = Contact,
        local_tag = LocalTag,
        cseq = 1,
        next_cseq = 2,
        proxy = maps:get(proxy, Opts, undefined),
        flow = maps:get(flow, Opts, undefined)
    },
    case send_request(Data) of
        {ok, TxnH} ->
            {ok, trying, Data#data{txn = TxnH}};
        {error, Reason} ->
            %% surfaced to the caller as start/2 -> {error, Reason}
            {stop, Reason}
    end.

%% ---- trying / proceeding ----

trying(info, {chappe_sip_op, TxnH, ok}, #data{txn = TxnH} = D) ->
    notify(D, {request_sent, #{call_id => D#data.call_id}}),
    {keep_state, D};
trying(info, {chappe_sip_op, TxnH, {error, Reason}}, #data{txn = TxnH} = D) ->
    notify(D, {error, Reason}),
    {stop, normal, D};
trying(
    info,
    {chappe_sip_response, TxnH, #{status := Status}, Raw},
    #data{txn = TxnH} = D
) ->
    handle_response(Status, Raw, D);
trying(info, {chappe_sip_response, PTxn, #{status := St}, _Raw}, D) when
    St >= 200
->
    %% a PRACK's own 2xx (or a stray final): release the PRACK transaction
    {keep_state, prack_done(PTxn, D)};
trying(cast, cancel, #data{txn = TxnH} = D) when TxnH =/= undefined ->
    _ = chappe_sip_engine:cancel_txn(TxnH),
    {keep_state, D};
trying(cast, cancel, D) ->
    {keep_state, D};
trying(info, {chappe_sip_engine_restart, _}, D) ->
    %% the native stack is going away; this transaction's reply will never
    %% arrive, so fail the caller cleanly instead of hanging
    notify(D, {error, engine_restart}),
    {stop, normal, D};
trying(info, _Other, D) ->
    {keep_state, D}.

%% ---- established: first 2xx accepted, linger for forked 2xx ----

established(
    info,
    {chappe_sip_response, TxnH, #{status := Status}, Raw},
    #data{txn = TxnH} = D
) when Status >= 200, Status < 300 ->
    %% a forked extra 2xx: accept it at transaction level then tear the
    %% extra dialog down (the app already has its dialog)
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case chappe_sip_msg:to_tag(Msg) of
        T when T =:= D#data.winner_tag ->
            % retransmit of the winner, ACK already sent
            {keep_state, D};
        _ ->
            _ = send_ack(Msg, D),
            _ = send_bye(Msg, D),
            {keep_state, D}
    end;
established(info, {chappe_sip_response, PTxn, #{status := St}, _Raw}, D) when
    St >= 200
->
    {keep_state, prack_done(PTxn, D)};
established(info, {chappe_sip_response, _TxnH, _Meta, _Raw}, D) ->
    {keep_state, D};
established(info, {chappe_sip_op, _H, _}, D) ->
    {keep_state, D};
established(cast, cancel, D) ->
    {keep_state, D};
established(state_timeout, linger_done, #data{txn = TxnH} = D) ->
    chappe_sip_engine:finish_txn(TxnH),
    {stop, normal, D};
established(info, {chappe_sip_engine_restart, _}, #data{txn = TxnH} = D) ->
    %% the dialog is already the app's; stop lingering for forked 2xx
    _ = chappe_sip_engine:finish_txn(TxnH),
    {stop, normal, D};
established(info, _Other, D) ->
    {keep_state, D}.

%% ---- response handling ----

handle_response(Status, Raw, D) when Status >= 100, Status < 200 ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    %% a reliable provisional (100rel) carries RSeq; PRACK it
    D2 = maybe_prack(Msg, D),
    notify(D, {provisional, Msg}),
    {keep_state, D2};
handle_response(Status, Raw, #data{method = <<"INVITE">>} = D) when
    Status >= 200, Status < 300
->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    ToTag = chappe_sip_msg:to_tag(Msg),
    case maybe_ack(Msg, D) of
        ok ->
            case establish_dialog(Msg, D) of
                {ok, Dialog} ->
                    notify(D, {ok, Dialog}),
                    {next_state, established, D#data{winner_tag = ToTag}, [
                        {state_timeout, 4000, linger_done}
                    ]};
                {error, Reason} ->
                    notify(D, {error, Reason}),
                    chappe_sip_engine:finish_txn(D#data.txn),
                    {stop, normal, D}
            end;
        {error, Reason} ->
            notify(D, {error, Reason}),
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, D}
    end;
handle_response(Status, Raw, D) when Status >= 200, Status < 300 ->
    %% non-INVITE success
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    notify(D, {response, Msg}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, D};
handle_response(Status, Raw, #data{auth_tried = false} = D) when
    Status =:= 401; Status =:= 407
->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case retry_with_auth(Status, Msg, D) of
        {ok, D2} ->
            {next_state, trying, D2};
        {error, Reason} ->
            notify(D, {error, sip_error(Status, Msg)}),
            _ = Reason,
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, D}
    end;
handle_response(Status, Raw, #data{opts = Opts, redirects = R} = D) when
    Status >= 300, Status < 400
->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case maps:get(follow_redirects, Opts, false) andalso R < 5 of
        true ->
            case redirect(Msg, D) of
                {ok, D2} ->
                    {next_state, trying, D2};
                {error, _} ->
                    notify(D, {error, sip_error(Status, Msg)}),
                    chappe_sip_engine:finish_txn(D#data.txn),
                    {stop, normal, D}
            end;
        false ->
            notify(D, {error, sip_error(Status, Msg)}),
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, D}
    end;
handle_response(Status, Raw, D) ->
    %% non-2xx final (includes 486, 603, 480, and 401/407 without auth)
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    notify(D, {error, sip_error(Status, Msg)}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, D}.

%% ---- reliable provisionals (100rel): PRACK ----

%% Send a PRACK for a reliable 1xx (one carrying RSeq), unless already done
%% for this RSeq (guards against 1xx retransmits). RAck = RSeq CSeq method.
maybe_prack(Msg, D) ->
    case chappe_sip_msg:get(<<"rseq">>, Msg) of
        undefined ->
            D;
        RSeq ->
            case lists:member(RSeq, D#data.pracked) of
                true -> D;
                false -> send_prack(RSeq, Msg, D)
            end
    end.

send_prack(
    RSeq,
    Msg,
    #data{
        call_id = CallId,
        cseq = InvCSeq,
        next_cseq = PCSeq
    } = D
) ->
    % our From (our tag)
    From = chappe_sip_msg:get(<<"from">>, Msg),
    % To with the peer's early tag
    To = chappe_sip_msg:get(<<"to">>, Msg),
    RURI = target_uri(Msg),
    RAck = <<RSeq/binary, " ", (integer_to_binary(InvCSeq))/binary, " INVITE">>,
    Raw =
        <<"PRACK ", RURI/binary, " SIP/2.0\r\n", "From: ", From/binary, "\r\n",
            "To: ", To/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
            "CSeq: ", (integer_to_binary(PCSeq))/binary, " PRACK\r\n", "RAck: ",
            RAck/binary, "\r\n", "Max-Forwards: 70\r\n",
            "Content-Length: 0\r\n\r\n">>,
    PRoute =
        case D#data.flow of
            undefined -> RURI;
            F -> {ws, F}
        end,
    case chappe_sip_engine:send_request(PRoute, Raw, self()) of
        {ok, PTxn} ->
            D#data{
                next_cseq = PCSeq + 1,
                prack_txns = [PTxn | D#data.prack_txns],
                pracked = [RSeq | D#data.pracked]
            };
        _ ->
            D
    end.

prack_done(PTxn, D) ->
    case lists:member(PTxn, D#data.prack_txns) of
        true ->
            chappe_sip_engine:finish_txn(PTxn),
            D#data{prack_txns = D#data.prack_txns -- [PTxn]};
        false ->
            D
    end.

%% ---- request building / sending ----

send_request(#data{} = D) ->
    Raw = build_request(D),
    chappe_sip_engine:send_request(route(D), Raw, self()).

%% originate over the WS flow when targeting a registered browser, else the
%% proxy URL (or undefined, letting sofia route by the Request-URI)
route(#data{flow = Flow}) when Flow =/= undefined -> {ws, Flow};
route(#data{proxy = Proxy}) -> Proxy.

build_request(#data{
    method = Method,
    uri = Uri,
    from = From,
    to = To,
    call_id = CallId,
    cseq = CSeq,
    contact = Contact,
    opts = Opts
}) ->
    Seq = integer_to_binary(CSeq),
    ExtraHeaders0 = maps:get(headers, Opts, []),
    %% advertise 100rel so the UAS may send reliable provisionals
    ExtraHeaders =
        case maps:get(rel100, Opts, undefined) of
            supported -> [{<<"Supported">>, <<"100rel">>} | ExtraHeaders0];
            require -> [{<<"Require">>, <<"100rel">>} | ExtraHeaders0];
            _ -> ExtraHeaders0
        end,
    AuthHeaders = maps:get('$auth_headers', Opts, []),
    {CT, Body} =
        case maps:get(local_sdp, Opts, undefined) of
            undefined ->
                {[], <<>>};
            Sdp ->
                {
                    [{<<"Content-Type">>, <<"application/sdp">>}],
                    iolist_to_binary(Sdp)
                }
        end,
    HdrBin = chappe_sip_hdr_io:join(ExtraHeaders ++ AuthHeaders ++ CT),
    <<Method/binary, " ", Uri/binary, " SIP/2.0\r\n", "From: ", From/binary,
        "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
        "CSeq: ", Seq/binary, " ", Method/binary, "\r\n", "Contact: <",
        Contact/binary, ">\r\n", "Max-Forwards: 70\r\n", HdrBin/binary,
        "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
        "\r\n\r\n", Body/binary>>.

%% ACK to a 2xx (unless no_ack for 3PCC). Built from the response so the
%% To carries the peer tag.
maybe_ack(_Msg, #data{opts = #{no_ack := true}}) ->
    ok;
maybe_ack(Msg, D) ->
    send_ack(Msg, D).

send_ack(Msg, #data{call_id = CallId, cseq = CSeq} = D) ->
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To = chappe_sip_msg:get(<<"to">>, Msg),
    RURI = target_uri(Msg),
    Seq = integer_to_binary(CSeq),
    Raw =
        <<"ACK ", RURI/binary, " SIP/2.0\r\n", "From: ", From/binary, "\r\n",
            "To: ", To/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
            "CSeq: ", Seq/binary, " ACK\r\n", "Max-Forwards: 70\r\n",
            "Content-Length: 0\r\n\r\n">>,
    case chappe_sip_engine:send_stateless(ack_route(D), Raw, self()) of
        {ok, _} -> ok;
        Err -> Err
    end.

%% ACK/BYE route: the WS flow for a browser target, else by Request-URI
ack_route(#data{flow = Flow}) when Flow =/= undefined -> {ws, Flow};
ack_route(_) -> undefined.

%% Tear down a forked extra dialog: BYE straight to its target.
send_bye(Msg, #data{call_id = CallId} = D) ->
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To = chappe_sip_msg:get(<<"to">>, Msg),
    RURI = target_uri(Msg),
    Raw =
        <<"BYE ", RURI/binary, " SIP/2.0\r\n", "From: ", From/binary, "\r\n",
            "To: ", To/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
            "CSeq: 2 BYE\r\n", "Max-Forwards: 70\r\n",
            "Content-Length: 0\r\n\r\n">>,
    chappe_sip_engine:send_stateless(ack_route(D), Raw, self()).

establish_dialog(Msg, #data{
    call_id = CallId,
    local_tag = LocalTag,
    owner = Owner,
    opts = Opts,
    next_cseq = NextCSeq,
    flow = Flow
}) ->
    % our From incl. our tag
    LocalAddr = chappe_sip_msg:get(<<"from">>, Msg),
    % our To incl. peer tag
    RemoteAddr = chappe_sip_msg:get(<<"to">>, Msg),
    RTarget = target_uri(Msg),
    %% the dialog continues from after any PRACKs sent during setup; carry the
    %% WS flow so the dialog can send in-dialog requests back over it
    DialogArgs = #{
        call_id => CallId,
        local_addr => LocalAddr,
        remote_addr => RemoteAddr,
        remote_target => RTarget,
        local_tag => LocalTag,
        owner => Owner,
        opts => Opts,
        cseq => NextCSeq,
        flow => Flow,
        %% RFC 3261 12.1.2: route set = 2xx Record-Route reversed
        route_set => lists:reverse(
            chappe_sip_msg:get_all(<<"record-route">>, Msg)
        ),
        remote_sdp => chappe_sip_msg:body(Msg)
    },
    case chappe_sip_engine:create_dialog(DialogArgs) of
        {ok, Pid, LegH} ->
            %% wait for the leg to be confirmed before handing the dialog
            %% to the app (else an immediate destroy hits setup state)
            case gen_statem:call(Pid, await_ready, 5000) of
                {ok, _} -> {ok, chappe_sip_dialog:make(Pid, LegH)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

retry_with_auth(Status, Msg, #data{opts = Opts, cseq = CSeq} = D) ->
    Auth = maps:get(auth, Opts, undefined),
    {ChalHdr, AuthHdrName} = challenge_header(Status),
    case {Auth, chappe_sip_msg:parsed(ChalHdr, Msg)} of
        {#{user := User, pass := Pass}, {ok, Challenge}} ->
            case
                chappe_sip_digest:credentials(
                    #{
                        method => D#data.method,
                        uri => D#data.uri,
                        username => User,
                        password => Pass,
                        challenge => Challenge
                    }
                )
            of
                {ok, Creds} ->
                    chappe_sip_engine:finish_txn(D#data.txn),
                    Opts2 = Opts#{'$auth_headers' => [{AuthHdrName, Creds}]},
                    D2 = D#data{
                        opts = Opts2,
                        cseq = CSeq + 1,
                        next_cseq = CSeq + 2,
                        auth_tried = true
                    },
                    case send_request(D2) of
                        {ok, TxnH} -> {ok, D2#data{txn = TxnH}};
                        Err -> Err
                    end;
                Err ->
                    Err
            end;
        _ ->
            {error, no_auth}
    end.

redirect(
    Msg,
    #data{
        cseq = CSeq,
        redirects = R,
        uri = OldUri,
        opts = Opts
    } = D
) ->
    case chappe_sip_msg:get(<<"contact">>, Msg) of
        undefined ->
            {error, no_contact};
        Contact ->
            case chappe_sip_hdr:name_addr(Contact) of
                {ok, #{uri := NewUri}} ->
                    chappe_sip_engine:finish_txn(D#data.txn),
                    %% do not replay an Authorization issued for the old
                    %% authority to a different one (credential leak)
                    Opts2 = strip_auth_across_authority(OldUri, NewUri, Opts),
                    D2 = D#data{
                        uri = NewUri,
                        to = <<"<", NewUri/binary, ">">>,
                        cseq = CSeq + 1,
                        next_cseq = CSeq + 2,
                        redirects = R + 1,
                        opts = Opts2
                    },
                    case send_request(D2) of
                        {ok, TxnH} -> {ok, D2#data{txn = TxnH}};
                        Err -> Err
                    end;
                _ ->
                    {error, bad_contact}
            end
    end.

%% Drop a computed Authorization header when the redirect crosses to a
%% different host:port; keep it for an intra-authority redirect.
strip_auth_across_authority(OldUri, NewUri, Opts) ->
    case same_authority(OldUri, NewUri) of
        true -> Opts;
        false -> maps:remove('$auth_headers', Opts)
    end.

same_authority(A, B) ->
    authority(A) =:= authority(B).

authority(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, M} -> {maps:get(host, M, undefined), maps:get(port, M, undefined)};
        _ -> undefined
    end.

%% ---- helpers ----

challenge_header(401) -> {<<"www-authenticate">>, <<"Authorization">>};
challenge_header(407) -> {<<"proxy-authenticate">>, <<"Proxy-Authorization">>}.

target_uri(Msg) ->
    case chappe_sip_msg:get(<<"contact">>, Msg) of
        undefined ->
            to_uri(Msg);
        Contact ->
            case chappe_sip_hdr:name_addr(Contact) of
                {ok, #{uri := Uri}} -> Uri;
                _ -> to_uri(Msg)
            end
    end.

to_uri(Msg) ->
    case chappe_sip_msg:to(Msg) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> <<"sip:unknown">>
    end.

sip_error(Status, Msg) ->
    #chappe_sip_error{
        status = Status,
        reason = default_or(chappe_sip_msg:reason(Msg)),
        response = Msg
    }.

default_or(undefined) -> <<>>;
default_or(R) -> R.

default_contact(Opts) ->
    case maps:get(contact, Opts, undefined) of
        undefined ->
            case chappe_sip_engine:contact() of
                undefined -> <<"sip:anonymous@localhost">>;
                C -> contact_uri(C)
            end;
        C ->
            C
    end.

contact_uri(C) ->
    case chappe_sip_hdr:name_addr(C) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> C
    end.

build_from(Opts, ContactUri) ->
    Tag = gen_tag(),
    case maps:get(from, Opts, undefined) of
        undefined ->
            <<"<", ContactUri/binary, ">;tag=", Tag/binary>>;
        From ->
            case binary:match(From, <<";tag=">>) of
                nomatch -> <<From/binary, ";tag=", Tag/binary>>;
                _ -> From
            end
    end.

extract_tag(From) ->
    case binary:split(From, <<";tag=">>) of
        [_, Rest] ->
            case binary:split(Rest, <<";">>) of
                [Tag, _] -> Tag;
                [Tag] -> Tag
            end;
        _ ->
            gen_tag()
    end.

gen_tag() ->
    binary:encode_hex(crypto:strong_rand_bytes(6), lowercase).

gen_call_id() ->
    <<
        (binary:encode_hex(crypto:strong_rand_bytes(8), lowercase))/binary,
        "@chappe"
    >>.

notify(#data{notify = Pid, ref = Ref}, Event) ->
    Pid ! {chappe_sip_uac, #uac_ref{pid = self(), ref = Ref}, Event},
    ok.
