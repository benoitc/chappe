%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% HEP capture: a call over UDP, TCP, TLS and WebSocket, with a capture
%% server (a UDP socket in the test) decoding every HEPv3 packet the node
%% sends. The native transports are captured by sofia (TPTAG_CAPT), the
%% WebSocket one by chappe_sip_hep.
-module(chappe_sip_hep_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    udp_call/1,
    tcp_call/1,
    tls_call/1,
    ws_call/1,
    off_by_default/1,
    bad_option/1,
    app_setting/1,
    restart_closes_socket/1
]).

-define(LO, {127, 0, 0, 1}).
-define(CAPTURE_ID, 2001).

all() ->
    [
        udp_call,
        tcp_call,
        tls_call,
        ws_call,
        off_by_default,
        bad_option,
        app_setting,
        restart_closes_socket
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    {ok, Hep} = gen_udp:open(0, [binary, {active, false}, {ip, ?LO}]),
    {ok, HP} = inet:port(Hep),
    [{hep, Hep}, {hep_port, HP} | Config].

end_per_testcase(_Case, Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    application:unset_env(chappe_sip, hep),
    gen_udp:close(?config(hep, Config)),
    ok.

%% ---- cases ----

%% A UDP call: the INVITE, the BYE and their responses all reach the
%% capture server, with the addresses and ports of each direction.
udp_call(Config) ->
    EP = start(Config, #{}),
    {ok, S} = gen_udp:open(0, [binary, {active, false}, {ip, ?LO}]),
    {ok, LP} = inet:port(S),
    Conn = {udp, S, EP},
    CallId = call(Conn, <<"UDP">>, LP),
    gen_udp:close(S),
    check(Config, CallId, udp, LP, EP, #{}).

%% A TCP call: captured by sofia like UDP, with the TCP protocol.
tcp_call(Config) ->
    EP = start(Config, #{}),
    {ok, S} = gen_tcp:connect(?LO, EP, [binary, {active, false}], 5000),
    {ok, LP} = inet:port(S),
    CallId = call({tcp, S}, <<"TCP">>, LP),
    gen_tcp:close(S),
    check(Config, CallId, tcp, LP, EP, #{}).

%% A TLS call: sofia captures the messages, not the TLS records.
tls_call(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "hepcerts"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    case gen_certs(Dir) of
        {error, no_openssl} ->
            {skip, "openssl not available"};
        ok ->
            TP = chappe_sip_test_port:pick(),
            _ = start(Config, #{
                tls => #{
                    contact =>
                        <<"sips:127.0.0.1:", (integer_to_binary(TP))/binary,
                            ";transport=tls">>,
                    cert_dir => list_to_binary(Dir),
                    verify => none,
                    allow_insecure => true
                }
            }),
            {ok, S} = ssl:connect(
                "127.0.0.1",
                TP,
                [
                    {verify, verify_none},
                    binary,
                    {active, false}
                ],
                5000
            ),
            {ok, {_, LP}} = ssl:sockname(S),
            CallId = call({tls, S}, <<"TLS">>, LP),
            ssl:close(S),
            %% sofia marks TLS with protocol 22 (IDP), as Homer expects
            check(Config, CallId, 22, LP, TP, #{})
    end.

%% A WebSocket call: captured by chappe_sip_hep, with the Call-ID in the
%% correlation chunk.
ws_call(Config) ->
    WP = chappe_sip_test_port:pick(),
    _ = start(Config, #{ws => #{port => WP}}),
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{
        handler => chappe_sip_ws_test_client,
        handler_opts => #{notify => self()},
        subprotocols => [<<"sip">>]
    }),
    CallId = call({ws, C}, <<"WS">>, 0),
    ws:close(C, 1000),
    check(Config, CallId, tcp, any, WP, #{correlation_id => CallId}).

%% Without a hep option nothing is sent anywhere.
off_by_default(Config) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => contact(EP)}),
    ok = answer(),
    {ok, S} = gen_udp:open(0, [binary, {active, false}, {ip, ?LO}]),
    {ok, LP} = inet:port(S),
    _ = call({udp, S, EP}, <<"UDP">>, LP),
    gen_udp:close(S),
    ?assertEqual({error, timeout}, gen_udp:recv(?config(hep, Config), 0, 500)).

%% A port sofia would not take, a version other than 3 or a bad host
%% fail the start.
bad_option(Config) ->
    EP = chappe_sip_test_port:pick(),
    Base = #{contact => contact(EP)},
    ?assertMatch(
        {error, {hep, {bad_port, 80}}},
        chappe_sip:start(Base#{
            hep => #{
                host => "127.0.0.1",
                port => 80
            }
        })
    ),
    HP = ?config(hep_port, Config),
    ?assertMatch(
        {error, {hep, {bad_version, 2}}},
        chappe_sip:start(Base#{
            hep => #{
                host => "127.0.0.1",
                port => HP,
                version => 2
            }
        })
    ),
    ?assertMatch(
        {error, {hep, {bad_host, _, _}}},
        chappe_sip:start(Base#{
            hep => #{
                host => "no.such.host.invalid",
                port => HP
            }
        })
    ).

