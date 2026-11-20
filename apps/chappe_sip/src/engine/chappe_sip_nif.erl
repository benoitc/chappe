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
%%                                                    (Meta conn: its TCP/TLS
%%                                                    connection's flow id;
%%                                                    local_ip, local_port,
%%                                                    local: the listen
%%                                                    address and its ident)
%%   {response, TxnH, Meta, RawSip}                   response to our request
%%   {ack, LegH | TxnH, RawSip}                       2xx ACK on a dialog leg,
%%                                                    or on the INVITE server
%%                                                    txn answered 2xx
%%   {ack_timeout, LegH | TxnH}                       that 2xx never ACKed
%%   {cancel, TxnH}                                   CANCEL of our server txn
%%   {op_ok, H} | {op_failed, H, Reason}              deferred op result
%%   {flow_closed, FlowId}                            that connection closed
%%   {health_ok, Seq}
%%   {started, Contact}
%%   {log, Level, Text}
%% start/2 and stop/1 are dirty IO NIFs (they wait on the stack thread's
%% readiness/exit handshakes).
%%
%% The shim checks its arguments before it copies them: a header, body,
%% route, reason, to-tag, leg field or start option holding a NUL byte is
%% badarg (sofia reads them as C strings), as is a leg field of 8 KiB or
%% more. A start option that is present but invalid fails start/2 with
%% {error, badarg}, and max_message_size must be 1 KiB to 64 MiB. A call
%% the shim has no memory for returns {error, enomem} and sends nothing.
%%
%% Loading a new version of this module while the old code still holds the
%% shim is an in-place upgrade, which the shim always refuses (the load
%% fails with on_load_failure). replace/0 is the way to load a new library:
%% with the stack stopped, it deletes and purges this module, then loads it
%% again (docs/design/engine.md, "Upgrading the NIF").
-module(chappe_sip_nif).

-export([
    start/2,
    stop/1,
    respond/7,
    reliable_respond/7,
    request/3,
    request/4,
    request/5,
    proxy_mark/2,
    send/3,
    send/4,
    send_response/2,
    relay/4,
    cancel/2,
    cancel/3,
    txn_done/2,
    leg_create/4,
    leg_destroy/2,
    health/1,
    discard/2,
    block/2,
    stats/0,
    engine_state/0,
    reserve_slot/0,
    release_slot/0,
    instances/0,
    replace/0
]).
-nifs([
    start/2,
    stop/1,
    respond/7,
    reliable_respond/7,
    request/3,
    request/4,
    request/5,
    proxy_mark/2,
    send/3,
    send/4,
    send_response/2,
    relay/4,
    cancel/2,
    cancel/3,
    txn_done/2,
    leg_create/4,
    leg_destroy/2,
    health/1,
    discard/2,
    block/2,
    stats/0,
    engine_state/0,
    reserve_slot/0,
    release_slot/0,
    instances/0
]).
-on_load(init/0).

-type engine() :: reference().
-type handle() :: non_neg_integer().
%% an outbound proxy URL, the id of an RFC 5626 TCP/TLS flow (the conn of a
%% request's meta) to send over, or undefined (by the Request-URI)
-type route() :: binary() | pos_integer() | undefined.
-type stats() :: #{
    incoming := non_neg_integer(),
    discarded := non_neg_integer(),
    events_dropped := non_neg_integer(),
    alloc_failed := non_neg_integer()
}.
-export_type([engine/0, handle/0, route/0, stats/0]).

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
%%                  passphrase => binary(), verify => none | peer,
%%                  verify_clients => boolean()},
%%         ident => binary(), contacts => [{binary(), binary()}],
%%         capture => binary(),
%%         sip_t1 => 10..60000, sip_t2 => 10..600000,
%%         sip_t4 => 10..600000, udp_mtu => 576..65535,
%%         tcp_keepalive_ms => 1000..3600000, outbound_proxy => binary()}
%% sip_t2 must not be below the T1 in effect (500 when sip_t1 is unset);
%% outbound_proxy is a sip: or sips: URI. tcp_keepalive_ms pings TCP
%% connections only: sofia's TLS transport has no connection timer.
%% contacts are the listen addresses after contact, each with its ident (the
%% address a send names with request/5 or send/4); ident is contact's. The
%% tls map takes ident and contacts the same way. With more than one
%% address every one needs an ident.
%% capture is a HEP capture URL (udp:Host:Port;hep=3;capture_id=N): sofia
%% sends a copy of every message to it.
%% verify (default peer) checks the server certificate of outbound TLS
%% connections against cafile.pem and the target host (RFC 5922);
%% verify_clients asks inbound clients for a certificate.
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
) -> ok | {error, not_ready | too_large | enomem}.
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
    ok | {error, not_ready | too_large | enomem}.
reliable_respond(_Engine, _TxnH, _Status, _Reason, _Headers, _Body, _ToTag) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Send a complete Erlang-built request. Route is an outbound proxy URL
%% binary, a flow id (the request goes over that connection), or
%% undefined. Returns {ok, TxnH} once enqueued; {op_ok, TxnH} or
%% {op_failed, TxnH, Reason} follows. Responses arrive as
%% {response, TxnH, Meta, RawSip}.
-spec request(engine(), route(), binary()) ->
    {ok, handle()} | {error, not_ready | too_large | enomem}.
