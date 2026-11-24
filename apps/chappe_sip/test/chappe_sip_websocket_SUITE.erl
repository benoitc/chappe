%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% SIP-over-WebSocket (RFC 7118) via livery.
%%
%% A ws:connect client drives SIP over a WebSocket to the engine. The WS
%% transaction layer and the engine backend multiplexing carry the existing
%% TU logic (registrar, UAS) over WS unchanged.
-module(chappe_sip_websocket_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    ws_register/1,
    ws_deregister_on_close/1,
    ws_call/1,
    ws_transport_survives_engine_gap/1,
    ws_malformed_does_not_crash/1,
    ws_connection_cap/1,
    ws_origin_allowlist/1,
    ws_start_failure/1,
    ws_error_final_has_totag/1,
    ws_invite_100_trying/1
]).

all() ->
    [
        ws_register,
        ws_deregister_on_close,
        ws_call,
        ws_transport_survives_engine_gap,
        ws_malformed_does_not_crash,
        ws_connection_cap,
        ws_origin_allowlist,
        ws_start_failure,
        ws_error_final_has_totag,
        ws_invite_100_trying
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    _ = chappe_sip_registry:clear(),
    application:unset_env(chappe_sip, max_ws_connections),
    application:unset_env(chappe_sip, ws_allowed_origins),
    ok.

%% REGISTER over WS is answered over WS and stored with its flow.
ws_register(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    ws:send(C, {text, register_req()}),
    R = recv_ws(200),
    {_, _} = binary:match(R, <<"CSeq: 1 REGISTER">>),
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    ws:close(C, 1000).

%% Closing the WS connection purges the binding: a WS UA is reachable only
%% over its flow (RFC 5626), so a dropped flow deregisters it.
ws_deregister_on_close(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    ws:send(C, {text, register_req()}),
    _ = recv_ws(200),
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    ws:close(C, 1000),
    ok = wait_gone(<<"sip:alice@127.0.0.1">>, 60),
    ok.

wait_gone(_Aor, 0) ->
    ct:fail(still_registered);
wait_gone(Aor, N) ->
    case chappe_sip:location(Aor) of
        [] ->
            ok;
        _ ->
            timer:sleep(50),
            wait_gone(Aor, N - 1)
    end.

%% While the engine's registered name is briefly absent (as during an engine
%% restart), an inbound WS frame that emits an engine event must not crash the
%% WS transport (it would take all WS state down with it).
ws_transport_survives_engine_gap(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    ws:send(C, {text, register_req()}),
    _ = recv_ws(200),
    TPid = whereis(chappe_sip_ws_transport),
    EPid = whereis(chappe_sip_engine),
    %% simulate the mid-restart window: the engine name is momentarily free
    true = unregister(chappe_sip_engine),
    try
        %% a second REGISTER makes the transport emit a {request,...} event
        ws:send(C, {text, register_req()}),
        timer:sleep(300),
        %% the transport must be the same live process (it did not crash)
        ?assertEqual(TPid, whereis(chappe_sip_ws_transport)),
        ?assert(is_process_alive(TPid))
    after
        register(chappe_sip_engine, EPid)
    end,
    ws:close(C, 1000).

%% A malformed WS SIP frame (missing mandatory headers, or non-UTF-8 bytes)
%% must not crash the singleton transport (which would close every session).
ws_malformed_does_not_crash(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    TPid = whereis(chappe_sip_ws_transport),
    %% valid request line + Via, but no From/To/Call-ID/CSeq (reviewer's repro)
    ws:send(
        C,
        {text, <<
            "INVITE sip:x@127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/WS d.invalid;branch=z9hG4bKbad\r\n"
            "Content-Length: 0\r\n\r\n"
        >>}
    ),
    %% a CANCEL with only a Via (exercises the response-build path)
    ws:send(
        C,
        {text, <<
            "CANCEL sip:x@127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/WS d.invalid;branch=z9hG4bKbad2\r\n"
            "Content-Length: 0\r\n\r\n"
        >>}
    ),
    %% a garbage line that is not a SIP message at all
    ws:send(C, {text, <<"not a sip message\r\n\r\n">>}),
    timer:sleep(200),
    ?assertEqual(TPid, whereis(chappe_sip_ws_transport)),
    ?assert(is_process_alive(TPid)),
    %% and it still serves a valid REGISTER afterwards
    ws:send(C, {text, register_req()}),
    R = recv_ws(200),
    {_, _} = binary:match(R, <<"CSeq: 1 REGISTER">>),
    ws:close(C, 1000).

%% a full call over WS: INVITE/200/ACK/BYE.
ws_call(_Config) ->
    {_EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        put(test_pid, Test),
        chappe_sip_handler:start(chappe_sip_echo_handler, Req, Res)
    end),
    C = connect(WP),
    ws:send(C, {text, invite_req()}),
    R200 = recv_ws(200),
    % SDP echoed
    {_, _} = binary:match(R200, <<"v=0">>),
    TT = to_tag(R200),
    ws:send(C, {text, ack_req(TT)}),
    ws:send(C, {text, bye_req(TT)}),
    % 200 to BYE
    _ = recv_ws(200),
    receive
        {handler_terminated, {destroyed, _}} -> ok
    after 5000 -> ct:fail(no_terminate)
    end,
    ws:close(C, 1000).

%% F11: with an Origin allowlist set, a disallowed browser Origin is refused at
%% the upgrade, while an allowed one connects.
ws_origin_allowlist(_Config) ->
    {_EP, WP} = start(),
    application:set_env(
        chappe_sip,
        ws_allowed_origins,
        [<<"https://good.example">>]
    ),
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    ?assertMatch(
        {error, _},
        ws:connect(Url, #{
            handler => chappe_sip_ws_test_client,
            handler_opts => #{notify => self()},
            subprotocols => [<<"sip">>],
            origin => <<"https://evil.example">>
        })
    ),
    {ok, C} = ws:connect(Url, #{
        handler => chappe_sip_ws_test_client,
        handler_opts => #{notify => self()},
        subprotocols => [<<"sip">>],
        origin => <<"https://good.example">>
    }),
    ws:close(C, 1000).

%% F11: a WS listener bind failure surfaces from chappe_sip:start instead of being
%% swallowed. An out-of-range port is a deterministic bind failure.
ws_start_failure(_Config) ->
    EP = pick(),
    R = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        ws => #{port => 99999}
    }),
    ?assertMatch({error, {ws, _}}, R).

%% F9: the WS connection cap refuses a connect past the limit (cap 0 refuses
%% any), so the transport bounds concurrent sessions.
ws_connection_cap(_Config) ->
    {_EP, _WP} = start(),
    application:set_env(chappe_sip, max_ws_connections, 0),
    D = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    ?assertEqual(
        {error, too_many_connections},
        chappe_sip_ws_transport:connect(D, undefined)
    ),
    exit(D, kill).

%% RFC 3261 8.2.6.2: a non-100 response over WS carries a To-tag, even an
%% error final the transport builds itself (a 405 for an unhandled method).
ws_error_final_has_totag(_Config) ->
    {_EP, WP} = start(),
    C = connect(WP),
    ws:send(C, {text, message_req()}),
    R405 = recv_ws(405),
    ?assertNotEqual(undefined, to_tag(R405)),
    ws:close(C, 1000).

%% RFC 3261 17.2.1: an INVITE over WS gets a 100 Trying from the transport
%% before the app's final response.
ws_invite_100_trying(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    C = connect(WP),
    ws:send(C, {text, invite_req()}),
    R100 = recv_ws(100),
    ?assertMatch({0, _}, binary:match(R100, <<"SIP/2.0 100">>)),
    _ = recv_ws(200),
    ws:close(C, 1000).

%% ---- helpers ----

message_req() ->
    <<
        "MESSAGE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsmsg\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=wsmsg\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Contact: <sip:alice@df7jal23ls0d.invalid;transport=ws>\r\n"
        "Call-ID: wsmsg-call@ct\r\nCSeq: 1 MESSAGE\r\n"
        "Content-Length: 0\r\n\r\n"
    >>.

start() ->
    EP = pick(),
    WP = pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        ws => #{port => WP}
    }),
    {EP, WP}.

