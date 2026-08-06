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
%% stale reply for a different command. Over TCP nothing is
%% retransmitted (the transport is reliable); the same timers only
%% enforce the attempts * timeout deadline, and messages are parsed
%% incrementally out of the byte stream. A broken connection fails
%% all pending requests with {error, closed} and reconnects in the
%% background; requests made while disconnected fail immediately.
%% The ws/wss transports behave like TCP (deadline only, no
%% retransmit, background reconnect) but need no stream parser:
%% WebSocket preserves message boundaries, so each binary frame is
%% exactly one "Cookie SP bencode" message. The connection is a
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
%% Cap on the un-consumed TCP stream buffer. NG replies are small bencode
%% dicts; a peer that never sends a space or advertises a huge string length
%% would otherwise grow the buffer without bound (the UDP path is capped by
%% recbuf). On exceed we drop the connection and reconnect.
-define(MAX_STREAM_BYTES, (4 * 1024 * 1024)).
-define(CALL_TIMEOUT, 5000).
-define(CONNECT_TIMEOUT, 3000).
-define(NG_SUBPROTOCOL, <<"ng.rtpengine.com">>).

-type opts() :: #{
    host := inet:ip_address() | string() | binary(),
    port := inet:port_number(),
    transport => udp | tcp | ws | wss,
    path => binary() | string(),
    tls_opts => [ssl:tls_client_option()],
    timeout => pos_integer(),
    attempts => pos_integer()
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
    buffer = <<>> :: binary(),
    host :: inet:ip_address() | string() | binary(),
    ip :: inet:ip_address(),
    port :: inet:port_number(),
    path = <<"/">> :: binary(),
    tls_opts = [] :: [ssl:tls_client_option()],
    timeout :: pos_integer(),
    attempts :: pos_integer(),
    pending = #{} :: #{binary() => #pending{}},
    stats = #{
        sent => 0,
        replies => 0,
        retransmits => 0,
        timeouts => 0,
        bad_replies => 0,
        unknown_cookies => 0,
        reconnects => 0
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
    Body = chappe_rtpengine_ng:encode_command(Command, Params),
    gen_server:call(Node, {cmd, Body}, infinity).

%% Fire-and-collect variant for state machines that must not block:
%% the result arrives as a {chappe_rtpengine_reply, Ref, Result} message. The
%% submission itself is a quick synchronous call so a dead client is
%% detected immediately (noproc exit).
-spec cmd_async(atom(), atom(), chappe_rtpengine_ng:params()) ->
    {ok, reference()} | {error, term()}.
cmd_async(Node, Command, Params) ->
    Body = chappe_rtpengine_ng:encode_command(Command, Params),
    Ref = make_ref(),
    case gen_server:call(Node, {cmd_async, Body, self(), Ref}, infinity) of
        ok -> {ok, Ref};
        {error, _} = Error -> Error
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
    case resolve(Host) of
        {ok, IP} ->
            State = #state{
                name = Name,
                transport = Transport,
                host = Host,
                ip = IP,
                port = Port,
                path = normalize_path(maps:get(path, Opts, <<"/">>)),
                tls_opts = maps:get(tls_opts, Opts, []),
                timeout = Timeout,
                attempts = Attempts
            },
            connect(State);
        {error, Reason} ->
            {stop, {resolve_failed, Host, Reason}}
    end.

handle_call({cmd, Body}, From, State0) ->
    case send_request(Body, From, State0) of
        {ok, State} ->
            {noreply, State};
        {error, Reason, State} ->
            {reply, {error, {send_failed, Reason}}, State}
    end;
handle_call({cmd_async, Body, Pid, Ref}, _From, State0) ->
    case send_request(Body, {async, Pid, Ref}, State0) of
        {ok, State} ->
            {reply, ok, State};
        {error, Reason, State} ->
            {reply, {error, {send_failed, Reason}}, State}
    end;
