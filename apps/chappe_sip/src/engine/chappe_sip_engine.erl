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
%% chappe_sip_engine_fake in tests). Its helpers, all running in this
%% process: chappe_sip_engine_opts (the start options and the snapshot),
%% chappe_sip_engine_backend (every call to the backend, the WS transport
%% and the forwarder), chappe_sip_engine_events (the stack's events and the
%% inbound dispatch), chappe_sip_engine_handles (the handle table and the
%% dialogs) and chappe_sip_engine_conns (the connections that closed).
-module(chappe_sip_engine).
-behaviour(gen_server).

-include("chappe_sip.hrl").
-include("chappe_sip_engine.hrl").

-export([start_link/0]).
-export([
    start/1,
    stop/0,
    use/2,
    handle/3,
    reset_routes/0
]).
-ifdef(TEST).
-export([restart_engine/0, check_health/1]).
-endif.
%% the guard's drop (chappe_sip_guard)
-export([discard/1, block_source/2, stats/0]).
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

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Bring the SIP stack up. Opts: #{contact := binary(), ...}
-spec start(map()) -> ok | {error, already_started | term()}.
start(Opts) when is_map(Opts) ->
    gen_server:call(?MODULE, {lifecycle, {start, Opts}}, 30000).

-spec stop() -> ok | {error, not_started | hung}.
stop() ->
    gen_server:call(?MODULE, {lifecycle, stop}, 15000).

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

%% gen_server

init([]) ->
    process_flag(trap_exit, true),
    %% restore routes/middleware persisted before a crash so the re-established
    %% engine keeps its handlers (routing is entirely Erlang-side)
    S = #state{
        mod = chappe_sip_config:get(engine_mod),
        routes = chappe_sip_engine_opts:cfg_get(routes, #{}),
        middlewares = chappe_sip_engine_opts:cfg_get(middlewares, [])
    },
    case chappe_sip_engine_opts:cfg_get(opts, undefined) of
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
%% stack's lifecycle, the routes, the handle table
%% (chappe_sip_engine_handles), the transactions, and what the engine
%% tells about itself.
handle_call({lifecycle, Op}, From, S) ->
    lifecycle(Op, From, S);
handle_call({routes, Op}, _From, S) ->
    routes(Op, S);
handle_call({handles, Op}, From, S) ->
    chappe_sip_engine_handles:handle(Op, From, S);
handle_call({txn, Op}, _From, S) ->
    txn(Op, S);
handle_call({info, Op}, _From, S) ->
    info(Op, S).

