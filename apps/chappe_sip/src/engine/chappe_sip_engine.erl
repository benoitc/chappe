%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Singleton owner of the NIF engine and inbound dispatcher.
%%
%% This process is the stable pid the C side monitors. It brings the SIP
%% stack up and down (serialized through the C-side atomic guard), routes
%% inbound requests to per-request workers, enforces the worker cap and
%% handler deadline, and runs the health check with the hang policy: a
%% hung sofia thread cannot trip heart on its own, so after
%% health_miss_limit misses this process attempts a bounded stop and then
%% applies engine_failure_action (halt by default).
%%
%% Routing is entirely Erlang-side: the C engine forwards every request,
%% so nothing needs replaying into C across engine restarts. The start opts,
%% routes and middleware are snapshotted into an ETS table owned by
%% chappe_sip_registry_keeper, so if this process crashes the restarted one
%% re-establishes the native stack and its handlers instead of leaving SIP
%% down.
%%
%% The engine backend is pluggable (engine_mod: chappe_sip_nif in production,
%% chappe_sip_engine_fake in tests).
-module(chappe_sip_engine).
-behaviour(gen_server).

%% guard-legal test for a WS-transport handle (mirrors chappe_sip_ws:base/0)
-define(IS_WS(H), (is_integer(H) andalso (H) >= 16#4000000000000000)).

%% Engine config snapshot (start opts + routes + middleware), persisted in an
%% ETS table owned by chappe_sip_registry_keeper so a restarted engine process can
%% re-establish the native stack instead of leaving SIP down (F6).
-define(CFG_TAB, chappe_sip_engine_cfg).

-export([start_link/0]).
-export([
    start/1,
    stop/0,
    restart_engine/0,
    use/2,
    handle/3,
    unhandle/1,
    reset_routes/0,
    respond/3,
    check_health/1
]).
%% dialog/uac support
-export([
    create_uas/2,
    create_dialog/1,
    reg_handle/2,
    unreg_handle/1,
    dialog_respond/6,
    send_request/3,
    send_stateless/3,
    relay_response/3,
    forward_response/1,
    cancel_txn/1,
    finish_txn/1,
    destroy_leg/1,
    contact/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

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
    health_waiters = [] :: [gen_server:from()]
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Bring the SIP stack up. Opts: #{contact := binary(), ...}
-spec start(map()) -> ok | {error, already_started | term()}.
start(Opts) when is_map(Opts) ->
    gen_server:call(?MODULE, {start, Opts}, 30000).

-spec stop() -> ok | {error, not_started | hung}.
stop() ->
    gen_server:call(?MODULE, stop, 15000).

%% Controlled restart of the SIP engine: tear down live dialogs (owners
%% get {destroy, engine_restart}), stop and restart the NIF engine with
%% the same options, and keep routes/middleware. All SIP state is lost.
-spec restart_engine() -> ok | {error, term()}.
restart_engine() ->
    gen_server:call(?MODULE, restart_engine, 30000).

%% Register middleware: fun(Req, Res, Next), optionally method-scoped.
-spec use(binary() | '*', chappe_sip_middleware:mw()) -> ok.
use(Method, Fun) when is_function(Fun, 3) ->
    gen_server:call(?MODULE, {use, Method, Fun}).

%% Register the handler for a SIP method: fun(Req, Res).
-spec handle(binary(), fun(), map()) -> ok.
handle(Method, Fun, Opts) when is_binary(Method), is_function(Fun, 2) ->
    gen_server:call(?MODULE, {handle, Method, Fun, Opts}).

%% Unregister a method handler.
-spec unhandle(binary()) -> ok.
unhandle(Method) ->
    gen_server:call(?MODULE, {unhandle, Method}).

%% Drop all routes and middleware (tests, reconfiguration).
-spec reset_routes() -> ok.
reset_routes() ->
    gen_server:call(?MODULE, reset_routes).

%% Manual response path (tests, diagnostics).
-spec respond(non_neg_integer(), 100..699, binary()) -> ok | {error, term()}.
respond(TxnH, Status, Reason) ->
    gen_server:call(?MODULE, {respond, TxnH, Status, Reason}).

%% Create a UAS dialog for an incoming dialog-forming request. Called by
%% chappe_sip_dialog from the request worker. Returns the started dialog fsm.
-spec create_uas(chappe_sip_req:req(), map()) ->
    {ok, pid()} | {error, term()}.
create_uas(Req, Opts) ->
    gen_server:call(?MODULE, {create_uas, Req, Opts}).

%% Route engine handle events (op_ok/op_failed/response/ack/in-dialog
%% request/cancel for this handle) to Pid.
-spec reg_handle(non_neg_integer(), pid()) -> ok.
reg_handle(H, Pid) ->
    gen_server:call(?MODULE, {reg_handle, H, Pid}).

-spec unreg_handle(non_neg_integer()) -> ok.
unreg_handle(H) ->
    gen_server:call(?MODULE, {unreg_handle, H}).

%% Reply to a server transaction with a dialog tag (dialog fsm path).
-spec dialog_respond(
    non_neg_integer(),
    100..699,
    binary(),
    binary(),
    binary(),
    binary()
) -> ok | {error, term()}.
dialog_respond(TxnH, Status, Reason, Headers, Body, ToTag) ->
    gen_server:call(
        ?MODULE,
        {dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag}
    ).

%% Send a complete request; responses/op results route to Pid.
-spec send_request(binary() | undefined, binary(), pid()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Route, Raw, Pid) ->
    gen_server:call(?MODULE, {send_request, Route, Raw, Pid}).

%% Proxy: relay a downstream response upstream on a server transaction.
-spec relay_response(non_neg_integer(), 100..699, binary()) ->
    ok | {error, term()}.
relay_response(ServerTxnH, Status, Raw) ->
    gen_server:call(?MODULE, {relay_response, ServerTxnH, Status, Raw}).

%% Proxy: statelessly forward a response upstream with no server
%% transaction (a forked second 2xx). Raw must keep the proxy's own top
%% Via; the engine strips it and routes by the next Via.
-spec forward_response(binary()) -> ok | {error, term()}.
forward_response(Raw) ->
    gen_server:call(?MODULE, {forward_response, Raw}).

%% Create a dialog on the UAC side (leg + established fsm). DialogArgs is
%% the chappe_sip_dialog_fsm arg map without the leg. Returns {ok, Pid, LegH}.
-spec create_dialog(map()) -> {ok, pid(), non_neg_integer()} | {error, term()}.
create_dialog(DialogArgs) ->
    gen_server:call(?MODULE, {create_dialog, DialogArgs}).

%% Fire-and-forget send (ACK to a 2xx); op result routes to Pid.
-spec send_stateless(
    binary() | {ws, integer()} | undefined,
    binary(),
    pid()
) ->
    {ok, non_neg_integer() | ws_ack} | {error, term()}.
send_stateless(Route, Raw, Pid) ->
    gen_server:call(?MODULE, {send_stateless, Route, Raw, Pid}).

%% CANCEL an outstanding INVITE client transaction.
-spec cancel_txn(non_neg_integer()) -> ok | {error, term()}.
cancel_txn(TxnH) ->
    gen_server:call(?MODULE, {cancel_txn, TxnH}).

%% Release a client transaction handle and stop routing for it.
-spec finish_txn(non_neg_integer()) -> ok.
finish_txn(TxnH) ->
    gen_server:cast(?MODULE, {finish_txn, TxnH}).

%% The engine's bound contact URI (for building From/Contact on UAC).
-spec contact() -> binary() | undefined.
contact() ->
    gen_server:call(?MODULE, contact).

%% Destroy a dialog leg (from the fsm's terminate).
-spec destroy_leg(non_neg_integer()) -> ok.
destroy_leg(LegH) ->
    gen_server:cast(?MODULE, {destroy_leg, LegH}).

%% Force one health round-trip through the stack thread event loop.
-spec check_health(timeout()) -> ok | {error, timeout | not_started}.
check_health(Timeout) ->
    try
        gen_server:call(?MODULE, check_health, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout}
    end.

%% gen_server

init([]) ->
    process_flag(trap_exit, true),
    %% restore routes/middleware persisted before a crash so the re-established
    %% engine keeps its handlers (routing is entirely Erlang-side)
    S = #state{
        mod = chappe_sip_config:get(engine_mod),
        routes = cfg_get(routes, #{}),
        middlewares = cfg_get(middlewares, [])
    },
    case cfg_get(opts, undefined) of
        undefined ->
            %% first boot (or after a clean stop): wait for chappe_sip:start
            {ok, S};
        Opts ->
            %% a prior start persisted opts and no clean stop cleared them, so
            %% this is a crash-restart: re-establish the native stack async
            self() ! reestablish,
            {ok, S#state{engine_opts = Opts}}
    end.

handle_call({start, _}, _From, #state{engine = E} = S) when E =/= undefined ->
    {reply, {error, already_started}, S};
handle_call({start, Opts}, _From, #state{mod = Mod} = S) ->
    case validate_tls(maps:get(tls, Opts, undefined)) of
        ok ->
            NOpts = normalize_contact(Opts),
            case
                start_engine(
                    Mod,
                    NOpts,
                    chappe_sip_config:get(engine_start_retries),
                    100
                )
            of
                {ok, Engine} ->
                    cfg_put(opts, NOpts),
                    {reply, ok, S#state{
                        engine = Engine,
                        engine_opts = NOpts,
                        tref = schedule_health(Engine),
                        misses = 0
                    }};
                {error, Reason} ->
                    {reply, {error, Reason}, S}
            end;
        {error, _} = Err ->
            {reply, Err, S}
    end;
handle_call(restart_engine, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    restart_engine,
    _From,
    #state{
        mod = Mod,
        engine = Engine,
        engine_opts = Opts,
        dialogs = Dialogs,
        monitored = Monitored
    } = S
) ->
    %% tell dialogs and UAC fsms their SIP state is going away, so an in-flight
    %% transaction fails cleanly instead of waiting for a reply that the new
    %% native stack will never deliver
    maps:foreach(
        fun(Pid, _) -> Pid ! {chappe_sip_engine_restart, undefined} end,
        Dialogs
    ),
    maps:foreach(
        fun(Pid, _) -> Pid ! {chappe_sip_engine_restart, undefined} end,
        Monitored
    ),
    _ = Mod:stop(Engine),
    S1 = stack_down(S),
    case
        start_engine(
            Mod, Opts, chappe_sip_config:get(engine_start_retries), 100
        )
    of
        {ok, NewEngine} ->
            {reply, ok, S1#state{
                engine = NewEngine,
                tref = schedule_health(NewEngine)
            }};
        {error, Reason} ->
            {reply, {error, Reason}, S1}
    end;
handle_call(stop, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(stop, _From, #state{mod = Mod, engine = Engine} = S) ->
    Result = Mod:stop(Engine),
    %% a clean stop must not auto-reestablish on a later process crash
    cfg_del(opts),
    {reply, Result, stack_down(S)};
handle_call({use, Method, Fun}, _From, #state{middlewares = MW} = S) ->
    MW1 = MW ++ [{Method, Fun}],
    cfg_put(middlewares, MW1),
    {reply, ok, S#state{middlewares = MW1}};
handle_call({handle, Method, Fun, _Opts}, _From, #state{routes = R} = S) ->
    R1 = R#{Method => Fun},
    cfg_put(routes, R1),
    {reply, ok, S#state{routes = R1}};
handle_call({unhandle, Method}, _From, #state{routes = R} = S) ->
    R1 = maps:remove(Method, R),
    cfg_put(routes, R1),
    {reply, ok, S#state{routes = R1}};
handle_call(reset_routes, _From, S) ->
    cfg_put(routes, #{}),
    cfg_put(middlewares, []),
    {reply, ok, S#state{routes = #{}, middlewares = []}};
handle_call({respond, _, _, _}, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    {respond, TxnH, Status, Reason},
    _From,
    #state{mod = Mod, engine = Engine} = S
) ->
    {reply, Mod:respond(Engine, TxnH, Status, Reason, <<>>, <<>>, <<>>), S};
handle_call({create_uas, Req, Opts}, {WorkerPid, _}, S) ->
    do_create_uas(Req, Opts, WorkerPid, S);
handle_call({create_dialog, DialogArgs}, _From, S) ->
    %% WS-only nodes have engine = undefined; a WS-flow dialog still creates
    %% its leg on the transport. dialog_leg_create/5 returns not_started for
    %% a non-WS dialog with no native engine.
    do_create_dialog(DialogArgs, S);
handle_call({send_stateless, {ws, Flow}, Raw, _Pid}, _From, S) ->
    _ = chappe_sip_ws_transport:send_stateless(Flow, Raw),
    {reply, {ok, ws_ack}, S};
handle_call({send_stateless, _, _, _}, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    {send_stateless, Route, Raw, _Pid},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when
    Engine =/= undefined
->
    %% fire-and-forget (a 2xx ACK / stateless BYE): no response is expected, so
    %% do not retain a handle route (it would linger until the owner exits)
    {reply, Mod:send(Engine, Route, Raw), S};
handle_call({cancel_txn, TxnH}, _From, S) when ?IS_WS(TxnH) ->
    _ = chappe_sip_ws_transport:cancel(TxnH),
    {reply, ok, S};
handle_call(
    {cancel_txn, TxnH},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when Engine =/= undefined ->
    {reply, Mod:cancel(Engine, TxnH), S};
handle_call(
    {relay_response, ServerTxnH, Status, Raw},
    _From,
    #state{handles = HM} = S
) when ?IS_WS(ServerTxnH) ->
    R = ws_call(fun() ->
        chappe_sip_ws_transport:relay(ServerTxnH, Status, Raw)
    end),
    HM1 =
        case Status >= 200 of
            true -> maps:remove(ServerTxnH, HM);
            false -> HM
        end,
    {reply, R, S#state{handles = HM1}};
handle_call(
    {relay_response, ServerTxnH, Status, Raw},
    _From,
    #state{mod = Mod, engine = Engine, handles = HM} = S
) when
    Engine =/= undefined
->
    R = Mod:relay(Engine, ServerTxnH, Status, Raw),
    HM1 =
        case Status >= 200 of
            true -> maps:remove(ServerTxnH, HM);
            false -> HM
        end,
    {reply, R, S#state{handles = HM1}};
handle_call({forward_response, _}, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    {forward_response, Raw},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when Engine =/= undefined ->
    {reply, Mod:send_response(Engine, Raw), S};
handle_call(contact, _From, #state{contact = C} = S) ->
    {reply, C, S};
handle_call({reg_handle, H, Pid}, _From, S) ->
    S1 = ensure_monitored(Pid, S),
    {reply, ok, S1#state{handles = (S1#state.handles)#{H => Pid}}};
handle_call({unreg_handle, H}, _From, #state{handles = HM} = S) ->
    {reply, ok, S#state{handles = maps:remove(H, HM)}};
handle_call(
    {dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag},
    _From,
    S
) when ?IS_WS(TxnH) ->
    {reply,
        ws_call(fun() ->
            chappe_sip_ws_transport:respond(
                TxnH, Status, Reason, Headers, Body, ToTag
            )
        end), S};
handle_call(
    {dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when
    Engine =/= undefined
->
    {reply, Mod:respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag), S};
handle_call({send_request, {ws, Flow}, Raw, Pid}, _From, S) ->
    case
        ws_call(fun() ->
            chappe_sip_ws_transport:send_request(Flow, Raw, Pid)
        end)
    of
        {ok, TxnH} ->
            %% a worker that originates a request (proxy fork / UAC) is a
            %% long-lived owner; disarm its deadline and monitor a UAC fsm so
            %% its crash sweeps this handle
            S1 = ensure_monitored(Pid, disarm_deadline(Pid, S)),
            {reply, {ok, TxnH}, S1#state{
                handles = (S1#state.handles)#{TxnH => Pid}
            }};
        Err ->
            {reply, Err, S}
    end;
handle_call({send_request, _, _, _}, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    {send_request, Route, Raw, Pid},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when
    Engine =/= undefined
->
    case Mod:request(Engine, Route, Raw) of
        {ok, TxnH} ->
            S1 = ensure_monitored(Pid, disarm_deadline(Pid, S)),
            {reply, {ok, TxnH}, S1#state{
                handles = (S1#state.handles)#{TxnH => Pid}
            }};
        Err ->
            {reply, Err, S}
    end;
handle_call(check_health, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    check_health,
    From,
    #state{mod = Mod, engine = Engine, health_waiters = W} = S
) ->
    ok = Mod:health(Engine),
    {noreply, S#state{health_waiters = [From | W]}}.

handle_cast({destroy_leg, LegH}, #state{handles = HM} = S) when
    ?IS_WS(LegH)
->
    _ = chappe_sip_ws_transport:leg_destroy(LegH),
    {noreply, S#state{handles = maps:remove(LegH, HM)}};
handle_cast(
    {destroy_leg, LegH},
    #state{
        mod = Mod,
        engine = Engine,
        handles = HM
    } = S
) when
    Engine =/= undefined
->
    _ = Mod:leg_destroy(Engine, LegH),
    {noreply, S#state{handles = maps:remove(LegH, HM)}};
handle_cast({finish_txn, TxnH}, #state{handles = HM} = S) when
    ?IS_WS(TxnH)
->
    _ = chappe_sip_ws_transport:finish_txn(TxnH),
    {noreply, S#state{handles = maps:remove(TxnH, HM)}};
handle_cast(
    {finish_txn, TxnH},
    #state{
        mod = Mod,
        engine = Engine,
        handles = HM
    } = S
) when
    Engine =/= undefined
->
    _ = Mod:txn_done(Engine, TxnH),
    {noreply, S#state{handles = maps:remove(TxnH, HM)}};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(
    reestablish,
    #state{
        engine = undefined,
        mod = Mod,
        engine_opts = Opts
    } = S
) when
    map_size(Opts) > 0
->
    %% crash-restart recovery: bring the native stack back from persisted opts
    case
        start_engine(
            Mod, Opts, chappe_sip_config:get(engine_start_retries), 100
        )
    of
        {ok, Engine} ->
            logger:info(
                "chappe_sip_engine: re-established the SIP stack after a "
                "restart"
            ),
            {noreply, S#state{
                engine = Engine,
                tref = schedule_health(Engine),
                misses = 0
            }};
        {error, Reason} ->
            logger:error(
                "chappe_sip_engine: re-establish failed (~p); retrying",
                [Reason]
            ),
            _ = erlang:send_after(1000, self(), reestablish),
            {noreply, S}
    end;
handle_info(reestablish, S) ->
    {noreply, S};
handle_info({chappe_sip_engine, ws, Event}, S) ->
    %% events from the WS transport share the engine dispatch/handle_event
    {noreply, handle_event(Event, S)};
handle_info({chappe_sip_engine, Engine, Event}, #state{engine = Engine} = S) ->
    {noreply, handle_event(Event, S)};
handle_info({chappe_sip_engine, _Stale, _Event}, S) ->
    %% event from a previous engine instance racing its teardown; drop
    {noreply, S};
handle_info(
    {health_tick, Engine},
    #state{engine = Engine, mod = Mod, misses = M} = S
) ->
    case M >= chappe_sip_config:get(health_miss_limit) of
        true ->
            engine_failed(S);
        false ->
            ok = Mod:health(Engine),
            {noreply, S#state{misses = M + 1, tref = schedule_health(Engine)}}
    end;
handle_info({health_tick, _Stale}, S) ->
    {noreply, S};
handle_info({worker_deadline, Pid}, #state{workers = W} = S) ->
    case W of
        #{Pid := {_, TxnH, _, DTRef}} when DTRef =/= undefined ->
            logger:warning("chappe_sip: handler deadline expired for txn ~p", [
                TxnH
            ]),
            exit(Pid, kill),
            %% the DOWN handler answers 500 if nothing final went out
            {noreply, S};
        _ ->
            %% disarmed (became a call owner / proxy) or already gone
            {noreply, S}
    end;
handle_info(
    {'DOWN', MRef, process, Pid, Reason},
    #state{workers = W, handles = HM} = S
) ->
    case maps:take(Pid, W) of
        {{MRef, TxnH, FinalRef, DTRef}, W1} ->
            cancel_deadline(DTRef),
            ok = maybe_500(Reason, TxnH, FinalRef, S),
            %% a proxy worker also registered client-branch handles; destroy
            %% their C-side transactions and drop every handle it owned
            destroy_owned_handles(Pid, S),
            {noreply, S#state{workers = W1, handles = drop_pid(Pid, HM)}};
        error ->
            %% a dialog fsm / UAC fsm / other handle owner exited (possibly a
            %% crash, so terminate did not run): destroy its C-side legs/txns
            %% and drop its handle routes
            destroy_owned_handles(Pid, S),
            {noreply, S#state{
                handles = drop_pid(Pid, HM),
                dialogs = maps:remove(Pid, S#state.dialogs),
                monitored = maps:remove(Pid, S#state.monitored)
            }}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #state{engine = undefined}) ->
    ok;
terminate(_Reason, #state{mod = Mod, engine = Engine}) ->
    _ = Mod:stop(Engine),
    ok.

%% internal: config snapshot (survives an engine-process crash in the keeper's
%% ETS table, so a restarted engine can re-establish itself)

cfg_put(Key, Val) ->
    case ets:info(?CFG_TAB) of
        undefined ->
            ok;
        _ ->
            ets:insert(?CFG_TAB, {Key, Val}),
            ok
    end.

cfg_get(Key, Default) ->
    case ets:info(?CFG_TAB) of
        undefined ->
            Default;
        _ ->
            case ets:lookup(?CFG_TAB, Key) of
                [{Key, V}] -> V;
                [] -> Default
            end
    end.

cfg_del(Key) ->
    case ets:info(?CFG_TAB) of
        undefined ->
            ok;
        _ ->
            ets:delete(?CFG_TAB, Key),
            ok
    end.

%% internal: engine lifecycle

start_engine(_Mod, _Opts, 0, _Backoff) ->
    {error, engine_stuck_stopping};
start_engine(Mod, Opts, Retries, Backoff) ->
    case Mod:start(Opts, self()) of
        {ok, Engine} ->
            {ok, Engine};
        {error, stopping} ->
            %% a previous instance is tearing down; starts are serialized
            %% through the C atomic guard
            timer:sleep(Backoff),
            start_engine(Mod, Opts, Retries - 1, min(Backoff * 2, 5000));
        {error, Reason} ->
            {error, Reason}
    end.

%% An unrestricted sofia bind (transport=*) also opens a ws listener on
%% the TCP port and collides with the tcp transport (freeswitch fork
%% behavior). Default to udp,tcp unless the caller chose transports.
normalize_contact(#{contact := C} = Opts) ->
    case binary:match(C, <<";transport=">>) of
        nomatch -> Opts#{contact := <<C/binary, ";transport=udp,tcp">>};
        _ -> Opts
    end;
normalize_contact(Opts) ->
    Opts.

%% Reject an unrecognised TLS verify value instead of silently treating it as
%% "no verification" (which would weaken security without any signal).
validate_tls(undefined) ->
    ok;
validate_tls(Tls) when is_map(Tls) ->
    case maps:get(verify, Tls, none) of
        none -> ok;
        peer -> ok;
        Other -> {error, {tls, {bad_verify, Other}}}
    end;
validate_tls(_) ->
    {error, {tls, bad_options}}.

engine_failed(#state{mod = Mod, engine = Engine} = S) ->
    logger:critical(
        "chappe_sip_engine: stack thread unresponsive, applying failure action"
    ),
    _ = Mod:stop(Engine),
    case chappe_sip_config:get(engine_failure_action) of
        halt ->
            logger_std_h:filesync(default),
            erlang:halt(1);
        degrade ->
            logger:critical("chappe_sip_engine: degraded, SIP stack is down"),
            {noreply, stack_down(S)}
    end.

stack_down(#state{tref = TRef, workers = W} = S) ->
    _ =
        case TRef of
            undefined -> ok;
            _ -> erlang:cancel_timer(TRef)
        end,
    %% engine state is gone; kill in-flight workers, nothing to answer
    maps:foreach(
        fun(Pid, {MRef, _, _, DTRef}) ->
            erlang:demonitor(MRef, [flush]),
            cancel_deadline(DTRef),
            exit(Pid, kill)
        end,
        W
    ),
    %% stop monitoring UAC-fsm handle owners (their handles are gone now)
    maps:foreach(
        fun(_Pid, MRef) -> erlang:demonitor(MRef, [flush]) end,
        S#state.monitored
    ),
    [
        gen_server:reply(From, {error, not_started})
     || From <- S#state.health_waiters
    ],
    S#state{
        engine = undefined,
        tref = undefined,
        misses = 0,
        workers = #{},
        handles = #{},
        dialogs = #{},
        monitored = #{},
        health_waiters = []
    }.

schedule_health(Engine) ->
    erlang:send_after(
        chappe_sip_config:get(health_interval_ms),
        self(),
        {health_tick, Engine}
    ).

%% internal: events

handle_event({health_ok, _Seq}, #state{health_waiters = W} = S) ->
    [gen_server:reply(From, ok) || From <- W],
    S#state{misses = 0, health_waiters = []};
handle_event({log, Level, Text}, S) ->
    logger:log(log_level(Level), "chappe_sip_engine: ~s", [Text]),
    S;
handle_event({started, Contact}, S) ->
    logger:info("chappe_sip_engine: SIP stack up at ~s", [Contact]),
    S#state{contact = Contact};
handle_event({request, TxnH, undefined, Meta, Raw}, S) ->
    %% out-of-dialog request
    dispatch(TxnH, Meta, Raw, S);
handle_event({request, TxnH, LegH, Meta, Raw}, #state{handles = HM} = S) ->
    %% in-dialog request: route to the owning dialog fsm
    case HM of
        #{LegH := Pid} ->
            Pid ! {chappe_sip_indialog, LegH, TxnH, Meta, Raw},
            S;
        _ ->
            %% in-dialog request for a dialog we no longer have: RFC 3261
            %% 12.2.2 answers 481 rather than letting it time out (an ACK has
            %% no response, so drop that one)
            case maps:get(method, Meta, undefined) of
                <<"ACK">> ->
                    ok;
                _ ->
                    _ = respond_txn(
                        TxnH,
                        481,
                        <<"Call/Transaction Does Not Exist">>,
                        S
                    )
            end,
            S
    end;
handle_event({ack, LegH, Raw}, #state{handles = HM, contact = Contact} = S) ->
    case HM of
        #{LegH := Pid} ->
            Pid ! {chappe_sip_ack, LegH, Raw};
        _ ->
            %% no dialog leg: a 2xx ACK routed through us as a record-routing
            %% proxy is forwarded to the next hop; anything else is stray.
            %% A WS-range LegH means the ACK arrived over that WS flow.
            case is_own_route(Raw, Contact) of
                true ->
                    Arrived =
                        case ?IS_WS(LegH) of
                            true -> {ws, LegH};
                            false -> udp
                        end,
                    _ = spawn(fun() ->
                        try
                            chappe_sip_proxy:forward_indialog_ack(
                                Raw,
                                Arrived
                            )
                        catch
                            C:R:St ->
                                logger:warning(
                                    "chappe_sip: proxy 2xx-ACK forward "
                                    "failed: ~p:~p~n~p",
                                    [C, R, St]
                                )
                        end
                    end);
                false ->
                    ok
            end
    end,
    S;
handle_event({cancel, TxnH}, #state{handles = HM} = S) ->
    case HM of
        #{TxnH := Pid} -> Pid ! {chappe_sip_cancel, TxnH};
        _ -> ok
    end,
    S;
handle_event({prack, TxnH, Raw}, #state{handles = HM} = S) ->
    %% PRACK for a reliable provisional: route to the INVITE's owner
    case HM of
        #{TxnH := Pid} -> Pid ! {chappe_sip_prack, TxnH, Raw};
        _ -> ok
    end,
    S;
handle_event({response, TxnH, Meta, Raw}, #state{handles = HM} = S) ->
    case HM of
        #{TxnH := Pid} -> Pid ! {chappe_sip_response, TxnH, Meta, Raw};
        _ -> ok
    end,
    S;
handle_event({op_ok, H}, #state{handles = HM} = S) ->
    case HM of
        #{H := Pid} -> Pid ! {chappe_sip_op, H, ok};
        _ -> ok
    end,
    S;
handle_event({op_failed, H, Reason}, #state{handles = HM} = S) ->
    case HM of
        #{H := Pid} -> Pid ! {chappe_sip_op, H, {error, Reason}};
        _ -> ok
    end,
    S;
handle_event(Event, S) ->
    logger:debug("chappe_sip_engine: unhandled event ~p", [Event]),
    S.

%% Build a UAS dialog: allocate the leg, register it, start the fsm, and
%% send the dialog-forming response with the local tag. op_ok/op_failed
%% for the leg routes to the fsm, which confirms or fails setup.
do_create_uas(Req, Opts, WorkerPid, S) ->
    case at_dialog_cap(S) of
        true -> {reply, {error, max_dialogs}, S};
        false -> do_create_uas_1(Req, Opts, WorkerPid, S)
    end.

do_create_uas_1(Req, Opts, WorkerPid, S) ->
    Msg = chappe_sip_req:msg(Req),
    CallId = chappe_sip_msg:call_id(Msg),
    ToVal = chappe_sip_msg:get(<<"to">>, Msg),
    FromVal = chappe_sip_msg:get(<<"from">>, Msg),
    %% honor a caller-chosen tag (b2bua pre-tags relayed provisionals with
    %% the same value so the early dialog and the 2xx share one To-tag)
    LocalTag = maps:get(local_tag, Opts, chappe_sip_dialog:gen_tag()),
    LocalAddr = <<ToVal/binary, ";tag=", LocalTag/binary>>,
    TxnH = chappe_sip_req:txn(Req),
    RTarget = contact_uri(chappe_sip_msg:get(<<"contact">>, Msg), FromVal),
    case leg_create(TxnH, Req, CallId, LocalAddr, FromVal, S) of
        {ok, LegH} ->
            Owner = maps:get(owner, Opts, WorkerPid),
            FsmArgs = #{
                leg => LegH,
                txn => TxnH,
                opts => Opts,
                owner => Owner,
                local_tag => LocalTag,
                remote_addr => FromVal,
                local_addr => LocalAddr,
                remote_target => RTarget,
                %% RFC 3261 12.1.1: route set = request Record-Route,
                %% in order, so in-dialog requests traverse the proxies
                route_set => chappe_sip_msg:get_all(<<"record-route">>, Msg),
                remote_sdp => chappe_sip_req:body(Req),
                %% a WS-originated request carries its flow so the
                %% dialog can send in-dialog requests back over it
                flow => maps:get(flow, chappe_sip_req:meta(Req), undefined),
                call_id => CallId
            },
            case chappe_sip_dialog_sup:start_dialog(FsmArgs) of
                {ok, Pid} ->
                    _ = erlang:monitor(process, Pid),
                    %% send the dialog-forming response here (not from the
                    %% fsm init: that would re-enter this gen_server and
                    %% deadlock). op_ok/op_failed for the leg routes to Pid.
                    _ = send_uas_response(TxnH, LocalTag, Opts, S),
                    %% the owner now blocks for the call's lifetime; disarm its
                    %% handler deadline so it is not killed mid-call
                    S1 = disarm_deadline(Owner, S),
                    {reply, {ok, Pid}, S1#state{
                        handles = (S1#state.handles)#{LegH => Pid},
                        dialogs = (S1#state.dialogs)#{Pid => true}
                    }};
                {error, Reason} ->
                    _ = leg_destroy(TxnH, LegH, S),
                    {reply, {error, Reason}, S}
            end;
        Err ->
            {reply, Err, S}
    end.

%% create the dialog leg on the backend that owns the request's transaction
leg_create(TxnH, Req, CallId, LocalAddr, RemoteAddr, _S) when ?IS_WS(TxnH) ->
    Flow = maps:get(flow, chappe_sip_req:meta(Req), undefined),
    ws_call(fun() ->
        chappe_sip_ws_transport:leg_create(CallId, LocalAddr, RemoteAddr, Flow)
    end);
leg_create(
    _TxnH,
    _Req,
    CallId,
    LocalAddr,
    RemoteAddr,
    #state{mod = Mod, engine = Engine}
) when Engine =/= undefined ->
    Mod:leg_create(Engine, CallId, LocalAddr, RemoteAddr);
leg_create(_TxnH, _Req, _CallId, _LocalAddr, _RemoteAddr, _S) ->
    {error, not_started}.

leg_destroy(TxnH, LegH, _S) when ?IS_WS(TxnH) ->
    chappe_sip_ws_transport:leg_destroy(LegH);
leg_destroy(_TxnH, LegH, #state{mod = Mod, engine = Engine}) when
    Engine =/= undefined
->
    Mod:leg_destroy(Engine, LegH);
leg_destroy(_TxnH, _LegH, _S) ->
    ok.

send_uas_response(TxnH, LocalTag, Opts, S) ->
    Status = maps:get(status, Opts, 200),
    Reason = maps:get(reason, Opts, <<"OK">>),
    ExtraHeaders = with_contact(Status, maps:get(headers, Opts, []), S),
    {Headers, Body} =
        case maps:get(local_sdp, Opts, undefined) of
            undefined ->
                {chappe_sip_hdr_io:join(ExtraHeaders), <<>>};
            Sdp ->
                {
                    chappe_sip_hdr_io:join(
                        [
                            {<<"Content-Type">>, <<"application/sdp">>}
                            | ExtraHeaders
                        ]
                    ),
                    iolist_to_binary(Sdp)
                }
        end,
    case ?IS_WS(TxnH) of
        true ->
            ws_call(fun() ->
                chappe_sip_ws_transport:respond(
                    TxnH,
                    Status,
                    Reason,
                    Headers,
                    Body,
                    LocalTag
                )
            end);
        false ->
            (S#state.mod):respond(
                S#state.engine,
                TxnH,
                Status,
                Reason,
                Headers,
                Body,
                LocalTag
            )
    end.

%% A dialog-forming 2xx MUST carry a Contact (RFC 3261 12.1.1) so the peer
%% can build the dialog and target in-dialog requests. Add our own unless the
%% app already supplied one.
with_contact(Status, Headers, S) when Status >= 200, Status < 300 ->
    case has_hdr(<<"contact">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Contact">>, local_contact(S)}]
    end;
with_contact(_Status, Headers, _S) ->
    Headers.

has_hdr(Lname, Headers) ->
    lists:any(
        fun
            ({N, _}) -> string:lowercase(N) =:= Lname;
            (_) -> false
        end,
        Headers
    ).

%% The bound contact may arrive as a name-addr (<uri;params>); extract the
%% bare URI and drop params so the Contact is a single well-formed name-addr.
local_contact(#state{contact = C}) when is_binary(C) ->
    Uri =
        case chappe_sip_hdr:name_addr(C) of
            {ok, #{uri := U}} -> U;
            _ -> C
        end,
    Base =
        case binary:split(Uri, <<";">>) of
            [B | _] -> B;
            _ -> Uri
        end,
    <<"<", Base/binary, ">">>;
local_contact(_) ->
    <<"<sip:anonymous.invalid>">>.

%% peer Contact URI (in-dialog request target), else the remote addr URI
contact_uri(undefined, RemoteAddr) ->
    uri_of(RemoteAddr);
contact_uri(Contact, RemoteAddr) ->
    case chappe_sip_hdr:name_addr(Contact) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> uri_of(RemoteAddr)
    end.

uri_of(NameAddr) ->
    case chappe_sip_hdr:name_addr(NameAddr) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> NameAddr
    end.

%% Create a dialog (UAC path): allocate the leg and start the fsm already
%% established. Returns {ok, DialogPid, LegH}.
do_create_dialog(DialogArgs, S) ->
    case at_dialog_cap(S) of
        true -> {reply, {error, max_dialogs}, S};
        false -> do_create_dialog_1(DialogArgs, S)
    end.

do_create_dialog_1(DialogArgs, #state{handles = HM} = S) ->
    #{
        call_id := CallId,
        local_addr := LocalAddr,
        remote_addr := RemoteAddr
    } = DialogArgs,
    %% a WS dialog's leg must live in the WS transport so a peer-originated
    %% in-dialog request over the flow matches it (not the sofia leg index)
    Flow = maps:get(flow, DialogArgs, undefined),
    case dialog_leg_create(Flow, CallId, LocalAddr, RemoteAddr, S) of
        {ok, LegH} ->
            case chappe_sip_dialog_sup:start_dialog(DialogArgs#{leg => LegH}) of
                {ok, Pid} ->
                    _ = erlang:monitor(process, Pid),
                    {reply, {ok, Pid, LegH}, S#state{
                        handles = HM#{LegH => Pid},
                        dialogs = (S#state.dialogs)#{Pid => true}
                    }};
                {error, Reason} ->
                    _ = dialog_leg_destroy(LegH, S),
                    {reply, {error, Reason}, S}
            end;
        Err ->
            {reply, Err, S}
    end.

dialog_leg_create(Flow, CallId, LocalAddr, RemoteAddr, _S) when
    is_integer(Flow), ?IS_WS(Flow)
->
    chappe_sip_ws_transport:leg_create(CallId, LocalAddr, RemoteAddr, Flow);
dialog_leg_create(
    _Flow,
    CallId,
    LocalAddr,
    RemoteAddr,
    #state{mod = Mod, engine = Engine}
) when Engine =/= undefined ->
    Mod:leg_create(Engine, CallId, LocalAddr, RemoteAddr);
dialog_leg_create(_Flow, _CallId, _LocalAddr, _RemoteAddr, _S) ->
    {error, not_started}.

dialog_leg_destroy(LegH, _S) when ?IS_WS(LegH) ->
    chappe_sip_ws_transport:leg_destroy(LegH);
dialog_leg_destroy(LegH, #state{mod = Mod, engine = Engine}) when
    Engine =/= undefined
->
    _ = Mod:leg_destroy(Engine, LegH),
    ok;
dialog_leg_destroy(_LegH, _S) ->
    ok.

%% A request carrying our own Record-Route on top is in-dialog traffic for a
%% dialog we record-routed; forward it as a proxy instead of routing to a
%% local handler. Otherwise dispatch to the registered method handler.
dispatch(
    TxnH,
    Meta,
    Raw,
    #state{
        contact = Contact,
        mod = Mod,
        engine = Engine,
        workers = W
    } = S
) ->
    case is_own_route(Raw, Contact) of
        true ->
            case map_size(W) >= chappe_sip_config:get(max_request_workers) of
                true ->
                    shed(Mod, Engine, TxnH, 503, <<"Service Unavailable">>),
                    S;
                false ->
                    Handler = fun(Req, Res) ->
                        chappe_sip_proxy:forward_indialog(Req, Res)
                    end,
                    spawn_worker(TxnH, Meta, Raw, Handler, [], S)
            end;
        false ->
            dispatch_local(TxnH, Meta, Raw, S)
    end.

dispatch_local(
    TxnH,
    #{method := Method} = Meta,
    Raw,
    #state{
        mod = Mod,
        engine = Engine,
        routes = Routes,
        middlewares = MW,
        workers = W
    } = S
) ->
    case Routes of
        #{Method := Handler} ->
            case map_size(W) >= chappe_sip_config:get(max_request_workers) of
                true ->
                    shed(Mod, Engine, TxnH, 503, <<"Service Unavailable">>),
                    S;
                false ->
                    spawn_worker(TxnH, Meta, Raw, Handler, MW, S)
            end;
        _ when Method =:= <<"ACK">>; Method =:= <<"CANCEL">> ->
            %% ACK never needs an answer; CANCEL correlation lands in M3
            S;
        _ ->
            %% RFC 3261 21.4.5: a 405 MUST carry Allow. respond_txn handles a
            %% WS or native transaction (a bare shed would send a WS txn to nta)
            Allow = chappe_sip_hdr_io:join([{<<"Allow">>, allow_value(Routes)}]),
            respond_txn(TxnH, 405, <<"Method Not Allowed">>, Allow, S),
            S
    end.

%% the methods we have a handler for, for the Allow header
allow_value(Routes) ->
    iolist_to_binary(lists:join(<<", ">>, lists:sort(maps:keys(Routes)))).

%% True when the top Route header targets this proxy (a request the far end
%% loose-routed back to us after we record-routed the dialog). Gated on a
%% cheap byte scan so requests without a Route header skip the parse.
is_own_route(Raw, Contact) ->
    case binary:match(Raw, <<"\nRoute">>) of
        nomatch ->
            false;
        _ ->
            case chappe_sip_msg:parse(Raw) of
                {ok, Msg} ->
                    case chappe_sip_msg:get(<<"route">>, Msg) of
                        undefined ->
                            false;
                        RVal ->
                            chappe_sip_route:is_self(
                                RVal,
                                Contact,
                                chappe_sip_msg:call_id(Msg)
                            )
                    end;
                {error, _} ->
                    false
            end
    end.

%% A worker that has become a call owner (created a dialog) or a proxy/UAC
%% originator is legitimately long-lived; disarm its handler deadline so it is
%% not killed mid-call. The monitor stays, so crash cleanup is unaffected.
disarm_deadline(Pid, #state{workers = W} = S) ->
    case W of
        #{Pid := {MRef, TxnH, FinalRef, DTRef}} when DTRef =/= undefined ->
            _ = erlang:cancel_timer(DTRef),
            S#state{workers = W#{Pid => {MRef, TxnH, FinalRef, undefined}}};
        _ ->
            S
    end.

%% A disarmed worker's deadline ref is undefined; cancel only a real ref.
cancel_deadline(undefined) ->
    ok;
cancel_deadline(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

%% Enforce the advertised dialog ceiling (max_dialogs) at creation time.
at_dialog_cap(#state{dialogs = D}) ->
    map_size(D) >= chappe_sip_config:get(max_dialogs).

%% chappe_sip_ws_transport is a single gen_server. ws:send to a client is an async
%% cast, so it never blocks on a socket, but under an inbound-frame flood a
%% call to the transport could exceed the default 5s. Unhandled, that would
%% crash the engine and rest_for_one would take down ALL SIP (incl. UDP);
%% degrade to an error instead.
ws_call(Fun) ->
    try
        Fun()
    catch
        exit:{timeout, _} -> {error, ws_timeout};
        %% the transport is a permanent worker; if it is briefly down
        %% (restarting) a call to it exits noproc - do not crash the engine
        exit:{noproc, _} -> {error, ws_unavailable};
        exit:noproc -> {error, ws_unavailable}
    end.

spawn_worker(
    TxnH,
    Meta,
    Raw,
    Handler,
    MW,
    #state{
        mod = Mod,
        engine = Engine,
        workers = W,
        handles = HM
    } = S
) ->
    FinalRef = atomics:new(1, []),
    Sender = make_sender(Mod, Engine),
    Res = chappe_sip_res:new(TxnH, Sender, FinalRef),
    Args = #{
        raw => Raw,
        txn => TxnH,
        meta => Meta,
        res => Res,
        middlewares => MW,
        handler => Handler
    },
    case chappe_sip_request_sup:start_worker(Args) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            DTRef = erlang:send_after(
                chappe_sip_config:get(handler_deadline_ms),
                self(),
                {worker_deadline, Pid}
            ),
            %% route a later CANCEL for this server txn to the worker
            S#state{
                workers = W#{Pid => {MRef, TxnH, FinalRef, DTRef}},
                handles = HM#{TxnH => Pid}
            };
        {error, Reason} ->
            logger:error("chappe_sip: cannot start request worker: ~p", [Reason]),
            shed(Mod, Engine, TxnH, 500, <<"Server Internal Error">>),
            S
    end.

%% the sender fun runs in the worker process; the NIF respond call is
%% enqueue-only and safe from any process
make_sender(Mod, Engine) ->
    fun(TxnH, Status, Opts) ->
        Reason = maps:get(reason, Opts, <<>>),
        Headers = chappe_sip_hdr_io:join(maps:get(headers, Opts, [])),
        Body = iolist_to_binary(maps:get(body, Opts, <<>>)),
        ToTag = maps:get(to_tag, Opts, <<>>),
        case chappe_sip_ws:is_ws(TxnH) of
            true ->
                %% WS is reliable; a reliable 1xx is just a 1xx here
                ws_call(fun() ->
                    chappe_sip_ws_transport:respond(
                        TxnH,
                        Status,
                        Reason,
                        Headers,
                        Body,
                        ToTag
                    )
                end);
            false ->
                case
                    maps:get(reliable, Opts, false) andalso
                        Status > 100 andalso Status < 200
                of
                    true ->
                        Mod:reliable_respond(
                            Engine,
                            TxnH,
                            Status,
                            Reason,
                            Headers,
                            Body,
                            ToTag
                        );
                    false ->
                        Mod:respond(
                            Engine,
                            TxnH,
                            Status,
                            Reason,
                            Headers,
                            Body,
                            ToTag
                        )
                end
        end
    end.

shed(Mod, Engine, TxnH, Status, Reason) ->
    _ = Mod:respond(Engine, TxnH, Status, Reason, <<>>, <<>>, <<>>),
    ok.

%% Respond on a server transaction whether it lives in the WS transport or the
%% native backend. The /5 form carries a header blob (e.g. Allow on a 405).
respond_txn(TxnH, Status, Reason, S) ->
    respond_txn(TxnH, Status, Reason, <<>>, S).

respond_txn(TxnH, Status, Reason, Headers, _S) when ?IS_WS(TxnH) ->
    _ = chappe_sip_ws_transport:respond(
        TxnH, Status, Reason, Headers, <<>>, <<>>
    ),
    ok;
respond_txn(TxnH, Status, Reason, Headers, #state{mod = Mod, engine = Engine}) when
    Engine =/= undefined
->
    _ = Mod:respond(Engine, TxnH, Status, Reason, Headers, <<>>, <<>>),
    ok;
respond_txn(_TxnH, _Status, _Reason, _Headers, _S) ->
    ok.

%% A worker gone without a final response gets a 500, whatever the exit
%% reason: exiting normal without answering is a handler bug too.
maybe_500(
    _Reason,
    TxnH,
    FinalRef,
    #state{mod = Mod, engine = Engine}
) when Engine =/= undefined ->
    case atomics:get(FinalRef, 1) of
        0 -> shed(Mod, Engine, TxnH, 500, <<"Server Internal Error">>);
        _ -> ok
    end;
maybe_500(_, _, _, _) ->
    ok.

drop_pid(Pid, HM) ->
    maps:filter(fun(_H, P) -> P =/= Pid end, HM).

%% Monitor a handle-owner pid we do not already track (a UAC fsm), so its crash
%% reaches the DOWN handler and its handles/C-objects are cleaned up. Workers
%% and dialog fsms are already monitored elsewhere.
ensure_monitored(Pid, #state{monitored = M, workers = W, dialogs = D} = S) ->
    case
        maps:is_key(Pid, M) orelse maps:is_key(Pid, W) orelse
            maps:is_key(Pid, D)
    of
        true -> S;
        false -> S#state{monitored = M#{Pid => erlang:monitor(process, Pid)}}
    end.

%% Destroy the C-side objects of every handle a dead owner held (terminate /
%% destroy_leg did not run on a crash/kill). A handle is a leg or a
%% transaction; the wrong backend call is a no-op, so issue both.
destroy_owned_handles(Pid, #state{handles = HM} = S) ->
    _ = [destroy_handle(H, S) || {H, P} <- maps:to_list(HM), P =:= Pid],
    ok.

destroy_handle(H, _S) when ?IS_WS(H) ->
    _ = chappe_sip_ws_transport:finish_txn(H),
    _ = chappe_sip_ws_transport:leg_destroy(H),
    ok;
destroy_handle(H, #state{mod = Mod, engine = Engine}) when
    Engine =/= undefined
->
    _ = Mod:txn_done(Engine, H),
    _ = Mod:leg_destroy(Engine, H),
    ok;
destroy_handle(_H, _S) ->
    ok.

%% The tick carries the engine ref so ticks from a torn-down instance
%% are ignored by the handle_info match.

log_level(0) -> emergency;
log_level(1) -> alert;
log_level(2) -> critical;
log_level(3) -> error;
log_level(4) -> warning;
log_level(5) -> notice;
log_level(6) -> info;
log_level(_) -> debug.
