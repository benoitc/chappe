%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The #data{} of chappe_sip_uac_fsm, shared with its helpers
%% (chappe_sip_uac_req, _uac_sdp, _uac_early, _uac_retry). Private to the
%% uac directory.

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
    %% a preloaded route set (RFC 3261 8.1.1.1), Route header values
    route_set = [] :: [binary()],
    % when set, originate over this WS flow
    flow :: chappe_sip_engine:flow() | undefined,
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
    %% headers for the CANCEL and the BYE of an abandoned INVITE
    abandon_hdrs = [] :: [{binary(), iodata()}],
    %% the dialog the 2xx formed, while forked 2xx linger
    dialog :: chappe_sip_dialog:dialog() | undefined,
    %% retried once without the option tags a 420 named
    ext_retried = false :: boolean(),
    redirects = 0 :: non_neg_integer(),
    winner_tag :: binary() | undefined,
    %% the last CSeq number sent: the INVITE's, then each PRACK's and each
    %% request of an early dialog (shared with their fsms)
    seq :: atomics:atomics_ref(),
    prack_txns = [] :: [non_neg_integer()],
    %% RFC 3262 4: the last in-order RSeq of each early dialog (To tag)
    rseq = #{} :: #{binary() | undefined => pos_integer()},
    %% the answer we gave to an offer, in a PRACK or the ACK
    local_answer = <<>> :: binary(),
    %% RFC 4028 7.4: the largest Min-SE of the 422s to this INVITE, and how
    %% many times we retried after one
    min_se_422 = 0 :: non_neg_integer(),
    retries_422 = 0 :: non_neg_integer(),
    %% the early dialogs of this INVITE by To tag, and the To tags whose
    %% early dialog the callee ended with a BYE
    early = #{} :: #{binary() => chappe_sip_dialog:dialog()},
    byed = [] :: [binary()],
    %% the first SDP a response brought: the answer to our offer (RFC 3261
    %% 13.2.1), whatever a later response carries
    first_sdp = <<>> :: binary(),
    %% an INVITE watches its owner: the owner gone, the call is abandoned
    owner_mon :: reference() | undefined,
    %% we CANCELled the INVITE
    cancelled = false :: boolean(),
    %% the INVITE's call record (chappe_sip_cdr), and why it ends when the
    %% final response does not say it (timeout, owner_down)
    cdr :: binary() | undefined,
    cdr_why :: chappe_sip_cdr:reason() | undefined
}).
