%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The handle table of chappe_sip_engine: which process owns each
%% engine handle (a dialog leg, a transaction), the dialogs it creates,
%% and the cleanup when an owner goes.
%%
%% handle/3 serves the engine's `handles' call envelope: a UAS dialog, a
%% B2BUA's early leg, a UAC dialog, a proxied server transaction, a
%% disarmed deadline, a registered handle. down/4 sweeps the handles of a
%% worker or an owner that exited. Runs inside the engine process, on its
%% #state{} (chappe_sip_engine.hrl).
-module(chappe_sip_engine_handles).

-include("chappe_sip_engine.hrl").

-export([handle/3, down/4]).
-export([disarm_deadline/2, ensure_monitored/2, cancel_deadline/1]).

-spec handle(term(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}}.
handle({create_uas, Req, Opts}, {WorkerPid, _}, S) ->
    create_uas(Req, Opts, WorkerPid, S);
handle({early_leg, Req, LocalTag}, {Pid, _}, S) ->
    early_leg(Req, LocalTag, Pid, S);
handle({create_dialog, DialogArgs}, {Caller, _}, S) ->
    %% WS-only nodes have engine = undefined; a WS-flow dialog still creates
    %% its leg on the transport. The backend returns not_started for a
    %% non-WS dialog with no native engine.
    create_dialog(DialogArgs, Caller, S);
handle({mark_proxied, TxnH}, {Pid, _}, S) ->
    {reply, ok, mark_proxied(TxnH, Pid, S)};
handle({disarm, Pid}, _From, S) ->
    {reply, ok, disarm_deadline(Pid, S)};
