%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Every call chappe_sip_engine makes out to a pluggable module: the
%% engine backend (Mod, chappe_sip_nif in production, chappe_sip_engine_fake
%% in tests), the WS transport, and the proxy registered as the forwarder.
%%
%% A handle in the WS range (chappe_sip_ws:is_ws/1) goes to
%% chappe_sip_ws_transport, any other to Mod with the running Engine. With
%% no Engine (a WS-only node, a stopped stack) a native operation answers
%% {error, not_started} or does nothing, as each function says. The calls
%% hold no state: chappe_sip_engine keeps the handle table.
-module(chappe_sip_engine_backend).

-export([start/2, stop/2, health/2, block/3, stats/1, proxy_mark/3]).
-export([discard/3, discard_end/3, finish/3, destroy_handle/3]).
-export([respond/8, respond_txn/6, relay/5, forward_response/3]).
-export([request/6, ws_request/3, send/5, ws_send/2, cancel/4]).
-export([leg_create/6, leg_destroy/3]).
-export([sender/2, native_route/1, raw_method/1]).
-export([forwarder/1, forwarder/0, forward_handler/1, forward_ack/3]).

%% where a dialog leg goes: the WS transport over a flow, or the native
%% stack
-type where() :: {ws, integer() | undefined} | native.
-export_type([where/0]).

%% lifecycle and the guard

-spec start(module(), map()) -> {ok, term()} | {error, term()}.
start(Mod, Opts) ->
    Mod:start(Opts, self()).

-spec stop(module(), term()) -> term().
stop(Mod, Engine) ->
    Mod:stop(Engine).

-spec health(module(), term()) -> ok.
health(Mod, Engine) ->
    Mod:health(Engine).

-spec block(module(), binary(), non_neg_integer()) -> ok.
block(Mod, Addr, Ms) ->
    Mod:block(Addr, Ms).

-spec stats(module()) -> chappe_sip_nif:stats().
stats(Mod) ->
    Mod:stats().

-spec proxy_mark(module(), term(), non_neg_integer()) -> term().
proxy_mark(Mod, Engine, TxnH) ->
    Mod:proxy_mark(Engine, TxnH).

%% a native server transaction dropped without an answer
-spec discard(module(), term(), non_neg_integer()) -> term().
discard(Mod, Engine, TxnH) ->
    Mod:discard(Engine, TxnH).

%% the 408 that ends a discarded transaction once its client gave up
-spec discard_end(module(), term(), non_neg_integer()) -> term().
discard_end(Mod, Engine, TxnH) ->
    Mod:respond(Engine, TxnH, 408, <<"Request Timeout">>, <<>>, <<>>, <<>>).

%% release a transaction handle
-spec finish(module(), term(), non_neg_integer()) -> term().
finish(Mod, Engine, H) ->
    case chappe_sip_ws:is_ws(H) of
        true -> chappe_sip_ws_transport:finish_txn(H);
        false when Engine =:= undefined -> ok;
        false -> Mod:txn_done(Engine, H)
    end.

%% A handle a dead owner held is a leg or a transaction; the wrong call is
%% a no-op, so issue both.
-spec destroy_handle(module(), term(), non_neg_integer()) -> ok.
destroy_handle(Mod, Engine, H) ->
    _ = finish(Mod, Engine, H),
    _ = leg_destroy(Mod, Engine, H),
    ok.

%% responses

%% A response on a server transaction, with a dialog tag or <<>>.
-spec respond(
    module(),
    term(),
    non_neg_integer(),
    100..699,
    binary(),
    binary(),
    binary(),
    binary()
) -> term().
respond(Mod, Engine, TxnH, Status, Reason, Headers, Body, ToTag) ->
    sent(
        TxnH,
        Status,
        case chappe_sip_ws:is_ws(TxnH) of
            true ->
                ws_call(fun() ->
                    chappe_sip_ws_transport:respond(
                        TxnH, Status, Reason, Headers, Body, ToTag
                    )
                end);
            false when Engine =:= undefined ->
                {error, not_started};
            false ->
                Mod:respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag)
        end
    ).

%% Answer a request with no body and no tag, whatever the outcome.
%% Headers is a header blob (an Allow on a 405).
-spec respond_txn(
    module(), term(), non_neg_integer(), 100..699, binary(), binary()
) -> ok.
respond_txn(Mod, Engine, TxnH, Status, Reason, Headers) ->
    _ = respond(Mod, Engine, TxnH, Status, Reason, Headers, <<>>, <<>>),
    ok.

