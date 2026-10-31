%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% NG protocol transport client, one process per rtpengine node.
%%
%% Speaks NG over UDP (default), TCP (transport => tcp) for
%% deployments whose SDP bodies outgrow safe datagram sizes, or
%% WebSocket (transport => ws | wss) against rtpengine's HTTP
%% interface (--listen-http / --listen-https) to cross firewalls or
%% ride 443.
%%
%% Each request gets a fresh cookie framing "Cookie SP BencodedDict".
%% Over UDP the message is retransmitted byte-identical on a
%% per-attempt timer until a reply arrives or attempts are exhausted:
%% rtpengine caches replies by cookie (about 30 seconds), so a
%% retransmission is idempotent and a duplicate request is served the
%% cached reply. Cookies carry a random component because a restarted
%% client reusing a cookie within the cache window would be served a
%% stale reply for a different command. A UDP request larger than
%% max_datagram (default 65507, the IPv4 payload limit) is refused with
%% {error, too_large} before anything is sent, as is one the socket
%% rejects with emsgsize; use the TCP or WebSocket transport for bodies
%% that size. Over TCP nothing is
%% retransmitted (the transport is reliable); the same timers only
%% enforce the attempts * timeout deadline, and messages are parsed
%% incrementally out of the byte stream by chappe_rtpengine_stream
%% (linear in the stream size, 4 MiB and 256-byte cookie caps; a
%% stream it rejects drops the connection). A broken connection fails
%% all pending requests with {error, closed} and reconnects in the
%% background; requests made while disconnected fail immediately.
%% The host name is resolved again on every TCP connect attempt (the
%% WebSocket client resolves the URL host itself), so a node that
%% moves to a new address is found on reconnect, and a name that does
%% not resolve yet is retried like a refused connection.
%% Over UDP there is no connect to hook, so a host name is resolved
%% at start and again every resolve_interval_ms (default 60000,
%% infinity disables) and after resolve_after_timeouts consecutive
%% request timeouts (default 2). Resolution runs in a helper process so
%% a slow resolver never stalls replies; when the address changes the
%% client sends to the new one (reopening the socket if the address
%% family changed), and requests still being retransmitted follow it.
%% A failed re-resolution keeps the current address. An IP address
%% host is never re-resolved. The resolver option (a fun taking the
%% host and returning {ok, IP} | {error, Reason}) replaces inet for
%% custom lookups and tests.
%% The ws/wss transports behave like TCP (deadline only, no
%% retransmit, background reconnect) but need no stream parser:
%% WebSocket preserves message boundaries, so each binary (or text)
%% frame is exactly one "Cookie SP bencode" message. The connection is a
%% ws_session process (erlang_ws) negotiating the ng.rtpengine.com
%% subprotocol; a connect to a server that does not grant it fails.
%%
%% Callers use gen_server:call with timeout infinity: every pending
%% request is guaranteed a reply within attempts * timeout, terminate/2
%% answers whatever is left, and a crash reaches the caller as an exit
%% that the chappe_rtpengine facade translates to {error, client_down}.
-module(chappe_rtpengine_client).
-behaviour(gen_server).

-export([start_link/2, cmd/2, cmd/3, cmd_async/3, stats/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_TIMEOUT, 1000).
-define(DEFAULT_ATTEMPTS, 3).
-define(ACTIVE_N, 64).
-define(RECONNECT_AFTER, 1000).
%% Largest UDP payload over IPv4; IPv6 allows 65527 but the smaller
%% bound is the safe default for either family.
-define(DEFAULT_MAX_DATAGRAM, 65507).
%% Socket buffers sized for several maximal datagrams in flight; the
%% kernel default send buffer (9216 bytes on macOS) refuses large
%% offers outright.
-define(UDP_SOCKBUF, (256 * 1024)).
-define(CALL_TIMEOUT, 5000).
-define(CONNECT_TIMEOUT, 3000).
-define(NG_SUBPROTOCOL, <<"ng.rtpengine.com">>).
-define(DEFAULT_RESOLVE_INTERVAL, 60000).
-define(DEFAULT_RESOLVE_AFTER_TIMEOUTS, 2).

-type opts() :: #{
    host := inet:ip_address() | string() | binary(),
    port := inet:port_number(),
    transport => udp | tcp | ws | wss,
    path => binary() | string(),
    tls_opts => [ssl:tls_client_option()],
    timeout => pos_integer(),
    attempts => pos_integer(),
    max_datagram => pos_integer(),
    resolve_interval_ms => pos_integer() | infinity,
    resolve_after_timeouts => pos_integer(),
    resolver => chappe_rtpengine_resolve:resolver()
}.

