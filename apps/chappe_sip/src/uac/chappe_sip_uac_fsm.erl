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
%% While an INVITE rings, each tagged provisional (101..199) with a new To
%% tag forms an early dialog (RFC 3261 12.1): a dialog fsm in the early
%% state, reported to the caller as {early_dialog, Dialog} before the
%% provisional. It answers the callee's requests in that dialog, sends
%% UPDATE and INFO, and is indexed for Replaces (RFC 3891) as an early
%% dialog of ours; a destroy/1,2 on it CANCELs the INVITE. The 2xx with its
%% To tag confirms it and returns the same handle (13.2.2.4); every other
%% early dialog ends when the INVITE gets its final response, the owner
%% getting destroy with reason {early_ended, Status}. The INVITE, its
%% PRACKs and the early dialogs' requests share one CSeq counter.
%%
%% The fsm keeps the states and the response dispatch; its helpers build
%% and send the requests (chappe_sip_uac_req), answer offers
%% (chappe_sip_uac_sdp), run the early dialogs and PRACKs
%% (chappe_sip_uac_early) and the retries (chappe_sip_uac_retry).
-module(chappe_sip_uac_fsm).
-behaviour(gen_statem).

-include("chappe_sip.hrl").
-include("chappe_sip_uac.hrl").
-include("chappe_sip_uac_fsm.hrl").

-export([start_link/1]).
-export([init/1, callback_mode/0, terminate/3]).
-export([trying/3, established/3]).
%% for the helpers: an early dialog is reported to the caller
-export([notify/2]).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> state_functions.

