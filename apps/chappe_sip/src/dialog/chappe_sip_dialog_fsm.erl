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
%%
%% A dialog formed by a SUBSCRIBE (RFC 6665) carries a subscription: an
%% expiry timer, refreshes answered here, and a teardown that sends a final
%% NOTIFY (Subscription-State: terminated) instead of a BYE.
%%
%% On entering confirmed the fsm indexes itself in chappe_sip_dialog_index
%% by {CallId, LocalTag, RemoteTag} (RFC 3891 Replaces lookups). It removes
%% the entry before it tells the owner (or a destroy/1 caller) the dialog is
%% gone, and again in terminate/3; the index server sweeps a killed fsm.
%%
%% An early dialog of an INVITE we send (a tagged 1xx, RFC 3261 12.1) runs
%% here too, with uac set to the INVITE's UAC fsm: it answers the callee's
%% requests (UPDATE, INFO, a BYE that ends it), sends UPDATE and INFO, and
%% shares the INVITE's CSeq counter with the PRACKs the UAC fsm sends. A
%% destroy CANCELs the INVITE. The 2xx with its To tag confirms it
%% ({confirm, Args}, 13.2.2.4); any other final ends it ({early_end, _}).
%%
%% The work is shared with helpers that run in this process, on its
%% #data{} (chappe_sip_dialog_fsm.hrl): chappe_sip_dialog_route (the peer's
%% requests), _offer (offer/answer, pure), _out (what goes on the wire),
%% _sub (subscriptions and the teardown), _st (session timers) and _owner
%% (the owner, the index, the call record).
-module(chappe_sip_dialog_fsm).
-behaviour(gen_statem).

-include("chappe_sip_dialog_fsm.hrl").

