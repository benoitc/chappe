%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The #state{} of chappe_sip_engine, shared with its helpers
%% (chappe_sip_engine_events, chappe_sip_engine_handles). Private to the
%% engine directory.

-record(state, {
    mod :: module(),
    engine :: term() | undefined,
    routes = #{} :: #{binary() => fun()},
    middlewares = [] :: [{binary() | '*', chappe_sip_middleware:mw()}],
    %% WorkerPid => {MonRef, TxnH, FinalRef, DeadlineTRef}
    workers = #{} :: map(),
    %% engine handle (LegH / TxnH) => target pid, for routing op results,
    %% responses, in-dialog requests, acks and cancels
    handles = #{} :: #{non_neg_integer() => pid()},
    %% dialog fsm pids (subset of handle targets) for restart teardown
    dialogs = #{} :: #{pid() => true},
    %% other handle-owner pids we monitor (UAC fsms), so their crash sweeps
    %% their handles and destroys the C-side transactions/legs
    monitored = #{} :: #{pid() => reference()},
    engine_opts = #{} :: map(),
    contact :: binary() | undefined,
    tref :: reference() | undefined,
    misses = 0 :: non_neg_integer(),
    health_waiters = [] :: [gen_server:from()],
    %% server transactions a proxy owns (TxnH => owner pid): their CANCEL is
    %% forwarded, not answered 487 here, and a request merging with one is
    %% a spiral, not a merged request
    proxied = #{} :: #{non_neg_integer() => pid()},
    %% RFC 3261 8.2.2.2 merge index for out-of-dialog requests with no
    %% To-tag: {From-tag, Call-ID, CSeq} => {top Via branch, TxnH, worker}
    merge = #{} :: #{tuple() => {binary(), non_neg_integer(), pid()}},
    %% INVITE server transactions with an early UAS dialog (a 1xx from
    %% create_uas): a CANCEL ends that dialog too
    early_uas = #{} :: #{non_neg_integer() => pid()},
    %% with several listen addresses: the ident a process (a dialog, a UAC)
    %% sends from, so its requests leave from the address its Contact names
    locals = #{} :: #{pid() => binary()}
}).