request(_Engine, _Route, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% The same with the Via branch to use (a proxy's loop-detection branch).
-spec request(engine(), route(), binary(), binary()) ->
    {ok, handle()} | {error, not_ready | too_large | enomem}.
request(_Engine, _Route, _Raw, _Branch) ->
    erlang:nif_error(engine_nif_not_loaded).

%% The same, sent from the listen address with this ident (<<>>: any); Branch
%% may be <<>> (nta picks one).
-spec request(engine(), route(), binary(), binary(), binary()) ->
    {ok, handle()} | {error, not_ready | too_large | enomem}.
request(_Engine, _Route, _Raw, _Branch, _Ident) ->
    erlang:nif_error(engine_nif_not_loaded).

%% A proxy owns this INVITE server transaction: a CANCEL of it is reported
%% but not answered 487 by the engine (RFC 3261 16.10).
-spec proxy_mark(engine(), handle()) -> ok | {error, not_ready}.
proxy_mark(_Engine, _TxnH) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Fire-and-forget send (ACK to a 2xx). Returns {ok, OpH}; {op_ok, OpH} or
%% {op_failed, OpH, Reason} follows. No response is delivered.
-spec send(engine(), route(), binary()) ->
    {ok, handle()} | {error, not_ready | too_large | enomem}.
send(_Engine, _Route, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% The same, sent from the listen address with this ident (<<>>: any).
-spec send(engine(), route(), binary(), binary()) ->
    {ok, handle()} | {error, not_ready | too_large | enomem}.
send(_Engine, _Route, _Raw, _Ident) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Statelessly forward a complete response upstream (a forked second 2xx
%% that arrives after the server transaction was completed). The raw bytes
%% MUST still carry the proxy's own top Via; the engine strips it and routes
%% by the next Via. Fire-and-forget.
-spec send_response(engine(), binary()) ->
    ok | {error, not_ready | too_large | enomem}.
send_response(_Engine, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Proxy: relay a complete downstream response upstream on a server
%% transaction (top Via already stripped). Status >= 200 releases it.
-spec relay(engine(), handle(), 100..699, binary()) ->
    ok | {error, not_ready | too_large | enomem}.
relay(_Engine, _TxnH, _Status, _Raw) ->
    erlang:nif_error(engine_nif_not_loaded).

%% CANCEL an outstanding INVITE client transaction.
-spec cancel(engine(), handle()) -> ok | {error, not_ready}.
cancel(_Engine, _TxnH) ->
    erlang:nif_error(engine_nif_not_loaded).

%% CANCEL with extra headers (CRLF-joined), e.g. a Reason (RFC 3326).
-spec cancel(engine(), handle(), binary()) ->
    ok | {error, not_ready | too_large | enomem}.
cancel(_Engine, _TxnH, _Headers) ->
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
    {ok, handle()} | {error, not_ready | enomem}.
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

%% A request the guard drops: its retransmissions get no 100 Trying while
%% it waits for the 408 that ends it (never sent for a non-INVITE, RFC 4320).
-spec discard(engine(), handle()) -> ok | {error, not_ready}.
discard(_Engine, _TxnH) ->
    erlang:nif_error(engine_nif_not_loaded).

%% Discard every request from Addr (an IP literal, as source_ip) for TtlMs,
%% before a transaction is made of it; 0 lifts the block.
-spec block(binary(), non_neg_integer()) -> ok.
block(_Addr, _TtlMs) ->
    erlang:nif_error(engine_nif_not_loaded).

%% The server transactions held, the requests the blocklist discarded, the
%% events that never reached the owner (it was dead, or the shim had no
%% memory for the message), and the event binaries the shim could not
%% allocate.
-spec stats() -> stats().
stats() ->
    erlang:nif_error(engine_nif_not_loaded).

%% The engine singleton: none when no engine runs, is stopping, or a
%% replace holds the slot (replacing).
-spec engine_state() -> none | running | stopping | replacing.
engine_state() ->
    erlang:nif_error(engine_nif_not_loaded).

%% Take the free engine slot for replace/0: a start is then refused with
%% {error, replacing} until release_slot/0, or until the library is loaded
%% again (which frees it once the new instance is set up).
-spec reserve_slot() -> ok | {error, running | stopping | replacing}.
reserve_slot() ->
    erlang:nif_error(engine_nif_not_loaded).

-spec release_slot() -> ok | {error, not_reserved}.
release_slot() ->
    erlang:nif_error(engine_nif_not_loaded).

%% The module instances that share this library image: 2 while a purged
%% instance of the same file still holds an engine, 1 once its unload ran.
-spec instances() -> pos_integer().
instances() ->
    erlang:nif_error(engine_nif_not_loaded).

%% Load this module and its library again from the code path, once no
%% engine runs: reserve the engine slot, delete, purge, load. Refused while
%% an engine runs or is stopping, since purging under a live stack thread
%% is unsafe; the reservation keeps a start (a supervisor restart) from
%% running on the old library until the new one is set up.
-spec replace() ->
    {module, ?MODULE}
    | {error,
        running | stopping | replacing | old_code_in_use | not_deleted | term()}.
replace() ->
    case reserve_slot() of
        ok ->
            %% a tail call: no frame of this module stays on the stack, or
            %% the purge would find this process running old code
            chappe_sip_nif_reload:run(?MODULE);
        {error, _} = Error ->
            Error
    end.