%% The hep application setting is used when start/1 has none.
app_setting(Config) ->
    application:set_env(
        chappe_sip,
        hep,
        #{
            host => <<"127.0.0.1">>,
            port => ?config(hep_port, Config),
            capture_id => ?CAPTURE_ID
        }
    ),
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => contact(EP)}),
    ok = answer(),
    {ok, S} = gen_udp:open(0, [binary, {active, false}, {ip, ?LO}]),
    {ok, LP} = inet:port(S),
    CallId = call({udp, S, EP}, <<"UDP">>, LP),
    gen_udp:close(S),
    check(Config, CallId, udp, LP, EP, #{}).

%% sofia never closes its capture socket; the engine does, so stopping
%% and starting with capture on leaves no socket behind.
restart_closes_socket(Config) ->
    HP = ?config(hep_port, Config),
    Cycle = fun() ->
        EP = chappe_sip_test_port:pick(),
        ok = chappe_sip:start(#{
            contact => contact(EP),
            hep => #{host => "127.0.0.1", port => HP}
        }),
        ok = chappe_sip:stop()
    end,
    Cycle(),
    Before = open_fds(),
    [Cycle() || _ <- lists:seq(1, 6)],
    After = open_fds(),
    ct:log("open fds before ~p, after ~p", [Before, After]),
    ?assert(After =< Before + 1, {fd_leak, Before, After}).

%% ---- the call ----

start(Config, Extra) ->
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(
        maps:merge(
            #{
                contact => contact(EP),
                hep => #{
                    host => "127.0.0.1",
                    port => ?config(hep_port, Config),
                    capture_id => ?CAPTURE_ID
                }
            },
            Extra
        )
    ),
    ok = answer(),
    EP.

answer() ->
    chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()}),
        chappe_sip_dialog:wait(D)
    end).

%% INVITE, 200, ACK, BYE, 200. Returns the Call-ID.
call(Conn, Via, LP) ->
    CallId = <<"hep-", (hex(8))/binary>>,
    FT = hex(4),
    Inv = request(<<"INVITE">>, Via, LP, CallId, FT, undefined, 1, sdp()),
    ok = send(Conn, Inv),
    Ok = recv_status(Conn, 200, <<"INVITE">>),
    {ok, M} = chappe_sip_msg:parse(Ok),
    TT = chappe_sip_msg:to_tag(M),
    ok = send(Conn, request(<<"ACK">>, Via, LP, CallId, FT, TT, 1, <<>>)),
    ok = send(Conn, request(<<"BYE">>, Via, LP, CallId, FT, TT, 2, <<>>)),
    _ = recv_status(Conn, 200, <<"BYE">>),
    CallId.

