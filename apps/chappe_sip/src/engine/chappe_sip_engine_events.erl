%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The events of the native stack and the WS transport, as
%% chappe_sip_engine handles them.
%%
%% An event for a handle goes to the process the handle table names. An
%% out-of-dialog request is dispatched: forwarded by the proxy when it
%% carries our own Record-Route, else answered by the stack's policy
%% (chappe_sip_dispatch) or given to a new request worker that runs the
%% middleware and the handler. Runs inside the engine process, on its
%% #state{} (chappe_sip_engine.hrl).
-module(chappe_sip_engine_events).

-include("chappe_sip_engine.hrl").

-export([handle_event/2]).

%% One event of the stack or the WS transport (chappe_sip_nif lists them).
-spec handle_event(term(), #state{}) -> #state{}.
handle_event({health_ok, _Seq}, #state{health_waiters = W} = S) ->
    [gen_server:reply(From, ok) || From <- W],
    S#state{misses = 0, health_waiters = []};
handle_event({log, Level, Text}, S) ->
    logger:log(log_level(Level), "chappe_sip_engine: ~s", [Text]),
    S;
handle_event({flow_closed, Id}, S) ->
    %% a TCP/TLS connection a binding was learned on closed: RFC 5626 7
    ok = chappe_sip_engine_conns:closed(Id),
    chappe_sip_registry:remove_flow({conn, Id}),
    S;
handle_event({started, Contact}, S) ->
    logger:info("chappe_sip_engine: SIP stack up at ~s", [Contact]),
    S#state{contact = Contact};
handle_event({request, TxnH, undefined, Meta, Raw}, S) ->
    %% out-of-dialog request
    ok = chappe_sip_metrics:request(in, maps:get(method, Meta, undefined)),
    dispatch(TxnH, Meta, Raw, S);
handle_event({request, TxnH, LegH, Meta, Raw}, S) ->
    %% in-dialog request: route to the owning dialog fsm
    ok = chappe_sip_metrics:request(in, maps:get(method, Meta, undefined)),
    _ = indialog(TxnH, LegH, Meta, Raw, S),
    S;
handle_event({ack, LegH, Raw}, S) ->
    _ =
        to_owner(LegH, {chappe_sip_ack, LegH, Raw}, S) orelse
            stray_ack(LegH, Raw, S),
    S;
handle_event({ack_timeout, H}, S) ->
    %% our 2xx to an INVITE was never ACKed (Timer H)
    _ = to_owner(H, {chappe_sip_ack_timeout, H}, S),
    S;
handle_event({cancel, TxnH}, S) ->
    handle_event({cancel, TxnH, <<>>}, S);
handle_event({cancel, TxnH, Raw}, S) ->
    %% the CANCEL request goes along so the app sees its Reason (RFC 3326)
    Req = cancel_req(Raw),
    _ = to_owner(TxnH, {chappe_sip_cancel, TxnH, Req}, S),
    cancelled(TxnH, Req, S),
    S;
handle_event({flow_lost, Legs}, S) ->
    %% a WS connection closed: the dialogs bound to it are gone
    _ = [to_owner(L, {chappe_sip_flow_lost, L}, S) || L <- Legs],
    S;
handle_event({prack, TxnH, Raw}, S) ->
    %% PRACK for a reliable provisional: route to the INVITE's owner
    _ = to_owner(TxnH, {chappe_sip_prack, TxnH, Raw}, S),
    S;
handle_event({prack, TxnH, Raw, PrackH}, S) ->
    %% a PRACK with an offer (RFC 3262 5): the INVITE's owner answers it
    %% through the PRACK's own handle
    _ =
        to_owner(TxnH, {chappe_sip_prack, TxnH, Raw, PrackH}, S) orelse
            reply(PrackH, 500, <<"Server Internal Error">>, <<>>, S),
    S;
handle_event({response, TxnH, Meta, Raw}, S) ->
    ok = chappe_sip_metrics:response(in, maps:get(status, Meta, undefined)),
    _ = to_owner(TxnH, {chappe_sip_response, TxnH, Meta, Raw}, S),
    S;
handle_event({op_ok, H}, S) ->
    _ = to_owner(H, {chappe_sip_op, H, ok}, S),
    S;
handle_event({op_failed, H, Reason}, S) ->
    _ = to_owner(H, {chappe_sip_op, H, {error, Reason}}, S),
    S;
handle_event(Event, S) ->
    logger:debug("chappe_sip_engine: unhandled event ~p", [Event]),
    S.

%% send Msg to the process that owns handle H; false when none does
to_owner(H, Msg, #state{handles = HM}) ->
    case HM of
        #{H := Pid} ->
            Pid ! Msg,
            true;
        _ ->
            false
    end.

indialog(TxnH, LegH, Meta, Raw, S) ->
    to_owner(LegH, {chappe_sip_indialog, LegH, TxnH, Meta, Raw}, S) orelse
        no_leg(TxnH, Meta, S).

%% in-dialog request for a dialog we no longer have: RFC 3261 12.2.2
%% answers 481 rather than letting it time out (an ACK has no response, so
%% drop that one)
no_leg(_TxnH, #{method := <<"ACK">>}, _S) ->
    ok;
no_leg(TxnH, _Meta, S) ->
    no_dialog(TxnH, S).

%% no dialog leg: a 2xx ACK routed through us as a record-routing proxy is
%% forwarded to the next hop; anything else is stray
stray_ack(LegH, Raw, #state{contact = Contact}) ->
    chappe_sip_dispatch:is_own_route(Raw, Contact) andalso
        chappe_sip_engine_backend:forward_ack(
            chappe_sip_engine_backend:forwarder(), LegH, Raw
        ).

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

%% A request carrying our own Record-Route on top is in-dialog traffic for a
%% dialog we record-routed; the proxy forwards it instead of a local
%% handler. Otherwise dispatch to the registered method handler.
dispatch(TxnH, Meta, Raw, #state{contact = Contact} = S) ->
    case
        {
            chappe_sip_engine_backend:forwarder(),
            chappe_sip_dispatch:is_own_route(Raw, Contact)
        }
    of
        {Fwd, true} when Fwd =/= undefined ->
            forward(Fwd, TxnH, Meta, Raw, S);
        _ ->
            dispatch_local(TxnH, Meta, Raw, S)
    end.

forward(Fwd, TxnH, Meta, Raw, #state{workers = W} = S) ->
    case map_size(W) >= chappe_sip_config:get(max_request_workers) of
        true ->
            busy(TxnH, S);
        false ->
            Handler = chappe_sip_engine_backend:forward_handler(Fwd),
            %% a proxy: Require is the far UAS's (RFC 3261 16)
            spawn_worker(TxnH, Meta, Raw, Handler, [], #{role => proxy}, S)
    end.

dispatch_local(TxnH, #{method := Method} = Meta, Raw, S) ->
    case chappe_sip_dispatch:stray_in_dialog(Method, Raw) of
        true ->
            %% RFC 3261 12.2.2 and 15.1.2: a request for a dialog we do not
            %% have is not a new one
            no_dialog(TxnH, S),
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
            reply(TxnH, 403, <<"Forbidden">>, <<>>, S),
            S;
        false when map_size(S#state.workers) >= Max ->
            busy(TxnH, S);
        false ->
            run_handler(TxnH, Meta, Raw, Handler, Key, S)
    end.

run_handler(TxnH, #{method := Method} = Meta, Raw, Handler, RouteKey, S) ->
    case merge_check(TxnH, Method, Raw, S) of
        merged ->
            reply(TxnH, 482, <<"Loop Detected">>, <<>>, S),
            S;
        Key ->
            RouteOpts = chappe_sip_engine_opts:cfg_get(
                {route_opts, RouteKey}, #{}
            ),
            MW = S#state.middlewares,
            index_merge(
                Key,
                TxnH,
                spawn_worker(TxnH, Meta, Raw, Handler, MW, RouteOpts, S)
            )
    end.

unrouted(TxnH, Method, Routes, S) ->
    case chappe_sip_dispatch:unrouted(Method, Routes, events()) of
        noreply ->
            S;
        {Status, Reason, Hdrs} ->
            Joined = chappe_sip_hdr_io:join(Hdrs),
            reply(TxnH, Status, Reason, Joined, S),
            S
    end.

reject_event(TxnH, Events, S) ->
    Hdr = chappe_sip_hdr_io:join([chappe_sip_dispatch:event_header(Events)]),
    reply(TxnH, 489, <<"Bad Event">>, Hdr, S),
    S.

%% the event packages registered, and the events of the SUBSCRIBE handler
events() ->
    {
        chappe_sip_engine_opts:cfg_get(packages, #{}),
        chappe_sip_engine_opts:cfg_get(events, undefined)
    }.

%% merged requests (chappe_sip_dispatch:merge_check/4), native
%% transactions only: the stack keys the WS ones by flow
merge_check(TxnH, Method, Raw, #state{merge = Idx, proxied = Px}) ->
    case chappe_sip_ws:is_ws(TxnH) of
        true -> none;
        false -> chappe_sip_dispatch:merge_check(Method, Raw, Idx, Px)
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

spawn_worker(TxnH, Meta, Raw, Handler, MW, RouteOpts, S) ->
    #state{mod = Mod, engine = Engine, workers = W, handles = HM} = S,
    FinalRef = atomics:new(1, []),
    Res = chappe_sip_res:new(
        TxnH, chappe_sip_engine_backend:sender(Mod, Engine), FinalRef
    ),
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
            reply(TxnH, 500, <<"Server Internal Error">>, <<>>, S),
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

%% RFC 3261 12.2.2: no such dialog
no_dialog(TxnH, S) ->
    reply(TxnH, 481, <<"Call/Transaction Does Not Exist">>, <<>>, S).

%% overload: past max_request_workers the request is shed
busy(TxnH, S) ->
    reply(TxnH, 503, <<"Service Unavailable">>, <<>>, S),
    S.

%% Answer a request the node will not process. The transaction may live in
%% the WS transport, and a WS-only node has no native engine at all.
reply(TxnH, Status, Reason, Headers, #state{mod = Mod, engine = Engine}) ->
    chappe_sip_engine_backend:respond_txn(
        Mod, Engine, TxnH, Status, Reason, Headers
    ).

log_level(0) -> emergency;
log_level(1) -> alert;
log_level(2) -> critical;
log_level(3) -> error;
log_level(4) -> warning;
log_level(5) -> notice;
log_level(6) -> info;
log_level(_) -> debug.
