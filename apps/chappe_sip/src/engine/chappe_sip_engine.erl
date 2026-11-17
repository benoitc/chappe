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

-include("chappe_sip.hrl").

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
    allow_events/0,
    reset_routes/0,
    check_health/1,
    forwarder/1
]).
%% the guard's drop (chappe_sip_guard)
-export([discard/1, block_source/2, stats/0]).
-export([conn_closed/1]).

%% the connections that closed lately, and how many are kept
-define(CLOSED_TAB, chappe_sip_closed_conns).
-define(MAX_CLOSED, 10000).
%% dialog/uac support
-export([
    create_uas/2,
    early_leg/2,
    create_dialog/1,
    reg_handle/2,
    dialog_respond/6,
    send_request/3,
    send_request/4,
    mark_proxied/1,
    disarm/1,
    send_stateless/3,
    relay_response/3,
    forward_response/1,
    cancel_txn/1,
    cancel_txn/2,
    finish_txn/1,
    destroy_leg/1,
    contact/0,
    tls_contact/0
]).
-export_type([flow/0, route/0]).

%% An RFC 5626 flow a request can be sent back over: a WebSocket connection
%% (an integer), a TCP/TLS connection of the native stack ({conn, Id}), or
%% the address a UDP request came from ({udp, Ip, Port}, with the ident of
%% the listen address it reached when there are several).
-type flow() ::
    integer()
    | {conn, pos_integer()}
    | {udp, binary(), inet:port_number()}
    | {udp, binary(), inet:port_number(), binary()}.
%% Where a request goes: a URI (the next hop), a flow, or undefined (by the
%% Request-URI).
-type route() ::
    binary()
    | {ws, integer()}
    | {conn, pos_integer()}
    | {udp, binary(), inet:port_number()}
    | {udp, binary(), inet:port_number(), binary()}
    | undefined.
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

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Bring the SIP stack up. Opts: #{contact := binary(), ...}
-spec start(map()) -> ok | {error, already_started | term()}.
start(Opts) when is_map(Opts) ->
    gen_server:call(?MODULE, {lifecycle, {start, Opts}}, 30000).

-spec stop() -> ok | {error, not_started | hung}.
stop() ->
    gen_server:call(?MODULE, {lifecycle, stop}, 15000).

%% Controlled restart of the SIP engine: tear down live dialogs (owners
%% get {destroy, engine_restart}), stop and restart the NIF engine with
%% the same options, and keep routes/middleware. All SIP state is lost.
-spec restart_engine() -> ok | {error, term()}.
restart_engine() ->
    gen_server:call(?MODULE, {lifecycle, restart_engine}, 30000).

%% Register middleware: fun(Req, Res, Next), optionally method-scoped.
-spec use(binary() | '*', chappe_sip_middleware:mw()) -> ok.
use(Method, Fun) when is_function(Fun, 3) ->
    gen_server:call(?MODULE, {routes, {use, Method, Fun}}).

%% Register the handler for a SIP method: fun(Req, Res). Opts:
%% option_tags (accepted in Require on top of supported_option_tags),
%% proxy (the handler proxies: Proxy-Require is checked, not Require),
%% events (SUBSCRIBE only, see chappe_sip:subscribe/2), package (SUBSCRIBE
%% only: the handler of that one event package, see
%% chappe_sip:event_package/2).
-spec handle(binary(), fun(), map()) -> ok.
handle(Method, Fun, Opts) when is_binary(Method), is_function(Fun, 2) ->
    gen_server:call(?MODULE, {routes, {handle, Method, Fun, Opts}}).

%% Drop all routes and middleware (tests, reconfiguration).
-spec reset_routes() -> ok.
reset_routes() ->
    gen_server:call(?MODULE, {routes, reset}).

%% The dialog leg of an INVITE's early dialog, before its dialog fsm: a
%% B2BUA relaying provisionals under LocalTag takes the requests of that
%% early dialog (an UPDATE, RFC 3311) on the leg, as
%% {chappe_sip_indialog, LegH, TxnH, Meta, Raw}. Pass it to create_uas
%% (leg => LegH) for the final answer; the leg goes with the caller.
-spec early_leg(chappe_sip_req:req(), binary()) ->
    {ok, non_neg_integer()} | {error, term()}.
early_leg(Req, LocalTag) ->
    gen_server:call(?MODULE, {handles, {early_leg, Req, LocalTag}}).

%% Create a UAS dialog for an incoming dialog-forming request. Called by
%% chappe_sip_dialog from the request worker. Returns the started dialog fsm.
-spec create_uas(chappe_sip_req:req(), map()) ->
    {ok, pid()} | {error, term()}.
create_uas(Req, Opts) ->
    gen_server:call(?MODULE, {handles, {create_uas, Req, Opts}}).

%% Route engine handle events (op_ok/op_failed/response/ack/in-dialog
%% request/cancel for this handle) to Pid.
-spec reg_handle(non_neg_integer(), pid()) -> ok.
reg_handle(H, Pid) ->
    gen_server:call(?MODULE, {handles, {reg_handle, H, Pid}}).

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
        {txn, {dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag}}
    ).

