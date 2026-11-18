%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The dialog fsm's data, shared with its chappe_sip_dialog_* helpers.

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
    %% the peer's last offer put the session on hold (RFC 3264 8.4)
    remote_hold = false :: boolean(),
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
    %% our in-flight re-INVITE leaves its 2xx unACKed for the owner to ACK
    %% (ack/2) with the answer to the offer that 2xx carries
    reinvite_ack = auto :: auto | manual,
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
    cseq_ref :: atomics:atomics_ref() | undefined,
    %% the call record of an INVITE dialog (chappe_sip_cdr), and why the
    %% call ends when the destroy reason the owner sees does not say it
    cdr :: binary() | undefined,
    cdr_why :: chappe_sip_cdr:reason() | undefined,
    %% the call this dialog serves (chappe_sip_call): its in-dialog
    %% requests carry it, and the dialog is found by it while it lives
    call_ref :: binary() | undefined
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