-export_type([opts/0]).

-type reply_to() :: gen_server:from() | {async, pid(), reference()}.

-record(pending, {
    from :: reply_to(),
    datagram :: binary(),
    attempts_left :: non_neg_integer(),
    tref :: reference()
}).

-record(state, {
    name :: atom(),
    transport = udp :: udp | tcp | ws | wss,
    socket :: gen_udp:socket() | gen_tcp:socket() | pid() | undefined,
    ws_mref :: reference() | undefined,
    connected = false :: boolean(),
    stream = chappe_rtpengine_stream:new() :: chappe_rtpengine_stream:stream(),
    max_datagram = ?DEFAULT_MAX_DATAGRAM :: pos_integer(),
    host :: inet:ip_address() | string() | binary(),
    ip :: inet:ip_address() | undefined,
    port :: inet:port_number(),
    path = <<"/">> :: binary(),
    tls_opts = [] :: [ssl:tls_client_option()],
    timeout :: pos_integer(),
    attempts :: pos_integer(),
    pending = #{} :: #{binary() => #pending{}},
    resolver :: chappe_rtpengine_resolve:resolver() | undefined,
    resolve_interval = ?DEFAULT_RESOLVE_INTERVAL :: pos_integer() | infinity,
    resolve_after = ?DEFAULT_RESOLVE_AFTER_TIMEOUTS :: pos_integer(),
    consecutive_timeouts = 0 :: non_neg_integer(),
    %% {Ref, MRef} of the lookup in flight
    resolving :: {reference(), reference()} | undefined,
    stats = #{
        sent => 0,
        replies => 0,
        retransmits => 0,
        timeouts => 0,
        bad_replies => 0,
        unknown_cookies => 0,
        bad_sources => 0,
        reconnects => 0,
        address_changes => 0
    } :: #{atom() => non_neg_integer()}
}).

-type state() :: #state{}.

-spec start_link(atom(), opts()) -> gen_server:start_ret().
start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, Opts], []).