%% Send a complete request; responses/op results route to Pid.
-spec send_request(route(), binary(), pid()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Route, Raw, Pid) ->
    send_request(Route, Raw, Pid, #{}).

%% The same with options: `branch' sets the Via branch of the request (a
%% proxy puts its loop-detection hash there, RFC 3261 16.6 step 8).
-spec send_request(route(), binary(), pid(), map()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Route, Raw, Pid, Opts) ->
    gen_server:call(?MODULE, {txn, {send_request, Route, Raw, Pid, Opts}}).

%% A proxy owns this server transaction: a CANCEL is relayed to its
%% branches and the downstream 487 (or a late 2xx) goes upstream, instead
%% of the stack answering 487 itself (RFC 3261 16.10).
-spec mark_proxied(non_neg_integer()) -> ok.
mark_proxied(TxnH) ->
    gen_server:call(?MODULE, {handles, {mark_proxied, TxnH}}).

%% Pid owns a call (it originated an INVITE through a UAC, a b2bua): its
%% handler deadline no longer applies.
-spec disarm(pid()) -> ok.
disarm(Pid) ->
    gen_server:call(?MODULE, {handles, {disarm, Pid}}).

%% Proxy: relay a downstream response upstream on a server transaction.
-spec relay_response(non_neg_integer(), 100..699, binary()) ->
    ok | {error, term()}.
relay_response(ServerTxnH, Status, Raw) ->
    gen_server:call(?MODULE, {txn, {relay_response, ServerTxnH, Status, Raw}}).

%% Proxy: statelessly forward a response upstream with no server
%% transaction (a forked second 2xx). Raw must keep the proxy's own top
%% Via; the engine strips it and routes by the next Via.
-spec forward_response(binary()) -> ok | {error, term()}.
forward_response(Raw) ->
    gen_server:call(?MODULE, {txn, {forward_response, Raw}}).

%% Create a dialog on the UAC side (leg + established fsm). DialogArgs is
%% the chappe_sip_dialog_fsm arg map without the leg. Returns {ok, Pid, LegH}.
-spec create_dialog(map()) -> {ok, pid(), non_neg_integer()} | {error, term()}.
create_dialog(DialogArgs) ->
    gen_server:call(?MODULE, {handles, {create_dialog, DialogArgs}}).

%% Fire-and-forget send (ACK to a 2xx); op result routes to Pid.
-spec send_stateless(route(), binary(), pid()) ->
    {ok, non_neg_integer() | ws_ack} | {error, term()}.
send_stateless(Route, Raw, Pid) ->
    gen_server:call(?MODULE, {txn, {send_stateless, Route, Raw, Pid}}).

%% CANCEL an outstanding INVITE client transaction.
-spec cancel_txn(non_neg_integer()) -> ok | {error, term()}.
cancel_txn(TxnH) ->
    cancel_txn(TxnH, []).

%% CANCEL carrying extra headers (a Reason, RFC 3326).
-spec cancel_txn(non_neg_integer(), [{binary(), iodata()}]) ->
    ok | {error, term()}.
cancel_txn(TxnH, Headers) ->
    gen_server:call(?MODULE, {txn, {cancel_txn, TxnH, Headers}}).

%% End a request without answering it (the guard's drop). Over WebSocket
%% the transaction goes now. On the native transports nta has no silent
%% discard, so its retransmissions are absorbed without a 100 Trying and,
%% once the client has given up (64*T1), a 408 ends it: never sent for a
%% non-INVITE (RFC 4320), and too late to matter for an INVITE.
-spec discard(non_neg_integer()) -> ok.
discard(TxnH) ->
    gen_server:cast(?MODULE, {discard, TxnH}).

%% Discard every request from Addr (a source_ip) for Ms before the stack
%% makes a transaction of it: a source the guard drops costs nothing more.
%% 0 lifts the block. Over WebSocket nothing is blocked.
-spec block_source(binary(), non_neg_integer()) -> ok.
block_source(Addr, Ms) ->
    gen_server:call(?MODULE, {info, {block_source, Addr, Ms}}).

%% #{incoming => server transactions held, discarded => requests the
%% source blocklist discarded, events_dropped => events the shim could not
%% deliver, alloc_failed => event binaries it could not allocate}
-spec stats() -> chappe_sip_nif:stats().
stats() ->
    gen_server:call(?MODULE, {info, stats}).

%% Release a client transaction handle and stop routing for it.
-spec finish_txn(non_neg_integer()) -> ok.
finish_txn(TxnH) ->
    gen_server:cast(?MODULE, {finish_txn, TxnH}).

%% The engine's bound contact URI (for building From/Contact on UAC).
-spec contact() -> binary() | undefined.
contact() ->
    gen_server:call(?MODULE, {info, contact}).

%% The TLS listener's URI (sips:host:port), or undefined without one. A
%% wildcard bind address is replaced by the primary contact's host.
-spec tls_contact() -> binary() | undefined.
tls_contact() ->
    gen_server:call(?MODULE, {info, tls_contact}).

%% Destroy a dialog leg (from the fsm's terminate).
-spec destroy_leg(non_neg_integer()) -> ok.
destroy_leg(LegH) ->
    gen_server:cast(?MODULE, {destroy_leg, LegH}).

%% Force one health round-trip through the stack thread event loop.
-spec check_health(timeout()) -> ok | {error, timeout | not_started}.
check_health(Timeout) ->
    try
        gen_server:call(?MODULE, {lifecycle, check_health}, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout}
    end.

%% The proxy that forwards the in-dialog requests and 2xx ACKs loose-routed
%% back to us after we record-routed their dialog: a module with
%% forward_indialog/2 and forward_indialog_ack/2. chappe_sip_proxy_sup
%% registers chappe_sip_proxy when it starts; with none, such a request
%% goes to the handlers and such an ACK is dropped.
-spec forwarder(module()) -> ok.
forwarder(Mod) when is_atom(Mod) ->
    persistent_term:put({?MODULE, forwarder}, Mod).

forwarder() ->
    persistent_term:get({?MODULE, forwarder}, undefined).

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

%% Calls come in five envelopes, each served by its own helper: the
%% stack's lifecycle, the routes, the handle table, the transactions, and
%% what the engine tells about itself.
handle_call({lifecycle, Op}, From, S) ->
    lifecycle(Op, From, S);
handle_call({routes, Op}, _From, S) ->
    routes(Op, S);
handle_call({handles, Op}, From, S) ->
    handles(Op, From, S);
handle_call({txn, Op}, _From, S) ->
    txn(Op, S);
handle_call({info, Op}, _From, S) ->
    info(Op, S).

lifecycle({start, _}, _From, #state{engine = E} = S) when E =/= undefined ->
    {reply, {error, already_started}, S};
lifecycle({start, Opts}, _From, S) ->
    case start_opts(Opts) of
        {ok, NOpts} -> started(NOpts, S);
        {error, _} = Err -> {reply, Err, S}
    end;
lifecycle(restart_engine, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
lifecycle(restart_engine, _From, S) ->
    restart(S);
lifecycle(stop, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
lifecycle(stop, _From, #state{mod = Mod, engine = Engine} = S) ->
    %% the dialogs and UAC fsms lose their SIP state, as on a restart
    stack_gone(S),
    Result = Mod:stop(Engine),
    %% a clean stop must not auto-reestablish on a later process crash
    cfg_del(opts),
    publish(#{}),
    {reply, Result, stack_down(S)};
lifecycle(check_health, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
lifecycle(
    check_health,
    From,
    #state{mod = Mod, engine = Engine, health_waiters = W} = S
) ->
    ok = Mod:health(Engine),
    {noreply, S#state{health_waiters = [From | W]}}.

started(NOpts, #state{mod = Mod} = S) ->
    Retries = chappe_sip_config:get(engine_start_retries),
    case start_engine(Mod, NOpts, Retries, 100) of
        {ok, Engine} ->
            cfg_put(opts, NOpts),
            publish(NOpts),
            {reply, ok, S#state{
                engine = Engine,
                engine_opts = NOpts,
                tref = schedule_health(Engine),
                misses = 0
            }};
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end.

restart(#state{mod = Mod, engine = Engine, engine_opts = Opts} = S) ->
    %% tell dialogs and UAC fsms their SIP state is going away, so an
    %% in-flight transaction fails cleanly instead of waiting for a reply
    %% that the new native stack will never deliver
    stack_gone(S),
    _ = Mod:stop(Engine),
    S1 = stack_down(S),
    Retries = chappe_sip_config:get(engine_start_retries),
    case start_engine(Mod, Opts, Retries, 100) of
        {ok, NewEngine} ->
            {reply, ok, S1#state{
                engine = NewEngine,
                tref = schedule_health(NewEngine)
            }};
        {error, Reason} ->
            {reply, {error, Reason}, S1}
    end.

routes({use, Method, Fun}, #state{middlewares = MW} = S) ->
    MW1 = MW ++ [{Method, Fun}],
    cfg_put(middlewares, MW1),
    {reply, ok, S#state{middlewares = MW1}};
routes({handle, <<"SUBSCRIBE">>, Fun, #{package := Pkg0} = Opts}, S) ->
    Pkg = string:lowercase(Pkg0),
    cfg_put(packages, (cfg_get(packages, #{}))#{Pkg => Fun}),
    cfg_put({route_opts, {package, Pkg}}, route_opts(Opts)),
    {reply, ok, S};
routes({handle, Method, Fun, Opts}, #state{routes = R} = S) ->
    R1 = R#{Method => Fun},
    cfg_put(routes, R1),
    cfg_put({route_opts, Method}, route_opts(Opts)),
    Method =:= <<"SUBSCRIBE">> andalso
        cfg_put(events, maps:get(events, Opts, any)),
    {reply, ok, S#state{routes = R1}};
routes(reset, #state{routes = R} = S) ->
    _ = [cfg_del({route_opts, M}) || M <- maps:keys(R)],
    _ = [
        cfg_del({route_opts, {package, P}})
     || P <- maps:keys(cfg_get(packages, #{}))
    ],
    cfg_put(routes, #{}),
    cfg_del(events),
    cfg_del(packages),
    cfg_put(middlewares, []),
    {reply, ok, S#state{routes = #{}, middlewares = []}}.

handles({create_uas, Req, Opts}, {WorkerPid, _}, S) ->
    do_create_uas(Req, Opts, WorkerPid, S);
handles({early_leg, Req, LocalTag}, {Pid, _}, S) ->
    early_leg(Req, LocalTag, Pid, S);
handles({create_dialog, DialogArgs}, {Caller, _}, S) ->
    %% WS-only nodes have engine = undefined; a WS-flow dialog still creates
    %% its leg on the transport. dialog_leg_create/5 returns not_started for
    %% a non-WS dialog with no native engine.
    do_create_dialog(DialogArgs, Caller, S);
handles({mark_proxied, TxnH}, {Pid, _}, S) when ?IS_WS(TxnH) ->
    {reply, ok, S#state{proxied = (S#state.proxied)#{TxnH => Pid}}};
handles({mark_proxied, _TxnH}, _From, #state{engine = undefined} = S) ->
    {reply, ok, S};
handles({mark_proxied, TxnH}, {Pid, _}, #state{mod = Mod, engine = E} = S) ->
    _ = Mod:proxy_mark(E, TxnH),
    {reply, ok, S#state{proxied = (S#state.proxied)#{TxnH => Pid}}};
handles({disarm, Pid}, _From, S) ->
    {reply, ok, disarm_deadline(Pid, S)};
handles({reg_handle, H, Pid}, _From, S) ->
    S1 = ensure_monitored(Pid, S),
    {reply, ok, S1#state{handles = (S1#state.handles)#{H => Pid}}}.

early_leg(Req, LocalTag, Pid, S) ->
    Msg = chappe_sip_req:msg(Req),
    LocalAddr = chappe_sip_uas_response:local_addr(Msg, LocalTag),
    case
        leg_create(
            chappe_sip_req:txn(Req),
            Req,
            chappe_sip_msg:call_id(Msg),
            LocalAddr,
            chappe_sip_msg:get(<<"from">>, Msg),
            S
        )
    of
        {ok, LegH} ->
            {reply, {ok, LegH}, S#state{
                handles = (S#state.handles)#{LegH => Pid}
            }};
        Err ->
            {reply, Err, S}
    end.

%% the transactions: a WS handle goes to the transport, a native one to
%% the engine backend, which a WS-only node (or a stopped stack) lacks
txn({dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag}, S) ->
    {reply, tagged_respond(TxnH, Status, Reason, Headers, Body, ToTag, S), S};
txn({send_request, {ws, Flow}, Raw, Pid, _Opts}, S) ->
    ws_request(Flow, Raw, Pid, S);
txn({send_request, _, _, _, _}, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
txn({send_request, Route, Raw, Pid, Opts}, S) ->
    native_request(Route, Raw, Pid, Opts, S);
txn({send_stateless, {ws, Flow}, Raw, _Pid}, S) ->
    _ = chappe_sip_ws_transport:send_stateless(Flow, Raw),
    {reply, {ok, ws_ack}, S};
txn({send_stateless, _, _, _}, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
txn({send_stateless, Route, Raw, Pid}, #state{mod = Mod, engine = E} = S) ->
    %% fire-and-forget (a 2xx ACK / stateless BYE): no response is expected,
    %% so do not retain a handle route (it would linger until the owner
    %% exits)
    Local = maps:get(Pid, S#state.locals, undefined),
    case chappe_sip_binds:send_ident(Route, Local) of
        undefined ->
            {reply, Mod:send(E, native_route(Route), Raw), S};
        Ident ->
            {reply, Mod:send(E, native_route(Route), Raw, Ident), S}
    end;
txn({cancel_txn, TxnH, Hdrs}, S) when ?IS_WS(TxnH) ->
    _ = chappe_sip_ws_transport:cancel(TxnH, chappe_sip_hdr_io:join(Hdrs)),
    {reply, ok, S};
txn({cancel_txn, _, _}, #state{engine = undefined} = S) ->
    %% a UAC still running after the stack was stopped
    {reply, {error, not_started}, S};
txn({cancel_txn, TxnH, []}, #state{mod = Mod, engine = Engine} = S) ->
    {reply, Mod:cancel(Engine, TxnH), S};
txn({cancel_txn, TxnH, Hdrs}, #state{mod = Mod, engine = Engine} = S) ->
    {reply, Mod:cancel(Engine, TxnH, chappe_sip_hdr_io:join(Hdrs)), S};
txn({relay_response, ServerTxnH, Status, Raw}, S) when ?IS_WS(ServerTxnH) ->
    R = sent(
        ServerTxnH,
        Status,
        ws_call(fun() ->
            chappe_sip_ws_transport:relay(ServerTxnH, Status, Raw)
        end)
    ),
    {reply, R, relayed(ServerTxnH, Status, S)};
txn({relay_response, _, _, _}, #state{engine = undefined} = S) ->
    %% a proxy still running after the stack was stopped
    {reply, {error, not_started}, S};
txn({relay_response, ServerTxnH, Status, Raw}, S) ->
    #state{mod = Mod, engine = Engine} = S,
    R = sent(ServerTxnH, Status, Mod:relay(Engine, ServerTxnH, Status, Raw)),
    {reply, R, relayed(ServerTxnH, Status, S)};
txn({forward_response, _}, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
txn({forward_response, Raw}, #state{mod = Mod, engine = Engine} = S) ->
    {reply, Mod:send_response(Engine, Raw), S}.

%% a final response relayed upstream ends the server transaction's route
relayed(ServerTxnH, Status, #state{handles = HM} = S) when Status >= 200 ->
    S#state{handles = maps:remove(ServerTxnH, HM)};
relayed(_ServerTxnH, _Status, S) ->
    S.

%% a response with a dialog tag on a server transaction
tagged_respond(TxnH, Status, Reason, Headers, Body, ToTag, _S) when
    ?IS_WS(TxnH)
->
    sent(
        TxnH,
        Status,
        ws_call(fun() ->
            chappe_sip_ws_transport:respond(
                TxnH, Status, Reason, Headers, Body, ToTag
            )
        end)
    );
tagged_respond(_TxnH, _Status, _Reason, _Headers, _Body, _ToTag, #state{
    engine = undefined
}) ->
    {error, not_started};
tagged_respond(TxnH, Status, Reason, Headers, Body, ToTag, S) ->
    #state{mod = Mod, engine = Engine} = S,
    sent(
        TxnH,
        Status,
        Mod:respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag)
    ).

ws_request(Flow, Raw, Pid, S) ->
    case
        ws_call(fun() ->
            chappe_sip_ws_transport:send_request(Flow, Raw, Pid)
        end)
    of
        {ok, TxnH} ->
            %% a worker that originates a request (proxy fork / UAC) is a
            %% long-lived owner; disarm its deadline and monitor a UAC fsm so
            %% its crash sweeps this handle
            ok = chappe_sip_metrics:request(out, raw_method(Raw)),
            S1 = ensure_monitored(Pid, disarm_deadline(Pid, S)),
            {reply, {ok, TxnH}, S1#state{
                handles = (S1#state.handles)#{TxnH => Pid}
            }};
        Err ->
            {reply, Err, S}
    end.

native_request(Route, Raw, Pid, Opts, #state{mod = Mod, engine = Engine} = S) ->
    NRoute = native_route(Route),
    %% a local option sets the address Pid sends from from now on
    Locals =
        case maps:get(local, Opts, undefined) of
            undefined -> S#state.locals;
            L -> (S#state.locals)#{Pid => L}
        end,
    Ident = chappe_sip_binds:send_ident(
        Route, maps:get(Pid, Locals, undefined)
    ),
    Sent =
        case {maps:get(branch, Opts, undefined), Ident} of
            {undefined, undefined} ->
                Mod:request(Engine, NRoute, Raw);
            {Branch, undefined} ->
                Mod:request(Engine, NRoute, Raw, Branch);
            {undefined, _} ->
                Mod:request(Engine, NRoute, Raw, <<>>, Ident);
            {Branch, _} ->
                Mod:request(Engine, NRoute, Raw, Branch, Ident)
        end,
    case Sent of
        {ok, TxnH} ->
            ok = chappe_sip_metrics:request(out, raw_method(Raw)),
            S1 = ensure_monitored(Pid, disarm_deadline(Pid, S)),
            {reply, {ok, TxnH}, S1#state{
                handles = (S1#state.handles)#{TxnH => Pid},
                locals = Locals
            }};
        Err ->
            {reply, Err, S}
    end.

info({block_source, Addr, Ms}, #state{mod = Mod} = S) ->
    {reply, Mod:block(Addr, Ms), S};
info(stats, #state{mod = Mod} = S) ->
    {reply, Mod:stats(), S};
info(contact, #state{contact = C} = S) ->
    {reply, C, S};
info(tls_contact, S) ->
    {reply, tls_uri(S), S}.

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
handle_cast({discard, TxnH}, S) when ?IS_WS(TxnH) ->
    _ = chappe_sip_ws_transport:finish_txn(TxnH),
    {noreply, S};
handle_cast({discard, TxnH}, #state{mod = Mod, engine = Engine} = S) when
    Engine =/= undefined
->
    _ = Mod:discard(Engine, TxnH),
    %% a dropped request waits 64*T1 for the 408 that ends it
    _ = erlang:send_after(
        chappe_sip_config:t64(), self(), {discard_end, Engine, TxnH}
    ),
    {noreply, S};
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
            publish(Opts),
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
            {noreply,
                forget_txns(Pid, S#state{
                    workers = W1,
                    handles = drop_pid(Pid, HM),
                    locals = maps:remove(Pid, S#state.locals)
                })};
        error ->
            %% a dialog fsm / UAC fsm / other handle owner exited (possibly a
            %% crash, so terminate did not run): destroy its C-side legs/txns
            %% and drop its handle routes
            destroy_owned_handles(Pid, S),
            {noreply,
                forget_txns(Pid, S#state{
                    handles = drop_pid(Pid, HM),
                    dialogs = maps:remove(Pid, S#state.dialogs),
                    monitored = maps:remove(Pid, S#state.monitored),
                    early_uas = drop_pid(Pid, S#state.early_uas),
                    locals = maps:remove(Pid, S#state.locals)
                })}
    end;
handle_info(
    {discard_end, Engine, TxnH}, #state{mod = Mod, engine = Engine} = S
) ->
    _ = Mod:respond(
        Engine, TxnH, 408, <<"Request Timeout">>, <<>>, <<>>, <<>>
    ),
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #state{engine = undefined}) ->
    ok;
terminate(_Reason, #state{mod = Mod, engine = Engine}) ->
    _ = Mod:stop(Engine),
    ok.

%% what a route registration keeps for its workers
route_opts(Opts) ->
    Tags = maps:get(option_tags, Opts, []),
    Role =
        case maps:get(proxy, Opts, false) of
            true -> proxy;
            false -> uas
        end,
    #{option_tags => Tags, role => Role}.

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
            %% the connections of a previous engine are gone, and so are
            %% the bindings learned on them. Connection ids come from one
            %% counter for the life of the VM (the NIF's g_next_id), so an
            %% id never comes back: the record of closed ones is cleared
            %% only to free it, since the stack already refuses a previous
            %% engine's ids as unknown
            _ =
                ets:info(?CLOSED_TAB) =/= undefined andalso
                    ets:delete_all_objects(?CLOSED_TAB),
            chappe_sip_registry:remove_conn_flows(),
            {ok, Engine};
        {error, stopping} ->
            %% a previous instance is tearing down; starts are serialized
            %% through the C atomic guard
            timer:sleep(Backoff),
            start_engine(Mod, Opts, Retries - 1, min(Backoff * 2, 5000));
        {error, Reason} ->
            {error, Reason}
    end.

%% The options the engine backend starts with: TLS checked, the contact
%% restricted, the agent settings checked, the size cap and the HEP
%% capture URL added.
start_opts(Opts) ->
    case validate_tls(maps:get(tls, Opts, undefined)) of
        ok ->
            case chappe_sip_binds:options(Opts) of
                {ok, Opts1} ->
                    case agent_opts(Opts1) of
                        {ok, Opts2} -> with_capture(with_max_size(Opts2));
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% The agent settings, checked with the NIF's bounds and flattened into
%% its keys (sip_t1, sip_t2, sip_t4, outbound_proxy, tcp_keepalive_ms,
%% udp_mtu; tcp_keepalive_ms pings TCP connections only, not TLS ones).
%% aliases stay in Erlang: they are names of this node, known to
%% the proxy's own-address check (chappe_sip_binds:own_uris/0).
-spec agent_opts(map()) -> {ok, map()} | {error, {atom(), term()}}.
agent_opts(Opts) ->
    Checks = [
        {sip_timers, fun sip_timers/1},
        {outbound_proxy, fun outbound_proxy/1},
        {tcp_keepalive_ms, in_range(1000, 3600000)},
        {udp_mtu, in_range(576, 65535)},
        {aliases, fun chappe_sip_binds:aliases/1},
        {outbound_route, fun outbound_route/1}
    ],
    case
        maps:is_key(outbound_proxy, Opts) andalso
            maps:find(outbound_route, Opts)
    of
        {ok, R} -> {error, {outbound_route, {with_outbound_proxy, R}}};
        _ -> agent_opts(Opts, Checks)
    end.

agent_opts(Opts, Checks) ->
    lists:foldl(
        fun
            ({Key, Check}, {ok, Acc}) ->
                case maps:find(Key, Acc) of
                    error ->
                        {ok, Acc};
                    {ok, V} ->
                        case Check(V) of
                            {ok, Flat} ->
                                {ok, maps:merge(maps:remove(Key, Acc), Flat)};
                            error ->
                                {error, {Key, V}}
                        end
                end;
            (_, Err) ->
                Err
        end,
        {ok, Opts},
        [{K, flat(K, C)} || {K, C} <- Checks]
    ).

%% a check of one option, as the NIF keys it sets
flat(Key, Check) ->
    fun(V) ->
        case Check(V) of
            {ok, M} when is_map(M) -> {ok, M};
            ok -> {ok, #{Key => V}};
            error -> error
        end
    end.

in_range(Lo, Hi) ->
    fun
        (N) when is_integer(N), N >= Lo, N =< Hi -> ok;
        (_) -> error
    end.

%% RFC 3261 17.1.1.1: T1 (default 500 ms), T2 (4 s), T4 (5 s); T2 is the
%% cap on the retransmit interval, so never below T1
sip_timers(T) when is_map(T) ->
    Keys = [t1, t2, t4],
    T1 = maps:get(t1, T, 500),
    T2 = maps:get(t2, T, 4000),
    case
        maps:keys(maps:without(Keys, T)) =:= [] andalso
            ok =:= (in_range(10, 60000))(T1) andalso
            ok =:= (in_range(10, 600000))(T2) andalso
            ok =:= (in_range(10, 600000))(maps:get(t4, T, 5000)) andalso
            T2 >= T1
    of
        true ->
            {ok, #{nif_timer(K) => V || K := V <- T}};
        false ->
            error
    end;
sip_timers(_) ->
    error.

%% what the Erlang side reads of the running stack's options: its listen
%% addresses and aliases, and T1, which the 64*T1 timers kept in Erlang
%% follow (chappe_sip_config:t64/0)
publish(Opts) ->
    ok = chappe_sip_config:set_t1(maps:get(sip_t1, Opts, 500)),
    chappe_sip_binds:publish(Opts).

nif_timer(t1) -> sip_t1;
nif_timer(t2) -> sip_t2;
nif_timer(t4) -> sip_t4.

%% outbound_route: kept in Erlang as its Route value (chappe_sip_binds)
outbound_route(U) ->
    case chappe_sip_binds:outbound_route_opt(U) of
        {ok, R} -> {ok, #{outbound_route => R}};
        error -> error
    end.

%% a sip: or sips: URI with no NUL
outbound_proxy(P) when is_binary(P) ->
    case
        binary:match(P, <<0>>) =:= nomatch andalso
            byte_size(P) < 512 andalso chappe_sip_uri:parse(P)
    of
        {ok, #{scheme := S}} when S =:= sip; S =:= sips -> ok;
        _ -> error
    end;
outbound_proxy(_) ->
    error.

%% HEP capture of the native transports: sofia takes a capture URL
%% (TPTAG_CAPT), from the hep option or the application setting
with_capture(Opts) ->
    case maps:get(hep, Opts, chappe_sip_config:get(hep)) of
        undefined ->
            {ok, maps:remove(capture, Opts)};
        Hep ->
            case chappe_sip_hep:validate(Hep) of
                {ok, Cfg} ->
                    {ok, Opts#{capture => chappe_sip_hep:native_url(Cfg)}};
                {error, _} = Err ->
                    Err
            end
    end.

%% TLS verifies the server certificate of every outbound connection by
%% default (verify => peer, with the RFC 5922 subject check against the
%% target host). verify => none turns that off and is accepted only with
%% allow_insecure => true (tests). verify_clients => true also requires a
%% verified client certificate on inbound connections. An unrecognised
%% value fails the start rather than weakening verification silently.
-spec validate_tls(term()) -> ok | {error, {tls, term()}}.
validate_tls(undefined) ->
    ok;
validate_tls(Tls) when is_map(Tls) ->
    Insecure = maps:get(allow_insecure, Tls, false),
    case {maps:get(verify, Tls, peer), maps:get(verify_clients, Tls, false)} of
        {_, VC} when not is_boolean(VC) ->
            {error, {tls, {bad_verify_clients, VC}}};
        {peer, _} ->
            ok;
        {none, _} ->
            case Insecure of
                true -> ok;
                _ -> {error, {tls, insecure_verify_none}}
            end;
        {Other, _} ->
            {error, {tls, {bad_verify, Other}}}
    end;
validate_tls(_) ->
    {error, {tls, bad_options}}.

%% the configured message-size cap goes to the NIF unless start/1 set one
with_max_size(Opts) ->
    case maps:is_key(max_message_size, Opts) of
        true ->
            Opts;
        false ->
            Opts#{max_message_size => chappe_sip_config:get(max_message_size)}
    end.

%% the TLS listener URI, a wildcard host replaced by the primary one
tls_uri(#state{engine_opts = #{tls := #{contact := C}}} = S) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(C)) of
        {ok, #{host := H} = U} ->
            Host =
                case lists:member(H, [<<"0.0.0.0">>, <<"[::]">>, <<"*">>]) of
                    true -> primary_host(S, H);
                    false -> H
                end,
            Port =
                case maps:get(port, U, undefined) of
                    undefined -> <<>>;
                    P -> <<":", (integer_to_binary(P))/binary>>
                end,
            <<"sips:", Host/binary, Port/binary>>;
        _ ->
            undefined
    end;
tls_uri(_S) ->
    undefined.

primary_host(#state{contact = C}, Default) when is_binary(C) ->
    case chappe_sip_uri:parse(chappe_sip_hdr:name_addr_uri(C)) of
        {ok, #{host := H}} -> H;
        _ -> Default
    end;
primary_host(_S, Default) ->
    Default.

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
            stack_gone(S),
            {noreply, stack_down(S)}
    end.

%% tell dialogs and UAC fsms their SIP state is going away (a restart, a
%% stop, a degrade), so an in-flight transaction fails cleanly instead of
%% waiting for a reply that will never come
stack_gone(#state{dialogs = Dialogs, monitored = Monitored}) ->
    maps:foreach(
        fun(Pid, _) -> Pid ! {chappe_sip_engine_restart, undefined} end,
        Dialogs
    ),
    maps:foreach(
        fun(Pid, _) -> Pid ! {chappe_sip_engine_restart, undefined} end,
        Monitored
    ).

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
        health_waiters = [],
        proxied = #{},
        merge = #{},
        early_uas = #{},
        locals = #{}
    }.

schedule_health(Engine) ->
    erlang:send_after(
        chappe_sip_config:get(health_interval_ms),
        self(),
        {health_tick, Engine}
    ).

%% internal: events

%% the native stack's route: a TCP/TLS flow by its id, a UDP flow as the
%% address it came from (RFC 5626 5.3: the request goes back over it)
native_route({conn, Id}) ->
    Id;
native_route({udp, Ip, Port, _Local}) ->
    native_route({udp, Ip, Port});
native_route({udp, Ip, Port}) ->
    Host =
        case binary:match(Ip, <<":">>) of
            nomatch -> Ip;
            _ -> <<"[", Ip/binary, "]">>
        end,
    <<"sip:", Host/binary, ":", (integer_to_binary(Port))/binary,
        ";transport=udp">>;
native_route(Route) ->
    Route.

handle_event({health_ok, _Seq}, #state{health_waiters = W} = S) ->
    [gen_server:reply(From, ok) || From <- W],
    S#state{misses = 0, health_waiters = []};
handle_event({log, Level, Text}, S) ->
    logger:log(log_level(Level), "chappe_sip_engine: ~s", [Text]),
    S;
handle_event({flow_closed, Id}, S) ->
    %% a TCP/TLS connection a binding was learned on closed: RFC 5626 7
    ok = closed_conn(Id),
    chappe_sip_registry:remove_flow({conn, Id}),
    S;
handle_event({started, Contact}, S) ->
    logger:info("chappe_sip_engine: SIP stack up at ~s", [Contact]),
    S#state{contact = Contact};
handle_event({request, TxnH, undefined, Meta, Raw}, S) ->
    %% out-of-dialog request
    ok = chappe_sip_metrics:request(in, maps:get(method, Meta, undefined)),
    dispatch(TxnH, Meta, Raw, S);
handle_event({request, TxnH, LegH, Meta, Raw}, #state{handles = HM} = S) ->
    %% in-dialog request: route to the owning dialog fsm
    ok = chappe_sip_metrics:request(in, maps:get(method, Meta, undefined)),
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
            %% proxy is forwarded to the next hop; anything else is stray
            chappe_sip_dispatch:is_own_route(Raw, Contact) andalso
                forward_ack(forwarder(), LegH, Raw)
    end,
    S;
handle_event({ack_timeout, H}, #state{handles = HM} = S) ->
    %% our 2xx to an INVITE was never ACKed (Timer H)
    case HM of
        #{H := Pid} -> Pid ! {chappe_sip_ack_timeout, H};
        _ -> ok
    end,
    S;
handle_event({cancel, TxnH}, S) ->
    handle_event({cancel, TxnH, <<>>}, S);
handle_event({cancel, TxnH, Raw}, #state{handles = HM} = S) ->
    %% the CANCEL request goes along so the app sees its Reason (RFC 3326)
    Req = cancel_req(Raw),
    case HM of
        #{TxnH := Pid} -> Pid ! {chappe_sip_cancel, TxnH, Req};
        _ -> ok
    end,
    cancelled(TxnH, Req, S),
    S;
handle_event({flow_lost, Legs}, #state{handles = HM} = S) ->
    %% a WS connection closed: the dialogs bound to it are gone
    _ = [
        Pid ! {chappe_sip_flow_lost, L}
     || L <- Legs, {ok, Pid} <- [maps:find(L, HM)]
    ],
    S;
handle_event({prack, TxnH, Raw}, #state{handles = HM} = S) ->
    %% PRACK for a reliable provisional: route to the INVITE's owner
    case HM of
        #{TxnH := Pid} -> Pid ! {chappe_sip_prack, TxnH, Raw};
        _ -> ok
    end,
    S;
handle_event({prack, TxnH, Raw, PrackH}, #state{handles = HM} = S) ->
    %% a PRACK with an offer (RFC 3262 5): the INVITE's owner answers it
    %% through the PRACK's own handle
    case HM of
        #{TxnH := Pid} ->
            Pid ! {chappe_sip_prack, TxnH, Raw, PrackH};
        _ ->
            shed(PrackH, 500, <<"Server Internal Error">>, S)
    end,
    S;
handle_event({response, TxnH, Meta, Raw}, #state{handles = HM} = S) ->
    ok = chappe_sip_metrics:response(in, maps:get(status, Meta, undefined)),
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

%% A WS-range LegH means the ACK arrived over that WS flow.
forward_ack(undefined, _LegH, _Raw) ->
    ok;
forward_ack(Fwd, LegH, Raw) ->
    Arrived =
        case ?IS_WS(LegH) of
            true -> {ws, LegH};
            false -> udp
        end,
    _ = spawn(fun() ->
        try
            Fwd:forward_indialog_ack(Raw, Arrived)
        catch
            C:R:St ->
                logger:warning(
                    "chappe_sip: proxy 2xx-ACK forward failed: ~p:~p~n~p",
                    [C, R, St]
                )
        end
    end),
    ok.

%% the stack answered the INVITE 487 (a proxy relays its branches' final
%% instead): an early dialog it formed ends, and so does its call record
cancelled(TxnH, Req, #state{proxied = Px, early_uas = Early}) ->
    case maps:is_key(TxnH, Px) of
        true ->
            ok;
        false ->
            chappe_sip_cdr:txn_cancel(TxnH),
            case Early of
                #{TxnH := DPid} -> DPid ! {chappe_sip_cancel, TxnH, Req};
                _ -> ok
            end
    end.

cancel_req(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> chappe_sip_req:new(Msg, undefined, #{});
        {error, _} -> undefined
    end.

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
    %% honor a caller-chosen tag (b2bua pre-tags relayed provisionals with
    %% the same value so the early dialog and the 2xx share one To-tag)
    LocalTag = maps:get(local_tag, Opts, chappe_sip_dialog:gen_tag()),
    TxnH = chappe_sip_req:txn(Req),
    %% a B2BUA's early leg (early_leg/2) becomes the dialog's
    Leg =
        case maps:get(leg, Opts, undefined) of
            undefined ->
                leg_create(
                    TxnH,
                    Req,
                    chappe_sip_msg:call_id(Msg),
                    chappe_sip_uas_response:local_addr(Msg, LocalTag),
                    chappe_sip_msg:get(<<"from">>, Msg),
                    S
                );
            EarlyLeg ->
                {ok, EarlyLeg}
        end,
    case Leg of
        {ok, LegH} -> start_uas(Req, Opts, WorkerPid, LocalTag, LegH, S);
        Err -> {reply, Err, S}
    end.

start_uas(Req, Opts, WorkerPid, LocalTag, LegH, S) ->
    TxnH = chappe_sip_req:txn(Req),
    %% contact_params: a feature tag after the `>' (+sip.srs for a
    %% recording server, RFC 7866 6.2)
    Ours = chappe_sip_uas_response:contact(Req, tls_uri(S), S#state.contact),
    Contact = <<Ours/binary, (maps:get(contact_params, Opts, <<>>))/binary>>,
    Owner = maps:get(owner, Opts, WorkerPid),
    FsmArgs = chappe_sip_uas_response:fsm_args(Req, #{
        leg => LegH,
        owner => Owner,
        local_tag => LocalTag,
        contact => Contact,
        opts => Opts
    }),
    case chappe_sip_dialog_sup:start_dialog(FsmArgs) of
        {ok, Pid} ->
            _ = erlang:monitor(process, Pid),
            %% send the dialog-forming response here (not from the fsm
            %% init: that would re-enter this gen_server and deadlock).
            %% op_ok/op_failed for the leg routes to Pid.
            _ = send_uas_response(TxnH, LocalTag, Opts, Contact, S),
            {reply, {ok, Pid}, uas_started(Req, Opts, Owner, LegH, Pid, S)};
        {error, Reason} ->
            _ = leg_destroy(TxnH, LegH, S),
            {reply, {error, Reason}, S}
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
        case AckWait andalso not ?IS_WS(TxnH) of
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