connect(WP) ->
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{
        handler => chappe_sip_ws_test_client,
        handler_opts => #{notify => self()},
        subprotocols => [<<"sip">>]
    }),
    C.

recv_ws(Code) ->
    CB = integer_to_binary(Code),
    receive
        {ws_in, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                _ -> recv_ws(Code)
            end;
        {ws_in, _Other} ->
            recv_ws(Code)
    after 6000 -> ct:fail({no_ws_status, Code})
    end.

to_tag(Resp) ->
    {ok, M} = chappe_sip_msg:parse(Resp),
    chappe_sip_msg:to_tag(M).
pick() -> chappe_sip_test_port:pick().

sdp() ->
    <<
        "v=0\r\no=alice 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
    >>.

%% RFC 7118: WS clients use a random ".invalid" host in the Via; responses
%% route back on the connection, not by resolving it.
register_req() ->
    <<
        "REGISTER sip:127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsreg\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=wsreg\r\n"
        "To: <sip:alice@127.0.0.1>\r\n"
        "Contact: <sip:alice@df7jal23ls0d.invalid;transport=ws>\r\n"
        "Call-ID: wsreg-call@ct\r\n"
        "CSeq: 1 REGISTER\r\nExpires: 3600\r\nContent-Length: 0\r\n\r\n"
    >>.

invite_req() ->
    S = sdp(),
    L = integer_to_binary(byte_size(S)),
    <<
        "INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsinv\r\n"
        "Max-Forwards: 70\r\n"
        "From: Alice <sip:alice@127.0.0.1>;tag=wsinv\r\n"
        "To: <sip:app@127.0.0.1>\r\n"
        "Contact: <sip:alice@df7jal23ls0d.invalid;transport=ws>\r\n"
        "Call-ID: wscall@ct\r\nCSeq: 1 INVITE\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: ",
        L/binary,
        "\r\n\r\n",
        S/binary
    >>.

ack_req(TT) ->
    <<
        "ACK sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsack\r\n"
        "Max-Forwards: 70\r\n"
        "From: Alice <sip:alice@127.0.0.1>;tag=wsinv\r\n"
        "To: <sip:app@127.0.0.1>;tag=",
        TT/binary,
        "\r\n"
        "Contact: <sip:alice@df7jal23ls0d.invalid;transport=ws>\r\n"
        "Call-ID: wscall@ct\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n"
    >>.

bye_req(TT) ->
    <<
        "BYE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsbye\r\n"
        "Max-Forwards: 70\r\n"
        "From: Alice <sip:alice@127.0.0.1>;tag=wsinv\r\n"
        "To: <sip:app@127.0.0.1>;tag=",
        TT/binary,
        "\r\n"
        "Call-ID: wscall@ct\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n"
    >>.