lifecycle({start, _}, _From, #state{engine = E} = S) when E =/= undefined ->
    {reply, {error, already_started}, S};
lifecycle({start, Opts}, _From, S) ->
    case chappe_sip_engine_opts:start_opts(Opts) of
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
    Result = chappe_sip_engine_backend:stop(Mod, Engine),
    %% a clean stop must not auto-reestablish on a later process crash
    chappe_sip_engine_opts:cfg_del(opts),
    publish(#{}),
    {reply, Result, stack_down(S)};
lifecycle(check_health, _From, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
lifecycle(
    check_health,
    From,
    #state{mod = Mod, engine = Engine, health_waiters = W} = S
) ->
    ok = chappe_sip_engine_backend:health(Mod, Engine),
    {noreply, S#state{health_waiters = [From | W]}}.

started(NOpts, S) ->
    case bring_up(NOpts, S) of
        {ok, S1} ->
            chappe_sip_engine_opts:cfg_put(opts, NOpts),
            publish(NOpts),
            {reply, ok, S1#state{engine_opts = NOpts}};
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end.

restart(#state{mod = Mod, engine = Engine, engine_opts = Opts} = S) ->
    %% tell dialogs and UAC fsms their SIP state is going away, so an
    %% in-flight transaction fails cleanly instead of waiting for a reply
    %% that the new native stack will never deliver
    stack_gone(S),
    _ = chappe_sip_engine_backend:stop(Mod, Engine),
    S1 = stack_down(S),
    case bring_up(Opts, S1) of
        {ok, S2} -> {reply, ok, S2};
        {error, Reason} -> {reply, {error, Reason}, S1}
    end.

%% crash-restart recovery: bring the native stack back from persisted opts
reestablish(Opts, S) ->
    case bring_up(Opts, S) of
        {ok, S1} ->
            logger:info(
                "chappe_sip_engine: re-established the SIP stack after a "
                "restart"
            ),
            publish(Opts),
            S1;
        {error, Reason} ->
            logger:error(
                "chappe_sip_engine: re-establish failed (~p); retrying",
                [Reason]
            ),
            _ = erlang:send_after(1000, self(), reestablish),
            S
    end.

%% start the native stack with Opts and schedule its first health check
bring_up(Opts, #state{mod = Mod} = S) ->
    Retries = chappe_sip_config:get(engine_start_retries),
    case start_engine(Mod, Opts, Retries, 100) of
        {ok, Engine} ->
            {ok, S#state{
                engine = Engine,
                tref = schedule_health(Engine),
                misses = 0
            }};
        {error, _} = Err ->
            Err
    end.

%% a route registration, kept in the snapshot too
routes(Op, #state{routes = R, middlewares = MW} = S) ->
    {R1, MW1} = chappe_sip_engine_opts:routes(Op, R, MW),
    {reply, ok, S#state{routes = R1, middlewares = MW1}}.

%% the transactions: a WS handle goes to the transport, a native one to
%% the engine backend, which a WS-only node (or a stopped stack) lacks
txn({dialog_respond, TxnH, Status, Reason, Headers, Body, ToTag}, S) ->
    #state{mod = Mod, engine = E} = S,
    {reply,
        chappe_sip_engine_backend:respond(
            Mod, E, TxnH, Status, Reason, Headers, Body, ToTag
        ),
        S};
txn({send_request, {ws, Flow}, Raw, Pid, _Opts}, S) ->
    originated(
        chappe_sip_engine_backend:ws_request(Flow, Raw, Pid), Raw, Pid, S
    );
txn({send_request, _, _, _, _}, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
txn({send_request, Route, Raw, Pid, Opts}, S) ->
    native_request(Route, Raw, Pid, Opts, S);
txn({send_stateless, {ws, Flow}, Raw, _Pid}, S) ->
    _ = chappe_sip_engine_backend:ws_send(Flow, Raw),
    {reply, {ok, ws_ack}, S};
txn({send_stateless, _, _, _}, #state{engine = undefined} = S) ->
    {reply, {error, not_started}, S};
txn({send_stateless, Route, Raw, Pid}, #state{mod = Mod, engine = E} = S) ->
    %% fire-and-forget (a 2xx ACK / stateless BYE): no response is expected,
    %% so do not retain a handle route (it would linger until the owner
    %% exits)
    Local = maps:get(Pid, S#state.locals, undefined),
    Ident = chappe_sip_binds:send_ident(Route, Local),
    {reply, chappe_sip_engine_backend:send(Mod, E, Route, Raw, Ident), S};
txn({cancel_txn, TxnH, Hdrs}, #state{mod = Mod, engine = E} = S) ->
    {reply, chappe_sip_engine_backend:cancel(Mod, E, TxnH, Hdrs), S};
txn({relay_response, ServerTxnH, Status, Raw}, S) ->
    relay(ServerTxnH, Status, Raw, S);
txn({forward_response, Raw}, #state{mod = Mod, engine = E} = S) ->
    {reply, chappe_sip_engine_backend:forward_response(Mod, E, Raw), S}.

%% a WS server transaction, or a native one of a running stack (a proxy
%% may still run after the stack was stopped)
relay(TxnH, Status, Raw, #state{mod = Mod, engine = E} = S) ->
    case chappe_sip_ws:is_ws(TxnH) orelse E =/= undefined of
        true ->
            R = chappe_sip_engine_backend:relay(Mod, E, TxnH, Status, Raw),
            {reply, R, relayed(TxnH, Status, S)};
        false ->
            {reply, {error, not_started}, S}
    end.

%% a final response relayed upstream ends the server transaction's route
relayed(ServerTxnH, Status, #state{handles = HM} = S) when Status >= 200 ->
    S#state{handles = maps:remove(ServerTxnH, HM)};
relayed(_ServerTxnH, _Status, S) ->
    S.

native_request(Route, Raw, Pid, Opts, #state{mod = Mod, engine = E} = S) ->
    %% a local option sets the address Pid sends from from now on
    Locals =
        case maps:get(local, Opts, undefined) of
            undefined -> S#state.locals;
            L -> (S#state.locals)#{Pid => L}
        end,
    Ident = chappe_sip_binds:send_ident(
        Route, maps:get(Pid, Locals, undefined)
    ),
    Branch = maps:get(branch, Opts, undefined),
    case chappe_sip_engine_backend:request(Mod, E, Route, Raw, Branch, Ident) of
        {ok, _} = Sent -> originated(Sent, Raw, Pid, S#state{locals = Locals});
        Err -> {reply, Err, S}
    end.

%% a worker that originates a request (proxy fork / UAC) is a long-lived
%% owner; disarm its deadline and monitor a UAC fsm so its crash sweeps
%% this handle
originated({ok, TxnH}, Raw, Pid, S) ->
    ok = chappe_sip_metrics:request(
        out, chappe_sip_engine_backend:raw_method(Raw)
    ),
    S1 = chappe_sip_engine_handles:ensure_monitored(
        Pid, chappe_sip_engine_handles:disarm_deadline(Pid, S)
    ),
    {reply, {ok, TxnH}, S1#state{handles = (S1#state.handles)#{TxnH => Pid}}};
originated(Err, _Raw, _Pid, S) ->
    {reply, Err, S}.

info({block_source, Addr, Ms}, #state{mod = Mod} = S) ->
    {reply, chappe_sip_engine_backend:block(Mod, Addr, Ms), S};
info(stats, #state{mod = Mod} = S) ->
    {reply, chappe_sip_engine_backend:stats(Mod), S};
info(contact, #state{contact = C} = S) ->
    {reply, C, S};
info(tls_contact, #state{engine_opts = Opts, contact = C} = S) ->
    {reply, chappe_sip_engine_opts:tls_uri(Opts, C), S}.

handle_cast({destroy_leg, LegH}, S) ->
    {noreply, release(LegH, fun chappe_sip_engine_backend:leg_destroy/3, S)};
handle_cast({finish_txn, TxnH}, S) ->
    {noreply, release(TxnH, fun chappe_sip_engine_backend:finish/3, S)};
handle_cast({discard, TxnH}, S) ->
    {noreply, discard_txn(TxnH, S)};
handle_cast(_Msg, S) ->
    {noreply, S}.

%% a WS handle, or a native one of a running stack, released and no
%% longer routed
release(H, Op, #state{mod = Mod, engine = E, handles = HM} = S) ->
    case chappe_sip_ws:is_ws(H) orelse E =/= undefined of
        true ->
            _ = Op(Mod, E, H),
            S#state{handles = maps:remove(H, HM)};
        false ->
            S
    end.

discard_txn(TxnH, #state{mod = Mod, engine = E} = S) ->
    _ =
        case chappe_sip_ws:is_ws(TxnH) of
            true ->
                chappe_sip_engine_backend:finish(Mod, E, TxnH);
            false when E =:= undefined ->
                ok;
            false ->
                _ = chappe_sip_engine_backend:discard(Mod, E, TxnH),
                %% a dropped request waits 64*T1 for the 408 that ends it
                erlang:send_after(
                    chappe_sip_config:t64(), self(), {discard_end, E, TxnH}
                )
        end,
    S.

handle_info(
    reestablish, #state{engine = undefined, engine_opts = Opts} = S
) when map_size(Opts) > 0 ->
    {noreply, reestablish(Opts, S)};
handle_info(reestablish, S) ->
    {noreply, S};
handle_info({chappe_sip_engine, ws, Event}, S) ->
    %% events from the WS transport share the engine dispatch/handle_event
    {noreply, chappe_sip_engine_events:handle_event(Event, S)};
handle_info({chappe_sip_engine, Engine, Event}, #state{engine = Engine} = S) ->
    {noreply, chappe_sip_engine_events:handle_event(Event, S)};
handle_info({chappe_sip_engine, _Stale, _Event}, S) ->
    %% event from a previous engine instance racing its teardown; drop
    {noreply, S};
handle_info({health_tick, Engine}, #state{engine = Engine} = S) ->
    health_tick(S);
handle_info({health_tick, _Stale}, S) ->
    {noreply, S};
handle_info({worker_deadline, Pid}, S) ->
    ok = worker_deadline(Pid, S),
    {noreply, S};
handle_info({'DOWN', MRef, process, Pid, Reason}, S) ->
    {noreply, chappe_sip_engine_handles:down(MRef, Pid, Reason, S)};
handle_info(
    {discard_end, Engine, TxnH}, #state{mod = Mod, engine = Engine} = S
) ->
    _ = chappe_sip_engine_backend:discard_end(Mod, Engine, TxnH),
    {noreply, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #state{engine = undefined}) ->
    ok;
terminate(_Reason, #state{mod = Mod, engine = Engine}) ->
    _ = chappe_sip_engine_backend:stop(Mod, Engine),
    ok.

%% The tick carries the engine ref so ticks from a torn-down instance
%% are ignored by the handle_info match.
health_tick(#state{engine = Engine, mod = Mod, misses = M} = S) ->
    case M >= chappe_sip_config:get(health_miss_limit) of
        true ->
            engine_failed(S);
        false ->
            ok = chappe_sip_engine_backend:health(Mod, Engine),
            {noreply, S#state{misses = M + 1, tref = schedule_health(Engine)}}
    end.

worker_deadline(Pid, #state{workers = W}) ->
    case W of
        #{Pid := {_, TxnH, _, DTRef}} when DTRef =/= undefined ->
            logger:warning("chappe_sip: handler deadline expired for txn ~p", [
                TxnH
            ]),
            %% the DOWN handler answers 500 if nothing final went out
            exit(Pid, kill),
            ok;
        _ ->
            %% disarmed (became a call owner / proxy) or already gone
            ok
    end.

%% internal: engine lifecycle

start_engine(_Mod, _Opts, 0, _Backoff) ->
    {error, engine_stuck_stopping};
start_engine(Mod, Opts, Retries, Backoff) ->
    case chappe_sip_engine_backend:start(Mod, Opts) of
        {ok, Engine} ->
            %% the connections of a previous engine are gone, and so are
            %% the bindings learned on them
            ok = chappe_sip_engine_conns:clear(),
            chappe_sip_registry:remove_conn_flows(),
            {ok, Engine};
        {error, stopping} ->
            %% a previous instance is tearing down; starts are serialized
            %% through the C atomic guard
            retry_start(Mod, Opts, Retries, Backoff);
        {error, replacing} ->
            %% chappe_sip_nif:replace/0 holds the slot until the new library
            %% is loaded
            retry_start(Mod, Opts, Retries, Backoff);
        {error, Reason} ->
            {error, Reason}
    end.

retry_start(Mod, Opts, Retries, Backoff) ->
    timer:sleep(Backoff),
    start_engine(Mod, Opts, Retries - 1, min(Backoff * 2, 5000)).

%% what the Erlang side reads of the running stack's options: its listen
%% addresses and aliases, and T1, which the 64*T1 timers kept in Erlang
%% follow (chappe_sip_config:t64/0)
publish(Opts) ->
    ok = chappe_sip_config:set_t1(maps:get(sip_t1, Opts, 500)),
    chappe_sip_binds:publish(Opts).

engine_failed(#state{mod = Mod, engine = Engine} = S) ->
    logger:critical(
        "chappe_sip_engine: stack thread unresponsive, applying failure action"
    ),
    _ = chappe_sip_engine_backend:stop(Mod, Engine),
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
    _ = [
        Pid ! {chappe_sip_engine_restart, undefined}
     || Pid <- maps:keys(Dialogs) ++ maps:keys(Monitored)
    ],
    ok.

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
            chappe_sip_engine_handles:cancel_deadline(DTRef),
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

-ifdef(TEST).
%% Controlled restart of the SIP engine: tear down live dialogs (owners
%% get {destroy, engine_restart}), stop and restart the NIF engine with
%% the same options, and keep routes/middleware. All SIP state is lost.
-spec restart_engine() -> ok | {error, term()}.
restart_engine() ->
    gen_server:call(?MODULE, {lifecycle, restart_engine}, 30000).

%% Force one health round-trip through the stack thread event loop.
-spec check_health(timeout()) -> ok | {error, timeout | not_started}.
check_health(Timeout) ->
    try
        gen_server:call(?MODULE, {lifecycle, check_health}, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout}
    end.
-endif.