-spec cmd(atom(), atom()) -> chappe_rtpengine_ng:result() | {error, term()}.
cmd(Node, Command) ->
    cmd(Node, Command, #{}).

%% Encode in the calling process; the client only frames and sends.
-spec cmd(atom(), atom(), chappe_rtpengine_ng:params()) ->
    chappe_rtpengine_ng:result() | {error, term()}.
cmd(Node, Command, Params) ->
    case encode(Command, Params) of
        {ok, Body} -> gen_server:call(Node, {cmd, Body}, infinity);
        {error, _} = Error -> Error
    end.

%% Fire-and-collect variant for state machines that must not block:
%% the result arrives as a {chappe_rtpengine_reply, Ref, Result} message. The
%% submission itself is a quick synchronous call so a dead client is
%% detected immediately (noproc exit).
-spec cmd_async(atom(), atom(), chappe_rtpengine_ng:params()) ->
    {ok, reference()} | {error, term()}.
cmd_async(Node, Command, Params) ->
    case encode(Command, Params) of
        {ok, Body} ->
            Ref = make_ref(),
            Request = {cmd_async, Body, self(), Ref},
            case gen_server:call(Node, Request, infinity) of
                ok -> {ok, Ref};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% A parameter bencode cannot carry (a float, a tuple) is the caller's
%% error, returned rather than raised in a session process.
encode(Command, Params) ->
    try
        {ok, chappe_rtpengine_ng:encode_command(Command, Params)}
    catch
        error:{bad_param, _, _} = Reason -> {error, Reason}
    end.

-spec stats(atom()) -> #{atom() => non_neg_integer()}.
stats(Node) ->
    gen_server:call(Node, stats, ?CALL_TIMEOUT).

%% gen_server callbacks

init([Name, Opts]) ->
    process_flag(trap_exit, true),
    Host = maps:get(host, Opts),
    Port = maps:get(port, Opts),
    Transport = maps:get(transport, Opts, udp),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Attempts = maps:get(attempts, Opts, ?DEFAULT_ATTEMPTS),
    State = #state{
        name = Name,
        transport = Transport,
        host = Host,
        port = Port,
        path = normalize_path(maps:get(path, Opts, <<"/">>)),
        tls_opts = maps:get(tls_opts, Opts, []),
        timeout = Timeout,
        attempts = Attempts,
        max_datagram = maps:get(max_datagram, Opts, ?DEFAULT_MAX_DATAGRAM),
        resolver = maps:get(resolver, Opts, undefined),
        resolve_interval = maps:get(
            resolve_interval_ms, Opts, ?DEFAULT_RESOLVE_INTERVAL
        ),
        resolve_after = maps:get(
            resolve_after_timeouts, Opts, ?DEFAULT_RESOLVE_AFTER_TIMEOUTS
        )
    },
    case Transport of
        udp ->
            %% connectionless: resolved now, then again on a timer and
            %% after repeated timeouts (there is no reconnect to hook)
            case resolve(State) of
                {ok, IP} ->
                    schedule_resolve(State),
                    connect(State#state{ip = IP});
                {error, Reason} ->
                    {stop, {resolve_failed, Host, Reason}}
            end;
        _ ->
            connect(State)
    end.

handle_call({cmd, Body}, From, State0) ->
    case send_request(Body, From, State0) of
        {ok, State} ->
            {noreply, State};
        {error, Reason, State} ->
            {reply, send_error(Reason), State}
    end;
handle_call({cmd_async, Body, Pid, Ref}, _From, State0) ->
    case send_request(Body, {async, Pid, Ref}, State0) of
        {ok, State} ->
            {reply, ok, State};
        {error, Reason, State} ->
            {reply, send_error(Reason), State}
    end;
handle_call(stats, _From, State) ->
    {reply, State#state.stats, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Only rtpengine's own address and port can answer: a datagram from
%% anywhere else, even with a live cookie, is dropped (and counted).
handle_info(
    {udp, Socket, IP, Port, Packet},
    #state{socket = Socket, ip = IP, port = Port} = State
) ->
    {noreply, handle_packet(Packet, State)};
handle_info({udp, Socket, IP, Port, _Packet}, #state{socket = Socket} = State) ->
    ?LOG_WARNING(
        "chappe_rtpengine_client ~p: reply from ~s:~b dropped, not the node",
        [State#state.name, inet:ntoa(IP), Port]
    ),
    {noreply, bump(bad_sources, State)};
handle_info({udp_passive, Socket}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, ?ACTIVE_N}]),
    {noreply, State};
handle_info({tcp, Socket, Data}, #state{socket = Socket} = State) ->
    {noreply, stream_in(Data, State)};
handle_info({tcp_passive, Socket}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, ?ACTIVE_N}]),
    {noreply, State};
handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
    ?LOG_WARNING("chappe_rtpengine_client ~p: connection closed by peer", [
        State#state.name
    ]),
    {noreply, drop_connection(State)};
handle_info({tcp_error, Socket, Reason}, #state{socket = Socket} = State) ->
    ?LOG_WARNING("chappe_rtpengine_client ~p: connection error: ~p", [
        State#state.name, Reason
    ]),
    {noreply, drop_connection(State)};
%% One binary WebSocket frame is one complete reply; route it through
%% the datagram path, not the stream parser.
handle_info(
    {chappe_rtpengine_ws_frame, Pid, Frame}, #state{socket = Pid} = State
) ->
    {noreply, handle_packet(Frame, State)};
handle_info(
    {'DOWN', MRef, process, Pid, Reason},
    #state{socket = Pid, ws_mref = MRef} = State
) ->
    ?LOG_WARNING("chappe_rtpengine_client ~p: websocket session down: ~p", [
        State#state.name, Reason
    ]),
    {noreply, drop_connection(State)};
handle_info(reconnect, #state{connected = false} = State) when
    State#state.transport =/= udp
->
    case connect(State) of
        {ok, State1} -> {noreply, State1};
        %% connect/1 never stops for reconnecting transports; keep the
        %% compiler honest
        Other -> Other
    end;
handle_info(reconnect, State) ->
    {noreply, State};
handle_info({timeout, TRef, Cookie}, State) ->
    {noreply, handle_attempt_timeout(Cookie, TRef, State)};
handle_info(re_resolve, State) ->
    schedule_resolve(State),
    {noreply, start_resolve(State)};
handle_info(
    {chappe_rtpengine_resolved, Ref, Result},
    #state{resolving = {Ref, MRef}} = State
) ->
    erlang:demonitor(MRef, [flush]),
    {noreply, resolved(Result, State#state{resolving = undefined})};
handle_info(
    {'DOWN', MRef, process, _Pid, Reason},
    #state{resolving = {_Ref, MRef}} = State
) ->
    ?LOG_WARNING("chappe_rtpengine_client ~p: resolver crashed: ~p", [
        State#state.name, Reason
    ]),
    {noreply, State#state{resolving = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{pending = Pending} = State) ->
    maps:foreach(
        fun(_Cookie, #pending{from = From, tref = TRef}) ->
            erlang:cancel_timer(TRef),
            reply_pending(From, {error, shutdown})
        end,
        Pending
    ),
    close_socket(State),
    ok.

%% internal

connect(#state{transport = udp, ip = IP} = State) ->
    case open_udp(IP) of
        {ok, Socket} ->
            {ok, State#state{socket = Socket, connected = true}};
        {error, Reason} ->
            {stop, {socket_open_failed, Reason}}
    end;
connect(#state{transport = tcp, host = Host, port = Port} = State) ->
    case resolve(State) of
        {ok, IP} ->
            SockOpts = [
                binary,
                family(IP),
                {active, ?ACTIVE_N},
                {packet, raw},
                {nodelay, true}
            ],
            case gen_tcp:connect(IP, Port, SockOpts, ?CONNECT_TIMEOUT) of
                {ok, Socket} ->
                    {ok, State#state{
                        ip = IP,
                        socket = Socket,
                        connected = true,
                        stream = chappe_rtpengine_stream:new()
                    }};
                {error, Reason} ->
                    connect_failed(Reason, State)
            end;
        {error, Reason} ->
            connect_failed({resolve_failed, Host, Reason}, State)
    end;
connect(#state{transport = WsT} = State) when WsT =:= ws; WsT =:= wss ->
    Opts0 = #{
        handler => chappe_rtpengine_ws_handler,
        handler_opts => #{owner => self()},
        subprotocols => [?NG_SUBPROTOCOL],
        timeout => ?CONNECT_TIMEOUT
    },
    Opts =
        case WsT of
            wss -> Opts0#{ssl_opts => State#state.tls_opts};
            ws -> Opts0
        end,
    case ws:connect(ws_url(State), Opts) of
        {ok, Pid} ->
            MRef = erlang:monitor(process, Pid),
            {ok, State#state{
                socket = Pid, ws_mref = MRef, connected = true
            }};
        {error, Reason} ->
            ?LOG_WARNING(
                "chappe_rtpengine_client ~p: websocket connect failed: ~p", [
                    State#state.name, Reason
                ]
            ),
            _ = erlang:send_after(?RECONNECT_AFTER, self(), reconnect),
            {ok, State#state{
                socket = undefined, ws_mref = undefined, connected = false
            }}
    end.

open_udp(IP) ->
    %% Large SDP bodies exceed default buffers: the kernel refuses
    %% datagrams beyond sndbuf, and gen_udp silently truncates replies
    %% beyond its user buffer, which must hold one maximal datagram.
    SockOpts = [
        binary,
        family(IP),
        {active, ?ACTIVE_N},
        {sndbuf, ?UDP_SOCKBUF},
        {recbuf, ?UDP_SOCKBUF},
        {buffer, 65536}
    ],
    gen_udp:open(0, SockOpts).

connect_failed(Reason, State) ->
    ?LOG_WARNING("chappe_rtpengine_client ~p: connect failed: ~p", [
        State#state.name, Reason
    ]),
    _ = erlang:send_after(?RECONNECT_AFTER, self(), reconnect),
    {ok, State#state{socket = undefined, connected = false}}.

ws_url(#state{transport = WsT, host = Host, port = Port, path = Path}) ->
    Scheme =
        case WsT of
            ws -> <<"ws://">>;
            wss -> <<"wss://">>
        end,
    iolist_to_binary([
        Scheme, url_host(Host), $:, integer_to_binary(Port), Path
    ]).

url_host(IP) when tuple_size(IP) =:= 8 ->
    [$[, inet:ntoa(IP), $]];
url_host(IP) when is_tuple(IP) ->
    inet:ntoa(IP);
url_host(Host) ->
    Host.

normalize_path(Path) when is_list(Path) ->
    normalize_path(list_to_binary(Path));
normalize_path(<<"/", _/binary>> = Path) ->
    Path;
normalize_path(Path) when is_binary(Path) ->
    <<"/", Path/binary>>.

family(IP) when tuple_size(IP) =:= 8 -> inet6;
family(_IP) -> inet.

close_socket(#state{socket = undefined}) ->
    ok;
close_socket(#state{transport = udp, socket = Socket}) ->
    gen_udp:close(Socket);
close_socket(#state{transport = tcp, socket = Socket}) ->
    gen_tcp:close(Socket);
close_socket(#state{socket = Pid, ws_mref = MRef}) ->
    _ = erlang:demonitor(MRef, [flush]),
    %% the session may already be gone (that is often why we are here)
    try
        ws:stop(Pid)
    catch
        _:_ -> ok
    end.

%% Fail everything in flight, then reconnect in the background.
drop_connection(State0) ->
    maps:foreach(
        fun(_Cookie, #pending{from = From, tref = TRef}) ->
            erlang:cancel_timer(TRef),
            reply_pending(From, {error, closed})
        end,
        State0#state.pending
    ),
    close_socket(State0),
    _ = erlang:send_after(?RECONNECT_AFTER, self(), reconnect),
    State = bump(reconnects, State0),
    State#state{
        socket = undefined,
        ws_mref = undefined,
        connected = false,
        stream = chappe_rtpengine_stream:new(),
        pending = #{}
    }.

send_request(_Body, _ReplyTo, #state{connected = false} = State) ->
    {error, not_connected, State};
send_request(Body, ReplyTo, State0) ->
    Cookie = make_cookie(),
    Datagram = <<Cookie/binary, $\s, Body/binary>>,
    case checked_send(State0, Datagram) of
        ok ->
            TRef = erlang:start_timer(State0#state.timeout, self(), Cookie),
            Pending = #pending{
                from = ReplyTo,
                datagram = Datagram,
                attempts_left = State0#state.attempts - 1,
                tref = TRef
            },
            {ok, add_pending(Cookie, Pending, bump(sent, State0))};
        {error, Reason} ->
            {error, Reason, State0}
    end.

%% Refused sends that retrying cannot fix: a UDP datagram over the
%% configured limit, or one the kernel rejects as too big.
send_error(too_large) -> {error, too_large};
send_error(Reason) -> {error, {send_failed, Reason}}.

checked_send(#state{transport = udp, max_datagram = Max}, Datagram) when
    byte_size(Datagram) > Max
->
    {error, too_large};
checked_send(#state{transport = udp} = State, Datagram) ->
    case transport_send(State, Datagram) of
        {error, emsgsize} -> {error, too_large};
        Other -> Other
    end;
checked_send(State, Datagram) ->
    transport_send(State, Datagram).

transport_send(#state{transport = udp, socket = S, ip = IP, port = Port}, Data) ->
    gen_udp:send(S, IP, Port, Data);
transport_send(#state{transport = tcp, socket = S}, Data) ->
    gen_tcp:send(S, Data);
transport_send(#state{socket = Pid}, Data) ->
    %% ws/wss: a cast into the session; a send that never reaches the
    %% wire surfaces as a session exit and the deadline timer.
    ws:send(Pid, {binary, Data}).

reply_pending({async, Pid, Ref}, Result) ->
    Pid ! {chappe_rtpengine_reply, Ref, Result},
    ok;
reply_pending(From, Result) ->
    gen_server:reply(From, Result).

handle_packet(Packet, State0) ->
    case binary:split(Packet, <<" ">>) of
        [Cookie, Body] ->
            Decoded =
                case chappe_rtpengine_bencode:decode(Body) of
                    {ok, Value} -> {ok, Value};
                    {error, _} -> {bad, Body}
                end,
            deliver(Cookie, Decoded, State0);
        _ ->
            ?LOG_WARNING("chappe_rtpengine_client ~p: unparseable datagram", [
                State0#state.name
            ]),
            bump(bad_replies, State0)
    end.

%% TCP byte stream: deliver every message the chunk completed; a
%% stream the framer rejects (corrupt, or over its caps) is dropped
%% after delivering what came before the bad bytes.
stream_in(Data, State0) ->
    Deliver = fun({Cookie, Value}, Acc) ->
        deliver(Cookie, {ok, Value}, Acc)
    end,
    case chappe_rtpengine_stream:feed(Data, State0#state.stream) of
        {ok, Messages, Stream} ->
            lists:foldl(Deliver, State0#state{stream = Stream}, Messages);
        {error, Reason, Messages} ->
            State = lists:foldl(Deliver, State0, Messages),
            ?LOG_WARNING(
                "chappe_rtpengine_client ~p: bad stream (~p), reconnecting",
                [State#state.name, Reason]
            ),
            drop_connection(State)
    end.

deliver(Cookie, Decoded, State0) ->
    case take_pending(Cookie, State0) of
        {ok, #pending{from = From, tref = TRef}, State1} ->
            erlang:cancel_timer(TRef),
            reply_to_caller(
                From, Decoded, State1#state{consecutive_timeouts = 0}
            );
        error ->
            %% Late reply for a request that already timed out, or a
            %% duplicate reply. Drop it.
            ?LOG_DEBUG("chappe_rtpengine_client ~p: unknown cookie ~p", [
                State0#state.name, Cookie
            ]),
            bump(unknown_cookies, State0)
    end.

reply_to_caller(From, {ok, Reply}, State) when is_map(Reply) ->
    case maps:find(<<"warning">>, Reply) of
        {ok, Warning} ->
            ?LOG_WARNING("chappe_rtpengine_client ~p: warning from node: ~p", [
                State#state.name, Warning
            ]);
        error ->
            ok
    end,
    reply_pending(From, chappe_rtpengine_ng:decode_reply(Reply)),
    bump(replies, State);
reply_to_caller(From, {bad, Body}, State) ->
    reply_pending(From, {error, {bad_reply, Body}}),
    bump(bad_replies, State);
reply_to_caller(From, {ok, Other}, State) ->
    reply_pending(From, {error, {bad_reply, Other}}),
    bump(bad_replies, State).

handle_attempt_timeout(Cookie, TRef, State0) ->
    case maps:find(Cookie, State0#state.pending) of
        {ok, #pending{tref = TRef} = Pending} ->
            retransmit_or_fail(Cookie, Pending, State0);
        _ ->
            %% Stale timer: the reply arrived after the timer message
            %% was already queued, or the entry was re-armed.
            State0
    end.

retransmit_or_fail(Cookie, #pending{attempts_left = 0} = Pending, State0) ->
    ?LOG_WARNING(
        "chappe_rtpengine_client ~p: request timed out after ~p attempts", [
            State0#state.name, State0#state.attempts
        ]
    ),
    reply_pending(Pending#pending.from, {error, timeout}),
    State = timed_out(bump(timeouts, State0)),
    State#state{pending = maps:remove(Cookie, State#state.pending)};
retransmit_or_fail(Cookie, Pending0, State0) ->
    State1 =
        case State0#state.transport of
            udp ->
                ?LOG_DEBUG("chappe_rtpengine_client ~p: retransmitting ~p", [
                    State0#state.name, Cookie
                ]),
                case transport_send(State0, Pending0#pending.datagram) of
                    ok ->
                        ok;
                    {error, Reason} ->
                        %% Keep the retry schedule going; a transient
                        %% send error ends up as {error, timeout} once
                        %% attempts run out.
                        ?LOG_WARNING(
                            "chappe_rtpengine_client ~p: retransmit send failed: ~p",
                            [State0#state.name, Reason]
                        )
                end,
                bump(retransmits, State0);
            _ ->
                %% reliable transports (tcp, ws, wss): the timer only
                %% enforces the overall deadline, nothing is resent
                State0
        end,
    TRef = erlang:start_timer(State1#state.timeout, self(), Cookie),
    Pending = Pending0#pending{
        attempts_left = Pending0#pending.attempts_left - 1,
        tref = TRef
    },
    add_pending(Cookie, Pending, State1).

%% A UDP node that stops answering may have moved: after
%% resolve_after_timeouts timeouts in a row, look the name up again.
timed_out(#state{transport = udp} = State) ->
    N = State#state.consecutive_timeouts + 1,
    case N >= State#state.resolve_after of
        true -> start_resolve(State#state{consecutive_timeouts = 0});
        false -> State#state{consecutive_timeouts = N}
    end;
timed_out(State) ->
    State.

add_pending(Cookie, Pending, State) ->
    State#state{pending = maps:put(Cookie, Pending, State#state.pending)}.

take_pending(Cookie, State) ->
    case maps:take(Cookie, State#state.pending) of
        {Pending, Rest} -> {ok, Pending, State#state{pending = Rest}};
        error -> error
    end.

-spec bump(atom(), state()) -> state().
bump(Key, #state{stats = Stats} = State) ->
    State#state{stats = maps:update_with(Key, fun(N) -> N + 1 end, Stats)}.

%% The cookie is the only thing tying a reply to its request, so it must
%% not be guessable: 128 bits from the crypto RNG.
make_cookie() ->
    Rand = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    Uniq = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    <<Rand/binary, "-", Uniq/binary>>.

resolve(#state{resolver = Resolver, host = Host}) ->
    chappe_rtpengine_resolve:resolve(Resolver, Host).

schedule_resolve(#state{resolve_interval = infinity}) ->
    ok;
schedule_resolve(#state{host = Host, resolve_interval = Interval}) ->
    case chappe_rtpengine_resolve:is_name(Host) of
        true ->
            _ = erlang:send_after(Interval, self(), re_resolve),
            ok;
        false ->
            ok
    end.

%% One lookup at a time, in a helper so a slow resolver never delays
%% replies.
start_resolve(#state{resolving = {_, _}} = State) ->
    State;
start_resolve(#state{host = Host, resolver = Resolver} = State) ->
    case chappe_rtpengine_resolve:is_name(Host) of
        true ->
            State#state{
                resolving = chappe_rtpengine_resolve:async(Resolver, Host)
            };
        false ->
            State
    end.

resolved({ok, IP}, #state{ip = IP} = State) ->
    State;
resolved({ok, IP}, #state{ip = Old} = State) ->
    ?LOG_NOTICE("chappe_rtpengine_client ~p: ~p moved from ~p to ~p", [
        State#state.name, State#state.host, Old, IP
    ]),
    case family(IP) =:= family(Old) of
        true ->
            bump(address_changes, State#state{ip = IP});
        false ->
            case open_udp(IP) of
                {ok, Socket} ->
                    close_socket(State),
                    bump(address_changes, State#state{
                        ip = IP, socket = Socket
                    });
                {error, Reason} ->
                    ?LOG_WARNING(
                        "chappe_rtpengine_client ~p: socket for ~p: ~p", [
                            State#state.name, IP, Reason
                        ]
                    ),
                    State
            end
    end;
resolved({error, Reason}, State) ->
    ?LOG_WARNING(
        "chappe_rtpengine_client ~p: re-resolving ~p failed: ~p, keeping ~p",
        [State#state.name, State#state.host, Reason, State#state.ip]
    ),
    State.
