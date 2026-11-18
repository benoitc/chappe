%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The #state{} of chappe_sip_ws_transport, shared with its transaction
%% tables (chappe_sip_ws_txn). Private to the ws directory and its tests.

-record(state, {
    % persistent monotonic handle source
    counter :: atomics:atomics_ref(),
    % Flow => {Conn, Peer, ws | wss}
    conns = #{} :: #{integer() => {pid(), term(), ws | wss}},
    % Conn monitor => Flow
    mons = #{} :: #{reference() => integer()},
    % ServerTxnH => #{flow,branch,method,msg,state,timer,last,tag,...}
    stxn = #{} :: #{integer() => map()},
    %% {Flow, Branch, Method} => ServerTxnH (a branch is unique only within
    %% a flow, and the method is part of the match, RFC 3261 17.2.3)
    branch_ix = #{} :: #{{integer(), binary(), binary()} => integer()},
    % ClientTxnH => #{flow,branch,pid,req,method,timer,prov,final,cancel}
    ctxn = #{} :: #{integer() => map()},
    % our Via branch => ClientTxnH
    cbranch_ix = #{} :: #{binary() => integer()},
    % LegH => #{flow,call_id,ltag,rtag}
    legs = #{} :: #{integer() => map()},
    % {CallId,LTag,RTag} => LegH
    leg_ix = #{} :: #{term() => integer()},
    %% {CallId,LTag,RTag} => TRef: our 2xx to an INVITE waiting for its ACK
    ackw = #{} :: #{term() => reference()}
}).