request(Method, Via, LP, CallId, FT, TT, CSeq, Body) ->
    Proto = string:lowercase(Via),
    To =
        case TT of
            undefined -> <<"<sip:uas@127.0.0.1>">>;
            _ -> <<"<sip:uas@127.0.0.1>;tag=", TT/binary>>
        end,
    iolist_to_binary([
        Method,
        " sip:uas@127.0.0.1 SIP/2.0\r\n",
        "Via: SIP/2.0/",
        Via,
        " 127.0.0.1:",
        integer_to_binary(LP),
        ";branch=z9hG4bK",
        hex(6),
        ";rport\r\n",
        "Max-Forwards: 70\r\n",
        "From: <sip:caller@127.0.0.1>;tag=",
        FT,
        "\r\n",
        "To: ",
        To,
        "\r\n",
        "Call-ID: ",
        CallId,
        "\r\n",
        "CSeq: ",
        integer_to_binary(CSeq),
        " ",
        Method,
        "\r\n",
        "Contact: <sip:caller@127.0.0.1:",
        integer_to_binary(LP),
        ";transport=",
        Proto,
        ">\r\n",
        case Body of
            <<>> -> [];
            _ -> "Content-Type: application/sdp\r\n"
        end,
        "Content-Length: ",
        integer_to_binary(byte_size(Body)),
        "\r\n\r\n",
        Body
    ]).

send({udp, S, EP}, Bin) ->
    gen_udp:send(S, ?LO, EP, Bin);
send({tcp, S}, Bin) ->
    gen_tcp:send(S, Bin);
send({tls, S}, Bin) ->
    ssl:send(S, Bin);
send({ws, C}, Bin) ->
    ws:send(C, {text, Bin}),
    ok.

%% the next response with this status and CSeq method
recv_status(Conn, Status, Method) ->
    recv_status(
        Conn,
        Status,
        Method,
        <<>>,
        erlang:monotonic_time(millisecond) + 5000
    ).

recv_status(Conn, Status, Method, Buf, Deadline) ->
    case frame(Buf) of
        {ok, Msg, Rest} ->
            case is_status(Msg, Status, Method) of
                true -> Msg;
                false -> recv_status(Conn, Status, Method, Rest, Deadline)
            end;
        more ->
            Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
            case recv(Conn, Left) of
                {ok, Data} ->
                    recv_status(
                        Conn,
                        Status,
                        Method,
                        <<Buf/binary, Data/binary>>,
                        Deadline
                    );
                {error, Why} ->
                    ct:fail({no_response, Status, Method, Why})
            end
    end.

recv({udp, S, _}, T) ->
    case gen_udp:recv(S, 0, T) of
        {ok, {_, _, D}} -> {ok, D};
        E -> E
    end;
recv({tcp, S}, T) ->
    gen_tcp:recv(S, 0, T);
recv({tls, S}, T) ->
    ssl:recv(S, 0, T);
recv({ws, _}, T) ->
    receive
        {ws_in, D} -> {ok, D}
    after T -> {error, timeout}
    end.

is_status(Msg, Status, Method) ->
    case chappe_sip_msg:parse(Msg) of
        {ok, M} ->
            chappe_sip_msg:status(M) =:= Status andalso
                binary:match(chappe_sip_msg:get(<<"cseq">>, M), Method) =/=
                    nomatch;
        _ ->
            false
    end.

%% one message off a byte stream, by its Content-Length
frame(Buf) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        nomatch ->
            more;
        {Pos, 4} ->
            Head = binary:part(Buf, 0, Pos),
            Len =
                case
                    re:run(
                        Head,
                        "\\r\\n(?:content-length|l)[ \\t]*:[ \\t]*(\\d+)",
                        [caseless, {capture, all_but_first, binary}]
                    )
                of
                    {match, [L]} -> binary_to_integer(L);
                    nomatch -> 0
                end,
            Total = Pos + 4 + Len,
            case byte_size(Buf) >= Total of
                true ->
                    <<Msg:Total/binary, Rest/binary>> = Buf,
                    {ok, Msg, Rest};
                false ->
                    more
            end
    end.

%% ---- the capture server ----