init(#{uri := Uri0, opts := Opts} = Args) ->
    %% RFC 3261 19.1.5: a method parameter names the method when the caller
    %% gives none, and never goes in the Request-URI
    {UriMethod, Uri} = chappe_sip_uri:take_param(Uri0, <<"method">>),
    case chappe_sip_uri:is_sips_unreliable(Uri) of
        true ->
            %% 19.1.1: a SIPS URI names a reliable transport; nothing is sent
            {stop, {bad_uri, sips_unreliable_transport}};
        false ->
            Method =
                case {maps:find(method, Opts), UriMethod} of
                    {{ok, M}, _} -> M;
                    {error, M} when is_binary(M), M =/= <<>> -> M;
                    {error, _} -> <<"INVITE">>
                end,
            start_request(Args#{uri := Uri}, Method)
    end.

start_request(
    #{
        uri := Uri,
        opts := Opts0,
        ref := Ref,
        notify := Notify,
        owner := Owner
    },
    Method
) ->
    %% auth_state: the challenges a previous request of the caller answered
    %% (a registration refresh), so this one carries credentials at once
    Opts = call_ref(Method, Opts0),
    {Challenges, NonceCount} = maps:get(auth_state, Opts, {[], #{}}),
    Data0 = #data{
        challenges = Challenges,
        nonce_count = NonceCount,
        uri = Uri,
        method = Method,
        opts = Opts,
        ref = Ref,
        notify = Notify,
        owner = Owner,
        call_id = maps:get(call_id, Opts, chappe_sip_uac_req:gen_call_id()),
        %% set below, once the contact is known
        from = <<>>,
        contact = <<>>,
        local_tag = <<>>,
        to = maps:get(to, Opts, <<"<", Uri/binary, ">">>),
        cseq = maps:get(cseq, Opts, 1),
        seq = atomics:new(1, []),
        proxy = maps:get(proxy, Opts, undefined),
        route_set = maps:get(
            route_set, Opts, chappe_sip_uac_req:preloaded_route(Opts)
        ),
        flow = maps:get(flow, Opts, undefined),
        tried = [Uri]
    },
    send_first(with_from(Data0)).

with_from(#data{opts = Opts} = D) ->
    Contact = chappe_sip_uac_req:default_contact(D),
    From = chappe_sip_uac_req:build_from(Opts, Contact),
    D#data{
        from = From,
        contact = Contact,
        local_tag = chappe_sip_uac_req:extract_tag(From)
    }.

send_first(#data{method = Method, owner = Owner} = Data) ->
    case chappe_sip_uac_req:send_request(Data) of
        {ok, Data1} when Method =:= <<"INVITE">> ->
            %% the owner waits on this INVITE for as long as it rings (a
            %% b2bua A leg, a handler originating a call): its handler
            %% deadline no longer applies
            _ = chappe_sip_engine:disarm(Owner),
            {ok, trying, Data1#data{
                owner_mon = erlang:monitor(process, Owner),
                cdr = open_cdr(Data1)
            }};
        {ok, Data1} ->
            {ok, trying, Data1};
        {error, Reason} ->
            %% surfaced to the caller as start/2 -> {error, Reason}
            {stop, Reason}
    end.

%% An INVITE starts a call: it serves the caller's call_ref, else one of
%% its own (chappe_sip_call); its dialogs serve it too.
call_ref(<<"INVITE">>, #{call_ref := Ref} = Opts) when is_binary(Ref) ->
    Opts;
call_ref(<<"INVITE">>, Opts) ->
    Opts#{call_ref => chappe_sip_call:new_ref()};
call_ref(_Method, Opts) ->
    Opts.

%% ---- trying / proceeding ----

trying(info, {chappe_sip_op, TxnH, ok}, #data{txn = TxnH} = D) ->
    sent(D);
trying(info, {chappe_sip_op, TxnH, {error, Reason}}, #data{txn = TxnH} = D) ->
    give_up(Reason, D);
trying(
    info,
    {chappe_sip_response, TxnH, #{status := Status}, Raw},
    #data{txn = TxnH} = D
) when Status >= 300 ->
    %% a non-2xx final ends the early dialogs of the INVITE (RFC 3261 12.3)
    handle_response(Status, Raw, chappe_sip_uac_early:end_early(Status, D));
trying(
    info,
    {chappe_sip_response, TxnH, #{status := Status}, Raw},
    #data{txn = TxnH} = D
) ->
    handle_response(Status, Raw, D);
trying(info, {chappe_sip_early_byed, Tag}, #data{early = Early} = D) ->
    {keep_state, D#data{
        early = maps:remove(Tag, Early), byed = [Tag | D#data.byed]
    }};
trying(info, {chappe_sip_response, PTxn, #{status := St}, _Raw}, D) when
    St >= 200
->
    %% a PRACK's own 2xx (or a stray final): release the PRACK transaction
    {keep_state, chappe_sip_uac_early:prack_done(PTxn, D)};
trying(cast, cancel, D) ->
    trying(cast, {cancel, []}, D);
trying(cast, {cancel, Hdrs}, #data{txn = TxnH} = D) when TxnH =/= undefined ->
    _ = chappe_sip_engine:cancel_txn(TxnH, Hdrs),
    {keep_state, D#data{cancelled = true}};
trying(cast, {cancel, _}, D) ->
    {keep_state, D};
trying(cast, abandon, D) ->
    %% create_uac's timeout passed
    abandon(D, timeout);
trying(cast, {abandon, Why}, D) ->
    %% the owner of an early dialog of ours is gone
    abandon(D, Why);
trying(cast, {abandon, Why, Hdrs}, D) ->
    %% chappe_sip_uac:abandon/2, a fork's losing branch say
    abandon(D#data{abandon_hdrs = Hdrs}, Why);
trying(info, {'DOWN', MRef, process, _, _}, #data{owner_mon = MRef} = D) ->
    %% nobody will take the call: CANCEL it, and BYE a 2xx that still comes
    abandon(D#data{owner_mon = undefined}, owner_down);
trying({call, From}, destroy, D) ->
    trying({call, From}, {destroy, #{}}, D);
trying({call, From}, {destroy, Opts}, #data{txn = TxnH} = D) when
    TxnH =/= undefined
->
    %% an early dialog of ours named by a Replaces: CANCEL the INVITE
    _ = chappe_sip_engine:cancel_txn(TxnH, maps:get(headers, Opts, [])),
    {keep_state, D#data{cancelled = true}, [{reply, From, ok}]};
trying({call, From}, _Req, D) ->
    %% only destroy applies to an early dialog handle
    {keep_state, D, [{reply, From, {error, early}}]};
trying(info, {chappe_sip_engine_restart, _}, D) ->
    %% the native stack is going away; this transaction's reply will never
    %% arrive, so fail the caller cleanly instead of hanging
    give_up(engine_restart, D);
trying(info, _Other, D) ->
    {keep_state, D}.

%% the engine sent the request
sent(D) ->
    notify(
        D,
        {request_sent, #{
            call_id => D#data.call_id,
            uri => D#data.uri,
            method => D#data.method,
            cseq => D#data.cseq
        }}
    ),
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
            _ = chappe_sip_uac_req:send_ack(Msg, <<>>, D),
            _ = chappe_sip_uac_req:send_bye(Msg, D),
            {keep_state, D}
    end;
established(info, {chappe_sip_response, PTxn, #{status := St}, _Raw}, D) when
    St >= 200
->
    {keep_state, chappe_sip_uac_early:prack_done(PTxn, D)};
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
established(cast, {abandon, _Why, Hdrs}, #data{dialog = Dialog} = D) when
    Dialog =/= undefined
->
    _ = spawn(fun() ->
        chappe_sip_dialog:destroy(Dialog, #{headers => Hdrs})
    end),
    {keep_state, D#data{dialog = undefined}};
established(cast, {abandon, _, _}, D) ->
    {keep_state, D};
established(cast, {abandon, _}, D) ->
    %% the dialog fsm watches the owner itself now
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

terminate(_Reason, _State, D) ->
    _ = chappe_sip_uac_early:end_early(undefined, D),
    ok.

%% ---- response handling: one helper per status class ----

handle_response(Status, Raw, D) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    response(Status, Msg, D).

response(Status, Msg, D) when Status >= 100, Status < 200 ->
    provisional(Status, Msg, D);
response(Status, Msg, #data{method = <<"INVITE">>, abandoned = true} = D) when
    Status >= 200, Status < 300
->
    abandoned_2xx(Status, Msg, D);
response(Status, Msg, #data{method = <<"INVITE">>} = D) when
    Status >= 200, Status < 300
->
    invite_2xx(Status, Msg, D);
response(422, Msg, #data{method = <<"INVITE">>} = D) ->
    case chappe_sip_uac_retry:session_interval(Msg, D) of
        {ok, D2} -> {next_state, trying, D2};
        give_up -> fail(sip_error(422, Msg), D)
    end;
response(Status, Msg, D) when Status >= 200, Status < 300 ->
    %% non-INVITE success
    ok = report_auth(D),
    notify(D, {response, Msg}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, D};
response(Status, Msg, D) when Status =:= 401; Status =:= 407 ->
    case chappe_sip_uac_retry:with_auth(Status, Msg, D) of
        {ok, D2} -> {next_state, trying, D2};
        {error, _Reason} -> fail(sip_error(Status, Msg), D)
    end;
response(420, Msg, #data{ext_retried = false} = D) ->
    case chappe_sip_uac_retry:without_extensions(Msg, D) of
        {ok, D3} -> {keep_state, D3};
        {error, Reason} -> give_up(Reason, D);
        error -> fail(sip_error(420, Msg), D)
    end;
response(Status, Msg, D) when Status >= 300, Status < 400 ->
    redirected(Status, Msg, D);
response(Status, Msg, #data{targets = [_ | _]} = D) when
    Status >= 400, Status < 600
->
    %% RFC 3261 8.1.3.4: a redirect target failed; try the next one (a
    %% 6xx is a global failure and ends the search)
    chappe_sip_engine:finish_txn(D#data.txn),
    retried(chappe_sip_uac_retry:next_target(D), Status, Msg, D);
response(Status, Msg, D) ->
    %% non-2xx final (includes 486, 603, 480, and 401/407 without auth)
    fail(sip_error(Status, Msg), D).

provisional(Status, Msg, D) ->
    case chappe_sip_uac_early:reliable(Status, Msg, D) of
        drop ->
            %% RFC 3262 4: a retransmission or out of order, not processed
            {keep_state, D};
        Rel ->
            D1 = chappe_sip_uac_early:early_dialog(Status, Msg, D),
            %% a reliable provisional (100rel) is PRACKed
            D2 =
                case Rel of
                    {new, RSeq, Key} ->
                        chappe_sip_uac_early:send_prack(RSeq, Msg, D1#data{
                            rseq = (D1#data.rseq)#{Key => RSeq}
                        });
                    unreliable ->
                        D1
                end,
            chappe_sip_cdr:progress(D#data.cdr, Status, #{}),
            notify(D, {provisional, Msg}),
            {keep_state, chappe_sip_uac_sdp:first_sdp(Msg, D2)}
    end.

%% the caller timed out and our CANCEL lost the race: end the call
abandoned_2xx(Status, Msg, D) ->
    AckBody =
        case chappe_sip_uac_sdp:ack_answer(Msg, D) of
            {ok, B} -> B;
            reject -> chappe_sip_uac_sdp:reject_answer(chappe_sip_msg:body(Msg))
        end,
    _ = chappe_sip_uac_req:send_ack(Msg, AckBody, D),
    _ = chappe_sip_uac_req:send_bye(Msg, D#data.abandon_hdrs, D),
    cdr_answered(Status, Msg, D),
    chappe_sip_cdr:stop(D#data.cdr, D#data.cdr_why),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, chappe_sip_uac_early:end_early(Status, D)}.

invite_2xx(Status, Msg, D0) ->
    D = chappe_sip_uac_sdp:first_sdp(Msg, D0),
    Byed = lists:member(chappe_sip_msg:to_tag(Msg), D#data.byed),
    case chappe_sip_uac_sdp:ack_answer(Msg, D) of
        {ok, AckBody} when not Byed ->
            answered(Msg, AckBody, D);
        {ok, AckBody} ->
            %% the callee BYEd this early dialog: the 2xx confirms nothing,
            %% so the call it would set up ends here (RFC 3261 13.2.2.4)
            refuse_2xx(
                Status, Msg, AckBody, {bye, remote}, early_dialog_terminated, D
            );
        reject ->
            %% RFC 3261 13.2.2.4: a valid answer in the ACK, then a BYE
            Answer = chappe_sip_uac_sdp:reject_answer(chappe_sip_msg:body(Msg)),
            refuse_2xx(
                Status, Msg, Answer, {bye, local}, offer_not_acceptable, D
            )
    end.

%% ACK and BYE a 2xx that sets up no call, and fail the caller with Err
refuse_2xx(Status, Msg, AckBody, Why, Err, D) ->
    _ = chappe_sip_uac_req:maybe_ack(Msg, AckBody, D),
    _ = chappe_sip_uac_req:send_bye(Msg, D),
    cdr_answered(Status, Msg, D),
    chappe_sip_cdr:stop(D#data.cdr, Why),
    notify(D, {error, Err}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, chappe_sip_uac_early:end_early(Status, D)}.

redirected(Status, Msg, #data{opts = Opts, redirects = R} = D) ->
    case maps:get(follow_redirects, Opts, false) andalso R < 5 of
        true ->
            %% redirect/3 releases the transaction
            retried(
                chappe_sip_uac_retry:redirect(Status, Msg, D), Status, Msg, D
            );
        false ->
            fail(sip_error(Status, Msg), D)
    end.

%% a retry sent is the new transaction; when none could be sent, the
%% caller gets the response that asked for it
retried({ok, D2}, _Status, _Msg, _D) ->
    {next_state, trying, D2};
retried({error, _}, Status, Msg, D) ->
    give_up(sip_error(Status, Msg), D).

%% The dialog (its leg) exists before the ACK goes out: the callee may send
%% a request in it the moment it has the ACK, and one reaching the engine
%% before the leg is a request for no dialog of ours (481).
answered(Msg, AckBody, D) ->
    ToTag = chappe_sip_msg:to_tag(Msg),
    %% the record is answered before the dialog binds it
    cdr_answered(chappe_sip_msg:status(Msg), Msg, D),
    %% the early dialog of this To tag is confirmed; the others end
    {Mine, D1} = chappe_sip_uac_early:take_early(ToTag, D),
    case chappe_sip_uac_early:establish_dialog(Mine, Msg, D1) of
        {ok, Dialog} ->
            case chappe_sip_uac_req:maybe_ack(Msg, AckBody, D) of
                ok ->
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
                    _ = chappe_sip_uac_early:drop_dialog(Dialog),
                    fail(Reason, D)
            end;
        {error, Reason} ->
            _ = chappe_sip_uac_req:maybe_ack(Msg, AckBody, D),
            fail(Reason, D)
    end.

%% the request failed with Err: the caller is told and the transaction
%% released
fail(Err, D) ->
    notify(D, {error, Err}),
    chappe_sip_engine:finish_txn(D#data.txn),
    {stop, normal, D}.

%% the request failed with Err, its transaction already gone
give_up(Err, D) ->
    notify(D, {error, Err}),
    {stop, normal, D}.

%% report_auth => true: the challenges answered and their nonce counts, for
%% the caller's next request (auth_state)
report_auth(#data{opts = #{report_auth := true}, challenges = [_ | _]} = D) ->
    notify(D, {auth_state, {D#data.challenges, D#data.nonce_count}});
report_auth(_D) ->
    ok.

sip_error(Status, Msg) ->
    #chappe_sip_error{
        status = Status,
        reason = default_or(chappe_sip_msg:reason(Msg)),
        response = Msg
    }.

default_or(undefined) -> <<>>;
default_or(R) -> R.

notify(D, {error, Err} = Event) ->
    cdr_failed(Err, D),
    notify_1(D, Event);
notify(D, Event) ->
    notify_1(D, Event).

notify_1(#data{abandoned = true}, _Event) ->
    %% the caller stopped listening
    ok;
notify_1(#data{notify = Pid, ref = Ref}, Event) ->
    Pid ! {chappe_sip_uac, #uac_ref{pid = self(), ref = Ref}, Event},
    ok.

%% CANCEL the INVITE nobody waits for; a 2xx that still comes is ACKed and
%% BYEd (response/3)
abandon(#data{abandoned = true} = D, _Why) ->
    {keep_state, D};
abandon(#data{txn = TxnH, abandon_hdrs = Hdrs} = D, Why) ->
    _ = TxnH =/= undefined andalso chappe_sip_engine:cancel_txn(TxnH, Hdrs),
    {keep_state, D#data{abandoned = true, cdr_why = Why}}.

%% ---- call records (chappe_sip_cdr) ----

%% Opts cdr => #{role => b2b_b, link => Id}: a b2bua's B leg
open_cdr(#data{opts = Opts} = D) ->
    Cdr = maps:get(cdr, Opts, #{}),
    CallRef = maps:get(call_ref, Opts, undefined),
    ok = chappe_sip_hep:correlate(D#data.call_id, CallRef, uac),
    chappe_sip_cdr:open(
        maps:get(role, Cdr, uac),
        #{
            link => maps:get(link, Cdr, undefined),
            call_ref => CallRef,
            related => maps:get(related, Opts, undefined),
            call_id => D#data.call_id,
            from => D#data.from,
            to => D#data.to,
            request_uri => D#data.uri,
            local_tag => D#data.local_tag,
            transport => uri_transport(D#data.uri)
        },
        self()
    ).

uri_transport(Uri) ->
    case chappe_sip_uri:take_param(Uri, <<"transport">>) of
        {T, _} when is_binary(T) -> T;
        _ -> undefined
    end.

cdr_answered(Status, Msg, D) ->
    chappe_sip_cdr:progress(D#data.cdr, Status, #{
        remote_tag => chappe_sip_msg:to_tag(Msg)
    }).

%% the INVITE failed: the reason we gave up, else what the final says
cdr_failed(_Err, #data{cdr = undefined}) ->
    ok;
cdr_failed(_Err, #data{cdr = Id, cdr_why = Why}) when Why =/= undefined ->
    chappe_sip_cdr:stop(Id, Why);
cdr_failed(#chappe_sip_error{status = 487}, #data{cdr = Id, cancelled = true}) ->
    chappe_sip_cdr:cancelled(Id);
cdr_failed(#chappe_sip_error{status = Status}, #data{cdr = Id}) ->
    chappe_sip_cdr:progress(Id, Status, #{});
cdr_failed(engine_restart, #data{cdr = Id}) ->
    chappe_sip_cdr:stop(Id, engine_restart);
cdr_failed(Other, #data{cdr = Id}) ->
    chappe_sip_cdr:stop(Id, {process_down, Other}).
