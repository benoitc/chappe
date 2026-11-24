%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Fake rtpengine for tests: a UDP server that decodes NG datagrams and
%% answers according to a handler fun. The handler receives the count
%% of datagrams seen so far (0-based) and the decoded command dict, and
%% returns:
%%   {reply, Map}           reply with the bencoded map
%%   {reply_dup, Map}       reply twice (duplicate datagram on the wire)
%%   {reply_raw, Bin}       reply with raw bytes after the cookie
%%   {reply_after, Ms, Map} reply after a delay
%%   drop                   no reply
%% Every received {Cookie, Cmd} is logged and retrievable, which lets
%% tests assert that retransmissions reuse the same cookie. The
%% handler can be swapped at runtime with set_handler/2 to simulate a
%% node going unresponsive and recovering.
%%
%% start_tcp/1 runs the same fake over NG-TCP (one connection at a
%% time, re-accepting after a close, incremental stream parsing).
%% TCP handlers may additionally return:
%%   {reply_split, Map}  send the reply in two chunks with a delay
%%   {reply_raw, Bin}    send the cookie, a space, then raw bytes
%%   {raw, Bin}          send raw bytes with no cookie at all
%%   close               close the connection without replying
%%
%% start_ws/1 and start_wss/1 run the fake over NG-WebSocket using
%% erlang_ws's reference server (ws_h1_tcp_server), granting the
%% ng.rtpengine.com subprotocol and terminating TLS for wss with an
%% in-memory throwaway certificate. One binary frame is one message;
%% handlers may return {reply, _} | {reply_text, _} (the reply in a
%% text frame) | {reply_raw, _} | {reply_after, _} | drop | close, and
%% replies are cached by cookie like the UDP
%% fake. start_ws/2 takes #{subprotocols => [binary()] | none} to
%% model a server granting a different (or no) subprotocol.
-module(chappe_rtpengine_fake_server).

-export([
    start/0,
    start/1,
    start_at/3,
    start_tcp/0,
    start_tcp/1,
    start_ws/0,
    start_ws/1,
    start_ws/2,
    start_wss/0,
    start_wss/1,
    stop/1,
    received/1,
    set_handler/2,
    default_handler/2
]).

start() ->
    start(fun default_handler/2).

start(Handler) ->
    {ok, _, _} = start_at(Handler, {127, 0, 0, 1}, 0).

%% A UDP fake bound to a given address and port (0 picks one), so two
%% fakes can share a port on different addresses; {error, Reason} when
%% the address is not available on this host.
start_at(Handler, IP, Port0) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Handler, IP, Port0) end),
    receive
        {Pid, {ok, Port}} -> {ok, Pid, Port};
        {Pid, {error, _} = Error} -> Error
    after 5000 -> error(fake_server_start_timeout)
    end.

start_tcp() ->
    start_tcp(fun default_handler/2).

start_tcp(Handler) ->
    Parent = self(),
    Pid = spawn_link(fun() -> tcp_init(Parent, Handler) end),
    receive
        {Pid, Port} -> {ok, Pid, Port}
    after 5000 -> error(fake_server_start_timeout)
    end.

start_ws() ->
    start_ws(fun default_handler/2).

