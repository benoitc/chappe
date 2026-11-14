%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The WebSocket sink against a client that behaves as mod_audio_fork
%% and mod_audio_stream do (a text message of metadata, then binary L16
%% messages), and against raw sockets that do not.
-module(chappe_audio_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

all() ->
    [
        fork_flow,
        stream_module_flow,
        stereo_frames,
        token_in_header,
        refusals,
        second_connection_refused,
        slow_handshake,
        max_pending,
        oversized_frame,
        server_text,
        close_stream,
        connect_timeout,
        owner_death,
        stream_crash,
        set_owner,
        flood_bound,
        bad_options,
        tls,
        from_peer_node
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_audio),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_audio).

init_per_testcase(_Case, Config) ->
    {ok, L} = chappe_audio:listen(#{}),
    [{listener, L} | Config].

end_per_testcase(_Case, Config) ->
    try
        chappe_audio:stop_listener(?config(listener, Config))
    catch
        exit:_ -> ok
    end.

%% ---- cases ----

%% A fork connects with mod_audio_fork's subprotocol, which is echoed;
%% the metadata, then the audio, reach the owner tagged with the ref, in
%% order; the fork closing ends the stream with closed, and the stream
%% leaves its pg group and the registry.
fork_flow(Config) ->
    Ref = <<"call-1">>,
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{ref => Ref}),
    ?assertEqual([S], chappe_audio:streams(Ref)),
    {ok, C} = chappe_audio_test_ws:connect(Url, #{
        subprotocols => [<<"audio.drachtio.org">>]
    }),
    {connected, #{subprotocol := <<"audio.drachtio.org">>, path := Path}} =
        event(S, Ref),
    ?assertMatch(<<"/audio/", _/binary>>, Path),
    ok = chappe_audio_test_ws:send(C, {text, <<"{\"call\": \"one\"}">>}),
    Frames = [tone(160, I) || I <- lists:seq(1, 50)],
    [ok = chappe_audio_test_ws:send(C, {binary, F}) || F <- Frames],
    ?assertEqual({text, <<"{\"call\": \"one\"}">>}, event(S, Ref)),
    ?assertEqual(Frames, [frame(event(S, Ref)) || _ <- Frames]),
    ok = ws:close(C, 1000, <<>>),
    ?assertEqual(closed, event(S, Ref)),
    wait_dead(S),
    wait(fun() -> chappe_audio:streams(Ref) =:= [] end),
    ?assertEqual(error, chappe_audio_registry:lookup(id(Url))).

%% mod_audio_stream offers no subprotocol: none is selected, and the
%% events carry no ref when the stream has none.
stream_module_flow(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{}),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, #{subprotocol := undefined}}} = recv(),
    ok = chappe_audio_test_ws:send(C, {binary, tone(320, 1)}),
    {chappe_audio, S, {frame, _}} = recv(),
    ok = ws:close(C, 1000, <<>>),
    {chappe_audio, S, closed} = recv().

%% In stereo a message must hold whole sample pairs: one that does not
%% is counted and dropped, the next one goes through.
stereo_frames(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{
        format => #{rate => 16000, channels => 2}
    }),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    ok = chappe_audio_test_ws:send(C, {binary, <<1, 2, 3, 4, 5, 6>>}),
    ok = chappe_audio_test_ws:send(C, {binary, <<1, 2, 3, 4, 5, 6, 7, 8>>}),
    {chappe_audio, S, {frame, <<1, 2, 3, 4, 5, 6, 7, 8>>}} = recv(),
    ?assertMatch(
        #{bad_frames := 1, frames := 1, format := #{channels := 2}},
        chappe_audio:info(S)
    ),
    [Lv, Rv] = chappe_audio:levels(<<16384:16/little, 0:16>>, 2),
    ?assert(abs(Lv + 6.02) < 0.1),
    ?assertEqual('-inf', Rv),
    ok = chappe_audio:close(S).

%% The token may come as a Bearer token or as the password of Basic
%% auth (mod_audio_fork's MOD_AUDIO_BASIC_AUTH_* variables).
token_in_header(Config) ->
    L = ?config(listener, Config),
    lists:foreach(
        fun(Auth) ->
            {ok, S, Url} = chappe_audio:open(L, #{}),
            [NoQuery, Token] = binary:split(Url, <<"?token=">>),
            {ok, _C} = chappe_audio_test_ws:connect(NoQuery, #{
                extra_headers => [{<<"authorization">>, Auth(Token)}]
            }),
            {chappe_audio, S, {connected, _}} = recv(),
            ok = chappe_audio:close(S),
            receive
                {chappe_audio, S, closed} -> ok
            after 5000 -> ct:fail(not_closed)
            end
        end,
        [
            fun(T) -> <<"Bearer ", T/binary>> end,
            fun(T) ->
                <<"Basic ", (base64:encode(<<"fs:", T/binary>>))/binary>>
            end
        ]
    ).

%% Every refusal is an HTTP status before the upgrade, then the
%% connection closes; nothing reaches the stream, which still waits.
refusals(Config) ->
    L = ?config(listener, Config),
    {ok, S, Url} = chappe_audio:open(L, #{}),
    Port = port(L),
    {Path, Token} = path_token(Url),
    Good = fun(P) -> upgrade(<<"GET">>, P, <<"13">>) end,
    ?assertEqual(404, status(Port, Good(<<"/other/x?token=", Token/binary>>))),
    ?assertEqual(404, status(Port, Good(<<"/audio/a/b?token=", Token/binary>>))),
    ?assertEqual(401, status(Port, Good(<<"/audio/nope?token=", Token/binary>>))),
    ?assertEqual(401, status(Port, Good(<<Path/binary, "?token=bad">>))),
    ?assertEqual(401, status(Port, Good(Path))),
    Full = <<Path/binary, "?token=", Token/binary>>,
    ?assertEqual(405, status(Port, upgrade(<<"POST">>, Full, <<"13">>))),
    ?assertEqual(426, status(Port, upgrade(<<"GET">>, Full, <<"8">>))),
    ?assertEqual(
        400,
        status(Port, <<"GET ", Full/binary, " HTTP/1.1\r\nhost: x\r\n\r\n">>)
    ),
    ?assertEqual(400, status(Port, <<"GET ", Full/binary, " HTTP/1.0\r\n\r\n">>)),
    Big = binary:copy(<<"x-pad: 0123456789\r\n">>, 1000),
    ?assertEqual(
        400, status(Port, <<"GET ", Full/binary, " HTTP/1.1\r\n", Big/binary>>)
    ),
    ?assertEqual(400, status(Port, <<"garbage\r\n\r\n">>)),
    NoHost = binary:replace(Good(Full), <<"host: 127.0.0.1\r\n">>, <<>>),
    ?assertEqual(400, status(Port, NoHost)),
    ?assertMatch(#{phase := waiting}, chappe_audio:info(S)),
    ok = chappe_audio:close(S).

%% One connection per stream: a second one with the right token is
%% refused while the first is up.
second_connection_refused(Config) ->
    L = ?config(listener, Config),
    {ok, S, Url} = chappe_audio:open(L, #{}),
    {ok, _C} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    {Path, Token} = path_token(Url),
    Full = <<Path/binary, "?token=", Token/binary>>,
    ?assertEqual(401, status(port(L), upgrade(<<"GET">>, Full, <<"13">>))),
    ok = chappe_audio:close(S).

%% A client that never finishes its request is cut at handshake_timeout.
slow_handshake(_Config) ->
    {ok, L} = chappe_audio:listen(#{handshake_timeout => 300}),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port(L), [binary, {active, false}]),
    ok = gen_tcp:send(Sock, <<"GET /audio/x HTTP/1.1\r\n">>),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 2000),
    chappe_audio:stop_listener(L).

%% Past max_pending handshakes going, a new connection is closed before
%% anything is read; once they end, connections are served again.
max_pending(_Config) ->
    {ok, L} = chappe_audio:listen(#{max_pending => 3, handshake_timeout => 2000}),
    Port = port(L),
    Idle = [
        element(2, gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]))
     || _ <- lists:seq(1, 3)
    ],
    timer:sleep(200),
    {ok, Extra} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    ?assertEqual({error, closed}, gen_tcp:recv(Extra, 0, 1500)),
    [gen_tcp:close(I) || I <- Idle],
    timer:sleep(1500),
    {ok, S, Url} = chappe_audio:open(L, #{}),
    {ok, _} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    chappe_audio:stop_listener(L).

%% A message over max_frame closes the connection with 1009 (RFC 6455
%% 7.4.1) and ends the stream.
oversized_frame(_Config) ->
    {ok, L} = chappe_audio:listen(#{max_frame => 1024}),
    {ok, S, Url} = chappe_audio:open(L, #{}),
    C = raw(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    raw_send(C, {binary, binary:copy(<<0>>, 2048)}),
    ?assertEqual(1009, close_code(C)),
    {chappe_audio, S, closed} = recv(),
    chappe_audio:stop_listener(L).

%% send_text reaches the fork (the way its JSON commands go).
server_text(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{}),
    ?assertEqual({error, not_connected}, chappe_audio:send_text(S, <<"x">>)),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    ok = chappe_audio:send_text(S, <<"{\"type\": \"mark\"}">>),
    {ws_client, C, {text, <<"{\"type\": \"mark\"}">>}} = recv(),
    ok = chappe_audio:close(S).

%% close/1 closes with 1000, and the owner gets closed.
close_stream(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{}),
    C = raw(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    ok = chappe_audio:close(S),
    ?assertEqual(1000, close_code(C)),
    {chappe_audio, S, closed} = recv(),
    wait_dead(S),
    ok = chappe_audio:close(S).

%% A fork that never connects: the stream closes at connect_timeout.
connect_timeout(Config) ->
    {ok, S, _Url} = chappe_audio:open(?config(listener, Config), #{
        connect_timeout => 200
    }),
    {chappe_audio, S, closed} = recv(),
    wait_dead(S).

%% The owner dies: the stream closes the connection with 1001 (going
%% away), leaves pg and the registry, and stops.
owner_death(Config) ->
    L = ?config(listener, Config),
    Test = self(),
    Ref = <<"owner-death">>,
    Owner = spawn(fun() ->
        Test ! chappe_audio:open(L, #{ref => Ref}),
        receive
            stop -> ok
        end
    end),
    {ok, S, Url} = recv(),
    C = raw(Url),
    wait(fun() -> maps:get(phase, chappe_audio:info(S)) =:= connected end),
    exit(Owner, kill),
    ?assertEqual(1001, close_code(C)),
    wait_dead(S),
    wait(fun() -> chappe_audio:streams(Ref) =:= [] end),
    ?assertEqual(error, chappe_audio_registry:lookup(id(Url))).

%% The stream crashes: the link takes its session down, the fork sees
%% the connection end, the owner sees the stream go, and the listener
%% serves the next stream.
stream_crash(Config) ->
    L = ?config(listener, Config),
    {ok, S, Url} = chappe_audio:open(L, #{ref => <<"crash">>}),
    Mon = monitor(process, S),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    {chappe_audio, S, {connected, _}} = recv(),
    exit(S, kill),
    {'DOWN', Mon, process, S, killed} = recv(),
    receive
        {ws_client, C, {closed, _}} -> ok
    after 5000 -> ct:fail(still_connected)
    end,
    wait(fun() -> chappe_audio:streams(<<"crash">>) =:= [] end),
    {ok, S2, Url2} = chappe_audio:open(L, #{}),
    {ok, _} = chappe_audio_test_ws:connect(Url2),
    {chappe_audio, S2, {connected, _}} = recv(),
    ok = chappe_audio:close(S2).

%% set_owner moves the events, and the old owner's death no longer
%% matters.
set_owner(Config) ->
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{}),
    Test = self(),
    New = spawn(fun() -> fwd(Test) end),
    ok = chappe_audio:set_owner(S, New),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    {fwd, {chappe_audio, S, {connected, _}}} = recv(),
    ok = chappe_audio_test_ws:send(C, {binary, <<0, 0>>}),
    {fwd, {chappe_audio, S, {frame, <<0, 0>>}}} = recv(),
    ?assertEqual({error, badarg}, chappe_audio:set_owner(S, nobody)),
    ok = chappe_audio:close(S).

%% An owner that never reads: past max_queue messages waiting at it,
%% frames are dropped and counted, and the memory of the owner and the
%% stream stays flat however long the fork sends.
flood_bound(Config) ->
    Owner = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {ok, S, Url} = chappe_audio:open(?config(listener, Config), #{
        owner => Owner, max_queue => 100
    }),
    {ok, C} = chappe_audio_test_ws:connect(Url),
    wait(fun() -> maps:get(phase, chappe_audio:info(S)) =:= connected end),
    Frame = tone(320, 1),
    Send = fun(N) -> [ok = chappe_audio_test_ws:send(C, {binary, Frame}) || _ <- lists:seq(1, N)] end,
    Send(2000),
    wait(fun() -> maps:get(frames, chappe_audio:info(S)) =:= 2000 end),
    {memory, M1} = process_info(S, memory),
    {memory, O1} = process_info(Owner, memory),
    Send(20000),
    wait(fun() -> maps:get(frames, chappe_audio:info(S)) =:= 22000 end),
    {memory, M2} = process_info(S, memory),
    {memory, O2} = process_info(Owner, memory),
    #{dropped := Dropped} = chappe_audio:info(S),
    {message_queue_len, Q} = process_info(Owner, message_queue_len),
    ct:pal("owner queue ~p, dropped ~p, stream ~p -> ~p, owner ~p -> ~p", [
        Q, Dropped, M1, M2, O1, O2
    ]),
    ?assert(Q =< 101),
    ?assert(Dropped >= 22000 - 101),
    ?assert(M2 < 2 * M1 + 65536),
    ?assert(O2 < 2 * O1 + 65536),
    ok = chappe_audio:close(S),
    exit(Owner, kill).

%% Bad arguments fail in the caller.
bad_options(Config) ->
    L = ?config(listener, Config),
    ?assertEqual({error, {bad_option, ref}}, chappe_audio:open(L, #{ref => 1})),
    ?assertEqual(
        {error, {bad_option, format}},
        chappe_audio:open(L, #{format => #{channels => 3}})
    ),
    ?assertEqual({error, {bad_option, nope}}, chappe_audio:open(L, #{nope => 1})),
    ?assertEqual({error, badarg}, chappe_audio:open(L, nope)),
    ?assertEqual({error, {bad_option, port}}, chappe_audio:listen(#{port => -1})),
    ?assertEqual({error, no_listener}, chappe_audio:open(#{})).

%% wss: the listener terminates TLS with the options it is given.
tls(_Config) ->
    Key = [{key, {rsa, 2048, 65537}}, {digest, sha256}],
    #{server_config := Server, client_config := Client} =
        public_key:pkix_test_data(#{
            server_chain => #{root => Key, intermediates => [], peer => Key},
            client_chain => #{root => Key, intermediates => [], peer => Key}
        }),
    {ok, L} = chappe_audio:listen(#{tls => Server}),
    {ok, S, Url} = chappe_audio:open(L, #{}),
    ?assertMatch(<<"wss://", _/binary>>, Url),
    {ok, C} = chappe_audio_test_ws:connect(Url, #{
        ssl_opts => [{verify, verify_peer}, {server_name_indication, disable} | Client]
    }),
    {chappe_audio, S, {connected, _}} = recv(),
    ok = chappe_audio_test_ws:send(C, {binary, <<1, 0>>}),
    {chappe_audio, S, {frame, <<1, 0>>}} = recv(),
    ok = chappe_audio:close(S),
    chappe_audio:stop_listener(L).

%% An app on another node opens a stream on this node's listener, gets
%% its events there, and finds it through pg.
from_peer_node(Config) ->
    ok = ensure_dist(),
    L = ?config(listener, Config),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(), args => Paths, connection => standard_io}),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [chappe_audio]),
    Test = self(),
    Ref = <<"peer-call">>,
    Owner = erlang:spawn(Node, fun() ->
        Test ! {opened, chappe_audio:open(L, #{ref => Ref})},
        fwd(Test)
    end),
    {opened, {ok, S, Url}} = recv(),
    ?assertEqual(node(), node(S)),
    wait(fun() -> peer:call(Peer, chappe_audio, streams, [Ref]) =:= [S] end),
    C = raw(Url),
    {fwd, {chappe_audio, S, {connected, _}}} = recv(),
    raw_send(C, {binary, <<7, 0>>}),
    {fwd, {chappe_audio, S, {frame, <<7, 0>>}}} = recv(),
    ?assertEqual(Ref, peer:call(Peer, chappe_audio, ref, [S])),
    ?assertMatch(#{owner := Owner}, peer:call(Peer, chappe_audio, info, [S])),
    %% the owner's node goes: the stream sees its owner die
    peer:stop(Peer),
    ?assertEqual(1001, close_code(C)),
    wait_dead(S).

%% ---- helpers ----

%% A bare client over gen_tcp, to see the close codes the server sends.
raw(Url) ->
    {Path, Token} = path_token(Url),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, port_of(Url), [
        binary, {active, false}
    ]),
    ok = gen_tcp:send(
        Sock, upgrade(<<"GET">>, <<Path/binary, "?token=", Token/binary>>, <<"13">>)
    ),
    {ok, <<"HTTP/1.1 101", _/binary>> = Resp} = gen_tcp:recv(Sock, 0, 5000),
    [_, <<>>] = binary:split(Resp, <<"\r\n\r\n">>),
    Sock.

port_of(Url) ->
    #{port := Port} = uri_string:parse(Url),
    Port.

raw_send(Sock, Frame) ->
    ok = gen_tcp:send(Sock, ws_frame:encode(Frame, client)).

close_code(Sock) ->
    close_code(Sock, ws_frame:init_parser(#{role => client})).

close_code(Sock, P) ->
    {ok, Data} = gen_tcp:recv(Sock, 0, 5000),
    {ok, Msgs, P1} = ws_frame:parse(P, Data),
    case [C || {close, C, _} <- Msgs] of
        [Code | _] ->
            %% complete the closing handshake (RFC 6455 5.5.1)
            _ = gen_tcp:send(Sock, ws_frame:encode({close, Code, <<>>}, client)),
            Code;
        [] -> close_code(Sock, P1)
    end.

%% The next message, leaving a client's end of session in the mailbox
%% for the cases that wait on it.
recv() ->
    receive
        M when not is_tuple(M); element(1, M) =/= ws_client; tuple_size(M) =/= 3 ->
            M;
        {ws_client, _, Msg} = M when not is_tuple(Msg); element(1, Msg) =/= closed ->
            M
    after 5000 -> ct:fail(timeout)
    end.

%% one event shape with or without a ref: the ref is read from the
%% stream
event(S, Ref) ->
    receive
        {chappe_audio, S, _, _} -> ct:fail(four_tuple);
        {chappe_audio, S, E} ->
            ?assert(lists:member(chappe_audio:ref(S), [Ref, {error, closed}])),
            E
    after 5000 -> ct:fail(no_event)
    end.

frame({frame, F}) -> F.

fwd(To) ->
    receive
        M ->
            To ! {fwd, M},
            fwd(To)
    end.

tone(Bytes, Seed) ->
    <<<<((I * Seed) rem 2000 - 1000):16/little-signed>> || I <- lists:seq(1, Bytes div 2)>>.

id(Url) ->
    {Path, _} = path_token(Url),
    lists:last(binary:split(Path, <<"/">>, [global])).

path_token(Url) ->
    [Base, Token] = binary:split(Url, <<"?token=">>),
    #{path := Path} = uri_string:parse(Base),
    {Path, Token}.

port(L) ->
    maps:get(port, chappe_audio:listener_info(L)).

upgrade(Method, Target, Version) ->
    iolist_to_binary([
        Method,
        <<" ">>,
        Target,
        <<" HTTP/1.1\r\nhost: 127.0.0.1\r\nupgrade: websocket\r\n">>,
        <<"connection: Upgrade\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n">>,
        <<"sec-websocket-version: ">>,
        Version,
        <<"\r\n\r\n">>
    ]).

status(Port, Request) ->
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(Sock, Request),
    Resp = read_all(Sock, <<>>),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Resp,
    binary_to_integer(Code).

read_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, D} -> read_all(Sock, <<Acc/binary, D/binary>>);
        {error, closed} -> Acc
    end.

wait(F) ->
    wait(F, 100).

wait(_F, 0) ->
    ct:fail(wait_timeout);
wait(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait(F, N - 1)
    end.

wait_dead(Pid) ->
    wait(fun() -> not is_process_alive(Pid) end).

ensure_dist() ->
    case node() of
        nonode@nohost ->
            {ok, _} = net_kernel:start(chappe_audio_ct, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.
