%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc One opening handshake (RFC 6455 4.2), before anything is trusted.
%%
%% The process reads the upgrade request within handshake_timeout and
%% max_handshake bytes, checks that the path names a stream waiting on
%% this node and that the token matches it, checks the upgrade itself,
%% and only then answers 101 and hands the socket to the stream. Every
%% refusal is a plain HTTP status sent before the upgrade, after which
%% the connection closes: 404 for a path outside the listener's prefix,
%% 401 for an unknown stream, a wrong token or a stream already
%% connected (one answer for all three, so the status tells a scanner
%% nothing), 405 for a method other than GET, 426 for a WebSocket
%% version other than 13 (4.2.2, 4.4), 400 for anything else 4.2.1 asks
%% for (a missing Host, Upgrade, Connection or a bad key among them).
-module(chappe_audio_conn).
-behaviour(gen_server).

-export([start_link/1, go/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {cfg :: chappe_audio_listener:cfg()}).

-type state() :: #state{}.

-spec start_link(chappe_audio_listener:cfg()) -> {ok, pid()}.
start_link(Cfg) ->
    gen_server:start_link(?MODULE, Cfg, []).

%% Hand the accepted socket over (the caller has made Pid its owner).
-spec go(pid(), gen_tcp:socket()) -> ok.
go(Pid, Sock) ->
    gen_server:cast(Pid, {go, Sock}).

-spec init(chappe_audio_listener:cfg()) -> {ok, state()}.
init(Cfg) ->
    {ok, #state{cfg = Cfg}}.

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({go, Sock}, #state{cfg = Cfg} = S) ->
    #{handshake_timeout := Timeout} = Cfg,
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case transport(Sock, Cfg, Timeout) of
        {ok, T, H} ->
            _ = serve(T, H, read(T, H, <<>>, Deadline, Cfg), Cfg);
        error ->
            ok
    end,
    {stop, normal, S};
handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

transport(Sock, #{tls := undefined}, _Timeout) ->
    {ok, ws_transport_gen_tcp, Sock};
transport(Sock, #{tls := Tls}, Timeout) ->
    case ssl:handshake(Sock, Tls, Timeout) of
        {ok, TlsSock} ->
            {ok, ws_transport_ssl, TlsSock};
        {error, _} ->
            _ = gen_tcp:close(Sock),
            error
    end.

%% The request, read until its blank line, within the deadline and the
%% size bound.
read(T, H, Buf, Deadline, #{max_handshake := Max} = Cfg) ->
    case chappe_audio_http:parse(Buf) of
        {ok, Req, Rest} ->
            {ok, Req, Rest};
        {error, bad_request} ->
            {error, 400};
        more when byte_size(Buf) >= Max ->
            {error, 400};
        more ->
            Left = Deadline - erlang:monotonic_time(millisecond),
            case Left > 0 andalso T:recv(H, Left) of
                {ok, Data} ->
                    read(T, H, <<Buf/binary, Data/binary>>, Deadline, Cfg);
                _ ->
                    {error, closed}
            end
    end.

serve(T, H, {error, closed}, _Cfg) ->
    T:close(H);
serve(T, H, {error, Status}, _Cfg) ->
    refuse(T, H, Status);
serve(T, H, {ok, #{method := <<"GET">>} = Req, Rest}, Cfg) ->
    #{prefix := Prefix} = Cfg,
    case chappe_audio_http:route(Prefix, maps:get(path, Req)) of
        {ok, Id} -> stream(T, H, Id, Req, Rest, Cfg);
        error -> refuse(T, H, 404)
    end;
serve(T, H, {ok, _Req, _Rest}, _Cfg) ->
    refuse(T, H, 405).

stream(T, H, Id, Req, Rest, Cfg) ->
    Token = chappe_audio_http:token(Req),
    case chappe_audio_registry:lookup(Id) of
        {ok, Pid, Hash} ->
            case chappe_audio_lib:token_ok(Token, Hash) of
                true -> upgrade(T, H, Pid, Req, Rest, Cfg);
                false -> refuse(T, H, 401)
            end;
        error ->
            refuse(T, H, 401)
    end.

upgrade(T, H, Pid, #{headers := Headers} = Req, Rest, Cfg) ->
    case validate(Headers) of
        {ok, Info0} ->
            Info = subprotocol(Info0, Cfg),
            case chappe_audio_stream:claim(Pid) of
                ok -> accept(T, H, Pid, Req, Info, Rest);
                {error, _} -> refuse(T, H, 401)
            end;
        {error, {unsupported_version, _}} ->
            T:send(H, [
                <<"HTTP/1.1 426 Upgrade Required\r\n">>,
                <<"sec-websocket-version: 13\r\ncontent-length: 0\r\n">>,
                <<"connection: close\r\n\r\n">>
            ]),
            T:close(H);
        {error, _} ->
            refuse(T, H, 400)
    end.

%% RFC 6455 4.2.1 item 2, which ws_h1_upgrade leaves to the server: a
%% Host header field.
validate(Headers) ->
    case lists:keymember(<<"host">>, 1, Headers) of
        true -> ws_h1_upgrade:validate_request(Headers);
        false -> {error, missing_host}
    end.

%% The first subprotocol the client offers that the listener speaks
%% (mod_audio_fork offers audio.drachtio.org and needs it echoed); none
%% when the client offers none we speak (4.2.2: the server may select
%% none).
subprotocol(#{subprotocols := Offered} = Info, #{subprotocols := Ours}) ->
    case [P || P <- Offered, lists:member(P, Ours)] of
        [P | _] -> Info#{selected_subprotocol => P};
        [] -> Info
    end.

accept(T, H, Pid, Req, Info, Rest) ->
    Resp = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        [
            [N, <<": ">>, V, <<"\r\n">>]
         || {N, V} <- ws_h1_upgrade:response_headers(Info)
        ],
        <<"\r\n">>
    ],
    Peer =
        case T:peername(H) of
            {ok, P} -> P;
            _ -> undefined
        end,
    Conn = #{
        transport => T,
        handle => H,
        path => maps:get(path, Req),
        headers => maps:get(headers, Req),
        subprotocol => maps:get(selected_subprotocol, Info, undefined),
        peer => Peer,
        rest => Rest
    },
    case T:send(H, Resp) of
        ok ->
            case T:controlling_process(H, Pid) of
                ok ->
                    chappe_audio_stream:attach(Pid, Conn);
                {error, _} ->
                    chappe_audio_stream:attach_failed(Pid),
                    T:close(H)
            end;
        {error, _} ->
            chappe_audio_stream:attach_failed(Pid),
            T:close(H)
    end.

refuse(T, H, Status) ->
    _ = T:send(H, chappe_audio_http:refuse(Status)),
    T:close(H).