%% Every packet the capture server got for this call: the INVITE and the
%% BYE came in (peer to us), the 200s to both went out (us to peer).
check(Config, CallId, Proto, PeerPort, OurPort, Extra) ->
    Pkts = collect(?config(hep, Config), CallId, 3000),
    ct:log("~b packets for ~s:~n~p", [length(Pkts), CallId, Pkts]),
    In = fun(Start) -> find(Pkts, Start, in, PeerPort, OurPort) end,
    Out = fun(Start) -> find(Pkts, Start, out, PeerPort, OurPort) end,
    Now = os:system_time(second),
    lists:foreach(
        fun(P) ->
            ?assertMatch(
                #{
                    capture_id := ?CAPTURE_ID,
                    family := inet,
                    proto_type := 1
                },
                P
            ),
            ?assertEqual(proto(Proto), maps:get(proto, P)),
            {Sec, _} = maps:get(time, P),
            ?assert(abs(Now - Sec) < 30, {clock, Sec, Now}),
            maps:foreach(
                fun(K, V) -> ?assertEqual(V, maps:get(K, P)) end,
                Extra
            )
        end,
        [
            In(<<"INVITE ">>),
            In(<<"BYE ">>),
            Out(<<"SIP/2.0 200">>)
        ]
    ),
    ok.

proto(udp) -> udp;
proto(tcp) -> tcp;
proto(N) -> N.

%% the packets that carry CallId, until none came for a while
collect(Sock, CallId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collect(Sock, CallId, Deadline, []).

collect(Sock, CallId, Deadline, Acc) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case gen_udp:recv(Sock, 0, min(Left, 500)) of
        {ok, {_, _, Bin}} ->
            {ok, P} = chappe_sip_hep:decode(Bin),
            case binary:match(maps:get(payload, P), CallId) of
                nomatch -> collect(Sock, CallId, Deadline, Acc);
                _ -> collect(Sock, CallId, Deadline, [P | Acc])
            end;
        {error, timeout} when Acc =/= [] ->
            lists:reverse(Acc);
        {error, timeout} when Left > 0 ->
            collect(Sock, CallId, Deadline, Acc);
        {error, timeout} ->
            lists:reverse(Acc)
    end.

%% the packet whose payload starts with Start, in the given direction
find(Pkts, Start, Dir, PeerPort, OurPort) ->
    Match = [
        P
     || #{payload := Pl, src := {_, SP}, dst := {_, DP}} = P <- Pkts,
        binary:longest_common_prefix([Pl, Start]) =:= byte_size(Start),
        dir_ok(Dir, SP, DP, PeerPort, OurPort)
    ],
    case Match of
        [P | _] -> P;
        [] -> ct:fail({not_captured, Dir, Start, Pkts})
    end.

dir_ok(in, SP, DP, PeerPort, OurPort) ->
    DP =:= OurPort andalso (PeerPort =:= any orelse SP =:= PeerPort);
dir_ok(out, SP, DP, PeerPort, OurPort) ->
    SP =:= OurPort andalso (PeerPort =:= any orelse DP =:= PeerPort).

%% ---- helpers ----

open_fds() ->
    {ok, Fds} = file:list_dir("/dev/fd"),
    length(Fds).

contact(Port) ->
    <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>.

sdp() ->
    <<
        "v=0\r\no=hep 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
    >>.

hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).

gen_certs(Dir) ->
    Key = filename:join(Dir, "key.pem"),
    Cert = filename:join(Dir, "cert.pem"),
    Cmd = lists:flatten(
        io_lib:format(
            "openssl req -x509 -newkey rsa:2048 -keyout ~ts -out ~ts -days 2 "
            "-nodes -subj '/CN=127.0.0.1' 2>/dev/null",
            [Key, Cert]
        )
    ),
    _ = os:cmd(Cmd),
    case filelib:is_file(Cert) andalso filelib:is_file(Key) of
        false ->
            {error, no_openssl};
        true ->
            {ok, CertBin} = file:read_file(Cert),
            {ok, KeyBin} = file:read_file(Key),
            ok = file:write_file(
                filename:join(Dir, "agent.pem"),
                [CertBin, KeyBin]
            ),
            ok = file:write_file(filename:join(Dir, "cafile.pem"), CertBin),
            ok
    end.