handle_call(stats, _From, State) ->
    {reply, State#state.stats, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, Socket, _IP, _Port, Packet}, #state{socket = Socket} = State) ->
    {noreply, handle_packet(Packet, State)};
handle_info({udp_passive, Socket}, #state{socket = Socket} = State) ->
    ok = inet:setopts(Socket, [{active, ?ACTIVE_N}]),
    {noreply, State};
handle_info({tcp, Socket, Data}, #state{socket = Socket} = State) ->
    Buffer = <<(State#state.buffer)/binary, Data/binary>>,
    State1 = parse_stream(State#state{buffer = Buffer}),
    {noreply, guard_stream_buffer(State1)};
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
    Family = family(IP),
    %% Large SDP bodies exceed default buffers and gen_udp silently
    %% truncates datagrams beyond recbuf.
    SockOpts = [
        binary,
        Family,
        {active, ?ACTIVE_N},
        {recbuf, 65535},
        {buffer, 65536}
    ],
    case gen_udp:open(0, SockOpts) of
        {ok, Socket} ->
            {ok, State#state{socket = Socket, connected = true}};
        {error, Reason} ->
            {stop, {socket_open_failed, Reason}}
    end;
connect(#state{transport = tcp, ip = IP, port = Port} = State) ->
    SockOpts = [
        binary,
        family(IP),
        {active, ?ACTIVE_N},
        {packet, raw},
        {nodelay, true}
    ],
    case gen_tcp:connect(IP, Port, SockOpts, 3000) of
        {ok, Socket} ->
            {ok, State#state{
                socket = Socket, connected = true, buffer = <<>>
            }};
        {error, Reason} ->
            ?LOG_WARNING("chappe_rtpengine_client ~p: connect failed: ~p", [
                State#state.name, Reason
            ]),
            _ = erlang:send_after(?RECONNECT_AFTER, self(), reconnect),
            {ok, State#state{socket = undefined, connected = false}}
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
        buffer = <<>>,
        pending = #{}
    }.

send_request(_Body, _ReplyTo, #state{connected = false} = State) ->
    {error, not_connected, State};
send_request(Body, ReplyTo, State0) ->
    Cookie = make_cookie(),
    Datagram = <<Cookie/binary, $\s, Body/binary>>,
    case transport_send(State0, Datagram) of
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

%% One complete message at a time out of the TCP byte stream: bytes up
%% to the first space are the cookie, then exactly one bencode value.
parse_stream(State) ->
    case binary:split(State#state.buffer, <<" ">>) of
        [_NoSpaceYet] ->
            State;
        [Cookie, Rest] ->
            case chappe_rtpengine_bencode:decode_prefix(Rest) of
                {ok, Value, Remainder} ->
                    State1 = State#state{buffer = Remainder},
                    parse_stream(deliver(Cookie, {ok, Value}, State1));
                incomplete ->
                    State;
                {error, Reason} ->
                    ?LOG_WARNING(
                        "chappe_rtpengine_client ~p: corrupt stream (~p), reconnecting",
                        [State#state.name, Reason]
                    ),
                    drop_connection(State)
            end
    end.

%% Bound the un-consumed stream buffer: a peer that never completes a message
%% cannot grow it without limit. drop_connection already empties the buffer, so
%% this is a no-op right after a corrupt-stream drop.
guard_stream_buffer(#state{buffer = Buf, name = Name} = State) when
    byte_size(Buf) > ?MAX_STREAM_BYTES
->
    ?LOG_WARNING(
        "chappe_rtpengine_client ~p: stream buffer over ~p bytes; dropping",
        [Name, ?MAX_STREAM_BYTES]
    ),
    drop_connection(State);
guard_stream_buffer(State) ->
    State.

deliver(Cookie, Decoded, State0) ->
    case take_pending(Cookie, State0) of
        {ok, #pending{from = From, tref = TRef}, State1} ->
            erlang:cancel_timer(TRef),
            reply_to_caller(From, Decoded, State1);
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
    State = bump(timeouts, State0),
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

make_cookie() ->
    Rand = integer_to_binary(rand:uniform(1 bsl 64), 16),
    Uniq = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    <<Rand/binary, "-", Uniq/binary>>.

resolve(IP) when is_tuple(IP) ->
    {ok, IP};
resolve(Host) when is_binary(Host) ->
    resolve(binary_to_list(Host));
resolve(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, IP} ->
            {ok, IP};
        {error, _} ->
            case inet:getaddr(Host, inet) of
                {ok, IP} -> {ok, IP};
                {error, _} -> inet:getaddr(Host, inet6)
            end
    end.