%% an ACK names the dialog leg, or the INVITE server transaction of our 2xx
-define(IS_OURS(H, D), (H =:= D#data.leg orelse H =:= D#data.txn)).

-export([start_link/1]).
-export([init/1, callback_mode/0, terminate/3]).
-export([indialog_request/4]).
-export([
    setup/3,
    setup_failed/3,
    confirmed/3,
    in_transaction/3,
    terminating/3
]).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> state_functions.

%% Args (both UAS and UAC): leg, call_id, local_addr (our From w/ tag),
%% remote_addr (peer To/From w/ tag), remote_target (peer Contact URI),
%% local_tag, owner, opts, cseq (the last local CSeq number used: our next
%% in-dialog request takes cseq + 1, RFC 3261 12.2.1.1).
init(Args) ->
    Data = new_data(Args),
    %% in the index before a UAS dialog's 2xx leaves (chappe_sip_engine sends
    %% it once we are started), so a peer acting on that 2xx at once, by a
    %% Replaces or a find_dialog/3, finds the dialog. The state stream hears
    %% of it once it is confirmed (setup_done/1).
    Data1 = chappe_sip_dialog_owner:index(
        chappe_sip_dialog_offer:derived(Data)
    ),
    ok = announce(Data1),
    %% Any dialog-forming response (UAS) is sent by chappe_sip_engine (sending
    %% it from here would re-enter chappe_sip_engine during our own start and
    %% deadlock). A UAC dialog has already been answered (2xx) before we
    %% start. A setup timeout bounds the wait for the leg op result, so a
    %% never-arriving op_ok/op_failed does not strand the fsm and its leg.
    Timers =
        chappe_sip_subscription:timer(Data#data.sub) ++
            chappe_sip_dialog_st:st_timers(Data#data.st),
    {ok, setup, Data1, [{state_timeout, 30000, setup_timeout} | Timers]}.

new_data(
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
    Contact = maps:get(local_contact, Args, undefined),
    Sub = chappe_sip_subscription:new(
        maps:get(subscription, Opts, undefined), Contact
    ),
    #data{
        leg = LegH,
        txn = maps:get(txn, Args, undefined),
        %% a leg created ahead (a B2BUA's early leg) is ready already
        ready = maps:get(leg_ready, Args, false),
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
        remote_sdp = maps:get(remote_sdp, Args, <<>>),
        role = maps:get(role, Args, uac),
        index_state = initial_index_state(Args, Opts),
        sub = Sub,
        local_contact = Contact,
        remote_cseq = maps:get(remote_cseq, Args, 0),
        ack_wait = maps:get(ack_wait, Args, false),
        pending_ack = maps:get(pending_ack, Args, undefined),
        st = maps:get(
            session_timer, Args, maps:get(session_timer, Opts, undefined)
        ),
        st_cfg = chappe_sip_session_timer:config(Opts),
        option_tags = maps:get(option_tags, Opts, []),
        uac = maps:get(early_uac, Args, undefined),
        cseq_ref = maps:get(cseq_ref, Args, undefined),
        cdr = maps:get(cdr, Args, undefined),
        call_ref = maps:get(call_ref, Opts, undefined)
    }.

%% the state to index under once confirmed: early when the dialog-forming
%% response was provisional
initial_index_state(#{early_uac := Pid}, _Opts) when is_pid(Pid) ->
    early;
initial_index_state(_Args, Opts) ->
    case maps:get(status, Opts, 200) of
        S when is_integer(S), S < 200 -> early;
        _ -> confirmed
    end.

%% the call record follows the dialog, and the dialog is found by its
%% call's ref while it lives (chappe_sip_call)
announce(#data{call_ref = Ref, leg = LegH} = D) ->
    chappe_sip_dialog_owner:cdr_bind(D),
    chappe_sip_call:join(Ref, dialog, chappe_sip_dialog:make(self(), LegH)).

%% ---- setup: waiting for the leg op result ----

setup({call, From}, Req, D) ->
    setup_call(From, Req, D);
setup(info, Msg, D) ->
    setup_info(Msg, D);
setup(state_timeout, setup_timeout, D) ->
    abort_setup(setup_timeout, D);
setup({timeout, _}, _, D) ->
    %% subscription expiry, session refresh or expiry: once confirmed
    {keep_state, D, [postpone]}.

setup_call(From, await_ready, #data{ready = true, leg = LegH} = D) ->
    {next_state, confirmed, setup_done(D), [{reply, From, {ok, LegH}}]};
setup_call(From, await_ready, D) ->
    {keep_state, D#data{await_from = From}};
setup_call(From, Req, D) ->
    case chappe_sip_dialog_owner:is_query(Req) of
        %% what the dialog was started with is known already
        true ->
            chappe_sip_dialog_owner:query(From, Req, D);
        %% the dialog is indexed from its start, so it can be found (and
        %% called) before the owner has waited for its leg: serve the call
        %% once confirmed, or answer it {error, terminated} if the setup
        %% fails
        false ->
            {keep_state, D, [postpone]}
    end.

setup_info(
    {chappe_sip_op, LegH, ok}, #data{leg = LegH, await_from = undefined} = D
) ->
    {keep_state, D#data{ready = true}};
setup_info({chappe_sip_op, LegH, ok}, #data{leg = LegH, await_from = From} = D) ->
    {next_state, confirmed, setup_done(D#data{await_from = undefined}), [
        {reply, From, {ok, LegH}}
    ]};
setup_info({chappe_sip_op, LegH, {error, Reason}}, #data{leg = LegH} = D) ->
    abort_setup(Reason, D);
setup_info({'DOWN', MRef, process, _, _}, #data{owner_mon = MRef} = D) ->
    owner_down(setup, D);
setup_info({chappe_sip_engine_restart, _}, D) ->
    lost(setup, engine_restart, D);
setup_info({chappe_sip_flow_lost, LegH}, #data{leg = LegH} = D) ->
    lost(setup, flow_lost, D);
setup_info({chappe_sip_indialog, LegH, _, _, _}, #data{leg = LegH} = D) ->
    %% the peer may send a request (a BYE on our ACK) before the leg op
    %% result is in: handle it once confirmed rather than drop it
    {keep_state, D, [postpone]};
setup_info({chappe_sip_ack, H, _}, D) when ?IS_OURS(H, D) ->
    %% the 2xx ACK of a dialog-forming INVITE names its server transaction,
    %% and a fast peer sends it before the owner has waited for the leg
    {keep_state, D, [postpone]};
setup_info({chappe_sip_ack_timeout, H}, D) when ?IS_OURS(H, D) ->
    {keep_state, D, [postpone]};
setup_info({chappe_sip_cancel, TxnH, _}, #data{txn = TxnH} = D) ->
    {keep_state, D, [postpone]};
setup_info(_Other, D) ->
    {keep_state, D}.

%% the dialog leaves setup: the state stream hears of it now, not when it
%% was indexed, so a setup that fails never reads as confirmed
setup_done(#data{indexed = undefined} = D) ->
    D;
setup_done(D) ->
    ok = chappe_sip_dialog_owner:publish_state(D, D#data.index_state),
    D.

%% the caller waiting for the leg hears why the setup failed
abort_setup(Reason, D) ->
    chappe_sip_dialog_owner:reply_await(D, {error, Reason}),
    fail_setup(D).

%% a setup that fails answers the calls it postponed, then stops: they are
%% replayed in setup_failed, ahead of the zero timeout
fail_setup(D) ->
    {next_state, setup_failed, D, [{state_timeout, 0, stop}]}.

setup_failed(state_timeout, stop, D) ->
    {stop, normal, D};
setup_failed({call, From}, _Req, _D) ->
    {keep_state_and_data, [{reply, From, {error, terminated}}]};
setup_failed(_Type, _Event, D) ->
    {keep_state, D}.

%% ---- confirmed ----

confirmed(info, Msg, D) ->
    confirmed_info(Msg, D);
confirmed({call, From}, Req, D) ->
    confirmed_call(From, Req, D);
confirmed(cast, {early_end, Reason}, D) ->
    chappe_sip_dialog_owner:stop(Reason, D);
confirmed(cast, {early_sdp, Sdp}, D) ->
    {keep_state, chappe_sip_dialog_offer:early_sdp(Sdp, D)};
confirmed({timeout, Name}, Msg, D) ->
    confirmed_timeout(Name, Msg, D);
confirmed(state_timeout, sub_done, D) ->
    %% a terminated NOTIFY was answered: the subscription is over
    chappe_sip_dialog_owner:stop(terminated, D).

confirmed_info({chappe_sip_ack, H, Raw}, D) when ?IS_OURS(H, D) ->
    ack_received(Raw, D);
confirmed_info({chappe_sip_ack_timeout, H}, D) when ?IS_OURS(H, D) ->
    %% RFC 3261 13.3.1.4 and 14.2: our 2xx was never ACKed; end the session
    {From, Hdrs} = held_bye(D),
    chappe_sip_dialog_sub:start_teardown(From, Hdrs, D#data{
        ack_wait = false, bye_after_ack = undefined, bye_reason = no_ack
    });
confirmed_info({chappe_sip_final, TxnH, Status, Body}, D) ->
    D1 = chappe_sip_dialog_offer:claimed_final(TxnH, Status, Body, D),
    {keep_state, D1, chappe_sip_dialog_offer:held_modify(D1)};
confirmed_info(
    {chappe_sip_indialog, LegH, TxnH, Meta, Raw}, #data{leg = LegH} = D
) ->
    chappe_sip_dialog_route:handle_indialog(TxnH, Meta, Raw, D);
confirmed_info(
    {chappe_sip_cancel, TxnH, _Req},
    #data{role = uas, index_state = early, txn = TxnH} = D
) ->
    %% the caller CANCELled the INVITE of this early dialog: the stack
    %% answered it 487, so the early dialog is over (RFC 3261 9.2)
    chappe_sip_dialog_owner:stop(cancel, D);
confirmed_info({chappe_sip_cancel, _TxnH, _Req}, D) ->
    %% late CANCEL after the dialog was established; ignore
    {keep_state, D};
confirmed_info({st_refreshed, St}, D) ->
    chappe_sip_dialog_st:st_apply(St, D);
confirmed_info({chappe_sip_engine_restart, _}, D) ->
    lost(confirmed, engine_restart, D);
confirmed_info({chappe_sip_flow_lost, LegH}, #data{leg = LegH} = D) ->
    lost(confirmed, flow_lost, D);
confirmed_info({'DOWN', MRef, process, _, _}, #data{owner_mon = MRef} = D) ->
    owner_down(confirmed, D);
confirmed_info(_Other, D) ->
    {keep_state, D}.

confirmed_call(From, {confirm, Args}, D) ->
    early_confirm(From, Args, D);
confirmed_call(From, destroy, D) ->
    confirmed_call(From, {destroy, #{}}, D);
confirmed_call(From, {destroy, Opts}, D) ->
    destroy(From, maps:get(headers, Opts, []), D);
confirmed_call(From, {notify, _}, #data{sub = #{state := terminated}} = D) ->
    {keep_state, D, [{reply, From, {error, terminated}}]};
confirmed_call(From, {notify, Spec}, D) ->
    chappe_sip_dialog_sub:start_notify(From, Spec, D);
confirmed_call(From, {modify, SdpSpec}, D) ->
    confirmed_call(From, {modify, SdpSpec, #{}}, D);
confirmed_call(From, {modify, SdpSpec, Opts}, D) ->
    modify(From, SdpSpec, Opts, D);
confirmed_call(From, {request, ReqSpec}, D) ->
    chappe_sip_dialog_out:start_request(From, ReqSpec, D);
confirmed_call(From, {ack, Opts}, D) ->
    chappe_sip_dialog_out:send_delayed_ack(From, Opts, D);
confirmed_call(From, Query, D) ->
    chappe_sip_dialog_owner:query(From, Query, D).

confirmed_timeout(sub_expiry, expire, D) ->
    chappe_sip_dialog_sub:expire(D);
confirmed_timeout(st_refresh, refresh, #data{st = #{}} = D) ->
    chappe_sip_dialog_st:start_st_refresh(D);
confirmed_timeout(st_expire, expire, #data{st = #{}} = D) ->
    %% RFC 4028 10: no refresh before the session expiration
    chappe_sip_dialog_sub:start_teardown(undefined, [], D#data{
        bye_reason = session_expired
    });
confirmed_timeout(st_refresh, _, D) ->
    {keep_state, D};
confirmed_timeout(st_expire, _, D) ->
    {keep_state, D};
confirmed_timeout(glare_retry, retry, #data{glare_wait = {From, Spec}} = D) ->
    chappe_sip_dialog_out:start_reinvite(
        From, Spec, #{ack => D#data.reinvite_ack}, D#data{
            glare_wait = undefined
        }
    ).

destroy(From, Hdrs, #data{uac = Uac} = D) when Uac =/= undefined ->
    %% RFC 3261 15: the caller ends an early dialog of its INVITE with a
    %% CANCEL of that INVITE
    gen_statem:cast(Uac, {cancel, Hdrs}),
    {keep_state, D, [{reply, From, ok}]};
destroy(From, _Hdrs, #data{sub = #{state := terminated}} = D) ->
    {keep_state, D, [{reply, From, ok}]};
destroy(From, Hdrs, #data{ack_wait = true} = D) ->
    {keep_state, D#data{bye_after_ack = {From, Hdrs}}};
destroy(From, Hdrs, D) ->
    chappe_sip_dialog_sub:start_teardown(From, Hdrs, D).

modify(From, _SdpSpec, _Opts, #data{uac = Uac} = D) when Uac =/= undefined ->
    %% no re-INVITE before the INVITE completes (RFC 3261 14.1); an early
    %% dialog takes UPDATE
    {keep_state, D, [{reply, From, {error, early}}]};
modify(From, SdpSpec, Opts, D) ->
    case {chappe_sip_dialog_offer:invite_server_open(D), D#data.modify_wait} of
        {true, undefined} ->
            %% RFC 3261 14.1: wait for the INVITE server transaction to
            %% be confirmed (its ACK) or terminated
            {keep_state, D#data{modify_wait = {From, SdpSpec, Opts}}};
        {true, _Held} ->
            {keep_state, D, [{reply, From, {error, request_pending}}]};
        {false, _} ->
            chappe_sip_dialog_out:start_reinvite(From, SdpSpec, Opts, D#data{
                modify_wait = undefined
            })
    end.

%% The ACK of our 2xx: then send the BYE the owner asked for meanwhile,
%% or the re-INVITE it held.
ack_received(Raw, D) ->
    D1 = (chappe_sip_dialog_offer:handle_ack(Raw, D))#data{ack_wait = false},
    case D1#data.bye_after_ack of
        {From, Hdrs} ->
            chappe_sip_dialog_sub:start_teardown(From, Hdrs, D1#data{
                bye_after_ack = undefined
            });
        undefined ->
            {keep_state, D1, chappe_sip_dialog_offer:held_modify(D1)}
    end.

held_bye(#data{bye_after_ack = {From, Hdrs}}) -> {From, Hdrs};
held_bye(_) -> {undefined, []}.

%% ---- in_transaction: one outgoing in-dialog request in flight ----
%% Competing outgoing operations are postponed (serialized). Incoming
%% in-dialog requests and acks are still handled.

in_transaction(info, Msg, D) ->
    in_transaction_info(Msg, D);
in_transaction({call, From}, Req, D) ->
    in_transaction_call(From, Req, D);
in_transaction(cast, {early_end, Reason}, D) ->
    chappe_sip_dialog_owner:reply(txning_from(D), {error, terminated}),
    chappe_sip_dialog_owner:stop(Reason, D);
in_transaction(cast, {early_sdp, Sdp}, D) ->
    {keep_state, chappe_sip_dialog_offer:early_sdp(Sdp, D)};
in_transaction({timeout, _}, _, D) ->
    {keep_state, D, [postpone]}.

in_transaction_info(
    {chappe_sip_response, TxnH, #{status := Status}, Raw},
    #data{txning = {From, TxnH, Kind}} = D
) ->
    %% release the client transaction on a final (else one handle leaks per
    %% in-dialog request for the life of the dialog)
    _ = Status >= 200 andalso chappe_sip_engine:finish_txn(TxnH),
    %% a 2xx to our INVITE or UPDATE refreshes the session (RFC 4028 7.2)
    {D1, StActs} = chappe_sip_dialog_st:st_response(Status, Raw, D),
    chappe_sip_dialog_st:with_actions(
        finish_txn_response(From, Kind, Status, Raw, D1), StActs
    );
in_transaction_info(
    {chappe_sip_op, TxnH, {error, Reason}}, #data{txning = {From, TxnH, _}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    chappe_sip_dialog_owner:reply(From, {error, Reason}),
    {next_state, confirmed, D#data{txning = undefined}};
in_transaction_info({chappe_sip_op, _TxnH, _}, D) ->
    {keep_state, D};
in_transaction_info({chappe_sip_ack, H, _Raw}, D) when ?IS_OURS(H, D) ->
    %% handled once our transaction is done: it may release a held BYE
    {keep_state, D, [postpone]};
in_transaction_info({chappe_sip_ack_timeout, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_info({chappe_sip_final, TxnH, Status, Body}, D) ->
    {keep_state, chappe_sip_dialog_offer:claimed_final(TxnH, Status, Body, D)};
in_transaction_info(
    {chappe_sip_indialog, LegH, TxnH, Meta, Raw}, #data{leg = LegH} = D
) ->
    %% a peer BYE during our transaction still terminates the dialog
    chappe_sip_dialog_route:handle_indialog(TxnH, Meta, Raw, D);
in_transaction_info({st_refreshed, St}, D) ->
    chappe_sip_dialog_st:st_apply(St, D);
in_transaction_info({chappe_sip_engine_restart, _}, D) ->
    lost(in_transaction, engine_restart, D);
in_transaction_info({chappe_sip_flow_lost, LegH}, #data{leg = LegH} = D) ->
    lost(in_transaction, flow_lost, D);
in_transaction_info({'DOWN', MRef, process, _, _}, #data{owner_mon = MRef} = D) ->
    owner_down(in_transaction, D);
in_transaction_info(_Other, D) ->
    {keep_state, D}.

in_transaction_call(From, {confirm, Args}, D) ->
    %% the 2xx to the INVITE while our UPDATE in the early dialog runs
    early_confirm(From, Args, D);
in_transaction_call(_From, {modify, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(_From, {modify, _, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(_From, {request, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(_From, {ack, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(_From, {notify, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(_From, {destroy, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(_From, destroy, D) ->
    {keep_state, D, [postpone]};
in_transaction_call(From, Query, D) ->
    chappe_sip_dialog_owner:query(From, Query, D).

txning_from(#data{txning = {From, _, _}}) -> From;
txning_from(_) -> undefined.

finish_txn_response(From, {st_refresh, _} = Kind, Status, Raw, D) ->
    chappe_sip_dialog_st:st_refresh_response(From, Kind, Status, Raw, D);
finish_txn_response(From, {reinvite, _} = Kind, Status, Raw, D) ->
    chappe_sip_dialog_out:reinvite_response(From, Kind, Status, Raw, D);
finish_txn_response(_From, _Kind, Status, _Raw, D) when Status < 200 ->
    %% a provisional: the transaction stays open until its final response
    {keep_state, D};
finish_txn_response(From, Kind, Status, Raw, D) ->
    %% final to a request or a NOTIFY
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_dialog_owner:reply(From, {ok, Msg}),
    D1 = chappe_sip_dialog_offer:update_answered(Kind, Status, Msg, D),
    chappe_sip_dialog_sub:after_request(Kind, Status, D1#data{
        txning = undefined
    }).

%% ---- terminating: waiting for our BYE final response ----

terminating(info, Msg, D) ->
    terminating_info(Msg, D);
terminating({timeout, glare_retry}, _, #data{glare_wait = {From, _}} = D) ->
    chappe_sip_dialog_owner:reply(From, {error, terminating}),
    {keep_state, D#data{glare_wait = undefined}};
terminating({timeout, _}, _, D) ->
    {keep_state, D};
terminating({call, From}, Req, D) ->
    case chappe_sip_dialog_owner:is_query(Req) of
        true -> chappe_sip_dialog_owner:query(From, Req, D);
        false -> {keep_state, D, [{reply, From, {error, terminating}}]}
    end.

terminating_info(
    {chappe_sip_response, TxnH, #{status := Status}, _Raw},
    #data{pending = {_, TxnH}, sub = Sub} = D
) when Status < 200, Sub =/= undefined ->
    %% provisional to the final NOTIFY: keep waiting for its final
    {keep_state, D};
terminating_info(
    {chappe_sip_response, TxnH, _Meta, _Raw}, #data{pending = {From, TxnH}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    ended(From, D);
terminating_info(
    {chappe_sip_op, TxnH, {error, Reason}}, #data{pending = {From, TxnH}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    chappe_sip_dialog_owner:unindex(D),
    chappe_sip_dialog_owner:reply(From, {error, Reason}),
    {stop, normal, D};
terminating_info({chappe_sip_op, _TxnH, ok}, D) ->
    {keep_state, D};
terminating_info(
    {chappe_sip_indialog, LegH, TxnH, _Meta, _Raw}, #data{leg = LegH} = D
) ->
    %% peer BYE crossing our BYE: answer 200 and finish
    _ = chappe_sip_dialog_out:respond(TxnH, 200, <<"OK">>),
    {keep_state, D};
terminating_info({chappe_sip_engine_restart, _}, D) ->
    lost(terminating, engine_restart, D);
terminating_info({chappe_sip_flow_lost, LegH}, #data{leg = LegH} = D) ->
    %% our BYE can no longer be answered
    ended(pending_from(D), D);
terminating_info(_Other, D) ->
    {keep_state, D}.

%% our last request is done (or can no longer be answered): the dialog ends
ended(From, D) ->
    chappe_sip_dialog_owner:unindex(D),
    chappe_sip_dialog_owner:reply(From, ok),
    chappe_sip_dialog_owner:stop(chappe_sip_dialog_sub:term_reason(D), D).

pending_from(#data{pending = {From, _}}) -> From;
pending_from(_) -> undefined.

%% ---- the dialog lost its transport, its engine or its owner ----

%% the engine restarted, or the WS flow of the dialog closed
lost(setup, Reason, D) ->
    abort_setup(Reason, D#data{cdr_why = Reason});
lost(in_transaction, Reason, D) ->
    chappe_sip_dialog_owner:reply(txning_from(D), {error, Reason}),
    chappe_sip_dialog_owner:stop(Reason, D);
lost(_State, Reason, D) ->
    chappe_sip_dialog_owner:stop(Reason, D).

%% the owner is gone: on_owner_exit = destroy ends the dialog
owner_down(_State, #data{on_owner_exit = continue} = D) ->
    {keep_state, D};
owner_down(setup, D) ->
    %% owner died before the dialog was confirmed; drop the half-formed leg
    lost(setup, owner_down, D);
owner_down(_State, #data{uac = Uac} = D) when Uac =/= undefined ->
    %% before the INVITE completed: the UAC fsm CANCELs it and ends the
    %% call should a 2xx still come
    gen_statem:cast(Uac, {abandon, owner_down}),
    {keep_state, D};
owner_down(confirmed, #data{ack_wait = true} = D) ->
    {keep_state, D#data{bye_after_ack = {undefined, []}, cdr_why = owner_down}};
owner_down(confirmed, D) ->
    chappe_sip_dialog_sub:start_teardown(undefined, [], D#data{
        cdr_why = owner_down
    });
owner_down(in_transaction, D) ->
    %% owner died mid-transaction: abandon the in-flight txn and BYE
    chappe_sip_dialog_owner:reply(txning_from(D), {error, owner_down}),
    chappe_sip_dialog_sub:start_teardown(undefined, [], D#data{
        txning = undefined, cdr_why = owner_down
    }).

%% ---- early dialogs of an INVITE we send (RFC 3261 12.1, 13.2.2.4) ----

%% The 2xx with our To tag: the dialog is confirmed, its route set and
%% remote target are taken from the 2xx, and the session timer starts. The
%% session an UPDATE settled while early stands over the one the UAC fsm
%% computed from the responses.
early_confirm(From, Args, #data{cseq_ref = Ref} = D) when Ref =/= undefined ->
    D1 = D#data{
        remote_addr = maps:get(remote_addr, Args, D#data.remote_addr),
        remote_target = maps:get(remote_target, Args, D#data.remote_target),
        route_set = maps:get(route_set, Args, D#data.route_set),
        remote_sdp = chappe_sip_dialog_offer:keep_sdp(
            D#data.remote_sdp, maps:get(remote_sdp, Args, <<>>)
        ),
        local_sdp = chappe_sip_dialog_offer:keep_sdp(
            D#data.local_sdp, maps:get(local_sdp, Args, <<>>)
        ),
        local_cseq = max(D#data.local_cseq, atomics:get(Ref, 1)),
        pending_ack = maps:get(pending_ack, Args, undefined),
        st = maps:get(session_timer, Args, undefined),
        index_state = confirmed,
        uac = undefined,
        cseq_ref = undefined,
        cdr = maps:get(cdr, Args, D#data.cdr)
    },
    chappe_sip_dialog_owner:cdr_bind(D1),
    chappe_sip_dialog_owner:set_index_state(D1, confirmed),
    {keep_state, D1, [
        {reply, From, ok} | chappe_sip_dialog_st:st_timers(D1#data.st)
    ]};
early_confirm(From, _Args, D) ->
    {keep_state, D, [{reply, From, {error, not_early}}]}.

%% ---- the request of a dialog that has no fsm yet ----

%% An in-dialog request of a dialog that has no fsm yet (a B2BUA's early
%% leg): Dlg names its parts, the result is the raw request and where to
%% send it.
-spec indialog_request(
    #{
        remote_target := binary(),
        local_addr := binary(),
        remote_addr := binary(),
        call_id := binary(),
        route_set := [binary()],
        local_contact := binary() | undefined,
        cseq := pos_integer()
    },
    binary(),
    [{binary(), iodata()}],
    binary()
) -> {binary(), term()}.
indialog_request(Dlg, Method, Headers, Body) ->
    chappe_sip_dialog_out:indialog_request(Dlg, Method, Headers, Body).

terminate(Reason, _State, #data{leg = LegH} = D) ->
    chappe_sip_dialog_owner:unindex(D),
    %% a record not stopped on the way (a send failure, a setup that never
    %% completed) stops here; a killed fsm leaves it to chappe_sip_cdr
    chappe_sip_cdr:stop(
        D#data.cdr,
        case D#data.cdr_why of
            undefined -> {process_down, Reason};
            Why -> Why
        end
    ),
    %% a re-INVITE waiting out its 491 retry timer will not happen
    _ =
        case D#data.glare_wait of
            {From, _} ->
                chappe_sip_dialog_owner:reply(From, {error, terminated});
            undefined ->
                ok
        end,
    %% destroy_leg is a cast; unreg happens as part of it
    _ = chappe_sip_engine:destroy_leg(LegH),
    ok.
