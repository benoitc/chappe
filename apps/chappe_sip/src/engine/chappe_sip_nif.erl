%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc NIF stubs for the sofia-sip engine shim.
%%
%% Every function except start/2 and stop/1 is enqueue-only: it allocates
%% and hands an operation to the sofia stack thread via su_msg and returns
%% immediately. Creating operations (request/3, leg_create/4) return a
%% handle synchronously, but the underlying nta object is built later on
%% the stack thread; success or failure of that construction arrives as
%% an {op_ok, H} / {op_failed, H, Reason} event. So enqueue success is not
%% operation success.
%%
%% Events arrive as messages to the owner pid passed to start/2:
%%   {chappe_sip_engine, EngineRef, Event}
%% Event is one of
%%   {request, TxnH, LegH | undefined, Meta, RawSip}  inbound request
%%   {response, TxnH, Meta, RawSip}                   response to our request
%%   {ack, LegH, RawSip}                              2xx ACK on a dialog leg
%%   {cancel, TxnH}                                   CANCEL of our server txn
%%   {op_ok, H} | {op_failed, H, Reason}              deferred op result
%%   {health_ok, Seq}
%%   {started, Contact}
%%   {log, Level, Text}
%% start/2 and stop/1 are dirty IO NIFs (they wait on the stack thread's
%% readiness/exit handshakes).
-module(chappe_sip_nif).

-export([
    start/2,
    stop/1,
    respond/7,
    reliable_respond/7,
    request/3,
    send/3,
    send_response/2,
    relay/4,
    cancel/2,
    txn_done/2,
    leg_create/4,
    leg_destroy/2,
    health/1
]).
-nifs([
    start/2,
    stop/1,
    respond/7,
    reliable_respond/7,
    request/3,
    send/3,
    send_response/2,
    relay/4,
    cancel/2,
    txn_done/2,
    leg_create/4,
    leg_destroy/2,
    health/1
]).
-on_load(init/0).

-type engine() :: reference().
-type handle() :: non_neg_integer().
-export_type([engine/0, handle/0]).

init() ->
    Priv =
        case code:priv_dir(chappe_sip) of
            {error, bad_name} ->
                Ebin = filename:dirname(code:which(?MODULE)),
                filename:join(filename:dirname(Ebin), "priv");
            Dir ->
                Dir
        end,
    erlang:load_nif(filename:join([Priv, "lib", "chappe_sip_engine_nif"]), 0).

%% Opts: #{contact := binary(), max_message_size => pos_integer(),
%%         tls => #{contact := binary(), cert_dir => binary(),
%%                  passphrase => binary(), verify => none | peer}}
%% The tls contact binds a secondary TLS listener on its own port; cert_dir
%% holds agent.pem (cert+key) and cafile.pem.
-spec start(map(), pid()) -> {ok, engine()} | {error, term()}.
start(_Opts, _Owner) ->
    erlang:nif_error(engine_nif_not_loaded).

-spec stop(engine()) -> ok | {error, hung}.
stop(_Engine) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Reply to an incoming server transaction. Headers is a pre-joined
%% "Name: value\r\n" binary (<<>> for none), Body the payload (<<>> for
%% none), ToTag the local dialog tag for a dialog-forming response (<<>>
%% otherwise). The engine adds Via/To/From/Call-ID/CSeq/Content-Length.
%% Final (>= 200) responses complete and release the transaction.
-spec respond(
    engine(),
    handle(),
    100..699,
    binary(),
    binary(),
    binary(),
    binary()
) -> ok | {error, not_ready | too_large | badarg}.
respond(_Engine, _TxnH, _Status, _Reason, _Headers, _Body, _ToTag) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Send a reliable provisional (100rel, RFC 3262). Status must be 101..199.
%% nta owns RSeq/RAck, retransmission and PRACK matching; when the PRACK
%% arrives a {prack, TxnH, RawSip} event is delivered to the owner.
-spec reliable_respond(
    engine(),
    handle(),
    101..199,
    binary(),
    binary(),
    binary(),
    binary()
) ->
    ok | {error, not_ready | too_large | badarg}.
reliable_respond(_Engine, _TxnH, _Status, _Reason, _Headers, _Body, _ToTag) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Send a complete Erlang-built request. Route is an outbound proxy URL
%% binary or undefined. Returns {ok, TxnH} once enqueued; {op_ok, TxnH}
%% or {op_failed, TxnH, Reason} follows. Responses arrive as
%% {response, TxnH, Meta, RawSip}.
-spec request(engine(), binary() | undefined, binary()) ->
    {ok, handle()} | {error, not_ready | too_large | badarg}.
request(_Engine, _Route, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Fire-and-forget send (ACK to a 2xx). Returns {ok, OpH}; {op_ok, OpH} or
%% {op_failed, OpH, Reason} follows. No response is delivered.
-spec send(engine(), binary() | undefined, binary()) ->
    {ok, handle()} | {error, not_ready | too_large | badarg}.
send(_Engine, _Route, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Statelessly forward a complete response upstream (a forked second 2xx
%% that arrives after the server transaction was completed). The raw bytes
%% MUST still carry the proxy's own top Via; the engine strips it and routes
%% by the next Via. Fire-and-forget.
-spec send_response(engine(), binary()) ->
    ok | {error, not_ready | too_large | badarg}.
send_response(_Engine, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Proxy: relay a complete downstream response upstream on a server
%% transaction (top Via already stripped). Status >= 200 releases it.
-spec relay(engine(), handle(), 100..699, binary()) ->
    ok | {error, not_ready | too_large | badarg}.
relay(_Engine, _TxnH, _Status, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% CANCEL an outstanding INVITE client transaction.
-spec cancel(engine(), handle()) -> ok | {error, not_ready}.
cancel(_Engine, _TxnH) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Release a client transaction handle once the UAC is done with it
%% (after the final for non-INVITE, after the fork linger for INVITE).
-spec txn_done(engine(), handle()) -> ok | {error, not_ready}.
txn_done(_Engine, _TxnH) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Create a dialog leg to receive in-dialog requests. CallId, LocalAddr
%% (From with local tag) and RemoteAddr (To with remote tag) are the
%% dialog identity. Returns {ok, LegH}; {op_ok, LegH}/{op_failed,...}
%% follows. In-dialog requests arrive as {request, TxnH, LegH, ...} and
%% 2xx ACKs as {ack, LegH, RawSip}.
-spec leg_create(engine(), binary(), binary(), binary()) ->
    {ok, handle()} | {error, not_ready}.
leg_create(_Engine, _CallId, _LocalAddr, _RemoteAddr) ->
    erlang:nif_error(engine_nif_not_loaded).

-spec leg_destroy(engine(), handle()) -> ok | {error, not_ready}.
leg_destroy(_Engine, _LegH) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Round-trips through the su_root event loop; {health_ok, Seq} comes back
%% from inside the loop, proving the stack thread is servicing events.
-spec health(engine()) -> ok | {error, not_ready}.
health(_Engine) ->
    erlang:nif_error(engine_nif_not_loaded).
