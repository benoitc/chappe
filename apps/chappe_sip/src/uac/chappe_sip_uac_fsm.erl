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
%%
%% While an INVITE rings, each early dialog a tagged provisional forms is
%% indexed in chappe_sip_dialog_index (state early, role uac) under this
%% fsm's pid, so an INVITE with Replaces can name it (RFC 3891). A
%% destroy/1,2 on that handle CANCELs the INVITE. The entries go before the
%% dialog fsm of the answering 2xx indexes itself, and on every exit.
-module(chappe_sip_uac_fsm).
-behaviour(gen_statem).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").

-export([start_link/1]).
-export([init/1, callback_mode/0, terminate/3]).
-export([trying/3, established/3]).

%% challenged requests one INVITE may send: a realm per round, plus
%% stale nonces
-define(MAX_AUTH_ROUNDS, 4).

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
    %% the Digest challenges we answer, one per (header, realm), with the
    %% header our credentials go in (RFC 3261 22.2, 22.3)
    challenges = [] :: [{binary(), map()}],
    %% challenged requests sent so far (stale nonces included), bounded
    auth_rounds = 0 :: non_neg_integer(),
    %% requests sent per nonce: the nc of the next one (RFC 7616 3.4)
    nonce_count = #{} :: #{binary() => pos_integer()},
    %% the credentials of the last request sent, repeated on its 2xx ACK
    %% (RFC 3261 13.2.2.4)
    auth_hdrs = [] :: [{binary(), binary()}],
    %% 3xx targets still to try, best q first, and the ones tried
    targets = [] :: [binary()],
    tried = [] :: [binary()],
    %% the caller gave up (create_uac timeout): CANCEL, and BYE a 2xx
    abandoned = false :: boolean(),
    %% the dialog the 2xx formed, while forked 2xx linger
    dialog :: chappe_sip_dialog:dialog() | undefined,
    %% retried once without the option tags a 420 named
    ext_retried = false :: boolean(),
    redirects = 0 :: non_neg_integer(),
    winner_tag :: binary() | undefined,
    %% next available in-dialog CSeq (for PRACK); the INVITE keeps cseq
    next_cseq :: pos_integer(),
    prack_txns = [] :: [non_neg_integer()],
    %% RFC 3262 4: the last in-order RSeq of each early dialog (To tag)
    rseq = #{} :: #{binary() | undefined => pos_integer()},
    %% the answer we gave to an offer, in a PRACK or the ACK
    local_answer = <<>> :: binary(),
    %% RFC 4028 7.4: the largest Min-SE of the 422s to this INVITE, and how
    %% many times we retried after one
    min_se_422 = 0 :: non_neg_integer(),
    retries_422 = 0 :: non_neg_integer(),
    %% early dialogs indexed for Replaces (INVITE only)
    early = [] :: [chappe_sip_dialog_index:key()],
    %% the first SDP a response brought: the answer to our offer (RFC 3261
    %% 13.2.1), whatever a later response carries
    first_sdp = <<>> :: binary()
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
        flow = maps:get(flow, Opts, undefined),
        tried = [Uri]
    },
    case send_request(Data) of
        {ok, Data1} ->
            %% the owner waits on this INVITE for as long as it rings (a
            %% b2bua A leg, a handler originating a call): its handler
            %% deadline no longer applies
            _ = Method =:= <<"INVITE">> andalso chappe_sip_engine:disarm(Owner),
            {ok, trying, Data1};
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
trying(cast, cancel, D) ->
    trying(cast, {cancel, []}, D);