start_ws(Handler) ->
    start_ws(Handler, #{}).

start_ws(Handler, Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() -> ws_init(Parent, Handler, Opts) end),
    receive
        {Pid, Port} -> {ok, Pid, Port}
    after 5000 -> error(fake_server_start_timeout)
    end.

start_wss() ->
    start_wss(fun default_handler/2).

start_wss(Handler) ->
    %% the pkix_test_data defaults sign with SHA-1, which current TLS
    %% stacks refuse; ask for RSA + SHA-256 chains
    CertOpts = [{digest, sha256}, {key, {rsa, 2048, 65537}}],
    Chain = #{
        root => CertOpts,
        intermediates => [CertOpts],
        peer => CertOpts
    },
    Certs = public_key:pkix_test_data(#{
        server_chain => Chain, client_chain => Chain
    }),
    start_ws(Handler, #{tls => maps:get(server_config, Certs)}).

stop(Pid) ->
    Pid ! stop,
    ok.

received(Pid) ->
    Pid ! {self(), get_received},
    receive
        {Pid, Log} -> Log
    after 5000 -> error(fake_server_received_timeout)
    end.

set_handler(Pid, Handler) ->
    Pid ! {set_handler, Handler},
    ok.

default_handler(_N, #{<<"command">> := <<"ping">>}) ->
    {reply, #{<<"result">> => <<"pong">>}};
default_handler(_N, #{<<"command">> := Cmd, <<"sdp">> := SDP} = Dict) when
    Cmd =:= <<"offer">>; Cmd =:= <<"answer">>
->
    {reply, #{
        <<"result">> => <<"ok">>,
        <<"sdp">> => <<SDP/binary, "a=rtpengine:fake\r\n">>,
        <<"call-id-echo">> => maps:get(<<"call-id">>, Dict, <<>>)
    }};
%% publish is one-sided: rtpengine answers the offer itself, so the
%% reply SDP is an answer with every m-line accepted.
default_handler(_N, #{<<"command">> := <<"publish">>, <<"sdp">> := SDP}) ->
    {reply, #{
        <<"result">> => <<"ok">>,
        <<"sdp">> => <<SDP/binary, "a=rtpengine:fake-publish\r\n">>
    }};
default_handler(_N, #{<<"command">> := <<"query">>}) ->
    {reply, #{
        <<"result">> => <<"ok">>,
        <<"created">> => 1700000000,
        <<"tags">> => #{},
        <<"totals">> => #{<<"RTP">> => #{<<"packets">> => 0}}
    }};
default_handler(_N, #{<<"command">> := <<"delete">>}) ->
    {reply, #{<<"result">> => <<"ok">>}};
default_handler(N, #{<<"command">> := <<"subscribe request">>}) ->
    {reply, #{
        <<"result">> => <<"ok">>,
        <<"sdp">> => <<"v=0\r\nm=audio 40000 RTP/AVP 0\r\na=sendonly\r\n">>,
        <<"to-tag">> => <<"sub-", (integer_to_binary(N))/binary>>,
        <<"from-tags">> => [<<"ft">>]
    }};
default_handler(_N, #{<<"command">> := <<"subscribe answer">>}) ->
    {reply, #{<<"result">> => <<"ok">>}};
default_handler(_N, #{<<"command">> := <<"unsubscribe">>}) ->
    {reply, #{<<"result">> => <<"ok">>}};
default_handler(_N, #{<<"command">> := Cmd}) when
    Cmd =:= <<"play media">>;
    Cmd =:= <<"stop media">>;
    Cmd =:= <<"play DTMF">>;
    Cmd =:= <<"block DTMF">>;
    Cmd =:= <<"unblock DTMF">>;
    Cmd =:= <<"block media">>;
    Cmd =:= <<"unblock media">>;
    Cmd =:= <<"silence media">>;
    Cmd =:= <<"unsilence media">>;
    Cmd =:= <<"start recording">>;
    Cmd =:= <<"stop recording">>;
    Cmd =:= <<"start forwarding">>;
    Cmd =:= <<"stop forwarding">>
->
    {reply, #{<<"result">> => <<"ok">>}};
default_handler(_N, #{<<"command">> := <<"list">>} = Dict) ->
    Calls = [<<"c1">>, <<"c2">>, <<"c3">>],
    {reply, #{
        <<"result">> => <<"ok">>,
        <<"calls">> => lists:sublist(Calls, maps:get(<<"limit">>, Dict, 32))
    }};
default_handler(_N, #{<<"command">> := <<"statistics">>}) ->
    {reply, #{
        <<"result">> => <<"ok">>,
        <<"statistics">> => #{
            <<"currentstatistics">> => #{<<"sessionstotal">> => 3}
        }
    }};
default_handler(_N, _Dict) ->
    {reply, #{
        <<"result">> => <<"error">>,
        <<"error-reason">> => <<"Unrecognized command">>
    }}.

%% internal

init(Parent, Handler, IP, Port0) ->
    Family =
        case tuple_size(IP) of
            8 -> inet6;
            4 -> inet
        end,
    case
        gen_udp:open(Port0, [
            binary,
            Family,
            {active, true},
            {ip, IP},
            {recbuf, 262144},
            {sndbuf, 262144},
            {buffer, 65536}
        ])
    of
        {ok, Socket} ->
            {ok, Port} = inet:port(Socket),
            Parent ! {self(), {ok, Port}},
            loop(Socket, Handler, 0, [], #{});
        {error, _} = Error ->
            Parent ! {self(), Error}
    end.

%% Like real rtpengine, replies are cached by cookie: a duplicate
%% request (a retransmit) is served the cached bytes without invoking
%% the handler again. Every datagram is still logged. Dropped
%% requests cache nothing, so retransmits after drops reach the
%% handler as before.
loop(Socket, Handler, N, Log, Cache) ->
    receive
        {udp, Socket, IP, Port, Packet} ->
            [Cookie, Body] = binary:split(Packet, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Log1 = [{Cookie, Cmd} | Log],
            case maps:find(Cookie, Cache) of
                {ok, CachedBin} ->
                    ok = gen_udp:send(Socket, IP, Port, CachedBin),
                    loop(Socket, Handler, N, Log1, Cache);
                error ->
                    Cache1 =
                        handle_request(
                            Socket, IP, Port, Cookie, Handler(N, Cmd), Cache
                        ),
                    loop(Socket, Handler, N + 1, Log1, Cache1)
            end;
        {deferred, IP, Port, Cookie, Map} ->
            Bin = frame(Cookie, Map),
            ok = gen_udp:send(Socket, IP, Port, Bin),
            loop(Socket, Handler, N, Log, Cache#{Cookie => Bin});
        {set_handler, NewHandler} ->
            loop(Socket, NewHandler, N, Log, Cache);
        {From, get_received} ->
            From ! {self(), lists:reverse(Log)},
            loop(Socket, Handler, N, Log, Cache);
        stop ->
            gen_udp:close(Socket)
    end.

handle_request(Socket, IP, Port, Cookie, {reply, Map}, Cache) ->
    Bin = frame(Cookie, Map),
    ok = gen_udp:send(Socket, IP, Port, Bin),
    Cache#{Cookie => Bin};
handle_request(Socket, IP, Port, Cookie, {reply_dup, Map}, Cache) ->
    Bin = frame(Cookie, Map),
    ok = gen_udp:send(Socket, IP, Port, Bin),
    ok = gen_udp:send(Socket, IP, Port, Bin),
    Cache#{Cookie => Bin};
handle_request(Socket, IP, Port, Cookie, {reply_raw, Raw}, Cache) ->
    Bin = iolist_to_binary([Cookie, $\s, Raw]),
    ok = gen_udp:send(Socket, IP, Port, Bin),
    Cache#{Cookie => Bin};
handle_request(_Socket, IP, Port, Cookie, {reply_after, Ms, Map}, Cache) ->
    _ = erlang:send_after(Ms, self(), {deferred, IP, Port, Cookie, Map}),
    Cache;
handle_request(_Socket, _IP, _Port, _Cookie, drop, Cache) ->
    Cache.

frame(Cookie, Map) ->
    iolist_to_binary([Cookie, $\s, chappe_rtpengine_bencode:encode(Map)]).

%% TCP mode

tcp_init(Parent, Handler) ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {active, false},
        {ip, {127, 0, 0, 1}},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    Parent ! {self(), Port},
    tcp_loop(Listen, Handler, 0, [], undefined).

tcp_loop(Listen, Handler, N, Log, undefined) ->
    receive
        {set_handler, NewHandler} ->
            tcp_loop(Listen, NewHandler, N, Log, undefined);
        {From, get_received} ->
            From ! {self(), lists:reverse(Log)},
            tcp_loop(Listen, Handler, N, Log, undefined);
        stop ->
            gen_tcp:close(Listen)
    after 0 ->
        case gen_tcp:accept(Listen, 200) of
            {ok, Socket} ->
                ok = inet:setopts(Socket, [{active, true}]),
                tcp_loop(Listen, Handler, N, Log, {Socket, <<>>});
            {error, timeout} ->
                tcp_loop(Listen, Handler, N, Log, undefined)
        end
    end;
tcp_loop(Listen, Handler, N, Log, {Socket, Buffer}) ->
    receive
        {tcp, Socket, Data} ->
            case
                tcp_consume(
                    Socket,
                    Handler,
                    N,
                    Log,
                    <<Buffer/binary, Data/binary>>
                )
            of
                {continue, N1, Log1, Rest} ->
                    tcp_loop(Listen, Handler, N1, Log1, {Socket, Rest});
                {closed, N1, Log1} ->
                    tcp_loop(Listen, Handler, N1, Log1, undefined)
            end;
        {tcp_closed, Socket} ->
            tcp_loop(Listen, Handler, N, Log, undefined);
        {deferred_send, Socket2, Bin} ->
            _ = gen_tcp:send(Socket2, Bin),
            tcp_loop(Listen, Handler, N, Log, {Socket, Buffer});
        {set_handler, NewHandler} ->
            tcp_loop(Listen, NewHandler, N, Log, {Socket, Buffer});
        {From, get_received} ->
            From ! {self(), lists:reverse(Log)},
            tcp_loop(Listen, Handler, N, Log, {Socket, Buffer});
        stop ->
            gen_tcp:close(Socket),
            gen_tcp:close(Listen)
    end.

tcp_consume(Socket, Handler, N, Log, Buffer) ->
    case binary:split(Buffer, <<" ">>) of
        [_NoSpaceYet] ->
            {continue, N, Log, Buffer};
        [Cookie, Rest] ->
            case chappe_rtpengine_bencode:decode_prefix(Rest) of
                {ok, Cmd, Remainder} ->
                    Log1 = [{Cookie, Cmd} | Log],
                    case Handler(N, Cmd) of
                        {reply, Map} ->
                            ok = gen_tcp:send(Socket, [
                                Cookie,
                                $\s,
                                chappe_rtpengine_bencode:encode(Map)
                            ]),
                            tcp_consume(
                                Socket, Handler, N + 1, Log1, Remainder
                            );
                        {reply_split, Map} ->
                            Bin = iolist_to_binary([
                                Cookie,
                                $\s,
                                chappe_rtpengine_bencode:encode(Map)
                            ]),
                            Half = byte_size(Bin) div 2,
                            <<A:Half/binary, B/binary>> = Bin,
                            ok = gen_tcp:send(Socket, A),
                            _ = erlang:send_after(
                                50, self(), {deferred_send, Socket, B}
                            ),
                            tcp_consume(
                                Socket, Handler, N + 1, Log1, Remainder
                            );
                        {reply_raw, Raw} ->
                            ok = gen_tcp:send(Socket, [Cookie, $\s, Raw]),
                            tcp_consume(
                                Socket, Handler, N + 1, Log1, Remainder
                            );
                        {raw, Raw} ->
                            ok = gen_tcp:send(Socket, Raw),
                            tcp_consume(
                                Socket, Handler, N + 1, Log1, Remainder
                            );
                        drop ->
                            tcp_consume(
                                Socket, Handler, N + 1, Log1, Remainder
                            );
                        close ->
                            gen_tcp:close(Socket),
                            {closed, N + 1, Log1}
                    end;
                incomplete ->
                    {continue, N, Log, Buffer}
            end
    end.

%% WebSocket mode: ws_h1_tcp_server accepts and upgrades connections
%% (spawning one chappe_rtpengine_fake_ws_handler session each); this control
%% loop owns the handler fun, the request log and the reply cache.

ws_init(Parent, Handler, Opts) ->
    Subprotocols =
        case maps:get(subprotocols, Opts, [<<"ng.rtpengine.com">>]) of
            none -> #{};
            List -> #{subprotocols => List}
        end,
    Tls =
        case maps:find(tls, Opts) of
            {ok, TlsOpts} -> #{tls => TlsOpts};
            error -> #{}
        end,
    ServerOpts = maps:merge(
        #{
            port => 0,
            ip => {127, 0, 0, 1},
            handler => chappe_rtpengine_fake_ws_handler,
            handler_opts => #{control => self()}
        },
        maps:merge(Subprotocols, Tls)
    ),
    {ok, Srv} = ws_h1_tcp_server:start_link(ServerOpts),
    {ok, Port} = ws_h1_tcp_server:port(Srv),
    Parent ! {self(), Port},
    ws_loop(Srv, Handler, 0, [], #{}).

ws_loop(Srv, Handler, N, Log, Cache) ->
    receive
        {ws_frame, Session, Frame} ->
            [Cookie, Body] = binary:split(Frame, <<" ">>),
            {ok, Cmd} = chappe_rtpengine_bencode:decode(Body),
            Log1 = [{Cookie, Cmd} | Log],
            case maps:find(Cookie, Cache) of
                {ok, CachedBin} ->
                    Session ! {send, CachedBin},
                    ws_loop(Srv, Handler, N, Log1, Cache);
                error ->
                    Cache1 = ws_handle_request(
                        Session, Cookie, Handler(N, Cmd), Cache
                    ),
                    ws_loop(Srv, Handler, N + 1, Log1, Cache1)
            end;
        {deferred_ws, Session, Cookie, Map} ->
            Bin = frame(Cookie, Map),
            Session ! {send, Bin},
            ws_loop(Srv, Handler, N, Log, Cache#{Cookie => Bin});
        {set_handler, NewHandler} ->
            ws_loop(Srv, NewHandler, N, Log, Cache);
        {From, get_received} ->
            From ! {self(), lists:reverse(Log)},
            ws_loop(Srv, Handler, N, Log, Cache);
        stop ->
            ws_h1_tcp_server:stop(Srv)
    end.

ws_handle_request(Session, Cookie, {reply, Map}, Cache) ->
    Bin = frame(Cookie, Map),
    Session ! {send, Bin},
    Cache#{Cookie => Bin};
ws_handle_request(Session, Cookie, {reply_text, Map}, Cache) ->
    Bin = frame(Cookie, Map),
    Session ! {send_text, Bin},
    Cache#{Cookie => Bin};
ws_handle_request(Session, Cookie, {reply_raw, Raw}, Cache) ->
    Bin = iolist_to_binary([Cookie, $\s, Raw]),
    Session ! {send, Bin},
    Cache#{Cookie => Bin};
ws_handle_request(Session, Cookie, {reply_after, Ms, Map}, Cache) ->
    _ = erlang:send_after(Ms, self(), {deferred_ws, Session, Cookie, Map}),
    Cache;
ws_handle_request(Session, _Cookie, close, Cache) ->
    Session ! close,
    Cache;
ws_handle_request(_Session, _Cookie, drop, Cache) ->
    Cache.
