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
-module(chappe_sip_dialog_fsm).
-behaviour(gen_statem).

-include("chappe_sip_dialog.hrl").
-include("chappe_sip.hrl").

%% NOTIFY responses that remove a subscription (RFC 6665 4.2.2), plus the
%% 408 of a Timer F timeout
-define(NOTIFY_ENDS_SUB(S),
    (S =:= 404 orelse S =:= 405 orelse S =:= 408 orelse S =:= 410 orelse
        S =:= 416 orelse (S >= 480 andalso S =< 485) orelse S =:= 489 orelse
        S =:= 501 orelse S =:= 604)
).

%% an ACK names the dialog leg, or the INVITE server transaction of our 2xx
-define(IS_OURS(H, D), (H =:= D#data.leg orelse H =:= D#data.txn)).

%% calls that read dialog state (or set the handled events) and never touch
%% the wire: every post-setup state answers them
-define(IS_QUERY(Q),
    (Q =:= local_tag orelse Q =:= remote_tag orelse Q =:= call_id orelse
        Q =:= remote_sdp orelse Q =:= local_sdp orelse Q =:= local_contact orelse
        (is_tuple(Q) andalso tuple_size(Q) =:= 2 andalso
            element(1, Q) =:= set_handled))
).

-export([start_link/1]).
-export([requested_expires/2]).
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
    flow :: chappe_sip_engine:flow() | undefined,
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
    pending :: {gen_statem:from() | undefined, non_neg_integer()} | undefined,
    role = uac :: chappe_sip_dialog_index:role(),
    %% state to index under once confirmed: early when the dialog-forming
    %% response was provisional
    index_state = confirmed :: chappe_sip_dialog_index:dialog_state(),
    indexed :: chappe_sip_dialog_index:key() | undefined,
    %% RFC 6665 subscription; undefined for an INVITE dialog
    sub :: sub() | undefined,
    %% our Contact header value, repeated on in-dialog target refresh
    %% requests; undefined when the dialog was built without one
    local_contact :: binary() | undefined,
    %% RFC 4028 session timer (undefined: none) and the settings that answer
    %% the peer's refreshes
    st :: chappe_sip_session_timer:st() | undefined,
    st_cfg :: chappe_sip_session_timer:cfg() | undefined,
    %% option tags an in-dialog request may list in Require besides the
    %% supported_option_tags setting (the route's, RFC 3261 8.2.2.3)
    option_tags = [] :: [binary()],
    %% the destroy reason of a BYE we send on our own (session expiry)
    bye_reason :: term(),
    %% incoming re-INVITE / UPDATE the app claimed and has not answered
    %% yet, with the offer it carried (<<>> for none): RFC 3261 14.2 and
    %% RFC 3311 5.2 overlap rules, and the SDP to adopt on its 2xx
    srv_invite :: {non_neg_integer(), binary()} | undefined,
    srv_update :: {non_neg_integer(), binary()} | undefined,
    %% our 2xx carried an offer (offerless INVITE): the answer is in the ACK
    ack_answer = false :: boolean(),
    %% hold state our in-flight re-INVITE sets once it succeeds
    pending_hold = false :: boolean(),
    %% re-INVITE to try once more after a 491 (RFC 3261 14.1): set while
    %% the first attempt is in flight, then while its retry timer runs
    glare_retry :: {retry, term()} | undefined,
    glare_wait :: {gen_statem:from() | undefined, term()} | undefined,
    %% a UAS INVITE dialog waits for the ACK of its 2xx: the callee sends no
    %% BYE before it (RFC 3261 15), so a destroy meanwhile is held in
    %% bye_after_ack (caller, BYE headers) until the ACK or Timer H
    ack_wait = false :: boolean(),
    bye_after_ack ::
        {gen_statem:from() | undefined, [{binary(), iodata()}]} | undefined,
    %% Contact URIs of claimed target refresh requests (re-INVITE, UPDATE)
    %% by server transaction: the remote target moves on their 2xx
    refresh = #{} :: #{non_neg_integer() => binary()},
    %% a re-INVITE of ours held while an INVITE server transaction of the
    %% dialog is not confirmed yet (RFC 3261 14.1)
    modify_wait :: {gen_statem:from(), term(), map()} | undefined,
    %% a UAC dialog whose 2xx we did not ACK (no_ack, 3PCC): the INVITE's
    %% CSeq number and credentials, until the app sends the ACK (ack/2)
    pending_ack ::
        #{cseq := pos_integer(), headers := [{binary(), iodata()}]}
        | undefined,
    %% an early dialog of an INVITE we send: the UAC fsm, and the CSeq
    %% counter it shares with us until the dialog is confirmed
    uac :: pid() | undefined,
    cseq_ref :: atomics:atomics_ref() | undefined
}).

%% event: the SUBSCRIBE's Event value (with any id param), reused on every
%% NOTIFY; expires_at: monotonic ms, when the subscription ends (an
%% unsubscribe's grace included); granted_at: monotonic ms, when what the
%% subscriber was granted ends, which a NOTIFY's expires never passes
%% (RFC 6665 4.2.2); max/min: the granted Expires bounds;
%% grace: ms the owner has to send its final NOTIFY after an unsubscribe;
%% state: terminated once a terminated NOTIFY has been answered; contact:
%% the Contact of our dialog-forming 2xx, repeated on a refresh 2xx;
%% term_reason: the owner's destroy reason once the final NOTIFY completes;
%% keep_body: repeat the owner's last NOTIFY body on the NOTIFYs the fsm
%% sends itself (a package whose every NOTIFY needs a body, such as refer).
-type sub() :: #{
    event := binary() | undefined,
    expires_at := integer(),
    granted_at := integer(),
    max := non_neg_integer(),
    min := non_neg_integer(),
    grace := non_neg_integer(),
    state := active | terminated,
    contact := binary() | undefined,
    term_reason := term(),
    keep_body := boolean(),
    last_body := {binary() | undefined, binary()} | undefined
}.

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

callback_mode() -> state_functions.

%% Args (both UAS and UAC): leg, call_id, local_addr (our From w/ tag),
%% remote_addr (peer To/From w/ tag), remote_target (peer Contact URI),
%% local_tag, owner, opts, cseq (the last local CSeq number used: our next
%% in-dialog request takes cseq + 1, RFC 3261 12.2.1.1).
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
        remote_sdp = maps:get(remote_sdp, Args, <<>>),
        role = maps:get(role, Args, uac),
        index_state = initial_index_state(Args, Opts),
        sub = init_sub(
            maps:get(subscription, Opts, undefined),
            maps:get(local_contact, Args, undefined)
        ),
        local_contact = maps:get(local_contact, Args, undefined),
        remote_cseq = maps:get(remote_cseq, Args, 0),
        ack_wait = maps:get(ack_wait, Args, false),
        pending_ack = maps:get(pending_ack, Args, undefined),
        st = maps:get(
            session_timer, Args, maps:get(session_timer, Opts, undefined)
        ),
        st_cfg = chappe_sip_session_timer:config(Opts),
        option_tags = maps:get(option_tags, Opts, []),
        uac = maps:get(early_uac, Args, undefined),
        cseq_ref = maps:get(cseq_ref, Args, undefined)
    },
    Data1 = Data#data{ack_answer = answer_in_ack(Data)},
    %% Any dialog-forming response (UAS) is sent by chappe_sip_engine (sending
    %% it from here would re-enter chappe_sip_engine during our own start and
    %% deadlock). A UAC dialog has already been answered (2xx) before we
    %% start. A setup timeout bounds the wait for the leg op result, so a
    %% never-arriving op_ok/op_failed does not strand the fsm and its leg.
    {ok, setup, Data1,
        [{state_timeout, 30000, setup_timeout} | sub_timer(Data#data.sub)] ++
            st_timers(Data#data.st)}.

%% a UAS dialog formed by an offerless INVITE: our 2xx carries the offer and
%% the ACK the answer (RFC 3261 13.2.1)
answer_in_ack(#data{role = uas, sub = undefined, remote_sdp = <<>>} = D) ->
    D#data.local_sdp =/= <<>>;
answer_in_ack(_D) ->
    false.

%% ---- setup: waiting for the leg op result ----

setup({call, From}, await_ready, #data{ready = true, leg = LegH} = D) ->
    {next_state, confirmed, index(D), [{reply, From, {ok, LegH}}]};
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
    {next_state, confirmed, index(D#data{await_from = undefined}), [
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
setup({timeout, _}, _, D) ->
    %% subscription expiry, session refresh or expiry: once confirmed
    {keep_state, D, [postpone]};
setup(info, {chappe_sip_indialog, LegH, _, _, _}, #data{leg = LegH} = D) ->
    %% the peer may send a request (a BYE on our ACK) before the leg op
    %% result is in: handle it once confirmed rather than drop it
    {keep_state, D, [postpone]};
setup(info, {chappe_sip_ack, LegH, _}, #data{leg = LegH} = D) ->
    {keep_state, D, [postpone]};
setup(info, _Other, D) ->
    {keep_state, D};
setup({call, From}, _Req, D) ->
    {keep_state, D, [{reply, From, {error, not_ready}}]}.

%% ---- confirmed ----

confirmed(info, {chappe_sip_ack, H, Raw}, D) when ?IS_OURS(H, D) ->
    ack_received(Raw, D);
confirmed(info, {chappe_sip_ack_timeout, H}, D) when ?IS_OURS(H, D) ->
    %% RFC 3261 13.3.1.4 and 14.2: our 2xx was never ACKed; end the session
    {From, Hdrs} = held_bye(D),
    start_teardown(From, Hdrs, D#data{
        ack_wait = false, bye_after_ack = undefined, bye_reason = no_ack
    });
confirmed(info, {chappe_sip_final, TxnH, Status, Body}, D) ->
    D1 = claimed_final(TxnH, Status, Body, D),
    {keep_state, D1, held_modify(D1)};
confirmed(
    info, {chappe_sip_indialog, LegH, TxnH, Meta, Raw}, #data{leg = LegH} = D
) ->
    handle_indialog(TxnH, Meta, Raw, D);
confirmed(info, {chappe_sip_cancel, _TxnH, _Req}, D) ->
    %% late CANCEL after the dialog was established; ignore
    {keep_state, D};
confirmed({call, From}, {confirm, Args}, D) ->
    early_confirm(From, Args, D);
confirmed(cast, {early_end, Reason}, D) ->
    notify_terminal(D, Reason),
    {stop, normal, D};
confirmed(cast, {early_sdp, Sdp}, D) ->
    {keep_state, early_sdp(Sdp, D)};
confirmed({call, From}, destroy, D) ->
    confirmed({call, From}, {destroy, #{}}, D);
confirmed({call, From}, {destroy, Opts}, #data{uac = Uac} = D) when
    Uac =/= undefined
->
    %% RFC 3261 15: the caller ends an early dialog of its INVITE with a
    %% CANCEL of that INVITE
    gen_statem:cast(Uac, {cancel, maps:get(headers, Opts, [])}),
    {keep_state, D, [{reply, From, ok}]};
confirmed(
    {call, From}, {destroy, _}, #data{sub = #{state := terminated}} = D
) ->
    {keep_state, D, [{reply, From, ok}]};
confirmed({call, From}, {destroy, Opts}, #data{ack_wait = true} = D) ->
    {keep_state, D#data{bye_after_ack = {From, maps:get(headers, Opts, [])}}};
confirmed({call, From}, {destroy, Opts}, D) ->
    start_teardown(From, maps:get(headers, Opts, []), D);
confirmed({call, From}, {notify, _}, #data{sub = #{state := terminated}} = D) ->
    {keep_state, D, [{reply, From, {error, terminated}}]};
confirmed({call, From}, {notify, Spec}, D) ->
    start_notify(From, Spec, D);
confirmed({timeout, sub_expiry}, expire, #data{sub = Sub} = D) ->
    case maps:get(expires_at, Sub) > now_ms() of
        true ->
            %% postponed during a NOTIFY, then refreshed meanwhile: the
            %% re-armed timer stands
            {keep_state, D};
        false ->
            start_final_notify(undefined, <<"timeout">>, expired, D)
    end;
confirmed(state_timeout, sub_done, D) ->
    %% a terminated NOTIFY was answered: the subscription is over
    notify_terminal(D, terminated),
    {stop, normal, D};
confirmed({timeout, st_refresh}, refresh, #data{st = #{}} = D) ->
    start_st_refresh(D);
confirmed({timeout, st_expire}, expire, #data{st = #{}} = D) ->
    %% RFC 4028 10: no refresh before the session expiration
    start_teardown(undefined, [], D#data{bye_reason = session_expired});
confirmed({timeout, T}, _, D) when T =:= st_refresh; T =:= st_expire ->
    {keep_state, D};
confirmed(info, {st_refreshed, St}, D) ->
    st_apply(St, D);
confirmed({call, From}, {modify, SdpSpec}, D) ->
    confirmed({call, From}, {modify, SdpSpec, #{}}, D);
confirmed({call, From}, {modify, _, _}, #data{uac = Uac} = D) when
    Uac =/= undefined
->
    %% no re-INVITE before the INVITE completes (RFC 3261 14.1); an early
    %% dialog takes UPDATE
    {keep_state, D, [{reply, From, {error, early}}]};
confirmed({call, From}, {modify, SdpSpec, Opts}, D) ->
    case {invite_server_open(D), D#data.modify_wait} of
        {true, undefined} ->
            %% RFC 3261 14.1: wait for the INVITE server transaction to
            %% be confirmed (its ACK) or terminated
            {keep_state, D#data{modify_wait = {From, SdpSpec, Opts}}};
        {true, _Held} ->
            {keep_state, D, [{reply, From, {error, request_pending}}]};
        {false, _} ->
            start_reinvite(From, SdpSpec, Opts, D#data{modify_wait = undefined})
    end;
confirmed({timeout, glare_retry}, retry, #data{glare_wait = {From, Spec}} = D) ->
    start_reinvite(From, Spec, #{}, D#data{glare_wait = undefined});
confirmed({call, From}, {request, ReqSpec}, D) ->
    start_request(From, ReqSpec, D);
confirmed({call, From}, {ack, Opts}, D) ->
    send_delayed_ack(From, Opts, D);
confirmed({call, From}, Query, D) when ?IS_QUERY(Query) ->
    query(From, Query, D);
confirmed(info, {chappe_sip_engine_restart, _}, D) ->
    notify_terminal(D, engine_restart),
    {stop, normal, D};
confirmed(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy, uac = Uac} = D
) when Uac =/= undefined ->
    early_owner_down(D);
confirmed(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy, ack_wait = true} = D
) ->
    {keep_state, D#data{bye_after_ack = {undefined, []}}};
confirmed(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy} = D
) ->
    start_teardown(undefined, [], D);
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
    %% a 2xx to our INVITE or UPDATE refreshes the session (RFC 4028 7.2)
    {D1, StActs} = st_response(Status, Raw, D),
    with_actions(finish_txn_response(From, Kind, Status, Raw, D1), StActs);
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
in_transaction(info, {chappe_sip_ack, H, _Raw}, D) when ?IS_OURS(H, D) ->
    %% handled once our transaction is done: it may release a held BYE
    {keep_state, D, [postpone]};
in_transaction(info, {chappe_sip_ack_timeout, _}, D) ->
    {keep_state, D, [postpone]};
in_transaction(info, {chappe_sip_final, TxnH, Status, Body}, D) ->
    {keep_state, claimed_final(TxnH, Status, Body, D)};
in_transaction({call, From}, {confirm, Args}, D) ->
    %% the 2xx to the INVITE while our UPDATE in the early dialog runs
    early_confirm(From, Args, D);
in_transaction(cast, {early_end, Reason}, D) ->
    reply(txning_from(D), {error, terminated}),
    notify_terminal(D, Reason),
    {stop, normal, D};
in_transaction(cast, {early_sdp, Sdp}, D) ->
    {keep_state, early_sdp(Sdp, D)};
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
    element(1, Op) =:= ack;
    element(1, Op) =:= notify;
    element(1, Op) =:= destroy;
    Op =:= destroy
->
    {keep_state, D, [postpone]};
in_transaction({timeout, _}, _, D) ->
    {keep_state, D, [postpone]};
in_transaction(info, {st_refreshed, St}, D) ->
    st_apply(St, D);
in_transaction({call, From}, Query, D) when ?IS_QUERY(Query) ->
    query(From, Query, D);
in_transaction(info, {chappe_sip_engine_restart, _}, D) ->
    reply(txning_from(D), {error, engine_restart}),
    notify_terminal(D, engine_restart),
    {stop, normal, D};
in_transaction(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy, uac = Uac} = D
) when Uac =/= undefined ->
    early_owner_down(D);
in_transaction(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = destroy} = D
) ->
    %% owner died mid-transaction: abandon the in-flight txn and BYE
    reply(txning_from(D), {error, owner_down}),
    start_teardown(undefined, [], D#data{txning = undefined});
in_transaction(
    info,
    {'DOWN', MRef, process, _, _},
    #data{owner_mon = MRef, on_owner_exit = continue} = D
) ->
    {keep_state, D};
in_transaction(info, _Other, D) ->
    {keep_state, D}.

%% The ACK of our 2xx: then send the BYE the owner asked for meanwhile,
%% or the re-INVITE it held.
ack_received(Raw, D) ->
    D1 = (handle_ack(Raw, D))#data{ack_wait = false},
    case D1#data.bye_after_ack of
        {From, Hdrs} ->
            start_teardown(From, Hdrs, D1#data{bye_after_ack = undefined});
        undefined ->
            {keep_state, D1, held_modify(D1)}
    end.

%% an INVITE server transaction of this dialog not yet confirmed: an
%% incoming re-INVITE unanswered, or our 2xx to an INVITE not yet ACKed
invite_server_open(#data{srv_invite = {_, _}}) -> true;
invite_server_open(#data{ack_wait = Wait}) -> Wait.

%% replay a held re-INVITE once the INVITE server transaction is done
held_modify(#data{modify_wait = {From, Spec, Opts}} = D) ->
    case invite_server_open(D) of
        true -> [];
        false -> [{next_event, {call, From}, {modify, Spec, Opts}}]
    end;
held_modify(_D) ->
    [].

held_bye(#data{bye_after_ack = {From, Hdrs}}) -> {From, Hdrs};
held_bye(_) -> {undefined, []}.

txning_from(#data{txning = {From, _, _}}) -> From;
txning_from(_) -> undefined.

finish_txn_response(From, {st_refresh, _} = Kind, Status, Raw, D) ->
    st_refresh_response(From, Kind, Status, Raw, D);
finish_txn_response(From, {reinvite, NewSdp}, Status, Raw, D0) when
    Status >= 200, Status < 300
->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    D = new_target(Msg, D0),
    _ = send_ack_indialog(D),
    RemoteSdp = chappe_sip_msg:body(Msg),
    reply(From, {ok, RemoteSdp}),
    {next_state, confirmed, D#data{
        txning = undefined,
        local_sdp = NewSdp,
        remote_sdp = RemoteSdp,
        on_hold = D#data.pending_hold,
        glare_retry = undefined
    }};
finish_txn_response(
    From,
    {reinvite, _},
    491,
    _Raw,
    #data{
        glare_retry = {retry, Spec}
    } = D
) ->
    %% RFC 3261 14.1: glare; try once more after the randomized wait. The
    %% session is unchanged meanwhile. nta ACKs the 491 (17.1.1.3).
    {next_state, confirmed,
        D#data{
            txning = undefined,
            glare_retry = undefined,
            glare_wait = {From, Spec}
        },
        [{{timeout, glare_retry}, glare_delay(D), retry}]};
finish_txn_response(From, {reinvite, _}, Status, Raw, D) when
    Status =:= 481; Status =:= 408
->
    %% RFC 3261 12.2.1.2: the peer has no such dialog, or never answered
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    reply(From, {error, chappe_sip_error(Status, Msg)}),
    request_failed(Status, D);
finish_txn_response(From, {reinvite, _}, Status, Raw, D) when Status >= 200 ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    %% re-INVITE rejected: the dialog stays as it was. The INVITE client
    %% transaction ACKs a non-2xx itself (RFC 3261 17.1.1.3); a second ACK
    %% from here would be a stray 2xx-style one.
    reply(From, {error, chappe_sip_error(Status, Msg)}),
    {next_state, confirmed, D#data{
        txning = undefined,
        glare_retry = undefined
    }};
finish_txn_response(_From, _Kind, Status, _Raw, D) when Status < 200 ->
    %% a provisional (to our re-INVITE or another request): the
    %% transaction stays open until its final response
    {keep_state, D};
finish_txn_response(From, Kind, Status, Raw, D) ->
    %% final to a request or a NOTIFY
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    reply(From, {ok, Msg}),
    D1 = update_answered(Kind, Status, Msg, D),
    after_request(Kind, Status, D1#data{txning = undefined}).

%% the Contact of a 2xx to our target refresh request is the new remote
%% target (RFC 3261 12.2.1.2)
new_target(Msg, D) ->
    case chappe_sip_msg:get(<<"contact">>, Msg) of
        undefined ->
            D;
        Contact ->
            case chappe_sip_hdr:name_addr(Contact) of
                {ok, #{uri := Uri}} -> D#data{remote_target = Uri};
                _ -> D
            end
    end.

%% RFC 3261 12.2.1.2: a 481 or 408 to an in-dialog request ends the dialog
request_failed(Status, D) ->
    notify_terminal(D, {request_failed, Status}),
    {stop, normal, D}.

%% RFC 3311: our UPDATE offer is answered in its 2xx
update_answered({update, Sdp}, Status, Msg, D0) when
    Status >= 200, Status < 300
->
    D = new_target(Msg, D0),
    case chappe_sip_msg:body(Msg) of
        <<>> -> D;
        Answer -> D#data{local_sdp = Sdp, remote_sdp = Answer}
    end;
update_answered(_Kind, _Status, _Msg, D) ->
    D.

%% RFC 3261 14.1: the Call-ID owner (the dialog's UAC) waits 2.1 to 4 s,
%% the other side 0 to 2 s, in units of 10 ms
glare_delay(#data{role = uac}) -> (209 + rand:uniform(191)) * 10;
glare_delay(#data{}) -> (rand:uniform(201) - 1) * 10.

%% INVITE dialogs are unaffected by the response. A subscription ends on
%% the NOTIFY failures of RFC 6665 4.2.2 (and a Timer F 408) and once a
%% terminated NOTIFY is answered.
after_request(_Kind, Status, #data{sub = undefined} = D) when
    Status =:= 481; Status =:= 408
->
    request_failed(Status, D);
after_request(_Kind, _Status, #data{sub = undefined} = D) ->
    {next_state, confirmed, D};
after_request(_Kind, Status, D) when ?NOTIFY_ENDS_SUB(Status) ->
    notify_terminal(D, {notify_failed, Status}),
    {stop, normal, D};
after_request({notify, true}, _Status, #data{sub = Sub} = D) ->
    %% a zero state timeout runs after the calls postponed meanwhile, so a
    %% destroy/1 waiting on this NOTIFY is answered before the fsm stops
    {next_state, confirmed, D#data{sub = Sub#{state := terminated}}, [
        {state_timeout, 0, sub_done}
    ]};
after_request(_Kind, _Status, D) ->
    {next_state, confirmed, D}.

%% ---- terminating: waiting for our BYE final response ----

terminating(
    info,
    {chappe_sip_response, TxnH, #{status := Status}, _Raw},
    #data{pending = {_, TxnH}, sub = Sub} = D
) when Status < 200, Sub =/= undefined ->
    %% provisional to the final NOTIFY: keep waiting for its final
    {keep_state, D};
terminating(
    info,
    {chappe_sip_response, TxnH, _Meta, _Raw},
    #data{pending = {From, TxnH}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    unindex(D),
    reply(From, ok),
    notify_terminal(D, term_reason(D)),
    {stop, normal, D};
terminating(
    info,
    {chappe_sip_op, TxnH, {error, Reason}},
    #data{pending = {From, TxnH}} = D
) ->
    _ = chappe_sip_engine:finish_txn(TxnH),
    unindex(D),
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
terminating({timeout, glare_retry}, _, #data{glare_wait = {From, _}} = D) ->
    reply(From, {error, terminating}),
    {keep_state, D#data{glare_wait = undefined}};
terminating({timeout, _}, _, D) ->
    {keep_state, D};
terminating({call, From}, Query, D) when ?IS_QUERY(Query) ->
    query(From, Query, D);
terminating({call, From}, _Req, D) ->
    {keep_state, D, [{reply, From, {error, terminating}}]}.

%% ---- queries: answered in every state once the dialog is set up ----

query(From, local_tag, #data{local_tag = T} = D) ->
    {keep_state, D, [{reply, From, T}]};
query(From, remote_tag, #data{remote_addr = RA} = D) ->
    {keep_state, D, [{reply, From, addr_tag(RA)}]};
query(From, call_id, #data{call_id = C} = D) ->
    {keep_state, D, [{reply, From, C}]};
query(From, remote_sdp, #data{remote_sdp = S} = D) ->
    {keep_state, D, [{reply, From, S}]};
query(From, local_sdp, #data{local_sdp = S} = D) ->
    {keep_state, D, [{reply, From, S}]};
query(From, local_contact, #data{local_contact = C} = D) ->
    {keep_state, D, [{reply, From, C}]};
query(From, {set_handled, Events}, D) ->
    {keep_state, D#data{handled = Events}, [{reply, From, ok}]}.

%% ---- in-dialog request handling ----

handle_indialog(TxnH, _Meta, Raw, D) ->
    Req = parse_req(Raw, TxnH),
    case in_order(Req, D) of
        {ok, D1} ->
            require_check(TxnH, Req, D1);
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

%% RFC 3261 8.2.2.3: an in-dialog request listing an option tag we do not
%% support in Require gets 420 with Unsupported. ACK and CANCEL never reach
%% here (and must be exempt).
require_check(TxnH, Req, D) ->
    Supported = [
        lower(T)
     || T <- chappe_sip_config:get(supported_option_tags) ++ D#data.option_tags
    ],
    Msg = chappe_sip_req:msg(Req),
    case
        [
            T
         || T <- chappe_sip_msg:option_tags(<<"require">>, Msg),
            not lists:member(T, Supported)
        ]
    of
        [] ->
            route_indialog(TxnH, Req, D);
        Bad ->
            Hdrs = [
                {<<"Unsupported">>, iolist_to_binary(lists:join(<<", ">>, Bad))}
            ],
            _ = chappe_sip_engine:dialog_respond(
                TxnH, 420, <<"Bad Extension">>, hdrs(Hdrs), <<>>, <<>>
            ),
            {keep_state, D}
    end.

lower(B) -> <<<<(lower_byte(C))>> || <<C>> <= B>>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

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

%% In an INVITE dialog, the SUBSCRIBEs and NOTIFYs of a REFER's implicit
%% subscription (RFC 3515) belong to chappe_sip_refer once it has handled a
%% REFER here; anything else goes on to the owner as before.
route_indialog(TxnH, Req, #data{sub = undefined} = D) ->
    Method = chappe_sip_req:method(Req),
    Routed =
        (Method =:= <<"SUBSCRIBE">> orelse Method =:= <<"NOTIFY">>) andalso
            chappe_sip_refer:route(
                dialog(D),
                Req,
                %% neither method refreshes the session: its timer stays
                chappe_sip_res:new(TxnH, dialog_sender([], keep))
            ),
    case Routed of
        handled -> {keep_state, D};
        _ -> handle_indialog_1(TxnH, Req, D)
    end;
route_indialog(TxnH, Req, D) ->
    handle_indialog_1(TxnH, Req, D).

handle_indialog_1(TxnH, Req, D) ->
    Method = chappe_sip_req:method(Req),
    case Method of
        <<"BYE">> ->
            %% RFC 3261 15.1.2: the requests still pending in the dialog get
            %% a 487 before the BYE its 200
            _ = [
                chappe_sip_engine:dialog_respond(
                    Pending, 487, <<"Request Terminated">>, <<>>, <<>>, <<>>
                )
             || {Pending, _} <- [D#data.srv_invite, D#data.srv_update]
            ],
            %% and so does the INVITE of an early dialog of ours (the
            %% caller's BYE ends the early dialog, RFC 3261 15)
            _ = early_invite_terminated(D),
            early_byed(D),
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
        <<"SUBSCRIBE">> when D#data.sub =/= undefined ->
            handle_refresh(TxnH, Req, D);
        _ ->
            case overlap(Method, chappe_sip_req:body(Req), D) of
                ok ->
                    session_check(TxnH, Method, Req, D);
                {Status, Reason, Hdrs} ->
                    _ = chappe_sip_engine:dialog_respond(
                        TxnH, Status, Reason, hdrs(Hdrs), <<>>, <<>>
                    ),
                    {keep_state, D}
            end
    end.

early_invite_terminated(#data{role = uas, index_state = early, txn = Txn}) when
    Txn =/= undefined
->
    chappe_sip_engine:dialog_respond(
        Txn, 487, <<"Request Terminated">>, <<>>, <<>>, <<>>
    );
early_invite_terminated(_D) ->
    ok.

%% the callee's BYE ended an early dialog of our INVITE: the INVITE still
%% completes with its final response, which no longer confirms this dialog
early_byed(#data{uac = Uac, remote_addr = RA}) when Uac =/= undefined ->
    Uac ! {chappe_sip_early_byed, addr_tag(RA)},
    ok;
early_byed(_D) ->
    ok.

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
        remote_sdp = keep_sdp(
            D#data.remote_sdp, maps:get(remote_sdp, Args, <<>>)
        ),
        local_sdp = keep_sdp(D#data.local_sdp, maps:get(local_sdp, Args, <<>>)),
        local_cseq = max(D#data.local_cseq, atomics:get(Ref, 1)),
        pending_ack = maps:get(pending_ack, Args, undefined),
        st = maps:get(session_timer, Args, undefined),
        index_state = confirmed,
        uac = undefined,
        cseq_ref = undefined
    },
    set_index_state(D1, confirmed),
    {keep_state, D1, [{reply, From, ok} | st_timers(D1#data.st)]};
early_confirm(From, _Args, D) ->
    {keep_state, D, [{reply, From, {error, not_early}}]}.

keep_sdp(<<>>, New) -> New;
keep_sdp(Mine, _New) -> Mine.

%% a later provisional of this early dialog carried the first SDP
early_sdp(Sdp, #data{remote_sdp = <<>>} = D) -> D#data{remote_sdp = Sdp};
early_sdp(_Sdp, D) -> D.

%% the owner is gone before the INVITE completed: the UAC fsm CANCELs it
%% and ends the call should a 2xx still come
early_owner_down(#data{uac = Uac} = D) ->
    gen_statem:cast(Uac, abandon),
    {keep_state, D}.

%% the CSeq of our next request: an early dialog shares the INVITE's
%% counter with the PRACKs of the UAC fsm
next_cseq(#data{cseq_ref = undefined, local_cseq = CSeq} = D) ->
    {CSeq + 1, D#data{local_cseq = CSeq + 1}};
next_cseq(#data{cseq_ref = Ref} = D) ->
    Seq = atomics:add_get(Ref, 1, 1),
    {Seq, D#data{local_cseq = Seq}}.

%% RFC 4028 9: an INVITE or UPDATE refreshes the session; one below our
%% minimum interval gets 422
session_check(TxnH, Method, Req, D) ->
    case st_incoming(Method, Req, D) of
        {ok, StHdrs, St} ->
            dispatch_indialog(TxnH, Method, Req, StHdrs, St, D);
        {reject, Min} ->
            Hdrs = [{<<"Min-SE">>, integer_to_binary(Min)}],
            _ = chappe_sip_engine:dialog_respond(
                TxnH,
                422,
                <<"Session Interval Too Small">>,
                hdrs(Hdrs),
                <<>>,
                <<>>
            ),
            {keep_state, D}
    end.

%% StHdrs go on the 2xx; St is the session timer once the 2xx is sent (only
%% a 2xx refreshes the session, so an owner's sender reports it)
dispatch_indialog(TxnH, Method, Req, StHdrs, St, D0) ->
    Event = method_event(Method),
    D =
        case refresh_target(Method, Req) of
            undefined -> D0;
            Uri -> D0#data{refresh = (D0#data.refresh)#{TxnH => Uri}}
        end,
    case claimed(Event, D) of
        true ->
            %% RFC 3261 12.2.2, RFC 3311 5.1: the 2xx to a target refresh
            %% carries our Contact, the one of the dialog's other messages
            Res = chappe_sip_res:new(
                TxnH,
                dialog_sender(StHdrs ++ refresh_contact(Method, D), St)
            ),
            notify(D, Event, Req, Res),
            {keep_state, track_claimed(Method, TxnH, Req, D)};
        false ->
            {Status, Reason, Hdrs0, Body, D1} = auto_answer(Event, Req, D),
            Ok = Status >= 200 andalso Status < 300,
            Hdrs = Hdrs0 ++ [H || Ok, H <- StHdrs],
            _ = chappe_sip_engine:dialog_respond(
                TxnH, Status, Reason, hdrs(Hdrs), Body, <<>>
            ),
            D2 = refreshed(TxnH, Status, D1),
            %% our 2xx to a re-INVITE waits for its ACK (RFC 3261 14.1)
            D3 =
                case Method of
                    <<"INVITE">> -> D2#data{ack_wait = Ok};
                    _ -> D2
                end,
            notify4(D3, {auto_answered, Event}, Req),
            case Ok of
                true -> st_apply(St, D3);
                false -> {keep_state, D3}
            end
    end.

%% ---- offer/answer and request overlap (RFC 3261 14, RFC 3311 5.2) ----

%% An INVITE while ours is in flight is glare (491); one while the previous
%% incoming INVITE is unanswered gets 500 + Retry-After. UPDATE: the same
%% 500 on overlap, 491 when its offer crosses one of ours, 500 when it
%% arrives on top of an offer we have not answered yet.
overlap(<<"INVITE">>, _Body, #data{txning = {_, _, {reinvite, _}}}) ->
    {491, <<"Request Pending">>, []};
overlap(<<"INVITE">>, _Body, #data{txning = {_, _, {st_refresh, <<"INVITE">>}}}) ->
    {491, <<"Request Pending">>, []};
overlap(<<"INVITE">>, _Body, #data{srv_invite = {_, _}}) ->
    retry_later();
overlap(<<"UPDATE">>, _Body, #data{srv_update = {_, _}}) ->
    retry_later();
overlap(<<"UPDATE">>, Offer, D) when Offer =/= <<>> ->
    case {offer_out(D), D#data.srv_invite} of
        {true, _} -> {491, <<"Request Pending">>, []};
        {false, {_, InOffer}} when InOffer =/= <<>> -> retry_later();
        _ -> ok
    end;
overlap(_Method, _Body, _D) ->
    ok.

%% an offer of ours still waiting for its answer
offer_out(#data{txning = {_, _, {reinvite, Sdp}}}) ->
    Sdp =/= <<>>;
offer_out(#data{txning = {_, _, {update, _}}}) ->
    true;
offer_out(#data{txning = {_, _, {st_refresh, <<"INVITE">>}}} = D) ->
    D#data.local_sdp =/= <<>>;
offer_out(#data{uac = Uac, local_sdp = L, remote_sdp = <<>>}) when
    Uac =/= undefined, L =/= <<>>
->
    %% early: our INVITE's offer has no answer yet
    true;
offer_out(#data{ack_answer = Pending}) ->
    Pending.

retry_later() ->
    RA = integer_to_binary(rand:uniform(11) - 1),
    {500, <<"Server Internal Error">>, [{<<"Retry-After">>, RA}]}.

%% a claimed re-INVITE / UPDATE stays pending until the app answers it
track_claimed(<<"INVITE">>, TxnH, Req, D) ->
    D#data{srv_invite = {TxnH, chappe_sip_req:body(Req)}};
track_claimed(<<"UPDATE">>, TxnH, Req, D) ->
    D#data{srv_update = {TxnH, chappe_sip_req:body(Req)}};
track_claimed(_Method, _TxnH, _Req, D) ->
    D.

%% the app sent the final response to a claimed request; a 2xx settles the
%% offer/answer exchange it carried
claimed_final(TxnH, Status, Body, D0) ->
    D = refreshed(TxnH, Status, D0),
    claimed_final_1(TxnH, Status, Body, D).

claimed_final_1(TxnH, Status, Body, #data{srv_invite = {TxnH, Offer}} = D) ->
    D1 = D#data{srv_invite = undefined, ack_wait = is_2xx(Status)},
    case Status of
        S when S >= 200, S < 300, Offer =/= <<>> ->
            answered(Offer, Body, D1);
        S when S >= 200, S < 300, Body =/= <<>> ->
            %% offerless re-INVITE: our 2xx is the offer, the ACK answers
            D1#data{local_sdp = Body, ack_answer = true};
        _ ->
            D1
    end;
claimed_final_1(TxnH, Status, Body, #data{srv_update = {TxnH, Offer}} = D) ->
    D1 = D#data{srv_update = undefined},
    case Status >= 200 andalso Status < 300 andalso Offer =/= <<>> of
        true -> answered(Offer, Body, D1);
        false -> D1
    end;
claimed_final_1(_TxnH, _Status, _Body, D) ->
    D.

is_2xx(Status) -> Status >= 200 andalso Status < 300.

%% RFC 3261 12.2.2: a target refresh request we accept moves the remote
%% target to its Contact (a rejected one changes nothing, 8.2)
refreshed(TxnH, Status, #data{refresh = R} = D) ->
    case maps:take(TxnH, R) of
        {Uri, R1} when Status >= 200, Status < 300 ->
            D#data{refresh = R1, remote_target = Uri};
        {_Uri, R1} when Status >= 200 ->
            D#data{refresh = R1};
        _ ->
            D
    end.

%% the Contact URI of a target refresh request, if it has one
refresh_target(Method, Req) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    case chappe_sip_req:get(<<"contact">>, Req) of
        undefined ->
            undefined;
        Contact ->
            case chappe_sip_hdr:name_addr(Contact) of
                {ok, #{uri := Uri}} -> Uri;
                _ -> undefined
            end
    end;
refresh_target(_Method, _Req) ->
    undefined.

answered(Offer, <<>>, D) -> D#data{remote_sdp = Offer};
answered(Offer, Answer, D) -> D#data{remote_sdp = Offer, local_sdp = Answer}.

%% the ACK completing an INVITE whose 2xx carried our offer holds the answer
handle_ack(Raw, #data{ack_answer = Pending} = D) ->
    AckReq = parse_req(Raw, undefined),
    notify(D, ack, AckReq, undefined),
    case {Pending, chappe_sip_req:body(AckReq)} of
        {true, Answer} when Answer =/= <<>> ->
            D#data{remote_sdp = Answer, ack_answer = false};
        _ ->
            D#data{ack_answer = false}
    end.

%% ---- subscriptions (RFC 6665) ----

init_sub(undefined, _Contact) ->
    undefined;
init_sub(#{expires := Expires} = Opts, Contact) ->
    Grace = maps:get(unsubscribe_grace, Opts, 5000),
    #{
        event => maps:get(event, Opts, undefined),
        %% Expires: 0 on the initial SUBSCRIBE is a fetch: the owner has the
        %% unsubscribe grace to send its one terminated NOTIFY
        expires_at => now_ms() + expiry_ms(Expires, Grace),
        granted_at => now_ms() + Expires * 1000,
        max => maps:get(max, Opts, Expires),
        min => maps:get(min, Opts, 0),
        grace => Grace,
        state => active,
        contact => Contact,
        term_reason => terminated,
        keep_body => maps:get(keep_body, Opts, false),
        last_body => undefined
    }.

sub_timer(undefined) ->
    [];
sub_timer(#{expires_at := At}) ->
    [{{timeout, sub_expiry}, max(0, At - now_ms()), expire}].

expiry_ms(0, Grace) -> Grace;
expiry_ms(Seconds, _Grace) -> Seconds * 1000.

now_ms() -> erlang:monotonic_time(millisecond).

%% seconds left on the subscription, rounded up
remaining(#{granted_at := At}) ->
    max(0, (At - now_ms() + 999) div 1000).

%% The Expires a SUBSCRIBE asks for, or Default when it has none (or an
%% unreadable one).
-spec requested_expires(chappe_sip_req:req(), non_neg_integer()) ->
    non_neg_integer().
requested_expires(Req, Default) ->
    case chappe_sip_req:get(<<"expires">>, Req) of
        undefined ->
            Default;
        V ->
            try binary_to_integer(string:trim(V)) of
                N when N >= 0 -> N;
                _ -> Default
            catch
                error:badarg -> Default
            end
    end.

%% an in-dialog SUBSCRIBE refreshes this subscription only when its Event
%% names it (RFC 6665 8.2.1: type and id). Another one would be a second
%% subscription sharing the dialog, which is refused 403 (RFC 6665 4.5.2);
%% for the refer package that is also a subscription REFER did not create
%% (RFC 3515 2.4.4).
handle_refresh(TxnH, Req, #data{sub = #{event := Event}} = D) ->
    case same_event(chappe_sip_req:get(<<"event">>, Req), Event) of
        true ->
            refresh(TxnH, Req, D);
        false ->
            _ = chappe_sip_engine:dialog_respond(
                TxnH, 403, <<"Forbidden">>, <<>>, <<>>, <<>>
            ),
            {keep_state, D}
    end.

same_event(_Asked, undefined) ->
    true;
same_event(Asked, Event) ->
    case {chappe_sip_hdr:event(Asked), chappe_sip_hdr:event(Event)} of
        {{ok, E}, {ok, E}} -> true;
        _ -> false
    end.

%% Expires 0 unsubscribes (the owner then sends the final NOTIFY), anything
%% else refreshes the expiry within max/min
refresh(TxnH, Req, #data{sub = #{max := Max, min := Min} = Sub} = D) ->
    case requested_expires(Req, Max) of
        0 ->
            ok = refresh_respond(TxnH, 0, D),
            notify4(D, unsubscribed, Req),
            Now = now_ms(),
            Sub1 = Sub#{
                expires_at := Now + maps:get(grace, Sub), granted_at := Now
            },
            {keep_state, D#data{sub = Sub1}, sub_timer(Sub1)};
        N when N < Min ->
            Hdrs = [{<<"Min-Expires">>, integer_to_binary(Min)}],
            _ = chappe_sip_engine:dialog_respond(
                TxnH,
                423,
                <<"Interval Too Brief">>,
                chappe_sip_hdr_io:join(Hdrs),
                <<>>,
                <<>>
            ),
            {keep_state, D};
        N ->
            Granted = min(N, Max),
            ok = refresh_respond(TxnH, Granted, D),
            notify4(D, {refreshed, Granted}, Req),
            At = now_ms() + Granted * 1000,
            Sub1 = Sub#{expires_at := At, granted_at := At},
            {keep_state, D#data{sub = Sub1}, sub_timer(Sub1)}
    end.

refresh_respond(TxnH, Expires, #data{sub = #{contact := Contact}}) ->
    Hdrs =
        [{<<"Expires">>, integer_to_binary(Expires)}] ++
            [{<<"Contact">>, Contact} || Contact =/= undefined],
    _ = chappe_sip_engine:dialog_respond(
        TxnH, 200, <<"OK">>, chappe_sip_hdr_io:join(Hdrs), <<>>, <<>>
    ),
    ok.

%% an INVITE dialog ends with a BYE (carrying the caller's extra headers,
%% e.g. a Reason, RFC 3326), a subscription with a final NOTIFY
start_teardown(
    From,
    Hdrs,
    #data{sub = undefined, role = uas, index_state = early, txn = Txn} = D
) when Txn =/= undefined ->
    %% RFC 3261 15: the callee sends no BYE on an early dialog; its INVITE
    %% gets a final response instead
    _ = chappe_sip_engine:dialog_respond(
        Txn, 480, <<"Temporarily Unavailable">>, hdrs(Hdrs), <<>>, <<>>
    ),
    reply(From, ok),
    notify_terminal(D, byed),
    {stop, normal, D};
start_teardown(From, Hdrs, #data{sub = undefined} = D) ->
    start_bye(From, Hdrs, D);
start_teardown(From, _Hdrs, D) ->
    start_final_notify(From, <<"noresource">>, terminated, D).

start_final_notify(
    From, Reason, TermReason, #data{pending = undefined, sub = Sub} = D
) ->
    Seq = D#data.local_cseq + 1,
    D1 = D#data{local_cseq = Seq, sub = Sub#{term_reason := TermReason}},
    State = <<"terminated;reason=", Reason/binary>>,
    {CT, Body} =
        case Sub of
            #{last_body := {C, B}} -> {C, B};
            _ -> {undefined, <<>>}
        end,
    Headers =
        event_header(sub_event(D)) ++
            [{<<"Subscription-State">>, State}] ++ ct_header(CT, Body),
    Raw = build_indialog(D1, <<"NOTIFY">>, Seq, Headers, Body),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, terminating, D1#data{pending = {From, TxnH}}};
        {error, Why} ->
            reply(From, {error, Why}),
            notify_terminal(D1, TermReason),
            {stop, normal, D1}
    end;
start_final_notify(From, _Reason, _TermReason, D) ->
    %% final NOTIFY already in flight
    {keep_state, D, [{reply, From, ok}]}.

%% NOTIFY built from notify/2's spec: Event defaults to the subscription's,
%% Subscription-State carries the remaining expires for active/pending
start_notify(From, Spec, D) ->
    case notify_headers(Spec, D) of
        {ok, Headers, Terminal} ->
            ReqSpec = #{
                method => <<"NOTIFY">>,
                headers => Headers ++ maps:get(headers, Spec, []),
                body => maps:get(body, Spec, <<>>),
                content_type => maps:get(content_type, Spec, undefined)
            },
            start_request(From, ReqSpec, keep_body(ReqSpec, D), {
                notify, Terminal
            });
        {error, Reason} ->
            {keep_state, D, [{reply, From, {error, Reason}}]}
    end.

notify_headers(Spec, D) ->
    case maps:get(event, Spec, sub_event(D)) of
        undefined ->
            {error, no_event};
        Event when D#data.sub =:= undefined ->
            %% RFC 6665 4.2.1: no subscription but by SUBSCRIBE, save
            %% REFER's implicit one (RFC 3515)
            case chappe_sip_hdr:event(Event) of
                {ok, #{type := T}} when T =:= <<"refer">>; T =:= <<"REFER">> ->
                    notify_state(Event, Spec, D);
                _ ->
                    {error, no_subscription}
            end;
        Event ->
            notify_state(Event, Spec, D)
    end.

notify_state(Event, Spec, D) ->
    State = maps:get(state, Spec, undefined),
    case sub_state_value(State, Spec, D) of
        {ok, Value, Terminal} ->
            Headers =
                event_header(Event) ++ [{<<"Subscription-State">>, Value}],
            {ok, Headers, Terminal andalso D#data.sub =/= undefined};
        error ->
            {error, badarg}
    end.

sub_state_value(State, Spec, D) when State =:= active; State =:= pending ->
    Value = <<(atom_to_binary(State))/binary, (expires_param(Spec, D))/binary>>,
    {ok, Value, false};
sub_state_value({terminated, Reason}, _Spec, _D) ->
    {ok, <<"terminated;reason=", (to_bin(Reason))/binary>>, true};
sub_state_value(_, _Spec, _D) ->
    error.

%% a subscription states what is left of it; outside one (the implicit REFER
%% subscription of an INVITE dialog) only an explicit expires is sent
expires_param(_Spec, #data{sub = #{} = Sub}) ->
    <<";expires=", (integer_to_binary(remaining(Sub)))/binary>>;
expires_param(#{expires := N}, _D) when is_integer(N), N >= 0 ->
    <<";expires=", (integer_to_binary(N))/binary>>;
expires_param(_Spec, _D) ->
    <<>>.

keep_body(Spec, #data{sub = #{keep_body := true} = Sub} = D) ->
    #{content_type := CT, body := Body} = Spec,
    D#data{sub = Sub#{last_body := {CT, iolist_to_binary(Body)}}};
keep_body(_Spec, D) ->
    D.

term_reason(#data{sub = #{term_reason := R}}) -> R;
term_reason(#data{bye_reason = R}) when R =/= undefined -> R;
term_reason(_) -> byed.

sub_event(#data{sub = #{event := E}}) -> E;
sub_event(_) -> undefined.

event_header(undefined) -> [];
event_header(Event) -> [{<<"Event">>, Event}].

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) when is_list(L) -> iolist_to_binary(L).

%% ---- helpers ----

start_bye(From, Hdrs, #data{pending = undefined} = D0) ->
    Seq = D0#data.local_cseq + 1,
    D = D0#data{local_cseq = Seq},
    Raw = build_indialog(D, <<"BYE">>, Seq, Hdrs, <<>>),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            %% RFC 3891: a Replaces naming this dialog now gets 603
            set_index_state(D, terminated),
            {next_state, terminating, D#data{pending = {From, TxnH}}};
        {error, Reason} ->
            unindex(D),
            reply(From, {error, Reason}),
            {stop, normal, D}
    end;
start_bye(From, _Hdrs, D) ->
    %% BYE already in flight
    {keep_state, D, [{reply, From, ok}]}.

%% ---- re-INVITE / in-dialog request ----

%% Opts: retry_on_glare => true retries once after a 491 (RFC 3261 14.1).
%% The hold state and local SDP change only once the re-INVITE succeeds.
start_reinvite(
    From, SdpSpec, Opts, #data{local_sdp = CurSdp, on_hold = Hold} = D
) ->
    {NewSdp, NewHold} = resolve_sdp(SdpSpec, CurSdp, Hold),
    Retry =
        case maps:get(retry_on_glare, Opts, false) of
            true -> {retry, SdpSpec};
            false -> undefined
        end,
    Seq = D#data.local_cseq + 1,
    % ACK must reuse this CSeq
    D1 = D#data{local_cseq = Seq},
    Headers =
        [{<<"Content-Type">>, <<"application/sdp">>}] ++
            chappe_sip_session_timer:refresh_headers(D#data.st),
    Raw = build_indialog(D1, <<"INVITE">>, Seq, Headers, NewSdp),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, in_transaction, D1#data{
                pending_hold = NewHold,
                glare_retry = Retry,
                txning = {From, TxnH, {reinvite, NewSdp}}
            }};
        {error, Reason} ->
            {keep_state, D, [{reply, From, {error, Reason}}]}
    end.

start_request(From, #{method := <<"UPDATE">>} = ReqSpec, D) ->
    %% an UPDATE with a body is an offer (RFC 3311), answered in its 2xx
    case iolist_to_binary(maps:get(body, ReqSpec, <<>>)) of
        <<>> -> start_request(From, ReqSpec, D, request);
        Sdp -> start_request(From, ReqSpec, D, {update, Sdp})
    end;
start_request(From, ReqSpec, D) ->
    start_request(From, ReqSpec, D, request).

start_request(From, ReqSpec, D, Kind) ->
    Method = maps:get(method, ReqSpec),
    {Seq, D1} = next_cseq(D),
    Body = iolist_to_binary(maps:get(body, ReqSpec, <<>>)),
    Headers0 = maps:get(headers, ReqSpec, []),
    Headers =
        Headers0 ++
            st_request_headers(Method, Headers0, D) ++
            ct_header(maps:get(content_type, ReqSpec, undefined), Body),
    Raw = build_indialog(D1, Method, Seq, Headers, Body),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, in_transaction, D1#data{
                txning = {From, TxnH, Kind}
            }};
        {error, Reason} ->
            {keep_state, D, [{reply, From, {error, Reason}}]}
    end.

ct_header(undefined, <<>>) -> [];
ct_header(undefined, _Body) -> [];
ct_header(CT, _Body) -> [{<<"Content-Type">>, CT}].

%% hold/unhold rewrite the stored local SDP direction attribute
resolve_sdp(hold, CurSdp, _Hold) ->
    {next_version(chappe_sip_sdp_hold(CurSdp, true)), true};
resolve_sdp(unhold, CurSdp, _Hold) ->
    {next_version(chappe_sip_sdp_hold(CurSdp, false)), false};
resolve_sdp(Sdp, _CurSdp, Hold) when is_binary(Sdp); is_list(Sdp) ->
    {iolist_to_binary(Sdp), Hold};
resolve_sdp(undefined, CurSdp, Hold) ->
    {next_version(CurSdp), Hold}.

%% RFC 3261 14.1 (RFC 3264 8): a new offer built from our last session
%% description carries the next o= session version
next_version(Sdp) ->
    case
        re:run(Sdp, "^(o=\\S+ \\S+ )([0-9]+)", [
            multiline, {capture, [1, 2], index}
        ])
    of
        {match, [{S, L}, {VS, VL}]} ->
            V = binary_to_integer(binary:part(Sdp, VS, VL)),
            <<
                (binary:part(Sdp, 0, S))/binary,
                (binary:part(Sdp, S, L))/binary,
                (integer_to_binary(V + 1))/binary,
                (binary:part(Sdp, VS + VL, byte_size(Sdp) - VS - VL))/binary
            >>;
        nomatch ->
            Sdp
    end.

%% RFC 3264 8.4: hold moves every live stream to sendonly
%% (or inactive when it was recvonly); unhold reverses that. Each m= section
%% gets its own direction attribute, so a session-level one is folded into
%% them. A rejected stream (port 0) is left alone.
chappe_sip_sdp_hold(Sdp, Hold) ->
    Eol =
        case binary:match(Sdp, <<"\r\n">>) of
            nomatch -> <<"\n">>;
            _ -> <<"\r\n">>
        end,
    Lines = [L || L <- binary:split(Sdp, Eol, [global]), L =/= <<>>],
    {Session, Medias} = sdp_sections(Lines),
    SessDir = sdp_direction(Session, <<"sendrecv">>),
    Out =
        case Medias of
            [] ->
                set_direction(Session, hold_direction(SessDir, Hold));
            _ ->
                [L || L <- Session, not is_direction(L)] ++
                    lists:append([
                        media_hold(M, SessDir, Hold)
                     || M <- Medias
                    ])
        end,
    iolist_to_binary([[L, Eol] || L <- Out]).

%% session lines, then one list of lines per m= section
sdp_sections(Lines) ->
    {Session, Rest} = lists:splitwith(
        fun(L) -> not is_mline(L) end, Lines
    ),
    {Session, media_sections(Rest)}.

media_sections([]) ->
    [];
media_sections([M | Rest]) ->
    {Body, More} = lists:splitwith(fun(L) -> not is_mline(L) end, Rest),
    [[M | Body] | media_sections(More)].

is_mline(<<"m=", _/binary>>) -> true;
is_mline(_) -> false.

media_hold([M | _] = Section, SessDir, Hold) ->
    case binary:split(M, <<" ">>, [global]) of
        [_, <<"0">> | _] ->
            Section;
        _ ->
            Dir = sdp_direction(Section, SessDir),
            set_direction(Section, hold_direction(Dir, Hold))
    end.

hold_direction(<<"sendrecv">>, true) -> <<"sendonly">>;
hold_direction(<<"recvonly">>, true) -> <<"inactive">>;
hold_direction(<<"sendonly">>, false) -> <<"sendrecv">>;
hold_direction(<<"inactive">>, false) -> <<"recvonly">>;
hold_direction(Dir, _Hold) -> Dir.

sdp_direction(Lines, Default) ->
    case [D || <<"a=", D/binary>> <- Lines, is_direction(<<"a=", D/binary>>)] of
        [] -> Default;
        Dirs -> lists:last(Dirs)
    end.

is_direction(<<"a=", D/binary>>) ->
    lists:member(D, [
        <<"sendrecv">>, <<"sendonly">>, <<"recvonly">>, <<"inactive">>
    ]);
is_direction(_) ->
    false.

%% replace the section's direction attribute in place, or add one
set_direction(Lines, Dir) ->
    Attr = <<"a=", Dir/binary>>,
    case lists:any(fun is_direction/1, Lines) of
        true ->
            {Out, _} = lists:mapfoldl(
                fun(L, Done) ->
                    case is_direction(L) of
                        true when not Done -> {[Attr], true};
                        true -> {[], Done};
                        false -> {[L], Done}
                    end
                end,
                false,
                Lines
            ),
            lists:append(Out);
        false ->
            Lines ++ [Attr]
    end.

%% Build an in-dialog request (From=local, To=remote). RFC 3261 12.2.1.1:
%% behind a loose router (;lr) the Request-URI is the remote target and the
%% route set goes in Route; behind a strict router the first route is the
%% Request-URI and the remote target ends the Route list.
build_indialog(
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
    {RURI, RouteSet} = chappe_sip_route:request_target(Target, RouteSet0),
    Seq = integer_to_binary(CSeq),
    HdrBin = chappe_sip_hdr_io:join(
        with_supported(Method, with_contact(Method, Contact, Headers))
    ),
    CL = integer_to_binary(byte_size(Body)),
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n",
        (route_headers(RouteSet))/binary, "From: ", LocalAddr/binary, "\r\n",
        "To: ", RemoteAddr/binary, "\r\n", "Call-ID: ", CallId/binary, "\r\n",
        "CSeq: ", Seq/binary, " ", Method/binary, "\r\n",
        "Max-Forwards: 70\r\n", HdrBin/binary, "Content-Length: ", CL/binary,
        "\r\n\r\n", Body/binary>>.

%% Target refresh requests carry our Contact (RFC 3261 12.2.1.1 for
%% re-INVITE and UPDATE, RFC 6665 4.1.2.2 and 4.2.2 for SUBSCRIBE and
%% NOTIFY, RFC 3515 for REFER), unless the caller supplied one.
with_contact(_Method, undefined, Headers) ->
    Headers;
with_contact(Method, Contact, Headers) ->
    Refresh = lists:member(Method, [
        <<"INVITE">>, <<"UPDATE">>, <<"NOTIFY">>, <<"SUBSCRIBE">>, <<"REFER">>
    ]),
    Supplied = lists:any(
        fun({N, _}) -> string:lowercase(N) =:= <<"contact">> end, Headers
    ),
    case Refresh andalso not Supplied of
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

%% The ACK of a 2xx the UAC fsm left unacknowledged (no_ack, 3PCC): the
%% INVITE's CSeq number and credentials (RFC 3261 13.2.2.4), and the answer
%% to an offer the 2xx carried when Opts has one.
send_delayed_ack(From, _Opts, #data{pending_ack = undefined} = D) ->
    {keep_state, D, [{reply, From, {error, no_pending_ack}}]};
send_delayed_ack(From, Opts, #data{pending_ack = #{cseq := CSeq} = P} = D) ->
    Body = iolist_to_binary(maps:get(local_sdp, Opts, <<>>)),
    Hdrs =
        maps:get(headers, P) ++
            [{<<"Content-Type">>, <<"application/sdp">>} || Body =/= <<>>],
    Raw = build_indialog(D, <<"ACK">>, CSeq, Hdrs, Body),
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

%% ACK a re-INVITE 2xx (in-dialog, its own transaction; ACK reuses the
%% re-INVITE's CSeq number).
send_ack_indialog(#data{local_cseq = CSeq} = D) ->
    Raw = build_indialog(D, <<"ACK">>, CSeq, [], <<>>),
    chappe_sip_engine:send_stateless(route(D), Raw, self()).

%% in-dialog requests go over the dialog's WS flow when it has one, else the
%% sofia path routes by the Request-URI / Route set
%% Send destination: a WS flow wins (a browser is reached over its flow); else
%% with a route set (loose routing) the request goes to the first Route's URI
%% (RFC 3261 12.2.1.1), otherwise nta routes by the Request-URI. A sip:
%% first route is reached as sips: when the remote target is SIPS (8.1.2).
route(#data{flow = Flow}) when Flow =/= undefined ->
    chappe_sip_route:flow_route(Flow);
route(#data{route_set = [First | _], remote_target = Target}) ->
    case chappe_sip_hdr:name_addr(First) of
        {ok, #{uri := Uri}} -> chappe_sip_route:secure_hop(Target, Uri);
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

%% runs in the owner: a 2xx carries the session timer headers (unless the
%% owner set its own) and re-arms the fsm's timers (St = keep: leaves them
%% alone, for a request that does not refresh the session). The fsm hears of the
%% final response before it goes on the wire, so a request the peer sends
%% once it has it finds the transaction settled.
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
        Headers = chappe_sip_hdr_io:join(Hdrs),
        Body = iolist_to_binary(maps:get(body, Opts, <<>>)),
        _ =
            Status >= 200 andalso
                (Fsm ! {chappe_sip_final, TxnH, Status, Body}),
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

%% The answer to an in-dialog request nobody claimed:
%% {Status, Reason, Headers, Body, Data}.
%% re-INVITE / UPDATE with an offer: answered with the current local SDP,
%% the session unchanged (488 without one). An offerless re-INVITE gets our
%% SDP as the offer and the ACK carries the answer.
auto_answer(modify, Req, D) ->
    case {chappe_sip_req:body(Req), D#data.local_sdp} of
        {_, <<>>} ->
            not_acceptable(D);
        {<<>>, Sdp} ->
            sdp_ok(Sdp, D#data{ack_answer = true});
        {Offer, Sdp} ->
            sdp_ok(Sdp, D#data{remote_sdp = Offer})
    end;
auto_answer(update, Req, D) ->
    case {chappe_sip_req:body(Req), D#data.local_sdp} of
        {<<>>, _} -> {200, <<"OK">>, contact_hdr(D), <<>>, D};
        {_, <<>>} -> not_acceptable(D);
        {Offer, Sdp} -> sdp_ok(Sdp, D#data{remote_sdp = Offer})
    end;
auto_answer(refer, _Req, D) ->
    %% nobody here will act on the transfer
    {603, <<"Declined">>, [], <<>>, D};
auto_answer(options, _Req, D) ->
    %% RFC 3261 11.2
    Hdrs = [
        {<<"Allow">>, ?ALLOW},
        {<<"Accept">>, <<"application/sdp">>},
        {<<"Supported">>, ?SUPPORTED}
    ],
    {200, <<"OK">>, Hdrs, <<>>, D};
auto_answer({method, <<"PRACK">>}, _Req, D) ->
    %% no reliable provisional of ours is pending in a confirmed dialog
    {481, <<"Call/Transaction Does Not Exist">>, [], <<>>, D};
auto_answer({method, M}, _Req, D) when
    M =:= <<"REGISTER">>; M =:= <<"PUBLISH">>
->
    %% RFC 3261 8.2.1: known, not allowed here
    {405, <<"Method Not Allowed">>, [{<<"Allow">>, ?ALLOW}], <<>>, D};
auto_answer({method, _}, _Req, D) ->
    %% RFC 3261 8.2.1: a method we do not recognise
    {501, <<"Not Implemented">>, [{<<"Allow">>, ?ALLOW}], <<>>, D};
auto_answer(_Event, _Req, D) ->
    {200, <<"OK">>, [], <<>>, D}.

sdp_ok(Sdp, D) ->
    Hdrs = [{<<"Content-Type">>, <<"application/sdp">>} | contact_hdr(D)],
    {200, <<"OK">>, Hdrs, Sdp, D}.

not_acceptable(D) ->
    Warn = {<<"Warning">>, <<"399 chappe \"no local session description\"">>},
    {488, <<"Not Acceptable Here">>, [Warn], <<>>, D}.

%% target refresh responses carry our Contact (RFC 3261 12.2.2)
refresh_contact(Method, D) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    contact_hdr(D);
refresh_contact(_Method, _D) ->
    [].

contact_hdr(#data{local_contact = undefined}) -> [];
contact_hdr(#data{local_contact = C}) -> [{<<"Contact">>, C}].

hdrs([]) -> <<>>;
hdrs(Hdrs) -> chappe_sip_hdr_io:join(Hdrs).

%% claimed events and ack carry a Res slot (5-tuple)
notify(#data{owner = Owner} = D, Event, Req, Res) ->
    Owner ! {chappe_sip_dialog, dialog(D), Event, Req, Res},
    ok.

%% auto-answered notifications are informational (4-tuple, no Res)
notify4(#data{owner = Owner} = D, Event, Req) ->
    Owner ! {chappe_sip_dialog, dialog(D), Event, Req},
    ok.

%% the index entry goes first, so an owner told of the destroy never finds
%% the dialog again
notify_terminal_req(#data{owner = Owner} = D, Req) ->
    unindex(D),
    Owner ! {chappe_sip_dialog, dialog(D), destroy, Req},
    ok.

notify_terminal(#data{owner = Owner} = D, Reason) ->
    unindex(D),
    Owner ! {chappe_sip_dialog, dialog(D), destroy, Reason},
    ok.

%% ---- session timers (RFC 4028) ----

st_timers(undefined) -> [];
st_timers(St) -> chappe_sip_session_timer:timeouts(St).

%% a new session timer state restarts both timers (a 2xx refreshed it)
st_apply(undefined, #data{st = undefined} = D) ->
    {keep_state, D};
st_apply(St, D) ->
    {keep_state, D#data{st = St}, st_timers_or_cancel(St)}.

st_timers_or_cancel(undefined) -> chappe_sip_session_timer:cancel_timeouts();
st_timers_or_cancel(St) -> chappe_sip_session_timer:timeouts(St).

%% the peer's INVITE or UPDATE is a session refresh request (section 9)
st_incoming(Method, Req, #data{st = St, st_cfg = Cfg}) when
    Method =:= <<"INVITE">>; Method =:= <<"UPDATE">>
->
    chappe_sip_session_timer:incoming(chappe_sip_req:msg(Req), Cfg, St);
st_incoming(_Method, _Req, #data{st = St}) ->
    {ok, [], St}.

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

has_hdr(Name, Headers) ->
    L = string:lowercase(Name),
    lists:any(fun({N, _}) -> string:lowercase(N) =:= L end, Headers).

st_response(Status, Raw, #data{st = St} = D) when Status >= 200, Status < 300 ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            case chappe_sip_msg:cseq(Msg) of
                {ok, #{method := M}} when
                    M =:= <<"INVITE">>; M =:= <<"UPDATE">>
                ->
                    case chappe_sip_session_timer:response(Msg, Status, St) of
                        undefined when St =:= undefined -> {D, []};
                        St1 -> {D#data{st = St1}, st_timers_or_cancel(St1)}
                    end;
                _ ->
                    {D, []}
            end;
        {error, _} ->
            {D, []}
    end;
st_response(_Status, _Raw, D) ->
    {D, []}.

with_actions(Result, []) ->
    Result;
with_actions({next_state, S, D}, A) ->
    {next_state, S, D, A};
with_actions({next_state, S, D, A0}, A) ->
    {next_state, S, D, A0 ++ A};
with_actions({keep_state, D}, A) ->
    {keep_state, D, A};
with_actions({keep_state, D, A0}, A) ->
    {keep_state, D, A0 ++ A};
with_actions(Stop, _A) ->
    Stop.

%% Refresh at half the interval (section 10): UPDATE without a body when
%% the peer allows it, else a re-INVITE offering the unchanged SDP (7.4).
start_st_refresh(#data{st = #{peer_update := true}} = D) ->
    send_st_refresh(<<"UPDATE">>, [], <<>>, D);
start_st_refresh(#data{local_sdp = Sdp} = D) ->
    CT = [{<<"Content-Type">>, <<"application/sdp">>} || Sdp =/= <<>>],
    send_st_refresh(<<"INVITE">>, CT, Sdp, D).

send_st_refresh(Method, Headers, Body, #data{st = St} = D) ->
    Seq = D#data.local_cseq + 1,
    D1 = D#data{local_cseq = Seq},
    Hdrs = Headers ++ chappe_sip_session_timer:refresh_headers(St),
    Raw = build_indialog(D1, Method, Seq, Hdrs, Body),
    case chappe_sip_engine:send_request(route(D), Raw, self()) of
        {ok, TxnH} ->
            {next_state, in_transaction, D1#data{
                txning = {undefined, TxnH, {st_refresh, Method}}
            }};
        {error, _} ->
            %% the expiry timer still ends the session
            {keep_state, D}
    end.

%% The final response to our refresh; a 2xx already re-armed the timers.
st_refresh_response(_From, _Kind, Status, _Raw, D) when Status < 200 ->
    {keep_state, D};
st_refresh_response(_From, {st_refresh, Method}, Status, Raw, D) when
    Status < 300
->
    D1 =
        case Method of
            <<"INVITE">> ->
                {ok, Msg} = chappe_sip_msg:parse(Raw),
                _ = send_ack_indialog(D),
                D#data{remote_sdp = chappe_sip_msg:body(Msg)};
            _ ->
                D
        end,
    {next_state, confirmed, st_done(D1)};
st_refresh_response(_From, _Kind, Status, _Raw, D) when
    Status =:= 408; Status =:= 481
->
    %% section 10: the refresh timed out or the dialog is gone
    start_teardown(undefined, [], (st_done(D))#data{
        bye_reason = {refresh_failed, Status}
    });
st_refresh_response(_From, _Kind, 422, Raw, #data{st = St} = D) ->
    %% section 7.3: retry with the larger Min-SE the 422 names
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    case chappe_sip_session_timer:retry_after_422(Msg, St) of
        {retry, St1} -> start_st_refresh((st_done(D))#data{st = St1});
        give_up -> {next_state, confirmed, st_done(D)}
    end;
st_refresh_response(_From, _Kind, 491, _Raw, D) ->
    %% RFC 3261 14.1: glare, retry after 2.1 to 4 s
    {next_state, confirmed, st_done(D), [
        {{timeout, st_refresh}, 2100 + rand:uniform(1900), refresh}
    ]};
st_refresh_response(_From, _Kind, _Status, _Raw, D) ->
    %% no retry: the expiry timer ends the session unless the peer refreshes
    {next_state, confirmed, st_done(D)}.

%% the next request takes local_cseq + 1, so a 422 retry is one higher
st_done(D) ->
    D#data{txning = undefined}.

%% ---- dialog index (RFC 3891 Replaces) ----

initial_index_state(#{early_uac := Pid}, _Opts) when is_pid(Pid) ->
    early;
initial_index_state(_Args, Opts) ->
    case maps:get(status, Opts, 200) of
        S when is_integer(S), S < 200 -> early;
        _ -> confirmed
    end.

%% index under {CallId, LocalTag, RemoteTag}; a dialog whose peer never
%% tagged it cannot be named by a Replaces and is not indexed
index(#data{sub = Sub} = D) when Sub =/= undefined ->
    %% a Replaces names an INVITE dialog, never a subscription
    D;
index(#data{remote_addr = RA} = D) ->
    case addr_tag(RA) of
        undefined ->
            D;
        RemoteTag ->
            Key = {D#data.call_id, D#data.local_tag, RemoteTag},
            case
                chappe_sip_dialog_index:insert(
                    Key, D#data.leg, D#data.index_state, D#data.role, self()
                )
            of
                ok ->
                    D#data{indexed = Key};
                {error, Reason} ->
                    logger:warning(
                        "chappe_sip_dialog_fsm: not indexed ~p: ~p",
                        [Key, Reason]
                    ),
                    D
            end
    end.

set_index_state(#data{indexed = undefined}, _State) ->
    ok;
set_index_state(#data{indexed = Key}, State) ->
    chappe_sip_dialog_index:set_state(Key, State).

unindex(#data{indexed = undefined}) -> ok;
unindex(#data{indexed = Key}) -> chappe_sip_dialog_index:delete(Key).

dialog(#data{leg = LegH}) ->
    chappe_sip_dialog:make(self(), LegH).

reply_await(#data{await_from = undefined}, _) -> ok;
reply_await(#data{await_from = From}, Msg) -> gen_statem:reply(From, Msg).

reply(undefined, _) -> ok;
reply(From, Msg) -> gen_statem:reply(From, Msg).

terminate(_Reason, _State, #data{leg = LegH} = D) ->
    unindex(D),
    %% a re-INVITE waiting out its 491 retry timer will not happen
    _ =
        case D#data.glare_wait of
            {From, _} -> reply(From, {error, terminated});
            undefined -> ok
        end,
    %% destroy_leg is a cast; unreg happens as part of it
    _ = chappe_sip_engine:destroy_leg(LegH),
    ok.