trying(cast, {cancel, Hdrs}, #data{txn = TxnH} = D) when TxnH =/= undefined ->
    _ = chappe_sip_engine:cancel_txn(TxnH, Hdrs),
    {keep_state, D};
trying(cast, {cancel, _}, D) ->
    {keep_state, D};
trying(cast, abandon, #data{txn = TxnH} = D) ->
    _ = TxnH =/= undefined andalso chappe_sip_engine:cancel_txn(TxnH, []),
    {keep_state, D#data{abandoned = true}};
trying({call, From}, destroy, D) ->
    trying({call, From}, {destroy, #{}}, D);
trying({call, From}, {destroy, Opts}, #data{txn = TxnH} = D) when
    TxnH =/= undefined
->
    %% an early dialog of ours named by a Replaces: CANCEL the INVITE
    _ = chappe_sip_engine:cancel_txn(TxnH, maps:get(headers, Opts, [])),
    {keep_state, D, [{reply, From, ok}]};
trying({call, From}, _Req, D) ->
    %% only destroy applies to an early dialog handle
    {keep_state, D, [{reply, From, {error, early}}]};
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
            %% a retransmission of the winner: nta resends our ACK (it
            %% matches the 2xx to the ACK transaction, RFC 3261 13.2.2.4)
            {keep_state, D};
        _ ->
            _ = send_ack(Msg, <<>>, D),
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
established({call, From}, _Req, D) ->
    %% an early handle raced the answer: the dialog is the 2xx's now
    {keep_state, D, [{reply, From, {error, answered}}]};
established(cast, {cancel, _}, D) ->
    {keep_state, D};
established(cast, abandon, #data{dialog = Dialog} = D) when
    Dialog =/= undefined
->
    %% the 2xx beat the caller's timeout: nobody will use this dialog
    _ = spawn(fun() -> chappe_sip_dialog:destroy(Dialog) end),
    {keep_state, D#data{dialog = undefined}};
established(cast, abandon, D) ->
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
    case reliable(Status, Msg, D) of
        drop ->
            %% RFC 3262 4: a retransmission or out of order, not processed
            {keep_state, D};
        Rel ->
            D1 = index_early(Msg, D),
            %% a reliable provisional (100rel) is PRACKed
            D2 =
                case Rel of
                    {new, RSeq, Key} ->
                        send_prack(RSeq, Msg, D1#data{
                            rseq = (D1#data.rseq)#{Key => RSeq}
                        });
                    unreliable ->
                        D1
                end,
            notify(D, {provisional, Msg}),
            {keep_state, first_sdp(Msg, D2)}
    end;
handle_response(
    Status, Raw, #data{method = <<"INVITE">>, abandoned = true} = D
) when
    Status >= 200, Status < 300
->
    %% the caller timed out and our CANCEL lost the race: end the call
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    AckBody =
        case ack_answer(Msg, D) of
            {ok, B} -> B;
            reject -> reject_answer(chappe_sip_msg:body(Msg))
        end,
    _ = send_ack(Msg, AckBody, D),
    _ = send_bye(Msg, D),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, unindex_early(D)};
handle_response(Status, Raw, #data{method = <<"INVITE">>} = D0) when
    Status >= 200, Status < 300
->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    D = first_sdp(Msg, D0),
    case ack_answer(Msg, D) of
        {ok, AckBody} ->
            answered(Msg, AckBody, D);
        reject ->
            %% RFC 3261 13.2.2.4: a valid answer in the ACK, then a BYE
            _ = maybe_ack(Msg, reject_answer(chappe_sip_msg:body(Msg)), D),
            _ = send_bye(Msg, D),
            notify(D, {error, offer_not_acceptable}),
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, unindex_early(D)}
    end;
handle_response(422, Raw, #data{method = <<"INVITE">>} = D) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case retry_session_interval(Msg, D) of
        {ok, D2} ->
            {next_state, trying, D2};
        give_up ->
            notify(D, {error, sip_error(422, Msg)}),
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, D}
    end;
handle_response(Status, Raw, D) when Status >= 200, Status < 300 ->
    %% non-INVITE success
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    notify(D, {response, Msg}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, D};
handle_response(Status, Raw, D) when Status =:= 401; Status =:= 407 ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case retry_with_auth(Status, Msg, D) of
        {ok, D2} ->
            {next_state, trying, D2};
        {error, _Reason} ->
            notify(D, {error, sip_error(Status, Msg)}),
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, D}
    end;
handle_response(420, Raw, #data{ext_retried = false} = D) ->
    %% RFC 3261 8.1.3.5: retry without the extensions the UAS does not
    %% support, as a new transaction of the same call
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    Unsupported = option_tags(chappe_sip_msg:get_all(<<"unsupported">>, Msg)),
    case without_tags(Unsupported, D#data.opts) of
        {ok, Opts2} ->
            chappe_sip_engine:finish_txn(D#data.txn),
            D2 = D#data{
                opts = Opts2,
                cseq = D#data.cseq + 1,
                next_cseq = D#data.cseq + 2,
                ext_retried = true
            },
            case send_request(D2) of
                {ok, D3} ->
                    {keep_state, D3};
                {error, Reason} ->
                    notify(D, {error, Reason}),
                    {stop, normal, D}
            end;
        error ->
            notify(D, {error, sip_error(420, Msg)}),
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
                    %% redirect/2 released the transaction
                    notify(D, {error, sip_error(Status, Msg)}),
                    {stop, normal, D}
            end;
        false ->
            notify(D, {error, sip_error(Status, Msg)}),
            chappe_sip_engine:finish_txn(D#data.txn),
            {stop, normal, D}
    end;
handle_response(Status, Raw, #data{targets = [_ | _]} = D) when
    Status >= 400, Status < 600
->
    %% RFC 3261 8.1.3.4: a redirect target failed; try the next one (a
    %% 6xx is a global failure and ends the search)
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_engine:finish_txn(D#data.txn),
    case next_target(D) of
        {ok, D2} ->
            {next_state, trying, D2};
        {error, _} ->
            notify(D, {error, sip_error(Status, Msg)}),
            {stop, normal, D}
    end;
handle_response(Status, Raw, D) ->
    %% non-2xx final (includes 486, 603, 480, and 401/407 without auth)
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    notify(D, {error, sip_error(Status, Msg)}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, D}.

answered(Msg, AckBody, D) ->
    ToTag = chappe_sip_msg:to_tag(Msg),
    %% the answering dialog indexes itself under one of these keys
    D1 = unindex_early(D),
    case maybe_ack(Msg, AckBody, D1) of
        ok ->
            case establish_dialog(Msg, D) of
                {ok, Dialog} ->
                    %% a b2bua copies headers from the 2xx it bridges
                    _ =
                        maps:get(report_answer, D#data.opts, false) andalso
                            notify(D, {answer, Msg}),
                    notify(D, {ok, Dialog}),
                    {next_state, established,
                        D1#data{winner_tag = ToTag, dialog = Dialog}, [
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
    end.

%% ---- offer/answer (RFC 3261 13.2.1) ----

%% remember the first SDP any response brought
first_sdp(Msg, #data{first_sdp = <<>>} = D) ->
    D#data{first_sdp = chappe_sip_msg:body(Msg)};
first_sdp(_Msg, D) ->
    D.

%% The ACK body for a 2xx: nothing when our INVITE made the offer or a
%% PRACK already answered it (RFC 3262 5); the app's answer when the 2xx
%% carries the offer (an INVITE without one). Without an answer fun, or
%% when it refuses, the offer is not acceptable.
ack_answer(_Msg, #data{local_answer = A}) when A =/= <<>> ->
    {ok, <<>>};
ack_answer(_Msg, #data{opts = #{no_ack := true}}) ->
    %% 3PCC: the answer goes in the ACK the app sends (chappe_sip_dialog:ack/2)
    {ok, <<>>};
ack_answer(Msg, #data{opts = Opts}) ->
    Offer = chappe_sip_msg:body(Msg),
    case {offered(Opts), Offer} of
        {true, _} ->
            {ok, <<>>};
        {false, <<>>} ->
            {ok, <<>>};
        {false, _} ->
            answer_offer(Offer, Opts)
    end.

answer_offer(Offer, Opts) ->
    case maps:get(answer, Opts, undefined) of
        F when is_function(F, 1) ->
            case F(Offer) of
                {ok, Answer} -> {ok, iolist_to_binary(Answer)};
                _ -> reject
            end;
        _ ->
            reject
    end.

offered(Opts) ->
    maps:is_key(local_sdp, Opts) orelse maps:is_key(body, Opts).

%% A valid answer refusing every stream of the offer: each m= line with
%% port 0 (RFC 3264 6).
reject_answer(Offer) ->
    Lines = binary:split(Offer, <<"\r\n">>, [global, trim_all]),
    iolist_to_binary([[reject_line(L), <<"\r\n">>] || L <- Lines]).

reject_line(<<"m=", Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Media, Tail] ->
            [_Port | Proto] = binary:split(Tail, <<" ">>),
            iolist_to_binary([<<"m=">>, Media, <<" 0 ">>, Proto]);
        _ ->
            <<"m=", Rest/binary>>
    end;
reject_line(L) ->
    L.

%% ---- session timers (RFC 4028) ----

%% 7.3: retry after a 422 with Session-Expires and Min-SE raised to its
%% Min-SE, same Call-ID/From/To and the next CSeq; not when the 422 asks
%% for no more than we sent, and at most three times
retry_session_interval(Msg, #data{cseq = CSeq} = D) ->
    MinSE = chappe_sip_session_timer:min_se(Msg),
    case requested_interval(D) of
        Sent when is_integer(Sent), MinSE > Sent, D#data.retries_422 < 3 ->
            chappe_sip_engine:finish_txn(D#data.txn),
            D2 = D#data{
                cseq = CSeq + 1,
                next_cseq = CSeq + 2,
                min_se_422 = MinSE,
                retries_422 = D#data.retries_422 + 1
            },
            case send_request(D2) of
                {ok, D3} -> {ok, D3};
                {error, _} -> give_up
            end;
        _ ->
            give_up
    end.

%% the Session-Expires our INVITE carries, undefined when it asks for none
requested_interval(#data{opts = Opts, min_se_422 = M}) ->
    case maps:get(expires, chappe_sip_session_timer:config(Opts)) of
        undefined -> undefined;
        Mine -> max(Mine, M)
    end.
%% ---- early dialogs (RFC 3891 Replaces) ----

%% a provisional with a To tag forms an early dialog {CallId, OurTag, Tag}
index_early(Msg, #data{method = <<"INVITE">>, early = Early} = D) ->
    case chappe_sip_msg:to_tag(Msg) of
        undefined ->
            D;
        Tag ->
            Key = {D#data.call_id, D#data.local_tag, Tag},
            case lists:member(Key, Early) of
                true ->
                    D;
                false ->
                    case
                        chappe_sip_dialog_index:insert(
                            Key, D#data.txn, early, uac, self()
                        )
                    of
                        ok -> D#data{early = [Key | Early]};
                        {error, _} -> D
                    end
            end
    end;
index_early(_Msg, D) ->
    D.

unindex_early(#data{early = Early} = D) ->
    lists:foreach(fun chappe_sip_dialog_index:delete/1, Early),
    D#data{early = []}.

terminate(_Reason, _State, D) ->
    _ = unindex_early(D),
    ok.

%% ---- reliable provisionals (100rel): PRACK ----

%% RFC 3262 4: a 101..199 with Require: 100rel and an RSeq is reliable (a
%% 100 never is); one lacking either is an ordinary provisional, never
%% PRACKed. In each early dialog the first one sets the sequence; after it
%% only RSeq + 1 is new, a lower or equal RSeq is a retransmission and a
%% higher one is out of order: both are dropped without a PRACK.
reliable(Status, Msg, #data{rseq = Seen}) when Status > 100 ->
    Required = lists:member(
        <<"100rel">>, option_tags(chappe_sip_msg:get_all(<<"require">>, Msg))
    ),
    case Required andalso rseq(Msg) of
        false ->
            unreliable;
        undefined ->
            unreliable;
        N ->
            Key = chappe_sip_msg:to_tag(Msg),
            case maps:get(Key, Seen, undefined) of
                undefined -> {new, N, Key};
                Last when N =:= Last + 1 -> {new, N, Key};
                _ -> drop
            end
    end;
reliable(_Status, _Msg, _D) ->
    unreliable.

rseq(Msg) ->
    case chappe_sip_msg:get(<<"rseq">>, Msg) of
        undefined ->
            undefined;
        V ->
            try binary_to_integer(string:trim(V)) of
                N when N >= 1, N =< 16#FFFFFFFF -> N;
                _ -> undefined
            catch
                error:badarg -> undefined
            end
    end.

%% RFC 3262 5: an offer in a reliable 1xx (our INVITE had none) is
%% answered in the PRACK; the 2xx then carries no new offer
prack_answer(Msg, #data{opts = Opts, local_answer = <<>>} = D) ->
    Offer = chappe_sip_msg:body(Msg),
    case offered(Opts) orelse Offer =:= <<>> of
        true ->
            {<<>>, D};
        false ->
            case answer_offer(Offer, Opts) of
                {ok, Answer} -> {Answer, D#data{local_answer = Answer}};
                reject -> {<<>>, D}
            end
    end;
prack_answer(_Msg, D) ->
    {<<>>, D}.

%% RAck = RSeq CSeq method. The PRACK is a request of the early dialog
%% the 1xx formed: to its Contact, through its route set (RFC 3262 4,
%% RFC 3261 12.1.2), like the 2xx ACK.
send_prack(
    RSeq,
    Msg,
    #data{
        cseq = InvCSeq,
        next_cseq = PCSeq
    } = D
) ->
    RAck = <<
        (integer_to_binary(RSeq))/binary,
        " ",
        (integer_to_binary(InvCSeq))/binary,
        " INVITE"
    >>,
    {Body, D1} = prack_answer(Msg, D),
    CT =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    Hdrs = <<"RAck: ", RAck/binary, "\r\n", CT/binary>>,
    Raw = dialog_request(<<"PRACK">>, PCSeq, Hdrs, Body, Msg, D1),
    case chappe_sip_engine:send_request(ack_route(Msg, D1), Raw, self()) of
        {ok, PTxn} ->
            D1#data{
                next_cseq = PCSeq + 1,
                prack_txns = [PTxn | D1#data.prack_txns]
            };
        _ ->
            D1
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

%% Send the request D describes, with fresh credentials for every challenge
%% we answer; {ok, D} carries the new client transaction.
send_request(#data{} = D0) ->
    D = with_credentials(D0),
    Raw = build_request(D),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} -> {ok, D#data{txn = TxnH}};
        {error, _} = Err -> Err
    end.

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
    opts = Opts,
    min_se_422 = MinSE,
    auth_hdrs = AuthHeaders
}) ->
    Seq = integer_to_binary(CSeq),
    ExtraHeaders0 = maps:get(headers, Opts, []),
    %% advertise 100rel so the UAS may send reliable provisionals, and the
    %% option tags we support on an INVITE (RFC 3891 6.2)
    Supported = supported(Method, maps:get(rel100, Opts, undefined)),
    ExtraHeaders =
        %% RFC 3262 4: Require: 100rel on an INVITE only
        case {Method, maps:get(rel100, Opts, undefined)} of
            {<<"INVITE">>, require} ->
                [{<<"Require">>, <<"100rel">>} | ExtraHeaders0];
            _ ->
                ExtraHeaders0
        end ++ supported_header(Supported, ExtraHeaders0) ++
            allow_header(Method, ExtraHeaders0),
    %% RFC 4028 7.1: an INVITE asks for a Session-Expires when configured
    StHeaders =
        case Method of
            <<"INVITE">> -> chappe_sip_session_timer:uac_headers(Opts, MinSE);
            _ -> []
        end,
    {CT, Body} = request_body(Opts),
    HdrBin = chappe_sip_hdr_io:join(
        ExtraHeaders ++ StHeaders ++ AuthHeaders ++ CT
    ),
    <<Method/binary, " ", Uri/binary, " SIP/2.0\r\n", "From: ", From/binary,
        "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
        "CSeq: ", Seq/binary, " ", Method/binary, "\r\n", "Contact: ",
        (contact_value(Contact, Opts))/binary, "\r\n", "Max-Forwards: 70\r\n",
        HdrBin/binary, "Content-Length: ",
        (integer_to_binary(byte_size(Body)))/binary, "\r\n\r\n", Body/binary>>.

supported(<<"INVITE">>, supported) -> <<"100rel, ", ?SUPPORTED/binary>>;
supported(<<"INVITE">>, _) -> ?SUPPORTED;
supported(_Method, supported) -> <<"100rel, timer">>;
%% RFC 4028 7.1: timer on every request, not only the INVITE
supported(_Method, _) -> <<"timer">>.

%% RFC 3261 13.2.1: an INVITE SHOULD carry Allow, listing the methods we
%% take in the dialog; an app-supplied one wins
allow_header(<<"INVITE">>, Headers) ->
    case
        lists:any(
            fun({N, _}) -> string:lowercase(N) =:= <<"allow">> end, Headers
        )
    of
        true -> [];
        false -> [{<<"Allow">>, ?ALLOW}]
    end;
allow_header(_Method, _Headers) ->
    [].

%% an app-supplied Supported wins
supported_header(Value, Headers) ->
    case
        lists:any(
            fun({N, _}) -> string:lowercase(N) =:= <<"supported">> end, Headers
        )
    of
        true -> [];
        false -> [{<<"Supported">>, Value}]
    end.

%% The request body: local_sdp is the common case and types itself
%% application/sdp; body carries anything else (a SIPREC
%% multipart/mixed of SDP plus rs-metadata, an ISUP body, ...) with
%% content_type naming it. body wins when both are given.
request_body(Opts) ->
    case maps:get(body, Opts, undefined) of
        undefined ->
            case maps:get(local_sdp, Opts, undefined) of
                undefined ->
                    {[], <<>>};
                Sdp ->
                    {content_type(<<"application/sdp">>), iolist_to_binary(Sdp)}
            end;
        Body ->
            CT = maps:get(content_type, Opts, <<"application/sdp">>),
            {content_type(CT), iolist_to_binary(Body)}
    end.

content_type(CT) ->
    [{<<"Content-Type">>, CT}].

%% ACK to a 2xx (unless no_ack for 3PCC). Built from the response so the
%% To carries the peer tag.
maybe_ack(_Msg, _Body, #data{opts = #{no_ack := true}}) ->
    ok;
maybe_ack(Msg, Body, D) ->
    send_ack(Msg, Body, D).

%% The ACK to a 2xx is a request of the dialog the 2xx forms (RFC 3261
%% 13.2.2.4): to its Contact, through its route set (12.1.2), with the
%% INVITE's CSeq number.
send_ack(Msg, Body, #data{cseq = CSeq} = D) ->
    CT =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    %% the ACK carries the INVITE's credentials (13.2.2.4, 22.1)
    Hdrs = <<(chappe_sip_hdr_io:join(D#data.auth_hdrs))/binary, CT/binary>>,
    Raw = dialog_request(<<"ACK">>, CSeq, Hdrs, Body, Msg, D),
    case chappe_sip_engine:send_stateless(ack_route(Msg, D), Raw, self()) of
        {ok, _} -> ok;
        Err -> Err
    end.

%% Tear down a forked extra dialog, or one whose offer we refused.
send_bye(Msg, #data{cseq = CSeq} = D) ->
    Raw = dialog_request(<<"BYE">>, CSeq + 1, <<>>, <<>>, Msg, D),
    chappe_sip_engine:send_stateless(ack_route(Msg, D), Raw, self()).

%% RFC 3261 12.2.1.1: a strict router (no ;lr) takes the Request-URI
dialog_request(Method, Seq, Hdrs, Body, Msg, #data{call_id = CallId}) ->
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To = chappe_sip_msg:get(<<"to">>, Msg),
    {RURI, RouteSet} = chappe_sip_route:request_target(
        target_uri(Msg), route_set(Msg)
    ),
    Routes = <<<<"Route: ", R/binary, "\r\n">> || R <- RouteSet>>,
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n", Routes/binary, "From: ",
        From/binary, "\r\n", "To: ", To/binary, "\r\n", "Call-ID: ",
        CallId/binary, "\r\n", "CSeq: ", (integer_to_binary(Seq))/binary, " ",
        Method/binary, "\r\n", "Max-Forwards: 70\r\n", Hdrs/binary,
        "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary,
        "\r\n\r\n", Body/binary>>.

%% RFC 3261 12.1.2: the route set is the 2xx Record-Route, reversed
route_set(Msg) ->
    lists:reverse(chappe_sip_msg:get_all(<<"record-route">>, Msg)).

%% ACK/BYE/PRACK destination: the WS flow for a browser target, else the
%% first route (a loose or a strict router), else by Request-URI
ack_route(_Msg, #data{flow = Flow}) when Flow =/= undefined -> {ws, Flow};
ack_route(Msg, _D) ->
    case route_set(Msg) of
        [First | _] ->
            case chappe_sip_hdr:name_addr(First) of
                {ok, #{uri := Uri}} -> Uri;
                _ -> undefined
            end;
        [] ->
            undefined
    end.

%% the peer's session: the first SDP it sent when we made the offer or
%% answered its offer in a PRACK, else the offer in its 2xx
remote_sdp(Msg, #data{opts = Opts, first_sdp = First, local_answer = A}) ->
    case (offered(Opts) orelse A =/= <<>>) andalso First =/= <<>> of
        true -> First;
        false -> chappe_sip_msg:body(Msg)
    end.

establish_dialog(Msg, #data{min_se_422 = MinSE} = D) ->
    %% RFC 4028 7.2: the session timer the 2xx sets up
    St = chappe_sip_session_timer:uac_answer(
        Msg, requested_interval(D), MinSE
    ),
    establish_dialog(Msg, St, D).

establish_dialog(
    Msg,
    St,
    #data{
        call_id = CallId,
        local_tag = LocalTag,
        owner = Owner,
        opts = Opts,
        next_cseq = NextCSeq,
        flow = Flow
    } = D
) ->
    % our From incl. our tag
    LocalAddr = chappe_sip_msg:get(<<"from">>, Msg),
    % our To incl. peer tag
    RemoteAddr = chappe_sip_msg:get(<<"to">>, Msg),
    RTarget = target_uri(Msg),
    %% the dialog continues from after any PRACKs sent during setup; carry the
    %% WS flow so the dialog can send in-dialog requests back over it
    DialogArgs0 = #{
        call_id => CallId,
        local_addr => LocalAddr,
        remote_addr => RemoteAddr,
        remote_target => RTarget,
        local_tag => LocalTag,
        owner => Owner,
        opts => Opts,
        %% the last CSeq number used; in-dialog requests take the next one
        cseq => NextCSeq - 1,
        flow => Flow,
        %% RFC 3261 12.1.2: route set = 2xx Record-Route reversed
        route_set => route_set(Msg),
        remote_sdp => remote_sdp(Msg, D),
        %% repeated on in-dialog target refresh requests
        local_contact => contact_value(default_contact(Opts), Opts),
        session_timer => St
    },
    %% our session is the answer a PRACK carried, else the opts' offer
    DialogArgs1 =
        case D#data.local_answer of
            <<>> -> DialogArgs0;
            A -> DialogArgs0#{local_sdp => A}
        end,
    %% no_ack (3PCC): the dialog sends the 2xx ACK when the app has it
    DialogArgs =
        case Opts of
            #{no_ack := true} ->
                DialogArgs1#{
                    pending_ack => #{
                        cseq => D#data.cseq, headers => D#data.auth_hdrs
                    }
                };
            _ ->
                DialogArgs1
        end,
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

%% RFC 3261 22.2, 22.3: answer every Digest challenge of the 401/407, one
%% per realm (the strongest algorithm, RFC 8760), and keep answering the
%% ones of earlier rounds: a 407 then a 401 ends with both credentials on
%% the request. A new challenge for a realm we already answered means our
%% credentials were refused, unless it says stale=true (only the nonce
%% expired: retry with the new one, RFC 7616 3.3).
retry_with_auth(Status, Msg, #data{cseq = CSeq} = D) ->
    {ChalHdr, AuthHdrName} = challenge_header(Status),
    Auth = maps:get(auth, D#data.opts, undefined),
    Parsed = [
        C
     || V <- chappe_sip_msg:get_all(ChalHdr, Msg),
        {ok, C} <- [chappe_sip_hdr:auth(V)]
    ],
    Usable = [
        C
     || C <- chappe_sip_digest:select(Parsed),
        credentials_for(challenge_realm(C), Auth) =/= none
    ],
    case merge_challenges(AuthHdrName, Usable, D#data.challenges) of
        {ok, Cs} when D#data.auth_rounds < ?MAX_AUTH_ROUNDS ->
            chappe_sip_engine:finish_txn(D#data.txn),
            send_request(D#data{
                challenges = Cs,
                auth_rounds = D#data.auth_rounds + 1,
                cseq = CSeq + 1,
                next_cseq = CSeq + 2
            });
        {ok, _} ->
            {error, too_many_challenges};
        Err ->
            Err
    end.

merge_challenges(_Name, [], _Old) ->
    {error, no_auth};
merge_challenges(Name, New, Old) ->
    lists:foldl(
        fun
            (_C, {error, _} = Err) ->
                Err;
            (C, {ok, Acc}) ->
                Key = {Name, challenge_realm(C)},
                case [X || {N, X} <- Acc, {N, challenge_realm(X)} =:= Key] of
                    [] ->
                        {ok, Acc ++ [{Name, C}]};
                    [_ | _] ->
                        case is_stale(C) of
                            true -> {ok, replace_challenge(Key, C, Acc)};
                            false -> {error, rejected}
                        end
                end
        end,
        {ok, Old},
        New
    ).

replace_challenge({Name, Realm}, C, Cs) ->
    [
        case N =:= Name andalso challenge_realm(X) =:= Realm of
            true -> {N, C};
            false -> {N, X}
        end
     || {N, X} <- Cs
    ].

is_stale(#{params := P}) ->
    string:lowercase(maps:get(<<"stale">>, P, <<"false">>)) =:= <<"true">>.

challenge_realm(#{params := P}) -> maps:get(<<"realm">>, P, <<>>).

challenge_nonce(#{params := P}) -> maps:get(<<"nonce">>, P, <<>>).

%% auth is #{user, pass} or a list of them; one naming a realm answers only
%% that realm's challenges
credentials_for(_Realm, undefined) ->
    none;
credentials_for(Realm, #{} = A) ->
    credentials_for(Realm, [A]);
credentials_for(Realm, List) when is_list(List) ->
    Named = [A || #{realm := R} = A <- List, R =:= Realm],
    Any = [A || A <- List, not maps:is_key(realm, A)],
    case Named ++ Any of
        [#{user := U, pass := P} | _] -> {U, P};
        _ -> none
    end.

%% the Authorization / Proxy-Authorization headers of the next request:
%% one per challenge, each nonce counting its requests (RFC 7616 3.4)
with_credentials(#data{challenges = Cs, opts = Opts} = D) ->
    Auth = maps:get(auth, Opts, undefined),
    {Hdrs, NC} = lists:foldl(
        fun({Name, Chal}, {HAcc, NAcc}) ->
            Nonce = challenge_nonce(Chal),
            N = maps:get(Nonce, NAcc, 0) + 1,
            {User, Pass} = credentials_for(challenge_realm(Chal), Auth),
            case
                chappe_sip_digest:credentials(#{
                    method => D#data.method,
                    uri => D#data.uri,
                    username => User,
                    password => Pass,
                    challenge => Chal,
                    nc => N
                })
            of
                {ok, V} -> {HAcc ++ [{Name, V}], NAcc#{Nonce => N}};
                {error, _} -> {HAcc, NAcc}
            end
        end,
        {[], D#data.nonce_count},
        Cs
    ),
    D#data{auth_hdrs = Hdrs, nonce_count = NC}.

%% RFC 3261 8.1.3.4: the Contacts of a 3xx are new targets, tried best q
%% first; each failure moves to the next one
redirect(Msg, #data{redirects = R} = D) ->
    New = redirect_targets(Msg, D),
    Targets = New ++ (D#data.targets -- New),
    chappe_sip_engine:finish_txn(D#data.txn),
    next_target(D#data{targets = Targets, redirects = R + 1}).

next_target(#data{targets = []}) ->
    {error, no_target};
next_target(#data{targets = [T | Rest], uri = OldUri, cseq = CSeq} = D) ->
    D1 = strip_auth_across_authority(OldUri, T, D#data{
        uri = T,
        to = <<"<", T/binary, ">">>,
        cseq = CSeq + 1,
        next_cseq = CSeq + 2,
        targets = Rest,
        tried = [T | D#data.tried],
        rseq = #{},
        first_sdp = <<>>
    }),
    case send_request(D1) of
        {ok, D2} -> {ok, D2};
        {error, _} -> next_target(D1)
    end.

%% sip/sips Contacts not tried yet, by q (1.0 when absent), header order
%% on a tie. A URI's ?headers part is dropped: we do not let a redirect
%% add headers to our request (RFC 3261 19.1.5 makes them optional).
redirect_targets(Msg, #data{tried = Tried}) ->
    Contacts = lists:append([
        L
     || V <- chappe_sip_msg:get_all(<<"contact">>, Msg),
        {ok, L} <- [chappe_sip_hdr:name_addr_list(V)]
    ]),
    Ranked = [
        {-q_value(maps:get(params, C, #{})), I, without_headers(Uri)}
     || {I, #{uri := Uri} = C} <- lists:enumerate(Contacts),
        supported_target(Uri)
    ],
    Uris = [U || {_, _, U} <- lists:sort(Ranked)],
    dedup([U || U <- Uris, not lists:member(U, Tried)]).

dedup([]) -> [];
dedup([H | T]) -> [H | dedup([X || X <- T, X =/= H])].

supported_target(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{scheme := S}} -> S =:= sip orelse S =:= sips;
        _ -> false
    end.

without_headers(Uri) ->
    hd(binary:split(Uri, <<"?">>)).

q_value(#{<<"q">> := Q}) when is_binary(Q) ->
    try
        binary_to_float(Q)
    catch
        error:badarg ->
            try
                float(binary_to_integer(Q))
            catch
                error:badarg -> 0.0
            end
    end;
q_value(_) ->
    1.0.

%% The request options with the option tags a 420 named taken out of what
%% we require; error when we required none of them (nothing to retry).
without_tags([], _Opts) ->
    error;
without_tags(Tags, Opts) ->
    Rel100 =
        case
            {
                maps:get(rel100, Opts, undefined),
                lists:member(<<"100rel">>, Tags)
            }
        of
            {require, true} -> {changed, supported};
            {Other, _} -> Other
        end,
    Headers = maps:get(headers, Opts, []),
    Headers2 = lists:filtermap(fun(H) -> drop_required(H, Tags) end, Headers),
    case {Rel100, Headers2} of
        {{changed, R}, _} -> {ok, Opts#{rel100 => R, headers => Headers2}};
        {_, Headers} -> error;
        {_, _} -> {ok, Opts#{headers => Headers2}}
    end.

drop_required({N, V}, Tags) ->
    case string:lowercase(N) of
        <<"require">> ->
            case option_tags([iolist_to_binary(V)]) -- Tags of
                [] ->
                    false;
                Left ->
                    {true, {N, iolist_to_binary(lists:join(<<", ">>, Left))}}
            end;
        _ ->
            true
    end.

option_tags(Values) ->
    [
        string:lowercase(string:trim(T))
     || V <- Values,
        T <- binary:split(V, <<",">>, [global]),
        string:trim(T) =/= <<>>
    ].

%% Forget the challenges (and so the credentials) of the old target when a
%% redirect leaves its scheme, host or port, or when either URI does not
%% parse: they were issued for that authority only.
strip_auth_across_authority(OldUri, NewUri, D) ->
    case chappe_sip_uri:same_authority(OldUri, NewUri) of
        true -> D;
        false -> D#data{challenges = [], nonce_count = #{}, auth_hdrs = []}
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

%% The Contact header value: our URI in angle brackets, then any
%% contact_params (`;isfocus' for a conference focus, RFC 4579).
contact_value(Contact, Opts) ->
    <<"<", Contact/binary, ">", (maps:get(contact_params, Opts, <<>>))/binary>>.

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

notify(#data{abandoned = true}, _Event) ->
    %% the caller stopped listening
    ok;
notify(#data{notify = Pid, ref = Ref}, Event) ->
    Pid ! {chappe_sip_uac, #uac_ref{pid = self(), ref = Ref}, Event},
    ok.
