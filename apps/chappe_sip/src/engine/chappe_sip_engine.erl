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

%% the methods chappe_sip recognises; any other is answered 501
-define(KNOWN_METHODS, [
    <<"INVITE">>,
    <<"ACK">>,
    <<"CANCEL">>,
    <<"BYE">>,
    <<"OPTIONS">>,
    <<"REGISTER">>,
    <<"INFO">>,
    <<"UPDATE">>,
    <<"PRACK">>,
    <<"REFER">>,
    <<"SUBSCRIBE">>,
    <<"NOTIFY">>,
    <<"MESSAGE">>,
    <<"PUBLISH">>
]).

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
    allow_events/0,
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
%% the address a UDP request came from ({udp, Ip, Port}).
-type flow() ::
    integer()
    | {conn, pos_integer()}
    | {udp, binary(), inet:port_number()}.
%% Where a request goes: a URI (the next hop), a flow, or undefined (by the
%% Request-URI).
-type route() ::
    binary()
    | {ws, integer()}
    | {conn, pos_integer()}
    | {udp, binary(), inet:port_number()}
    | undefined.
-export([validate_tls/1]).
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
    early_uas = #{} :: #{non_neg_integer() => pid()}
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

%% Register the handler for a SIP method: fun(Req, Res). Opts:
%% option_tags (accepted in Require on top of supported_option_tags),
%% proxy (the handler proxies: Proxy-Require is checked, not Require),
%% events (SUBSCRIBE only, see chappe_sip:subscribe/2), package (SUBSCRIBE
%% only: the handler of that one event package, see
%% chappe_sip:event_package/2).
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
-spec send_request(route(), binary(), pid()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Route, Raw, Pid) ->
    send_request(Route, Raw, Pid, #{}).

%% The same with options: `branch' sets the Via branch of the request (a
%% proxy puts its loop-detection hash there, RFC 3261 16.6 step 8).
-spec send_request(route(), binary(), pid(), map()) ->
    {ok, non_neg_integer()} | {error, term()}.
send_request(Route, Raw, Pid, Opts) ->
    gen_server:call(?MODULE, {send_request, Route, Raw, Pid, Opts}).

%% A proxy owns this server transaction: a CANCEL is relayed to its
%% branches and the downstream 487 (or a late 2xx) goes upstream, instead
%% of the stack answering 487 itself (RFC 3261 16.10).
-spec mark_proxied(non_neg_integer()) -> ok.
mark_proxied(TxnH) ->
    gen_server:call(?MODULE, {mark_proxied, TxnH}).

%% Pid owns a call (it originated an INVITE through a UAC, a b2bua): its
%% handler deadline no longer applies.
-spec disarm(pid()) -> ok.
disarm(Pid) ->
    gen_server:call(?MODULE, {disarm, Pid}).

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
-spec send_stateless(route(), binary(), pid()) ->
    {ok, non_neg_integer() | ws_ack} | {error, term()}.
send_stateless(Route, Raw, Pid) ->
    gen_server:call(?MODULE, {send_stateless, Route, Raw, Pid}).

%% CANCEL an outstanding INVITE client transaction.
-spec cancel_txn(non_neg_integer()) -> ok | {error, term()}.
cancel_txn(TxnH) ->
    cancel_txn(TxnH, []).

%% CANCEL carrying extra headers (a Reason, RFC 3326).
-spec cancel_txn(non_neg_integer(), [{binary(), iodata()}]) ->
    ok | {error, term()}.
cancel_txn(TxnH, Headers) ->
    gen_server:call(?MODULE, {cancel_txn, TxnH, Headers}).

%% Release a client transaction handle and stop routing for it.
-spec finish_txn(non_neg_integer()) -> ok.
finish_txn(TxnH) ->
    gen_server:cast(?MODULE, {finish_txn, TxnH}).

%% The engine's bound contact URI (for building From/Contact on UAC).
-spec contact() -> binary() | undefined.
contact() ->
    gen_server:call(?MODULE, contact).

%% The TLS listener's URI (sips:host:port), or undefined without one. A
%% wildcard bind address is replaced by the primary contact's host.
-spec tls_contact() -> binary() | undefined.
tls_contact() ->
    gen_server:call(?MODULE, tls_contact).

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
    case start_opts(Opts) of
        {ok, NOpts} ->
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
    stack_gone(S#state{dialogs = Dialogs, monitored = Monitored}),
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
    %% the dialogs and UAC fsms lose their SIP state, as on a restart
    stack_gone(S),
    Result = Mod:stop(Engine),
    %% a clean stop must not auto-reestablish on a later process crash
    cfg_del(opts),
    {reply, Result, stack_down(S)};
handle_call({use, Method, Fun}, _From, #state{middlewares = MW} = S) ->
    MW1 = MW ++ [{Method, Fun}],
    cfg_put(middlewares, MW1),
    {reply, ok, S#state{middlewares = MW1}};
handle_call(
    {handle, <<"SUBSCRIBE">>, Fun, #{package := Pkg0} = Opts}, _From, S
) ->
    Pkg = string:lowercase(Pkg0),
    cfg_put(packages, (cfg_get(packages, #{}))#{Pkg => Fun}),
    cfg_put({route_opts, {package, Pkg}}, route_opts(Opts)),
    {reply, ok, S};
handle_call({handle, Method, Fun, Opts}, _From, #state{routes = R} = S) ->
    R1 = R#{Method => Fun},
    cfg_put(routes, R1),
    cfg_put({route_opts, Method}, route_opts(Opts)),
    Method =:= <<"SUBSCRIBE">> andalso
        cfg_put(events, maps:get(events, Opts, any)),
    {reply, ok, S#state{routes = R1}};
handle_call({unhandle, Method}, _From, #state{routes = R} = S) ->
    R1 = maps:remove(Method, R),
    cfg_put(routes, R1),
    cfg_del({route_opts, Method}),
    Method =:= <<"SUBSCRIBE">> andalso cfg_del(events),
    {reply, ok, S#state{routes = R1}};
handle_call(reset_routes, _From, #state{routes = R} = S) ->
    _ = [cfg_del({route_opts, M}) || M <- maps:keys(R)],
    _ = [
        cfg_del({route_opts, {package, P}})
     || P <- maps:keys(cfg_get(packages, #{}))
    ],
    cfg_put(routes, #{}),
    cfg_del(events),
    cfg_del(packages),
    cfg_put(middlewares, []),
    {reply, ok, S#state{routes = #{}, middlewares = []}};
handle_call({respond, TxnH, Status, Reason}, _From, S) when ?IS_WS(TxnH) ->
    {reply,
        sent(
            TxnH,
            Status,
            ws_call(fun() ->
                chappe_sip_ws_transport:respond(
                    TxnH, Status, Reason, <<>>, <<>>, <<>>
                )
            end)
        ),
        S};
handle_call({respond, _, _, _}, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call(
    {respond, TxnH, Status, Reason},
    _From,
    #state{mod = Mod, engine = Engine} = S
) ->
    {reply,
        sent(
            TxnH,
            Status,
            Mod:respond(Engine, TxnH, Status, Reason, <<>>, <<>>, <<>>)
        ),
        S};
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
    {reply, Mod:send(Engine, native_route(Route), Raw), S};
handle_call({cancel_txn, TxnH, Hdrs}, _From, S) when ?IS_WS(TxnH) ->
    _ = chappe_sip_ws_transport:cancel(TxnH, chappe_sip_hdr_io:join(Hdrs)),
    {reply, ok, S};
handle_call(
    {cancel_txn, TxnH, []},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when Engine =/= undefined ->
    {reply, Mod:cancel(Engine, TxnH), S};
handle_call(
    {cancel_txn, TxnH, Hdrs},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when Engine =/= undefined ->
    {reply, Mod:cancel(Engine, TxnH, chappe_sip_hdr_io:join(Hdrs)), S};
handle_call(
    {relay_response, ServerTxnH, Status, Raw},
    _From,
    #state{handles = HM} = S
) when ?IS_WS(ServerTxnH) ->
    R = sent(
        ServerTxnH,
        Status,
        ws_call(fun() ->
            chappe_sip_ws_transport:relay(ServerTxnH, Status, Raw)
        end)
    ),
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
    R = sent(ServerTxnH, Status, Mod:relay(Engine, ServerTxnH, Status, Raw)),
    HM1 =
        case Status >= 200 of
            true -> maps:remove(ServerTxnH, HM);
            false -> HM
        end,
    {reply, R, S#state{handles = HM1}};
handle_call({forward_response, _}, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
handle_call({Op, _, _, _}, _From, #state{engine = undefined} = S) when
    Op =:= relay_response; Op =:= cancel_txn
->
    %% a proxy or UAC still running after the stack was stopped
    {reply, {error, not_started}, S};
handle_call(
    {forward_response, Raw},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when Engine =/= undefined ->
    {reply, Mod:send_response(Engine, Raw), S};
handle_call(contact, _From, #state{contact = C} = S) ->
    {reply, C, S};
handle_call(tls_contact, _From, S) ->
    {reply, tls_uri(S), S};
handle_call({mark_proxied, TxnH}, {Pid, _}, S) when ?IS_WS(TxnH) ->
    {reply, ok, S#state{proxied = (S#state.proxied)#{TxnH => Pid}}};
handle_call(
    {mark_proxied, TxnH},
    {Pid, _},
    #state{mod = Mod, engine = Engine} = S
) when Engine =/= undefined ->
    _ = Mod:proxy_mark(Engine, TxnH),
    {reply, ok, S#state{proxied = (S#state.proxied)#{TxnH => Pid}}};
handle_call({mark_proxied, _TxnH}, _From, S) ->
    {reply, ok, S};
handle_call({disarm, Pid}, _From, S) ->
    {reply, ok, disarm_deadline(Pid, S)};
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
        sent(
            TxnH,
            Status,
            ws_call(fun() ->
                chappe_sip_ws_transport:respond(
                    TxnH, Status, Reason, Headers, Body, ToTag
                )
            end)
        ),
        S};
handle_call(
    {dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when
    Engine =/= undefined
->
    {reply,
        sent(
            TxnH,
            Status,
            Mod:respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag)
        ),
        S};
handle_call(
    {dialog_respond, _, _, _, _, _, _}, _From, #state{engine = undefined} = S
) ->
    {reply, {error, not_started}, S};
handle_call({send_request, {ws, Flow}, Raw, Pid, _Opts}, _From, S) ->
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
handle_call(
    {send_request, _, _, _, _}, _From, #state{engine = undefined} = S
) ->
    {reply, {error, not_started}, S};
handle_call(
    {send_request, Route, Raw, Pid, Opts},
    _From,
    #state{mod = Mod, engine = Engine} = S
) when
    Engine =/= undefined
->
    NRoute = native_route(Route),
    Sent =
        case maps:get(branch, Opts, undefined) of
            undefined -> Mod:request(Engine, NRoute, Raw);
            Branch -> Mod:request(Engine, NRoute, Raw, Branch)
        end,
    case Sent of
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
            {noreply,
                forget_txns(Pid, S#state{
                    workers = W1, handles = drop_pid(Pid, HM)
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
                    early_uas = drop_pid(Pid, S#state.early_uas)
                })}
    end;
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
            %% the bindings learned on them
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
%% restricted, the size cap and the HEP capture URL added.
start_opts(Opts) ->
    case validate_tls(maps:get(tls, Opts, undefined)) of
        ok -> with_capture(with_max_size(normalize_contact(Opts)));
        {error, _} = Err -> Err
    end.

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
    case chappe_sip_uri:parse(strip_angle(C)) of
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
    case chappe_sip_uri:parse(strip_angle(C)) of
        {ok, #{host := H}} -> H;
        _ -> Default
    end;
primary_host(_S, Default) ->
    Default.

strip_angle(C) ->
    case chappe_sip_hdr:name_addr(C) of
        {ok, #{uri := U}} -> U;
        _ -> C
    end.

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
        early_uas = #{}
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
    chappe_sip_registry:remove_flow({conn, Id}),
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
    CallId = chappe_sip_msg:call_id(Msg),
    ToVal = chappe_sip_msg:get(<<"to">>, Msg),
    FromVal = chappe_sip_msg:get(<<"from">>, Msg),
    %% honor a caller-chosen tag (b2bua pre-tags relayed provisionals with
    %% the same value so the early dialog and the 2xx share one To-tag)
    LocalTag = maps:get(local_tag, Opts, chappe_sip_dialog:gen_tag()),
    LocalAddr = <<ToVal/binary, ";tag=", LocalTag/binary>>,
    TxnH = chappe_sip_req:txn(Req),
    RTarget = contact_uri(chappe_sip_msg:get(<<"contact">>, Msg), FromVal),
    Contact = uas_contact(Req, S),
    %% a 2xx to an INVITE waits for its ACK (RFC 3261 13.3.1.4). The native
    %% stack keeps its server transaction until the ACK or Timer H and names
    %% it in both; the WS transport names the dialog leg.
    AckWait =
        chappe_sip_msg:method(Msg) =:= <<"INVITE">> andalso
            is_2xx(maps:get(status, Opts, 200)),
    case leg_create(TxnH, Req, CallId, LocalAddr, FromVal, S) of
        {ok, LegH} ->
            Owner = maps:get(owner, Opts, WorkerPid),
            FsmArgs = #{
                leg => LegH,
                txn => TxnH,
                role => uas,
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
                %% the Contact the 2xx carries; a subscription repeats it on
                %% a refresh 2xx (SUBSCRIBE is a target refresh request)
                local_contact => dialog_contact(Opts, Contact),
                call_id => CallId,
                %% RFC 3261 12.1.1: the remote CSeq starts at the request's
                remote_cseq => req_cseq(Msg),
                ack_wait => AckWait,
                %% the call record this INVITE opened, now the dialog's
                cdr => maps:get(cdr, chappe_sip_req:meta(Req), undefined)
            },
            case chappe_sip_dialog_sup:start_dialog(FsmArgs) of
                {ok, Pid} ->
                    _ = erlang:monitor(process, Pid),
                    %% send the dialog-forming response here (not from the
                    %% fsm init: that would re-enter this gen_server and
                    %% deadlock). op_ok/op_failed for the leg routes to Pid.
                    _ = send_uas_response(TxnH, LocalTag, Opts, Contact, S),
                    %% the owner now blocks for the call's lifetime; disarm its
                    %% handler deadline so it is not killed mid-call
                    S1 = disarm_deadline(Owner, S),
                    HM0 = S1#state.handles,
                    HM1 =
                        case AckWait andalso not ?IS_WS(TxnH) of
                            true -> HM0#{TxnH => Pid};
                            false -> HM0
                        end,
                    {reply, {ok, Pid}, S1#state{
                        handles = HM1#{LegH => Pid},
                        dialogs = (S1#state.dialogs)#{Pid => true},
                        early_uas = early_uas(Msg, Opts, TxnH, Pid, S1)
                    }};
                {error, Reason} ->
                    _ = leg_destroy(TxnH, LegH, S),
                    {reply, {error, Reason}, S}
            end;
        Err ->
            {reply, Err, S}
    end.

is_2xx(Status) -> is_integer(Status) andalso Status >= 200 andalso Status < 300.

%% a 1xx from create_uas forms an early dialog of the INVITE
early_uas(Msg, Opts, TxnH, Pid, #state{early_uas = E}) ->
    case {chappe_sip_msg:method(Msg), maps:get(status, Opts, 200)} of
        {<<"INVITE">>, St} when is_integer(St), St < 200 -> E#{TxnH => Pid};
        _ -> E
    end.

req_cseq(Msg) ->
    case chappe_sip_msg:cseq(Msg) of
        {ok, #{seq := N}} -> N;
        _ -> 0
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

send_uas_response(TxnH, LocalTag, Opts, Contact, S) ->
    Status = maps:get(status, Opts, 200),
    Reason = maps:get(reason, Opts, <<"OK">>),
    ExtraHeaders = with_allow(
        Status,
        Opts,
        with_supported(
            Status,
            Opts,
            with_contact(Status, maps:get(headers, Opts, []), Contact)
        )
    ),
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
    Sent =
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
        end,
    sent(TxnH, Status, Sent).

%% A dialog-forming 2xx MUST carry a Contact (RFC 3261 12.1.1) so the peer
%% can build the dialog and target in-dialog requests. Add our own unless the
%% app already supplied one.
with_contact(Status, Headers, Contact) when Status >= 200, Status < 300 ->
    case has_hdr(<<"contact">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Contact">>, Contact}]
    end;
with_contact(_Status, Headers, _Contact) ->
    Headers.

%% the 2xx forming an INVITE dialog lists our option tags (RFC 3891 6.2),
%% unless the app set its own Supported
with_supported(Status, #{subscription := _}, Headers) when Status >= 200 ->
    Headers;
with_supported(Status, _Opts, Headers) when Status >= 200, Status < 300 ->
    case has_hdr(<<"supported">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Supported">>, ?SUPPORTED}]
    end;
with_supported(_Status, _Opts, Headers) ->
    Headers.

%% RFC 3261 13.3.1.4: a 2xx to an INVITE SHOULD carry Allow
with_allow(Status, #{subscription := _}, Headers) when Status >= 200 ->
    Headers;
with_allow(Status, _Opts, Headers) when Status >= 200, Status < 300 ->
    case has_hdr(<<"allow">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"Allow">>, ?ALLOW}]
    end;
with_allow(_Status, _Opts, Headers) ->
    Headers.

dialog_contact(Opts, Contact) ->
    Supplied = [
        iolist_to_binary(V)
     || {N, V} <- maps:get(headers, Opts, []),
        string:lowercase(N) =:= <<"contact">>
    ],
    case Supplied of
        [C | _] -> C;
        [] -> Contact
    end.

has_hdr(Lname, Headers) ->
    lists:any(
        fun
            ({N, _}) -> string:lowercase(N) =:= Lname;
            (_) -> false
        end,
        Headers
    ).

%% RFC 3261 12.1.1: the 2xx Contact is a SIPS URI when the request had one
%% in its Request-URI, its top Record-Route, or (with no Record-Route) its
%% Contact; RFC 5630 also gives a dialog formed over TLS our sips Contact.
uas_contact(Req, S) ->
    Msg = chappe_sip_req:msg(Req),
    Secure =
        maps:get(transport, chappe_sip_req:meta(Req), undefined) =:= <<"tls">> orelse
            lists:any(fun is_sips/1, [
                chappe_sip_msg:uri(Msg) | sips_candidates(Msg)
            ]),
    case {Secure, tls_uri(S)} of
        {true, Tls} when is_binary(Tls) -> <<"<", Tls/binary, ">">>;
        _ -> local_contact(S)
    end.

%% the top Record-Route, else the Contact, as bare URIs
sips_candidates(Msg) ->
    Hdr =
        case chappe_sip_msg:get(<<"record-route">>, Msg) of
            undefined -> chappe_sip_msg:get(<<"contact">>, Msg);
            RR -> RR
        end,
    case Hdr of
        undefined ->
            [];
        V ->
            case chappe_sip_hdr:split_list(V) of
                [Top | _] -> [strip_angle(Top)];
                [] -> []
            end
    end.

is_sips(<<"sips:", _/binary>>) -> true;
is_sips(_) -> false.

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
    #state{contact = Contact, workers = W} = S
) ->
    case is_own_route(Raw, Contact) of
        true ->
            case map_size(W) >= chappe_sip_config:get(max_request_workers) of
                true ->
                    shed(TxnH, 503, <<"Service Unavailable">>, S),
                    S;
                false ->
                    Handler = fun(Req, Res) ->
                        chappe_sip_proxy:forward_indialog(Req, Res)
                    end,
                    %% a proxy: Require is the far UAS's (RFC 3261 16)
                    spawn_worker(
                        TxnH, Meta, Raw, Handler, [], #{role => proxy}, S
                    )
            end;
        false ->
            dispatch_local(TxnH, Meta, Raw, S)
    end.

dispatch_local(TxnH, #{method := Method} = Meta, Raw, S) ->
    case stray_in_dialog(Method, Raw) of
        true ->
            %% RFC 3261 12.2.2 and 15.1.2: a request for a dialog we do not
            %% have is not a new one
            respond_txn(TxnH, 481, <<"Call/Transaction Does Not Exist">>, S),
            S;
        false ->
            dispatch_route(TxnH, Meta, Raw, S)
    end.

%% A BYE, or a request tagged for a dialog, reaching the default leg names
%% no dialog of ours. A NOTIFY is left to its handler: the application runs
%% its own subscriptions, and their NOTIFYs carry our tag.
stray_in_dialog(Method, _Raw) when
    Method =:= <<"ACK">>; Method =:= <<"CANCEL">>; Method =:= <<"NOTIFY">>
->
    false;
stray_in_dialog(<<"BYE">>, _Raw) ->
    true;
stray_in_dialog(_Method, Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} -> chappe_sip_msg:to_tag(Msg) =/= undefined;
        {error, _} -> false
    end.

dispatch_route(
    TxnH, #{method := Method} = Meta, Raw, #state{routes = Routes} = S
) ->
    case route_for(Method, Raw, Routes) of
        {bad_event, Events} ->
            reject_event(TxnH, Events, S);
        {Handler, Key} ->
            dispatch_handler(TxnH, Meta, Raw, Handler, Key, S);
        none ->
            unrouted(TxnH, Method, Routes, S)
    end.

%% The handler of a request: its method's, the built-in NOTIFY router
%% (subscriptions of ours, REFERs we sent, then yours), or for a SUBSCRIBE
%% the one of its event package. Key names the route options.
route_for(<<"NOTIFY">> = M, _Raw, Routes) ->
    {chappe_sip_notify_router:handler(maps:get(M, Routes, undefined)), M};
route_for(<<"SUBSCRIBE">> = M, Raw, Routes) ->
    Pkgs = cfg_get(packages, #{}),
    Pkg = event_package(Raw),
    case {Pkgs, Routes} of
        {#{Pkg := Fun}, _} when Pkg =/= <<"refer">> ->
            {Fun, {package, Pkg}};
        {_, #{M := Handler}} ->
            {Handler, M};
        _ when map_size(Pkgs) > 0 ->
            {bad_event, allow_events()};
        _ ->
            none
    end;
route_for(Method, _Raw, Routes) ->
    case Routes of
        #{Method := Handler} -> {Handler, Method};
        _ -> none
    end.

dispatch_handler(
    TxnH,
    #{method := Method} = Meta,
    Raw,
    Handler,
    RouteKey,
    #state{middlewares = MW, workers = W} = S
) ->
    Max = chappe_sip_config:get(max_request_workers),
    case bad_event(Method, Raw) of
        {true, Events} ->
            reject_event(TxnH, Events, S);
        refer ->
            respond_txn(TxnH, 403, <<"Forbidden">>, <<>>, S),
            S;
        false when map_size(W) >= Max ->
            shed(TxnH, 503, <<"Service Unavailable">>, S),
            S;
        false ->
            case merge_check(TxnH, Method, Raw, S) of
                merged ->
                    respond_txn(TxnH, 482, <<"Loop Detected">>, S),
                    S;
                Key ->
                    index_merge(
                        Key,
                        TxnH,
                        spawn_worker(
                            TxnH,
                            Meta,
                            Raw,
                            Handler,
                            MW,
                            cfg_get({route_opts, RouteKey}, #{}),
                            S
                        )
                    )
            end
    end.

unrouted(_TxnH, <<"ACK">>, _Routes, S) ->
    %% ACK never needs an answer
    S;
unrouted(TxnH, <<"CANCEL">>, _Routes, S) ->
    %% nta answers a CANCEL matching one of our transactions; this one
    %% matches none (RFC 3261 9.2)
    respond_txn(TxnH, 481, <<"Call/Transaction Does Not Exist">>, S),
    S;
unrouted(TxnH, Method, Routes, S) ->
    %% respond_txn handles a WS or native transaction (a bare shed would
    %% send a WS txn to nta)
    {Status, Reason, Hdrs} = unhandled(Method, Routes),
    respond_txn(TxnH, Status, Reason, chappe_sip_hdr_io:join(Hdrs), S),
    S.

%% No handler for the method. OPTIONS is answered 200 with what we take,
%% as every UA must (RFC 3261 11); a method we know gets 405 and one we do
%% not 501 (21.4.5, 21.5.2), both with Allow.
unhandled(<<"OPTIONS">>, Routes) ->
    Events =
        case allow_events() of
            any ->
                [];
            [] ->
                [];
            Pkgs ->
                [
                    {<<"Allow-Events">>,
                        iolist_to_binary(lists:join(<<", ">>, Pkgs))}
                ]
        end,
    {200, <<"OK">>,
        [
            {<<"Allow">>, allow_value(Routes)},
            {<<"Accept">>, <<"application/sdp">>},
            {<<"Supported">>, ?SUPPORTED}
        ] ++ Events};
unhandled(Method, Routes) ->
    Allow = [{<<"Allow">>, allow_value(Routes)}],
    case lists:member(Method, ?KNOWN_METHODS) of
        true -> {405, <<"Method Not Allowed">>, Allow};
        false -> {501, <<"Not Implemented">>, Allow}
    end.

%% A SUBSCRIBE for a package the notifier does not serve, or with no Event
%% (the PINT default, never served), is answered 489 with the packages it
%% does serve (RFC 6665 4.2.1.1, 7.2.1, 8.3.2). An out-of-dialog SUBSCRIBE
%% for refer is refused 403.
bad_event(<<"SUBSCRIBE">>, Raw) ->
    case {event_package(Raw), allow_events()} of
        {<<"refer">>, _} ->
            %% a refer subscription exists only inside its REFER's dialog:
            %% out of dialog it matches none (RFC 3515 2.4.4)
            refer;
        {_, any} ->
            false;
        {Pkg, Events} ->
            case lists:member(Pkg, Events) of
                true -> false;
                false -> {true, Events}
            end
    end;
bad_event(_Method, _Raw) ->
    false.

reject_event(TxnH, Events, S) ->
    Hdr = chappe_sip_hdr_io:join([
        {<<"Allow-Events">>, iolist_to_binary(lists:join(<<", ">>, Events))}
    ]),
    respond_txn(TxnH, 489, <<"Bad Event">>, Hdr, S),
    S.

%% The event packages we serve: those registered with handle_package/3 and
%% those the SUBSCRIBE handler serves (chappe_sip:subscribe/2), or `any'
%% when that handler was registered without a list (or none serves any).
-spec allow_events() -> any | [binary()].
allow_events() ->
    Pkgs = lists:sort(maps:keys(cfg_get(packages, #{}))),
    case {cfg_get(events, undefined), Pkgs} of
        {any, _} -> any;
        {undefined, []} -> any;
        {undefined, _} -> Pkgs;
        {Events, _} -> lists:usort(Events ++ Pkgs)
    end.

event_package(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            case chappe_sip_msg:get(<<"event">>, Msg) of
                undefined ->
                    undefined;
                Ev ->
                    [Pkg | _] = binary:split(Ev, <<";">>),
                    string:lowercase(string:trim(Pkg))
            end;
        _ ->
            undefined
    end.

%% RFC 3261 8.2.2.2: a request with no To-tag whose From-tag, Call-ID and
%% CSeq match a transaction in progress but whose branch differs reached us
%% twice (a fork upstream): merged, 482. When that transaction is proxied
%% the request is a spiral through us (16.3) and goes on. Native
%% transactions only, the stack keys the WS ones by flow.
merge_check(TxnH, _Method, _Raw, _S) when ?IS_WS(TxnH) ->
    none;
merge_check(_TxnH, Method, _Raw, _S) when
    Method =:= <<"ACK">>; Method =:= <<"CANCEL">>
->
    none;
merge_check(_TxnH, _Method, Raw, #state{merge = Idx, proxied = Px}) ->
    case merge_key(Raw) of
        none ->
            none;
        {Key, Branch} ->
            case Idx of
                #{Key := {B, T, _}} when B =/= Branch ->
                    case maps:is_key(T, Px) of
                        true -> {Key, Branch};
                        false -> merged
                    end;
                _ ->
                    {Key, Branch}
            end
    end.

merge_key(Raw) ->
    case chappe_sip_msg:parse(Raw) of
        {ok, Msg} ->
            case
                {
                    chappe_sip_msg:to_tag(Msg),
                    chappe_sip_msg:from_tag(Msg),
                    chappe_sip_msg:cseq(Msg),
                    top_branch(Msg)
                }
            of
                {undefined, FT, {ok, #{seq := N, method := M}}, Branch} when
                    is_binary(FT), is_binary(Branch)
                ->
                    {{FT, chappe_sip_msg:call_id(Msg), N, M}, Branch};
                _ ->
                    none
            end;
        {error, _} ->
            none
    end.

top_branch(Msg) ->
    case chappe_sip_msg:get(<<"via">>, Msg) of
        undefined ->
            undefined;
        V ->
            [Top | _] = chappe_sip_hdr:split_list(V) ++ [V],
            case chappe_sip_hdr:via(Top) of
                {ok, #{params := #{<<"branch">> := B}}} when is_binary(B) -> B;
                _ -> undefined
            end
    end.

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

%% the methods we take out of dialog: those with a handler, plus the ones
%% the stack answers itself (ACK, CANCEL, BYE in a dialog, OPTIONS)
allow_value(Routes) ->
    Packages = [<<"SUBSCRIBE">> || map_size(cfg_get(packages, #{})) > 0],
    Methods = lists:usort(
        maps:keys(Routes) ++ Packages ++
            [<<"ACK">>, <<"BYE">>, <<"CANCEL">>, <<"OPTIONS">>, <<"NOTIFY">>]
    ),
    iolist_to_binary(lists:join(<<", ">>, Methods)).

%% True when the top Route header targets this proxy (a request the far end
%% loose-routed back to us after we record-routed the dialog). Gated on a
%% cheap byte scan so requests without a Route header skip the parse.
is_own_route(Raw, Contact) ->
    case binary:match(Raw, <<"espx=">>) of
        nomatch ->
            false;
        _ ->
            case chappe_sip_msg:parse(Raw) of
                {ok, Msg} ->
                    CallId = chappe_sip_msg:call_id(Msg),
                    case chappe_sip_route:routes(Msg) of
                        [Top | _] ->
                            chappe_sip_route:is_self(Top, Contact, CallId) orelse
                                %% behind a strict router our Record-Route
                                %% is the Request-URI (RFC 3261 16.4)
                                chappe_sip_route:uri_is_self(
                                    chappe_sip_msg:uri(Msg), CallId
                                );
                        [] ->
                            false
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
            {error, _} -> ok;
            _ -> chappe_sip_cdr:txn_response(TxnH, Status)
        end,
    Result.

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