handle({reg_handle, H, Pid}, _From, S) ->
    S1 = ensure_monitored(Pid, S),
    {reply, ok, S1#state{handles = (S1#state.handles)#{H => Pid}}}.

early_leg(Req, LocalTag, Pid, S) ->
    case uas_leg(Req, LocalTag, S) of
        {ok, LegH} ->
            {reply, {ok, LegH}, S#state{
                handles = (S#state.handles)#{LegH => Pid}
            }};
        Err ->
            {reply, Err, S}
    end.

%% the dialog leg of a request's dialog, on the backend that owns the
%% request's transaction
uas_leg(Req, LocalTag, #state{mod = Mod, engine = Engine}) ->
    Msg = chappe_sip_req:msg(Req),
    Where =
        case chappe_sip_ws:is_ws(chappe_sip_req:txn(Req)) of
            true -> {ws, maps:get(flow, chappe_sip_req:meta(Req), undefined)};
            false -> native
        end,
    chappe_sip_engine_backend:leg_create(
        Mod,
        Engine,
        Where,
        chappe_sip_msg:call_id(Msg),
        chappe_sip_uas_response:local_addr(Msg, LocalTag),
        chappe_sip_msg:get(<<"from">>, Msg)
    ).

mark_proxied(TxnH, Pid, #state{mod = Mod, engine = E, proxied = Px} = S) ->
    case chappe_sip_ws:is_ws(TxnH) of
        true ->
            S#state{proxied = Px#{TxnH => Pid}};
        false when E =:= undefined ->
            S;
        false ->
            _ = chappe_sip_engine_backend:proxy_mark(Mod, E, TxnH),
            S#state{proxied = Px#{TxnH => Pid}}
    end.

%% Build a UAS dialog: allocate the leg, register it, start the fsm, and
%% send the dialog-forming response with the local tag. op_ok/op_failed
%% for the leg routes to the fsm, which confirms or fails setup.
create_uas(Req, Opts, WorkerPid, S) ->
    case at_dialog_cap(S) of
        true -> {reply, {error, max_dialogs}, S};
        false -> create_uas_1(Req, Opts, WorkerPid, S)
    end.

create_uas_1(Req, Opts, WorkerPid, S) ->
    %% honor a caller-chosen tag (b2bua pre-tags relayed provisionals with
    %% the same value so the early dialog and the 2xx share one To-tag)
    LocalTag = maps:get(local_tag, Opts, chappe_sip_dialog:gen_tag()),
    %% a B2BUA's early leg (early_leg/2) becomes the dialog's
    Leg =
        case maps:get(leg, Opts, undefined) of
            undefined -> uas_leg(Req, LocalTag, S);
            EarlyLeg -> {ok, EarlyLeg}
        end,
    case Leg of
        {ok, LegH} -> start_uas(Req, Opts, WorkerPid, LocalTag, LegH, S);
        Err -> {reply, Err, S}
    end.

start_uas(Req, Opts, WorkerPid, LocalTag, LegH, S) ->
    #state{mod = Mod, engine = Engine} = S,
    TxnH = chappe_sip_req:txn(Req),
    %% contact_params: a feature tag after the `>' (+sip.srs for a
    %% recording server, RFC 7866 6.2)
    Tls = chappe_sip_engine_opts:tls_uri(S#state.engine_opts, S#state.contact),
    Ours = chappe_sip_uas_response:contact(Req, Tls, S#state.contact),
    Contact = <<Ours/binary, (maps:get(contact_params, Opts, <<>>))/binary>>,
    Owner = maps:get(owner, Opts, WorkerPid),
    FsmArgs = chappe_sip_uas_response:fsm_args(Req, #{
        leg => LegH,
        owner => Owner,
        local_tag => LocalTag,
        contact => Contact,
        opts => Opts
    }),
    case start_dialog(FsmArgs, LegH, S) of
        {ok, Pid} ->
            %% send the dialog-forming response here (not from the fsm
            %% init: that would re-enter this gen_server and deadlock).
            %% op_ok/op_failed for the leg routes to Pid.
            {Status, Reason, Headers, Body} =
                chappe_sip_uas_response:build(Opts, Contact),
            _ = chappe_sip_engine_backend:respond(
                Mod, Engine, TxnH, Status, Reason, Headers, Body, LocalTag
            ),
            {reply, {ok, Pid}, uas_started(Req, Opts, Owner, LegH, Pid, S)};
        Err ->
            {reply, Err, S}
    end.

%% the dialog's handles, and its owner's deadline disarmed: the owner now
%% blocks for the call's lifetime and must not be killed mid-call
uas_started(Req, Opts, Owner, LegH, Pid, S) ->
    Msg = chappe_sip_req:msg(Req),
    TxnH = chappe_sip_req:txn(Req),
    S1 = disarm_deadline(Owner, S),
    HM0 = S1#state.handles,
    AckWait = chappe_sip_uas_response:ack_wait(Msg, Opts),
    HM1 =
        case AckWait andalso not chappe_sip_ws:is_ws(TxnH) of
            true -> HM0#{TxnH => Pid};
            false -> HM0
        end,
    Early =
        case chappe_sip_uas_response:early(Msg, Opts) of
            true -> (S1#state.early_uas)#{TxnH => Pid};
            false -> S1#state.early_uas
        end,
    %% the dialog sends from the address the request came to
    Locals =
        case chappe_sip_binds:local(chappe_sip_req:meta(Req)) of
            undefined -> S1#state.locals;
            L -> (S1#state.locals)#{Pid => L}
        end,
    S1#state{
        handles = HM1#{LegH => Pid},
        dialogs = (S1#state.dialogs)#{Pid => true},
        early_uas = Early,
        locals = Locals
    }.

%% Create a dialog (UAC path): allocate the leg and start the fsm already
%% established. Returns {ok, DialogPid, LegH}.
create_dialog(DialogArgs, Caller, S) ->
    case at_dialog_cap(S) of
        true -> {reply, {error, max_dialogs}, S};
        false -> create_dialog_1(DialogArgs, Caller, S)
    end.

create_dialog_1(DialogArgs, Caller, S) ->
    #state{mod = Mod, engine = Engine, handles = HM} = S,
    #{
        call_id := CallId,
        local_addr := LocalAddr,
        remote_addr := RemoteAddr
    } = DialogArgs,
    %% a WS dialog's leg must live in the WS transport so a peer-originated
    %% in-dialog request over the flow matches it (not the sofia leg index)
    Flow = maps:get(flow, DialogArgs, undefined),
    Where =
        case chappe_sip_ws:is_ws(Flow) of
            true -> {ws, Flow};
            false -> native
        end,
    case
        chappe_sip_engine_backend:leg_create(
            Mod, Engine, Where, CallId, LocalAddr, RemoteAddr
        )
    of
        {ok, LegH} ->
            case start_dialog(DialogArgs#{leg => LegH}, LegH, S) of
                {ok, Pid} ->
                    %% the dialog a UAC forms sends from the UAC's address
                    {reply, {ok, Pid, LegH}, S#state{
                        handles = HM#{LegH => Pid},
                        dialogs = (S#state.dialogs)#{Pid => true},
                        locals = chappe_sip_binds:inherit(
                            Caller, Pid, S#state.locals
                        )
                    }};
                Err ->
                    {reply, Err, S}
            end;
        Err ->
            {reply, Err, S}
    end.

%% Start a dialog fsm on LegH, monitored; the leg goes if it cannot start.
start_dialog(Args, LegH, #state{mod = Mod, engine = Engine}) ->
    case chappe_sip_dialog_sup:start_dialog(Args) of
        {ok, Pid} ->
            _ = erlang:monitor(process, Pid),
            {ok, Pid};
        {error, _} = Err ->
            _ = chappe_sip_engine_backend:leg_destroy(Mod, Engine, LegH),
            Err
    end.

%% Enforce the advertised dialog ceiling (max_dialogs) at creation time.
at_dialog_cap(#state{dialogs = D}) ->
    map_size(D) >= chappe_sip_config:get(max_dialogs).

%% A worker or a handle owner went down.
-spec down(reference(), pid(), term(), #state{}) -> #state{}.
down(MRef, Pid, Reason, #state{workers = W, handles = HM} = S) ->
    case maps:take(Pid, W) of
        {{MRef, TxnH, FinalRef, DTRef}, W1} ->
            cancel_deadline(DTRef),
            ok = maybe_500(Reason, TxnH, FinalRef, S),
            %% a proxy worker also registered client-branch handles; destroy
            %% their C-side transactions and drop every handle it owned
            destroy_owned_handles(Pid, S),
            forget_txns(Pid, S#state{
                workers = W1,
                handles = drop_pid(Pid, HM),
                locals = maps:remove(Pid, S#state.locals)
            });
        error ->
            %% a dialog fsm / UAC fsm / other handle owner exited (possibly a
            %% crash, so terminate did not run): destroy its C-side legs/txns
            %% and drop its handle routes
            destroy_owned_handles(Pid, S),
            forget_txns(Pid, S#state{
                handles = drop_pid(Pid, HM),
                dialogs = maps:remove(Pid, S#state.dialogs),
                monitored = maps:remove(Pid, S#state.monitored),
                early_uas = drop_pid(Pid, S#state.early_uas),
                locals = maps:remove(Pid, S#state.locals)
            })
    end.

%% A worker gone without a final response gets a 500, whatever the exit
%% reason: exiting normal without answering is a handler bug too.
maybe_500(_Reason, TxnH, FinalRef, #state{mod = Mod, engine = Engine}) ->
    case atomics:get(FinalRef, 1) of
        0 ->
            chappe_sip_engine_backend:respond_txn(
                Mod, Engine, TxnH, 500, <<"Server Internal Error">>, <<>>
            );
        _ ->
            ok
    end.

%% a worker (or proxy owner) is gone: drop its merge and proxied entries
forget_txns(Pid, #state{merge = Idx, proxied = Px} = S) ->
    S#state{
        merge = maps:filter(fun(_K, {_, _, P}) -> P =/= Pid end, Idx),
        proxied = maps:filter(fun(_T, P) -> P =/= Pid end, Px)
    }.

drop_pid(Pid, HM) ->
    maps:filter(fun(_H, P) -> P =/= Pid end, HM).

%% Destroy the C-side objects of every handle a dead owner held (terminate /
%% destroy_leg did not run on a crash/kill).
destroy_owned_handles(Pid, #state{mod = Mod, engine = Engine, handles = HM}) ->
    _ = [
        chappe_sip_engine_backend:destroy_handle(Mod, Engine, H)
     || {H, P} <- maps:to_list(HM), P =:= Pid
    ],
    ok.

%% A worker that has become a call owner (created a dialog) or a proxy/UAC
%% originator is legitimately long-lived; disarm its handler deadline so it is
%% not killed mid-call. The monitor stays, so crash cleanup is unaffected.
-spec disarm_deadline(pid(), #state{}) -> #state{}.
disarm_deadline(Pid, #state{workers = W} = S) ->
    case W of
        #{Pid := {MRef, TxnH, FinalRef, DTRef}} when DTRef =/= undefined ->
            _ = erlang:cancel_timer(DTRef),
            S#state{workers = W#{Pid => {MRef, TxnH, FinalRef, undefined}}};
        _ ->
            S
    end.

%% A disarmed worker's deadline ref is undefined; cancel only a real ref.
-spec cancel_deadline(reference() | undefined) -> ok.
cancel_deadline(undefined) ->
    ok;
cancel_deadline(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

%% Monitor a handle-owner pid we do not already track (a UAC fsm), so its crash
%% reaches the DOWN handler and its handles/C-objects are cleaned up. Workers
%% and dialog fsms are already monitored elsewhere.
-spec ensure_monitored(pid(), #state{}) -> #state{}.
ensure_monitored(Pid, #state{monitored = M, workers = W, dialogs = D} = S) ->
    case
        maps:is_key(Pid, M) orelse maps:is_key(Pid, W) orelse
            maps:is_key(Pid, D)
    of
        true -> S;
        false -> S#state{monitored = M#{Pid => erlang:monitor(process, Pid)}}
    end.