send_uas_response(TxnH, LocalTag, Opts, Contact, S) ->
    {Status, Reason, Headers, Body} =
        chappe_sip_uas_response:build(Opts, Contact),
    tagged_respond(TxnH, Status, Reason, Headers, Body, LocalTag, S).

%% Create a dialog (UAC path): allocate the leg and start the fsm already
%% established. Returns {ok, DialogPid, LegH}.
do_create_dialog(DialogArgs, Caller, S) ->
    case at_dialog_cap(S) of
        true -> {reply, {error, max_dialogs}, S};
        false -> do_create_dialog_1(DialogArgs, Caller, S)
    end.

do_create_dialog_1(DialogArgs, Caller, #state{handles = HM} = S) ->
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
                    %% the dialog a UAC forms sends from the UAC's address
                    {reply, {ok, Pid, LegH}, S#state{
                        handles = HM#{LegH => Pid},
                        dialogs = (S#state.dialogs)#{Pid => true},
                        locals = chappe_sip_binds:inherit(
                            Caller, Pid, S#state.locals
                        )
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
%% dialog we record-routed; the proxy forwards it instead of a local
%% handler. Otherwise dispatch to the registered method handler.
dispatch(TxnH, Meta, Raw, #state{contact = Contact} = S) ->
    case {forwarder(), chappe_sip_dispatch:is_own_route(Raw, Contact)} of
        {Fwd, true} when Fwd =/= undefined ->
            forward(Fwd, TxnH, Meta, Raw, S);
        _ ->
            dispatch_local(TxnH, Meta, Raw, S)
    end.

forward(Fwd, TxnH, Meta, Raw, #state{workers = W} = S) ->
    case map_size(W) >= chappe_sip_config:get(max_request_workers) of
        true ->
            shed(TxnH, 503, <<"Service Unavailable">>, S),
            S;
        false ->
            Handler = fun(Req, Res) -> Fwd:forward_indialog(Req, Res) end,
            %% a proxy: Require is the far UAS's (RFC 3261 16)
            spawn_worker(TxnH, Meta, Raw, Handler, [], #{role => proxy}, S)
    end.

dispatch_local(TxnH, #{method := Method} = Meta, Raw, S) ->
    case chappe_sip_dispatch:stray_in_dialog(Method, Raw) of
        true ->
            %% RFC 3261 12.2.2 and 15.1.2: a request for a dialog we do not
            %% have is not a new one
            respond_txn(TxnH, 481, <<"Call/Transaction Does Not Exist">>, S),
            S;
        false ->
            dispatch_route(TxnH, Meta, Raw, S)
    end.

dispatch_route(
    TxnH, #{method := Method} = Meta, Raw, #state{routes = Routes} = S
) ->
    case chappe_sip_dispatch:route_for(Method, Raw, Routes, events()) of
        {bad_event, Events} ->
            reject_event(TxnH, Events, S);
        {Handler, Key} ->
            dispatch_handler(TxnH, Meta, Raw, Handler, Key, S);
        none ->
            unrouted(TxnH, Method, Routes, S)
    end.

dispatch_handler(TxnH, #{method := Method} = Meta, Raw, Handler, Key, S) ->
    Max = chappe_sip_config:get(max_request_workers),
    case chappe_sip_dispatch:bad_event(Method, Raw, events()) of
        {true, Events} ->
            reject_event(TxnH, Events, S);
        refer ->
            respond_txn(TxnH, 403, <<"Forbidden">>, <<>>, S),
            S;
        false when map_size(S#state.workers) >= Max ->
            shed(TxnH, 503, <<"Service Unavailable">>, S),
            S;
        false ->
            run_handler(TxnH, Meta, Raw, Handler, Key, S)
    end.

run_handler(TxnH, #{method := Method} = Meta, Raw, Handler, RouteKey, S) ->
    case merge_check(TxnH, Method, Raw, S) of
        merged ->
            respond_txn(TxnH, 482, <<"Loop Detected">>, S),
            S;
        Key ->
            RouteOpts = cfg_get({route_opts, RouteKey}, #{}),
            MW = S#state.middlewares,
            index_merge(
                Key,
                TxnH,
                spawn_worker(TxnH, Meta, Raw, Handler, MW, RouteOpts, S)
            )
    end.

%% respond_txn handles a WS or native transaction (a bare shed would send
%% a WS txn to nta)
unrouted(TxnH, Method, Routes, S) ->
    case chappe_sip_dispatch:unrouted(Method, Routes, events()) of
        noreply ->
            S;
        {Status, Reason, Hdrs} ->
            Joined = chappe_sip_hdr_io:join(Hdrs),
            respond_txn(TxnH, Status, Reason, Joined, S),
            S
    end.

reject_event(TxnH, Events, S) ->
    Hdr = chappe_sip_hdr_io:join([chappe_sip_dispatch:event_header(Events)]),
    respond_txn(TxnH, 489, <<"Bad Event">>, Hdr, S),
    S.

%% the event packages registered, and the events of the SUBSCRIBE handler
events() ->
    {cfg_get(packages, #{}), cfg_get(events, undefined)}.

%% The event packages we serve: those registered with a handler of their
%% own and those the SUBSCRIBE handler serves (chappe_sip:subscribe/2), or
%% `any' when that handler was registered without a list (or none serves
%% any).
-spec allow_events() -> any | [binary()].
allow_events() ->
    {Pkgs, Events} = events(),
    chappe_sip_dispatch:allow_events(Pkgs, Events).

%% merged requests (chappe_sip_dispatch:merge_check/4), native
%% transactions only: the stack keys the WS ones by flow
merge_check(TxnH, _Method, _Raw, _S) when ?IS_WS(TxnH) ->
    none;
merge_check(_TxnH, Method, Raw, #state{merge = Idx, proxied = Px}) ->
    chappe_sip_dispatch:merge_check(Method, Raw, Idx, Px).

%% the first transaction of a merge key stays indexed while its worker runs
index_merge(none, _TxnH, S) ->
    S;
index_merge({Key, Branch}, TxnH, #state{merge = Idx, handles = HM} = S) ->
    case {Idx, HM} of
        {#{Key := _}, _} ->
            S;
        {_, #{TxnH := Pid}} ->
            S#state{merge = Idx#{Key => {Branch, TxnH, Pid}}};
        _ ->
            S
    end.

%% a worker (or proxy owner) is gone: drop its merge and proxied entries
forget_txns(Pid, #state{merge = Idx, proxied = Px} = S) ->
    S#state{
        merge = maps:filter(fun(_K, {_, _, P}) -> P =/= Pid end, Idx),
        proxied = maps:filter(fun(_T, P) -> P =/= Pid end, Px)
    }.

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
    RouteOpts,
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
    Args = RouteOpts#{
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
                handler_deadline(Meta), self(), {worker_deadline, Pid}
            ),
            %% route a later CANCEL for this server txn to the worker
            S#state{
                workers = W#{Pid => {MRef, TxnH, FinalRef, DTRef}},
                handles = HM#{TxnH => Pid}
            };
        {error, Reason} ->
            logger:error("chappe_sip: cannot start request worker: ~p", [Reason]),
            shed(TxnH, 500, <<"Server Internal Error">>, S),
            S
    end.

%% A non-INVITE request is answered before its client gives up (Timer F,
%% 64*T1): a handler waiting on a user must not hold a SUBSCRIBE or a
%% REFER past it (RFC 6665 4.2.1.1, RFC 3515 6).
handler_deadline(#{method := <<"INVITE">>}) ->
    chappe_sip_config:get(handler_deadline_ms);
handler_deadline(_Meta) ->
    min(
        chappe_sip_config:get(handler_deadline_ms),
        chappe_sip_config:get(non_invite_deadline_ms)
    ).

%% the sender fun runs in the worker process; the NIF respond call is
%% enqueue-only and safe from any process
make_sender(Mod, Engine) ->
    fun(TxnH, Status, Opts) ->
        sent(TxnH, Status, sender_send(Mod, Engine, TxnH, Status, Opts))
    end.

sender_send(Mod, Engine, TxnH, Status, Opts) ->
    Reason = maps:get(reason, Opts, <<>>),
    Headers = chappe_sip_hdr_io:join(maps:get(headers, Opts, [])),
    Body = iolist_to_binary(maps:get(body, Opts, <<>>)),
    ToTag = maps:get(to_tag, Opts, <<>>),
    case chappe_sip_ws:is_ws(TxnH) of
        true ->
            %% WS is reliable: a reliable 1xx carries RSeq and is
            %% matched to its PRACK, but is never retransmitted
            Reliable = maps:get(reliable, Opts, false),
            ws_call(fun() ->
                ws_respond(
                    Reliable, TxnH, Status, Reason, Headers, Body, ToTag
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
    end.

%% a response went out on a server transaction: its call record, if any,
%% rings, answers or ends
sent(TxnH, Status, Result) ->
    _ =
        case Result of
            {error, _} ->
                ok;
            _ ->
                ok = chappe_sip_metrics:response(out, Status),
                chappe_sip_cdr:txn_response(TxnH, Status)
        end,
    Result.

%% the method of a request we send, its first token
raw_method(Raw) ->
    case binary:match(Raw, <<" ">>) of
        {N, _} when N > 0, N =< 32 -> binary:part(Raw, 0, N);
        _ -> undefined
    end.

ws_respond(true, TxnH, Status, Reason, Headers, Body, ToTag) ->
    chappe_sip_ws_transport:reliable_respond(
        TxnH, Status, Reason, Headers, Body, ToTag
    );
ws_respond(false, TxnH, Status, Reason, Headers, Body, ToTag) ->
    chappe_sip_ws_transport:respond(TxnH, Status, Reason, Headers, Body, ToTag).

%% Answer a request the node will not process (overload, a worker that could
%% not start or died without a final). The transaction may live in the WS
%% transport, and a WS-only node has no native engine at all.
shed(TxnH, Status, Reason, S) ->
    respond_txn(TxnH, Status, Reason, S).

%% Respond on a server transaction whether it lives in the WS transport or the
%% native backend. The /5 form carries a header blob (e.g. Allow on a 405).
respond_txn(TxnH, Status, Reason, S) ->
    respond_txn(TxnH, Status, Reason, <<>>, S).

respond_txn(TxnH, Status, Reason, Headers, _S) when ?IS_WS(TxnH) ->
    _ = sent(
        TxnH,
        Status,
        ws_call(fun() ->
            chappe_sip_ws_transport:respond(
                TxnH, Status, Reason, Headers, <<>>, <<>>
            )
        end)
    ),
    ok;
respond_txn(TxnH, Status, Reason, Headers, #state{mod = Mod, engine = Engine}) when
    Engine =/= undefined
->
    _ = sent(
        TxnH,
        Status,
        Mod:respond(Engine, TxnH, Status, Reason, Headers, <<>>, <<>>)
    ),
    ok;
respond_txn(_TxnH, _Status, _Reason, _Headers, _S) ->
    ok.

%% A worker gone without a final response gets a 500, whatever the exit
%% reason: exiting normal without answering is a handler bug too.
maybe_500(_Reason, TxnH, FinalRef, S) ->
    case atomics:get(FinalRef, 1) of
        0 -> shed(TxnH, 500, <<"Server Internal Error">>, S);
        _ -> ok
    end.

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

%% True when the native stack's TCP/TLS connection Id closed lately
%% (since this engine started; ids are never reused within the VM). A
%% request sent over a connection as it closes can come back as the
%% stack's own 503 rather than an error: the edge proxy tells a lost flow
%% from a busy UA with this (RFC 5626 5.3).
-spec conn_closed(pos_integer()) -> boolean().
conn_closed(Id) ->
    try
        ets:member(?CLOSED_TAB, Id)
    catch
        error:badarg -> false
    end.

%% the record is bounded: past ?MAX_CLOSED entries the older half goes
closed_conn(Id) ->
    try
        true = ets:insert(
            ?CLOSED_TAB, {Id, erlang:unique_integer([monotonic])}
        ),
        case ets:info(?CLOSED_TAB, size) > ?MAX_CLOSED of
            true ->
                Ts = lists:sort([T || {_, T} <- ets:tab2list(?CLOSED_TAB)]),
                Cut = lists:nth(?MAX_CLOSED div 2, Ts),
                _ = ets:select_delete(
                    ?CLOSED_TAB, [{{'_', '$1'}, [{'<', '$1', Cut}], [true]}]
                ),
                ok;
            false ->
                ok
        end
    catch
        error:badarg -> ok
    end.