%% Proxy: relay a downstream response upstream on a server transaction
%% (a WS one, or a native one of a running Engine).
-spec relay(module(), term(), non_neg_integer(), 100..699, binary()) ->
    term().
relay(Mod, Engine, TxnH, Status, Raw) ->
    sent(
        TxnH,
        Status,
        case chappe_sip_ws:is_ws(TxnH) of
            true ->
                ws_call(fun() ->
                    chappe_sip_ws_transport:relay(TxnH, Status, Raw)
                end);
            false ->
                Mod:relay(Engine, TxnH, Status, Raw)
        end
    ).

-spec forward_response(module(), term(), binary()) -> term().
forward_response(_Mod, undefined, _Raw) ->
    {error, not_started};
forward_response(Mod, Engine, Raw) ->
    Mod:send_response(Engine, Raw).

%% requests

%% A request on the native stack, with an optional Via branch and the
%% ident of the listen address it leaves from.
-spec request(
    module(),
    term(),
    chappe_sip_engine:route(),
    binary(),
    binary() | undefined,
    binary() | undefined
) -> {ok, non_neg_integer()} | {error, term()}.
request(Mod, Engine, Route, Raw, Branch, Ident) ->
    NRoute = native_route(Route),
    case {Branch, Ident} of
        {undefined, undefined} -> Mod:request(Engine, NRoute, Raw);
        {_, undefined} -> Mod:request(Engine, NRoute, Raw, Branch);
        {undefined, _} -> Mod:request(Engine, NRoute, Raw, <<>>, Ident);
        {_, _} -> Mod:request(Engine, NRoute, Raw, Branch, Ident)
    end.

-spec ws_request(integer(), binary(), pid()) ->
    {ok, non_neg_integer()} | {error, term()}.
ws_request(Flow, Raw, Pid) ->
    ws_call(fun() -> chappe_sip_ws_transport:send_request(Flow, Raw, Pid) end).

%% fire-and-forget on the native stack (a 2xx ACK, a stateless BYE)
-spec send(
    module(), term(), chappe_sip_engine:route(), binary(), binary() | undefined
) -> term().
send(Mod, Engine, Route, Raw, undefined) ->
    Mod:send(Engine, native_route(Route), Raw);
send(Mod, Engine, Route, Raw, Ident) ->
    Mod:send(Engine, native_route(Route), Raw, Ident).

-spec ws_send(integer(), binary()) -> term().
ws_send(Flow, Raw) ->
    chappe_sip_ws_transport:send_stateless(Flow, Raw).

%% CANCEL an INVITE client transaction, with extra headers or none
-spec cancel(module(), term(), non_neg_integer(), [{binary(), iodata()}]) ->
    ok | {error, term()}.
cancel(Mod, Engine, TxnH, Hdrs) ->
    case {chappe_sip_ws:is_ws(TxnH), Hdrs} of
        {true, _} ->
            _ = chappe_sip_ws_transport:cancel(
                TxnH, chappe_sip_hdr_io:join(Hdrs)
            ),
            ok;
        {false, _} when Engine =:= undefined ->
            %% a UAC still running after the stack was stopped
            {error, not_started};
        {false, []} ->
            Mod:cancel(Engine, TxnH);
        {false, _} ->
            Mod:cancel(Engine, TxnH, chappe_sip_hdr_io:join(Hdrs))
    end.

%% dialog legs

%% Create a dialog leg in the WS transport (over Flow) or the native stack.
-spec leg_create(module(), term(), where(), binary(), binary(), binary()) ->
    {ok, non_neg_integer()} | {error, term()}.
leg_create(_Mod, _Engine, {ws, Flow}, CallId, LocalAddr, RemoteAddr) ->
    ws_call(fun() ->
        chappe_sip_ws_transport:leg_create(CallId, LocalAddr, RemoteAddr, Flow)
    end);
leg_create(_Mod, undefined, native, _CallId, _LocalAddr, _RemoteAddr) ->
    {error, not_started};
leg_create(Mod, Engine, native, CallId, LocalAddr, RemoteAddr) ->
    Mod:leg_create(Engine, CallId, LocalAddr, RemoteAddr).

