%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Fake engine backend for pure-Erlang tests.
%%
%% Implements the chappe_sip_nif call surface (start/2, stop/1, respond/6,
%% health/1). The engine ref is this process's pid, so
%% {chappe_sip_engine, Ref, Event} routing in chappe_sip_engine works unchanged.
%% Tests drive it with inject_request/2 and observe responses with
%% await_response/1.
-module(chappe_sip_engine_fake).
-behaviour(gen_server).

%% chappe_sip_nif call surface
-export([
    start/2,
    stop/1,
    respond/7,
    reliable_respond/7,
    request/3, request/4,
    proxy_mark/2,
    send/3,
    send_response/2,
    relay/4,
    cancel/2, cancel/3,
    txn_done/2,
    leg_create/4,
    leg_destroy/2,
    health/1,
    discard/2,
    block/2,
    stats/0
]).
%% test driver API
-export([
    boot/0,
    shutdown/0,
    inject_request/2,
    inject_indialog/3,
    set_health/1,
    await_response/1, await_response/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(Opts, Owner) ->
    gen_server:call(?MODULE, {nif_start, Opts, Owner}).

stop(_Ref) ->
    gen_server:call(?MODULE, nif_stop).

respond(_Ref, TxnH, Status, Reason, Headers, Body, ToTag) ->
    gen_server:call(
        ?MODULE, {nif_respond, TxnH, Status, Reason, Headers, Body, ToTag}
    ).

reliable_respond(_Ref, TxnH, Status, Reason, Headers, Body, ToTag) ->
    gen_server:call(
        ?MODULE, {nif_respond, TxnH, Status, Reason, Headers, Body, ToTag}
    ).

request(_Ref, Route, Raw) ->
    gen_server:call(?MODULE, {nif_request, Route, Raw}).

request(Ref, Route, Raw, _Branch) ->
    request(Ref, Route, Raw).

proxy_mark(_Ref, _TxnH) ->
    ok.

send(_Ref, Route, Raw) ->
    gen_server:call(?MODULE, {nif_send, Route, Raw}).

send_response(_Ref, _Raw) ->
    ok.

relay(_Ref, TxnH, Status, Raw) ->
    gen_server:call(?MODULE, {nif_relay, TxnH, Status, Raw}).

cancel(_Ref, _TxnH) ->
    ok.

cancel(_Ref, _TxnH, _Headers) ->
    ok.

txn_done(_Ref, _TxnH) ->
    ok.

leg_create(_Ref, CallId, LocalAddr, RemoteAddr) ->
    gen_server:call(?MODULE, {nif_leg_create, CallId, LocalAddr, RemoteAddr}).

leg_destroy(_Ref, LegH) ->
    gen_server:call(?MODULE, {nif_leg_destroy, LegH}).

health(_Ref) ->
    gen_server:call(?MODULE, nif_health).

discard(_Ref, _TxnH) ->
    ok.

block(_Addr, _Ms) ->
    ok.

stats() ->
    #{incoming => 0, discarded => 0, events_dropped => 0, alloc_failed => 0}.

%% test API

boot() ->
    {ok, _} = gen_server:start({local, ?MODULE}, ?MODULE, [], []),
    ok.

shutdown() ->
    _ = gen_server:stop(?MODULE),
    ok.

%% false: the fake stack thread stops answering health checks (a hang).
-spec set_health(boolean()) -> ok.
set_health(On) ->
    gen_server:call(?MODULE, {set_health, On}).

%% Feed a request event into the owner (as the NIF would) and register
%% the calling test process as the observer of responses to TxnH.
-spec inject_request(non_neg_integer(), binary()) -> ok.
inject_request(TxnH, Raw) ->
    gen_server:call(?MODULE, {inject, TxnH, Raw, self()}).

%% Inject an in-dialog request (routed to the owning dialog by LegH) and
%% observe responses to its TxnH.
-spec inject_indialog(non_neg_integer(), non_neg_integer(), binary()) -> ok.
inject_indialog(LegH, TxnH, Raw) ->
    gen_server:call(?MODULE, {inject_indialog, LegH, TxnH, Raw, self()}).

-spec await_response(non_neg_integer()) -> {ok, map()} | timeout.
await_response(TxnH) ->
    await_response(TxnH, 3000).

await_response(TxnH, Timeout) ->
    receive
        {fake_response, TxnH, Resp} -> {ok, Resp}
    after Timeout -> timeout
    end.

%% gen_server

init([]) ->
    {ok, #{
        owner => undefined,
        started => false,
        observers => #{},
        seq => 0
    }}.

handle_call({nif_start, _Opts, Owner}, _From, #{started := true} = S) ->
    {reply, {error, already_started}, S#{owner => Owner}};
handle_call({nif_start, Opts, Owner}, _From, S) ->
    case Opts of
        #{contact := <<"sip:fail@", _/binary>>} ->
            {reply, {error, {engine_start, <<"forced failure">>}}, S};
        _ ->
            {reply, {ok, self()}, S#{owner => Owner, started => true}}
    end;
handle_call(nif_stop, _From, S) ->
    {reply, ok, S#{started => false}};
handle_call(
    {nif_respond, TxnH, Status, Reason, Headers, Body, ToTag},
    _From,
    #{observers := Obs} = S
) ->
    case Obs of
        #{TxnH := Pid} ->
            Pid !
                {fake_response, TxnH, #{
                    status => Status,
                    reason => Reason,
                    headers => Headers,
                    body => Body,
                    to_tag => ToTag
                }};
        _ ->
            ok
    end,
    {reply, ok, S};
handle_call(
    {nif_request, _Route, _Raw},
    _From,
    #{owner := Owner, seq := Seq} = S
) ->
    H = Seq + 1,
    %% confirm the op like the real shim
    Owner ! {chappe_sip_engine, self(), {op_ok, H}},
    {reply, {ok, H}, S#{seq => H}};
handle_call(
    {nif_send, _Route, _Raw},
    _From,
    #{owner := Owner, seq := Seq} = S
) ->
    H = Seq + 1,
    Owner ! {chappe_sip_engine, self(), {op_ok, H}},
    {reply, {ok, H}, S#{seq => H}};
handle_call(
    {nif_leg_create, _CallId, _Local, _Remote},
    _From,
    #{owner := Owner, seq := Seq} = S
) ->
    H = Seq + 1,
    Owner ! {chappe_sip_engine, self(), {op_ok, H}},
    {reply, {ok, H}, S#{seq => H}};
handle_call({nif_leg_destroy, _LegH}, _From, S) ->
    {reply, ok, S};
handle_call({set_health, On}, _From, S) ->
    {reply, ok, S#{silent => not On}};
handle_call(nif_health, _From, #{silent := true} = S) ->
    {reply, ok, S};
handle_call(nif_health, _From, #{owner := Owner, seq := Seq} = S) ->
    Owner ! {chappe_sip_engine, self(), {health_ok, Seq + 1}},
    {reply, ok, S#{seq => Seq + 1}};
handle_call(
    {inject, TxnH, Raw, Observer},
    _From,
    #{owner := Owner, observers := Obs} = S
) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    Meta = #{method => chappe_sip_msg:method(Msg)},
    Owner ! {chappe_sip_engine, self(), {request, TxnH, undefined, Meta, Raw}},
    {reply, ok, S#{observers => Obs#{TxnH => Observer}}};
handle_call(
    {inject_indialog, LegH, TxnH, Raw, Observer},
    _From,
    #{owner := Owner, observers := Obs} = S
) ->
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    Meta = #{method => chappe_sip_msg:method(Msg)},
    Owner ! {chappe_sip_engine, self(), {request, TxnH, LegH, Meta, Raw}},
    {reply, ok, S#{observers => Obs#{TxnH => Observer}}}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.