-spec leg_destroy(module(), term(), non_neg_integer()) -> term().
leg_destroy(Mod, Engine, LegH) ->
    case chappe_sip_ws:is_ws(LegH) of
        true -> chappe_sip_ws_transport:leg_destroy(LegH);
        false when Engine =:= undefined -> ok;
        false -> Mod:leg_destroy(Engine, LegH)
    end.

%% the request workers' sender

%% The sender fun runs in the worker process; the NIF respond call is
%% enqueue-only and safe from any process.
-spec sender(module(), term()) ->
    fun((non_neg_integer(), 100..699, map()) -> term()).
sender(Mod, Engine) ->
    fun(TxnH, Status, Opts) ->
        sent(TxnH, Status, sender_send(Mod, Engine, TxnH, Status, Opts))
    end.

sender_send(Mod, Engine, TxnH, Status, Opts) ->
    Reason = maps:get(reason, Opts, <<>>),
    Headers = chappe_sip_hdr_io:join(maps:get(headers, Opts, [])),
    Body = iolist_to_binary(maps:get(body, Opts, <<>>)),
    ToTag = maps:get(to_tag, Opts, <<>>),
    Reliable = maps:get(reliable, Opts, false),
    case chappe_sip_ws:is_ws(TxnH) of
        true ->
            %% WS is reliable: a reliable 1xx carries RSeq and is
            %% matched to its PRACK, but is never retransmitted
            ws_call(fun() ->
                ws_respond(
                    Reliable, TxnH, Status, Reason, Headers, Body, ToTag
                )
            end);
        false when Reliable, Status > 100, Status < 200 ->
            Mod:reliable_respond(
                Engine, TxnH, Status, Reason, Headers, Body, ToTag
            );
        false ->
            Mod:respond(Engine, TxnH, Status, Reason, Headers, Body, ToTag)
    end.

ws_respond(true, TxnH, Status, Reason, Headers, Body, ToTag) ->
    chappe_sip_ws_transport:reliable_respond(
        TxnH, Status, Reason, Headers, Body, ToTag
    );
ws_respond(false, TxnH, Status, Reason, Headers, Body, ToTag) ->
    chappe_sip_ws_transport:respond(TxnH, Status, Reason, Headers, Body, ToTag).

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

%% The native stack's route: a TCP/TLS flow by its id, a UDP flow as the
%% address it came from (RFC 5626 5.3: the request goes back over it).
-spec native_route(chappe_sip_engine:route()) ->
    binary() | pos_integer() | undefined.
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

%% The method of a request we send, its first token.
-spec raw_method(binary()) -> binary() | undefined.
raw_method(Raw) ->
    case binary:match(Raw, <<" ">>) of
        {N, _} when N > 0, N =< 32 -> binary:part(Raw, 0, N);
        _ -> undefined
    end.

%% the forwarder

%% The proxy that forwards the in-dialog requests and 2xx ACKs loose-routed
%% back to us after we record-routed their dialog: a module with
%% forward_indialog/2 and forward_indialog_ack/2. chappe_sip_proxy_sup
%% registers chappe_sip_proxy when it starts; with none, such a request
%% goes to the handlers and such an ACK is dropped.
-spec forwarder(module()) -> ok.
forwarder(Mod) when is_atom(Mod) ->
    persistent_term:put({chappe_sip_engine, forwarder}, Mod).

-spec forwarder() -> module() | undefined.
forwarder() ->
    persistent_term:get({chappe_sip_engine, forwarder}, undefined).

%% the request handler a forwarded in-dialog request runs
-spec forward_handler(module()) -> fun((term(), term()) -> term()).
forward_handler(Fwd) ->
    fun Fwd:forward_indialog/2.

%% Forward a 2xx ACK with no dialog leg. A WS-range LegH means the ACK
%% arrived over that WS flow.
-spec forward_ack(module() | undefined, non_neg_integer(), binary()) -> ok.
forward_ack(undefined, _LegH, _Raw) ->
    ok;
forward_ack(Fwd, LegH, Raw) ->
    Arrived =
        case chappe_sip_ws:is_ws(LegH) of
            true -> {ws, LegH};
            false -> udp
        end,
    _ = spawn(fun() -> forward_ack_run(Fwd, Raw, Arrived) end),
    ok.

forward_ack_run(Fwd, Raw, Arrived) ->
    try
        Fwd:forward_indialog_ack(Raw, Arrived)
    catch
        C:R:St ->
            logger:warning(
                "chappe_sip: proxy 2xx-ACK forward failed: ~p:~p~n~p",
                [C, R, St]
            )
    end.
