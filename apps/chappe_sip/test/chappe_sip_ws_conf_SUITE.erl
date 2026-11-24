%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% SIP-over-WebSocket conformance: RFC 7118 framing, the RFC 3261 timers
%% and transaction rules for a reliable transport, RFC 3262 over WS, the
%% RFC 5626 CRLF keepalive, and the connection guards (idle timeout, pings,
%% size and mailbox caps, overload answers).
%%
%% A ws:connect client (chappe_sip_ws_test_client) plays the browser; for the
%% client transaction cases it registers and the test originates requests to
%% it through chappe_sip_engine:send_request/3.
-module(chappe_sip_ws_conf_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
%% the transport's #state{}, to read its branch index by field name
-include_lib("chappe_sip/src/ws/chappe_sip_ws_transport.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    subprotocol_required/1,
    binary_frame_in/1,
    binary_frame_out/1,
    missing_header_400/1,
    content_length_checked/1,
    record_route_mirrored/1,
    received_rport/1,
    retransmission_matches/1,
    cancel_answers_487/1,
    progress_resent/1,
    reaper_answers/1,
    worker_cap_503/1,
    deadline_500/1,
    ws_only_node_sheds/1,
    timer_b/1,
    timer_c_cancels_and_acks/1,
    cancel_held_until_provisional/1,
    unacked_2xx_byes/1,
    prack_over_ws/1,
    crlf_keepalive_ws/1,
    crlf_keepalive_tcp/1,
    idle_timeout_reaps/1,
    ping_keeps_alive/1,
    mailbox_cap/1,
    message_size_cap/1,
    wss_listener/1
]).

-define(ENV, [
    max_request_workers,
    non_invite_deadline_ms,
    handler_deadline_ms,
    ws_server_txn_timeout_ms,
    ws_client_txn_timeout_ms,
    ws_timer_c_ms,
    ws_ack_timeout_ms,
    ws_progress_ms,
    ws_idle_timeout_ms,
    ws_ping_interval_ms,
    ws_transport_max_mailbox,
    max_message_size
]).

all() ->
    [
        subprotocol_required,
        binary_frame_in,
        binary_frame_out,
        missing_header_400,
        content_length_checked,
        record_route_mirrored,
        received_rport,
        retransmission_matches,
        cancel_answers_487,
        progress_resent,
        reaper_answers,
        worker_cap_503,
        deadline_500,
        ws_only_node_sheds,
        timer_b,
        timer_c_cancels_and_acks,
        cancel_held_until_provisional,
        unacked_2xx_byes,
        prack_over_ws,
        crlf_keepalive_ws,
        crlf_keepalive_tcp,
        idle_timeout_reaps,
        ping_keeps_alive,
        mailbox_cap,
        message_size_cap,
        wss_listener
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
    _ = [application:unset_env(chappe_sip, K) || K <- ?ENV],
    flush(),
    ok.

%% ---- RFC 7118 framing ----

%% RFC 7118 4.1: the upgrade negotiates the sip subprotocol; a client that
%% does not offer it is refused, one that does gets it back in the 101.
%% req: R7118-010
subprotocol_required(_Config) ->
    {_EP, WP} = start(),
    Url = url(WP),
    ?assertMatch(
        {error, _},
        ws:connect(Url, #{
            handler => chappe_sip_ws_test_client,
            handler_opts => #{notify => self()}
        })
    ),
    ?assertMatch(
        {error, _},
        ws:connect(Url, #{
            handler => chappe_sip_ws_test_client,
            handler_opts => #{notify => self()},
            subprotocols => [<<"chat">>]
        })
    ),
    C = connect(WP),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    ws:send(C, {text, register_req(<<"alice">>)}),
    _ = recv_ws(200),
    ws:close(C, 1000).

%% RFC 7118 4.2: a server accepts a SIP message in a binary frame.
%% req: R7118-012 R7118-002
binary_frame_in(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    ws:send(C, {binary, register_req(<<"alice">>)}),
    R = recv_ws(200),
    {_, _} = binary:match(R, <<"CSeq: 1 REGISTER">>),
    ws:close(C, 1000).

%% RFC 7118 4.2: a message that is not valid UTF-8 (a binary body) goes out
%% in a binary frame; a valid UTF-8 one in a text frame.
%% req: R7118-013 R7118-002
binary_frame_out(_Config) ->
    {_EP, WP} = start(),
    Body = <<16#ff, 16#fe, 0, 1, 2>>,
    ok = chappe_sip:options(fun(Req, Res) ->
        case chappe_sip_msg:call_id(chappe_sip_req:msg(Req)) of
            <<"bin@ct">> ->
                chappe_sip_res:send(Res, 200, #{
                    headers => [
                        {<<"Content-Type">>, <<"application/octet-stream">>}
                    ],
                    body => Body
                });
            _ ->
                chappe_sip_res:send(Res, 200, #{})
        end
    end),
    C = connect(WP),
    ws:send(C, {text, options_req(<<"bin@ct">>, <<"z9hG4bKbin1">>, <<>>)}),
    receive
        {ws_in_bin, <<"SIP/2.0 200", _/binary>> = Bin} ->
            ?assertNotEqual(nomatch, binary:match(Bin, Body))
    after 5000 -> ct:fail(no_binary_frame)
    end,
    ws:send(C, {text, options_req(<<"txt@ct">>, <<"z9hG4bKtxt1">>, <<>>)}),
    _ = recv_ws(200),
    ws:close(C, 1000).

%% RFC 3261 8.2.2: a request missing a mandatory header is answered 400 over
%% WS, not dropped; a response missing one is dropped without harm.
missing_header_400(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    C = connect(WP),
    TPid = whereis(chappe_sip_ws_transport),
    ws:send(
        C,
        {text, <<
            "OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/WS a.invalid;branch=z9hG4bKnofrom\r\n"
            "To: <sip:app@127.0.0.1>\r\n"
            "Call-ID: nofrom@ct\r\nCSeq: 1 OPTIONS\r\n"
            "Content-Length: 0\r\n\r\n"
        >>}
    ),
    R400 = recv_ws(400),
    {_, _} = binary:match(R400, <<"Call-ID: nofrom@ct">>),
    ws:send(
        C,
        {text, <<
            "SIP/2.0 200 OK\r\n"
            "Via: SIP/2.0/WS chappe.invalid;branch=z9hG4bKx\r\n"
            "Content-Length: 0\r\n\r\n"
        >>}
    ),
    ws:send(C, {text, options_req(<<"after@ct">>, <<"z9hG4bKafter">>, <<>>)}),
    _ = recv_ws(200),
    ?assertEqual(TPid, whereis(chappe_sip_ws_transport)),
    ws:close(C, 1000).

%% RFC 3261 18.3: a Content-Length that is not the body size (or repeated,
%% or negative) gets 400; none at all is fine over WS (RFC 7118 5).
%% req: R3261-373
content_length_checked(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    C = connect(WP),
    Base = fun(Br, CL) ->
        <<
            "OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/WS a.invalid;branch=",
            Br/binary,
            "\r\n"
            "Max-Forwards: 70\r\n"
            "From: <sip:p@127.0.0.1>;tag=cl\r\nTo: <sip:app@127.0.0.1>\r\n"
            "Call-ID: cl-",
            Br/binary,
            "@ct\r\nCSeq: 1 OPTIONS\r\n",
            CL/binary,
            "\r\n"
        >>
    end,
    ws:send(C, {text, Base(<<"z9hG4bKcl1">>, <<"Content-Length: 5\r\n">>)}),
    _ = recv_ws(400),
    ws:send(
        C,
        {text,
            Base(
                <<"z9hG4bKcl2">>,
                <<"Content-Length: 0\r\nContent-Length: 0\r\n">>
            )}
    ),
    _ = recv_ws(400),
    ws:send(C, {text, Base(<<"z9hG4bKcl3">>, <<"Content-Length: -1\r\n">>)}),
    _ = recv_ws(400),
    ws:send(C, {text, Base(<<"z9hG4bKcl4">>, <<>>)}),
    _ = recv_ws(200),
    ws:close(C, 1000).

%% RFC 3261 12.1.1: the Record-Route of the request is copied, in order,
%% into the responses that can make a dialog.
%% req: R3261-123
record_route_mirrored(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180, #{}),
        chappe_sip_res:send(Res, 486, #{})
    end),
    C = connect(WP),
    ws:send(
        C,
        {text,
            invite_req(
                <<"rr@ct">>,
                <<"z9hG4bKrr1">>,
                <<
                    "Record-Route: <sip:p1.example.com;lr>\r\n"
                    "Record-Route: <sip:p2.example.com;lr>\r\n"
                >>,
                <<>>
            )}
    ),
    R180 = recv_ws(180),
    {P1, _} = binary:match(R180, <<"Record-Route: <sip:p1.example.com;lr>">>),
    {P2, _} = binary:match(R180, <<"Record-Route: <sip:p2.example.com;lr>">>),
    ?assert(P1 < P2),
    R486 = recv_ws(486),
    ?assertEqual(nomatch, binary:match(R486, <<"Record-Route">>)),
    ws:close(C, 1000).

%% RFC 3261 18.2.1 and RFC 3581 4: received when the sent-by is not the
%% source address, rport only when the client asked with a bare rport, and
%% never twice.
%% req: R3581-009 R3261-359 R3261-360 R3261-361
received_rport(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    C = connect(WP),
    Ask = fun(Via, CallId) ->
        ws:send(
            C,
            {text, <<
                "OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
                "Via: ",
                Via/binary,
                "\r\n"
                "Max-Forwards: 70\r\n"
                "From: <sip:p@127.0.0.1>;tag=rp\r\n"
                "To: <sip:app@127.0.0.1>\r\n"
                "Call-ID: ",
                CallId/binary,
                "\r\n"
                "CSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n"
            >>}
        ),
        top_via(recv_ws_call(200, CallId))
    end,
    V1 = Ask(<<"SIP/2.0/WS a.invalid;rport;branch=z9hG4bKrp1">>, <<"rp1@ct">>),
    ?assertEqual(1, count(V1, <<"received=127.0.0.1">>)),
    ?assertEqual(1, count(V1, <<"rport=">>)),
    ?assertEqual(1, count(V1, <<"rport">>)),
    V2 = Ask(<<"SIP/2.0/WS a.invalid;branch=z9hG4bKrp2">>, <<"rp2@ct">>),
    ?assertEqual(1, count(V2, <<"received=127.0.0.1">>)),
    ?assertEqual(0, count(V2, <<"rport">>)),
    V3 = Ask(<<"SIP/2.0/WS 127.0.0.1:5999;branch=z9hG4bKrp3">>, <<"rp3@ct">>),
    ?assertEqual(0, count(V3, <<"received">>)),
    ?assertEqual(0, count(V3, <<"rport">>)),
    ws:close(C, 1000).

%% ---- server transactions ----

%% RFC 3261 17.2.1/17.2.3: a retransmitted INVITE matches its transaction
%% (no second request reaches the app) and gets the last response again;
%% the ACK of the non-2xx final ends it, and a CANCEL after that matches
%% nothing (481). No branch index entry is left behind.
%% req: R7118-001 R3261-313 R3261-318 R3261-319 R3261-C-012
retransmission_matches(_Config) ->
    {_EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        Test ! {inv, self()},
        receive
            go -> chappe_sip_res:send(Res, 486, #{})
        after 5000 -> ok
        end
    end),
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    C = connect(WP),
    Br = <<"z9hG4bKrtx1">>,
    Inv = invite_req(<<"rtx@ct">>, Br, <<>>, <<>>),
    ws:send(C, {text, Inv}),
    _ = recv_ws(100),
    W =
        receive
            {inv, P} -> P
        after 5000 -> ct:fail(no_invite)
        end,
    ws:send(C, {text, Inv}),
    _ = recv_ws(100),
    receive
        {inv, _} -> ct:fail(second_transaction)
    after 300 -> ok
    end,
    W ! go,
    R486 = recv_ws(486),
    TT = to_tag(R486),
    ws:send(C, {text, Inv}),
    R486b = recv_ws(486),
    ?assertEqual(TT, to_tag(R486b)),
    receive
        {inv, _} -> ct:fail(second_transaction)
    after 300 -> ok
    end,
    ws:send(C, {text, ack_non2xx(<<"rtx@ct">>, Br, TT)}),
    timer:sleep(200),
    ?assertEqual([], branch_entries(Br)),
    ws:send(C, {text, cancel_req(<<"rtx@ct">>, Br)}),
    _ = recv_ws(481),
    %% a non-INVITE ends with its final (Timer J is zero on WS)
    ws:send(C, {text, options_req(<<"rtxo@ct">>, <<"z9hG4bKrtxo">>, <<>>)}),
    _ = recv_ws(200),
    timer:sleep(100),
    ?assertEqual([], branch_entries(<<"z9hG4bKrtxo">>)),
    ws:close(C, 1000).

%% RFC 3261 9.2: a CANCEL of an INVITE the app has not answered gets 200,
%% the INVITE gets 487 with the same To-tag as any earlier response, and the
%% app's late exit adds no 500.
%% req: R3261-C-013 R3261-C-014
cancel_answers_487(_Config) ->
    {_EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180, #{}),
        Test ! inv,
        receive
            {chappe_sip_cancel, _, _} -> Test ! cancelled
        after 5000 -> ok
        end
    end),
    C = connect(WP),
    Br = <<"z9hG4bKcan1">>,
    ws:send(C, {text, invite_req(<<"can@ct">>, Br, <<>>, <<>>)}),
    receive
        inv -> ok
    after 5000 -> ct:fail(no_invite)
    end,
    TT = to_tag(recv_ws(180)),
    ws:send(C, {text, cancel_req(<<"can@ct">>, Br)}),
    R200 = recv_ws(200),
    {_, _} = binary:match(R200, <<"CANCEL">>),
    ?assertEqual(TT, to_tag(R200)),
    R487 = recv_ws(487),
    ?assertEqual(TT, to_tag(R487)),
    receive
        cancelled -> ok
    after 5000 -> ct:fail(app_not_told)
    end,
    receive
        {ws_in, <<"SIP/2.0 500", _/binary>>} -> ct:fail(late_500)
    after 500 -> ok
    end,
    ws:send(C, {text, ack_non2xx(<<"can@ct">>, Br, TT)}),
    ws:close(C, 1000).

%% RFC 3261 13.3.1.1: an INVITE left ringing sends its last non-100
%% provisional again every ws_progress_ms (60 s by default, as nta does on
%% UDP, TCP and TLS), with the same To-tag, and stops at the final.
%% req: R3261-213
progress_resent(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_progress_ms, 300),
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180, #{}),
        Test ! {inv, self()},
        receive
            go -> chappe_sip_res:send(Res, 486, #{})
        after 5000 -> ok
        end
    end),
    C = connect(WP),
    Br = <<"z9hG4bKprog1">>,
    ws:send(C, {text, invite_req(<<"prog@ct">>, Br, <<>>, <<>>)}),
    W =
        receive
            {inv, P} -> P
        after 5000 -> ct:fail(no_invite)
        end,
    TT = to_tag(recv_ws(180)),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual(TT, to_tag(recv_ws(180))),
    ?assertEqual(TT, to_tag(recv_ws(180))),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 500),
    W ! go,
    %% a resend may still precede the final; none may follow it
    R486 = until_final(),
    ?assertEqual(486, binary_to_integer(binary:part(R486, 8, 3))),
    ?assertEqual(TT, to_tag(R486)),
    receive
        {ws_in, <<"SIP/2.0 1", _/binary>>} -> ct:fail(provisional_after_final)
    after 1000 -> ok
    end,
    ws:send(C, {text, ack_non2xx(<<"prog@ct">>, Br, TT)}),
    ws:close(C, 1000).

%% A server transaction the app never answers is reaped with 408 (INVITE)
%% or 500 (anything else), not dropped silently.
reaper_answers(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_server_txn_timeout_ms, 300),
    Hang = fun(_Req, _Res) ->
        receive
            never -> ok
        after 3000 -> ok
        end
    end,
    ok = chappe_sip:invite(Hang),
    ok = chappe_sip:options(Hang),
    C = connect(WP),
    ws:send(
        C, {text, invite_req(<<"reap@ct">>, <<"z9hG4bKreap1">>, <<>>, <<>>)}
    ),
    _ = recv_ws(408),
    ws:send(C, {text, options_req(<<"reapo@ct">>, <<"z9hG4bKreap2">>, <<>>)}),
    _ = recv_ws(500),
    ws:close(C, 1000).

%% The worker cap answers 503 over WS (not through the native stack).
worker_cap_503(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        chappe_sip_res:send(Res, 200, #{})
    end),
    application:set_env(chappe_sip, max_request_workers, 0),
    C = connect(WP),
    ws:send(C, {text, options_req(<<"cap@ct">>, <<"z9hG4bKcap1">>, <<>>)}),
    _ = recv_ws(503),
    ws:close(C, 1000).

%% A handler past its deadline is killed and its WS request answered 500.
deadline_500(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, non_invite_deadline_ms, 200),
    ok = chappe_sip:options(fun(_Req, _Res) ->
        receive
            never -> ok
        end
    end),
    C = connect(WP),
    ws:send(C, {text, options_req(<<"dl@ct">>, <<"z9hG4bKdl1">>, <<>>)}),
    _ = recv_ws(500),
    ws:close(C, 1000).

%% A node with only a WS listener (no native engine) sheds 503 and 500 over
%% WS without crashing the engine process.
ws_only_node_sheds(_Config) ->
    WP = pick(),
    ok = chappe_sip:start(#{ws => #{port => WP}}),
    EPid = whereis(chappe_sip_engine),
    ok = chappe_sip:options(fun(_Req, _Res) ->
        receive
            never -> ok
        end
    end),
    application:set_env(chappe_sip, max_request_workers, 0),
    C = connect(WP),
    ws:send(C, {text, options_req(<<"wo1@ct">>, <<"z9hG4bKwo1">>, <<>>)}),
    _ = recv_ws(503),
    application:unset_env(chappe_sip, max_request_workers),
    application:set_env(chappe_sip, non_invite_deadline_ms, 200),
    ws:send(C, {text, options_req(<<"wo2@ct">>, <<"z9hG4bKwo2">>, <<>>)}),
    _ = recv_ws(500),
    ?assertEqual(EPid, whereis(chappe_sip_engine)),
    ws:close(C, 1000).

%% ---- client transactions ----

%% Timer B: an INVITE to a WS UA that never answers fails after 64*T1.
%% req: R7118-001 R3261-266 R3261-274
timer_b(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_client_txn_timeout_ms, 300),
    {C, Flow} = ws_ua(WP),
    {ok, TxnH} = chappe_sip_engine:send_request(
        {ws, Flow}, out_invite(<<"tb@ct">>), self()
    ),
    _ = recv_ws_method(<<"INVITE">>),
    receive
        {chappe_sip_op, TxnH, {error, timeout}} -> ok
    after 3000 -> ct:fail(no_timer_b)
    end,
    ws:close(C, 1000).

%% A provisional stops Timer B and starts Timer C; Timer C CANCELs, the 200
%% to the CANCEL is not taken for the INVITE's, and the 487 is passed up and
%% ACKed by the transaction with the INVITE's branch (RFC 3261 17.1.1.3).
%% req: R7118-001 R3261-277 R3261-280 R3261-288 R3261-289 R3261-290 R3261-291
timer_c_cancels_and_acks(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_client_txn_timeout_ms, 400),
    application:set_env(chappe_sip, ws_timer_c_ms, 900),
    {C, Flow} = ws_ua(WP),
    {ok, TxnH} = chappe_sip_engine:send_request(
        {ws, Flow}, out_invite(<<"tc@ct">>), self()
    ),
    Inv = recv_ws_method(<<"INVITE">>),
    ws:send(C, {text, resp(Inv, 180, <<"uatag">>)}),
    receive
        {chappe_sip_response, TxnH, #{status := 180}, _} -> ok
    after 3000 -> ct:fail(no_180)
    end,
    receive
        {chappe_sip_op, TxnH, {error, timeout}} -> ct:fail(timer_b_not_stopped)
    after 600 -> ok
    end,
    Cancel = recv_ws_method(<<"CANCEL">>, 3000),
    ?assertEqual(top_branch(Inv), top_branch(Cancel)),
    ws:send(C, {text, resp(Cancel, 200, <<"uatag">>)}),
    ws:send(C, {text, resp(Inv, 487, <<"uatag">>)}),
    receive
        {chappe_sip_response, TxnH, #{status := 487}, _} -> ok
    after 3000 -> ct:fail(no_487)
    end,
    receive
        {chappe_sip_response, TxnH, #{status := 200}, _} ->
            ct:fail(cancel_200_passed_up)
    after 300 -> ok
    end,
    Ack = recv_ws_method(<<"ACK">>),
    ?assertEqual(top_branch(Inv), top_branch(Ack)),
    ?assertEqual(<<"uatag">>, to_tag(Ack)),
    {_, _} = binary:match(Ack, <<"CSeq: 1 ACK">>),
    ws:close(C, 1000).

%% RFC 3261 9.1: a CANCEL waits for a provisional.
%% req: R3261-C-008
cancel_held_until_provisional(_Config) ->
    {_EP, WP} = start(),
    {C, Flow} = ws_ua(WP),
    {ok, TxnH} = chappe_sip_engine:send_request(
        {ws, Flow}, out_invite(<<"ch@ct">>), self()
    ),
    Inv = recv_ws_method(<<"INVITE">>),
    ok = chappe_sip_engine:cancel_txn(TxnH),
    no_ws_method(<<"CANCEL">>, 400),
    ws:send(C, {text, resp(Inv, 180, <<"uatag">>)}),
    Cancel = recv_ws_method(<<"CANCEL">>),
    ?assertEqual(top_branch(Inv), top_branch(Cancel)),
    ws:close(C, 1000).

%% RFC 3261 13.3.1.4: a 2xx never ACKed ends the session with a BYE.
%% req: R3261-222
unacked_2xx_byes(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_ack_timeout_ms, 300),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        put(test_pid, Test),
        chappe_sip_handler:start(chappe_sip_echo_handler, Req, Res)
    end),
    C = connect(WP),
    ws:send(
        C, {text, invite_req(<<"noack@ct">>, <<"z9hG4bKnoack">>, <<>>, sdp())}
    ),
    _ = recv_ws(200),
    Bye = recv_ws_method(<<"BYE">>, 5000),
    ws:send(C, {text, resp(Bye, 200, <<>>)}),
    receive
        {handler_terminated, _} -> ok
    after 5000 -> ct:fail(no_terminate)
    end,
    ws:close(C, 1000).

%% RFC 3262 over WS: the reliable 183 carries Require: 100rel and RSeq, its
%% PRACK is matched (200) and handed to the app, and a PRACK for nothing
%% outstanding gets 481.
%% req: R3262-010 R3262-015 R3262-016
prack_over_ws(_Config) ->
    {_EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send_reliable(Res, #{
            status => 183,
            headers => [{<<"Content-Type">>, <<"application/sdp">>}],
            body => sdp()
        }),
        Test ! {pracked, chappe_sip_res:await_prack(Res, 4000)},
        chappe_sip_res:send(Res, 486, #{})
    end),
    C = connect(WP),
    ws:send(
        C,
        {text,
            invite_req(
                <<"prack@ct">>,
                <<"z9hG4bKpri">>,
                <<"Supported: 100rel\r\n">>,
                sdp()
            )}
    ),
    R183 = recv_ws(183),
    {_, _} = binary:match(R183, <<"Require: 100rel">>),
    {match, [RSeq]} = re:run(R183, <<"RSeq: ([0-9]+)">>, [
        {capture, [1], binary}
    ]),
    TT = to_tag(R183),
    ws:send(
        C,
        {text, prack_req(<<"z9hG4bKpr1">>, TT, <<RSeq/binary, " 1 INVITE">>, 2)}
    ),
    R200 = recv_ws(200),
    {_, _} = binary:match(R200, <<"CSeq: 2 PRACK">>),
    receive
        {pracked, {ok, _}} -> ok
    after 5000 -> ct:fail(no_prack_to_app)
    end,
    R486 = recv_ws(486),
    ?assertEqual(TT, to_tag(R486)),
    ws:send(
        C,
        {text, prack_req(<<"z9hG4bKpr2">>, TT, <<RSeq/binary, " 1 INVITE">>, 3)}
    ),
    R481 = recv_ws(481),
    {_, _} = binary:match(R481, <<"CSeq: 3 PRACK">>),
    ws:close(C, 1000).

%% ---- keepalive and connection guards ----

%% RFC 5626 4.4.1 / 5.4: a CRLFCRLF ping gets a CRLF pong over WS.
%% req: R5626-001
crlf_keepalive_ws(_Config) ->
    {_EP, WP} = start(),
    C = connect(WP),
    ws:send(C, {text, <<"\r\n\r\n">>}),
    receive
        {ws_in, <<"\r\n">>} -> ok
    after 3000 -> ct:fail(no_pong)
    end,
    ws:close(C, 1000).

%% RFC 5626 5.4: and over TCP, through sofia (TPTAG_PONG2PING).
%% req: R5626-001
crlf_keepalive_tcp(_Config) ->
    {EP, _WP} = start(),
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, EP, [binary, {active, false}]),
    ok = gen_tcp:send(S, <<"\r\n\r\n">>),
    ?assertEqual({ok, <<"\r\n">>}, gen_tcp:recv(S, 0, 3000)),
    gen_tcp:close(S).

%% A connection with no inbound traffic is closed after ws_idle_timeout_ms.
idle_timeout_reaps(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_idle_timeout_ms, 300),
    application:set_env(chappe_sip, ws_ping_interval_ms, infinity),
    _C = connect(WP),
    receive
        {ws_closed, _} -> ok
    after 3000 -> ct:fail(not_reaped)
    end.

%% The server pings below the idle timeout; the client's pongs keep a quiet
%% connection open.
ping_keeps_alive(_Config) ->
    {_EP, WP} = start(),
    application:set_env(chappe_sip, ws_idle_timeout_ms, 500),
    application:set_env(chappe_sip, ws_ping_interval_ms, 150),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    receive
        {ws_closed, R} -> ct:fail({reaped, R})
    after 1500 -> ok
    end,
    ws:send(C, {text, register_req(<<"alice">>)}),
    _ = recv_ws(200),
    ws:close(C, 1000).

%% Frames arriving while the transport mailbox is at its cap are shed.
mailbox_cap(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    application:set_env(chappe_sip, ws_transport_max_mailbox, 0),
    ws:send(C, {text, register_req(<<"alice">>)}),
    receive
        {ws_in, <<"SIP/2.0 200", _/binary>>} -> ct:fail(not_shed)
    after 500 -> ok
    end,
    application:unset_env(chappe_sip, ws_transport_max_mailbox),
    ws:send(C, {text, register_req(<<"alice">>)}),
    _ = recv_ws(200),
    ws:close(C, 1000).

%% A message past max_message_size closes the connection (1009) inbound and
%% is refused outbound ({error, too_large}; the worker's 500 goes instead).
message_size_cap(_Config) ->
    {_EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test !
            {sent,
                chappe_sip_res:send(Res, 200, #{
                    headers => [{<<"Content-Type">>, <<"text/plain">>}],
                    body => binary:copy(<<"a">>, 3000)
                })}
    end),
    application:set_env(chappe_sip, max_message_size, 2000),
    C = connect(WP),
    ws:send(C, {text, options_req(<<"big@ct">>, <<"z9hG4bKbig1">>, <<>>)}),
    receive
        {sent, R} -> ?assertEqual({error, too_large}, R)
    after 5000 -> ct:fail(no_send)
    end,
    _ = recv_ws(500),
    ws:send(C, {text, binary:copy(<<"x">>, 4000)}),
    receive
        {ws_closed, _} -> ok
    after 3000 -> ct:fail(not_closed)
    end.

%% WSS: a TLS listener with the cert_dir layout of the SIP TLS listener;
%% requests to a WSS flow carry a WSS Via (RFC 7118 5.1).
wss_listener(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "wsscerts"),
    ok = filelib:ensure_path(Dir),
    case gen_certs(Dir) of
        {error, no_openssl} ->
            {skip, no_openssl};
        ok ->
            EP = pick(),
            SP = pick(),
            ok = chappe_sip:start(#{
                contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
                wss => #{
                    port => SP,
                    cert_dir => list_to_binary(Dir)
                }
            }),
            ok = chappe_sip:register(
                chappe_sip:registrar(#{allow_unauthenticated => true})
            ),
            Url = <<"wss://127.0.0.1:", (integer_to_binary(SP))/binary, "/ws">>,
            {ok, C} = ws:connect(Url, #{
                handler => chappe_sip_ws_test_client,
                handler_opts => #{notify => self()},
                subprotocols => [<<"sip">>],
                ssl_opts => [{verify, verify_none}]
            }),
            ws:send(C, {text, register_req(<<"bob">>)}),
            _ = recv_ws(200),
            {ok, _, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
            {ok, _} = chappe_sip_engine:send_request(
                {ws, Flow}, out_invite(<<"wss@ct">>), self()
            ),
            Inv = recv_ws_method(<<"INVITE">>),
            {_, _} = binary:match(Inv, <<"Via: SIP/2.0/WSS ">>),
            ws:close(C, 1000)
    end.

%% ---- helpers ----

start() ->
    EP = pick(),
    WP = pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        ws => #{port => WP}
    }),
    {EP, WP}.

url(WP) ->
    <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>.

connect(WP) ->
    {ok, C} = ws:connect(url(WP), #{
        handler => chappe_sip_ws_test_client,
        handler_opts => #{notify => self()},
        subprotocols => [<<"sip">>]
    }),
    C.

%% a registered WS UA (bob) and its flow
ws_ua(WP) ->
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    C = connect(WP),
    ws:send(C, {text, register_req(<<"bob">>)}),
    _ = recv_ws(200),
    {ok, _, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
    {C, Flow}.

pick() -> chappe_sip_test_port:pick().

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

recv_ws(Code) ->
    CB = integer_to_binary(Code),
    receive
        {ws_in, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} when C =:= CB -> Bin
    after 6000 -> ct:fail({no_ws_status, Code})
    end.

%% the next final response, skipping the provisionals before it
until_final() ->
    receive
        {ws_in, <<"SIP/2.0 1", _/binary>>} -> until_final();
        {ws_in, <<"SIP/2.0 ", _/binary>> = Bin} -> Bin
    after 6000 -> ct:fail(no_final)
    end.

recv_ws_call(Code, CallId) ->
    Bin = recv_ws(Code),
    case binary:match(Bin, <<"Call-ID: ", CallId/binary>>) of
        nomatch -> recv_ws_call(Code, CallId);
        _ -> Bin
    end.

recv_ws_method(M) -> recv_ws_method(M, 6000).

recv_ws_method(M, T) ->
    Sz = byte_size(M),
    receive
        {ws_in, <<P:Sz/binary, " ", _/binary>> = B} when P =:= M -> B
    after T -> ct:fail({no_ws_method, M})
    end.

no_ws_method(M, T) ->
    Sz = byte_size(M),
    receive
        {ws_in, <<P:Sz/binary, " ", _/binary>>} when P =:= M ->
            ct:fail({unexpected, M})
    after T -> ok
    end.

to_tag(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:to_tag(M).

top_via(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(<<"via">>, M).

top_branch(Bin) ->
    {match, [B]} = re:run(top_via(Bin), <<"branch=([^;\\s]+)">>, [
        {capture, [1], binary}
    ]),
    B.

count(Bin, Pat) -> length(binary:matches(Bin, Pat)).

%% the server transaction index entries still naming this branch
branch_entries(Br) ->
    #state{branch_ix = Ix} = sys:get_state(chappe_sip_ws_transport),
    [K || {_, B, _} = K <- maps:keys(Ix), B =:= Br].

%% a response to a request received over WS (echoes Via, From, To, Call-ID,
%% CSeq; tags the To unless it has one)
resp(ReqBin, Status, Tag) ->
    {ok, M} = chappe_sip_msg:parse(ReqBin),
    Vias = [
        [<<"Via: ">>, V, <<"\r\n">>]
     || V <- chappe_sip_msg:get_all(<<"via">>, M)
    ],
    To = chappe_sip_msg:get(<<"to">>, M),
    To1 =
        case {chappe_sip_msg:to_tag(M), Tag} of
            {undefined, T} when T =/= <<>> -> <<To/binary, ";tag=", T/binary>>;
            _ -> To
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" X\r\n">>,
        Vias,
        <<"From: ">>,
        chappe_sip_msg:get(<<"from">>, M),
        <<"\r\n">>,
        <<"To: ">>,
        To1,
        <<"\r\n">>,
        <<"Call-ID: ">>,
        chappe_sip_msg:call_id(M),
        <<"\r\n">>,
        <<"CSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, M),
        <<"\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]).

sdp() ->
    <<
        "v=0\r\no=alice 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n"
    >>.

register_req(User) ->
    <<
        "REGISTER sip:127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKreg",
        User/binary,
        (integer_to_binary(erlang:unique_integer([positive])))/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:",
        User/binary,
        "@127.0.0.1>;tag=wsreg\r\n"
        "To: <sip:",
        User/binary,
        "@127.0.0.1>\r\n"
        "Contact: <sip:",
        User/binary,
        "@df7jal23ls0d.invalid;transport=ws>\r\n"
        "Call-ID: wsreg-",
        User/binary,
        "@ct\r\n"
        "CSeq: 1 REGISTER\r\nExpires: 3600\r\nContent-Length: 0\r\n\r\n"
    >>.

options_req(CallId, Br, Extra) ->
    <<
        "OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS a.invalid;branch=",
        Br/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:p@127.0.0.1>;tag=op\r\nTo: <sip:app@127.0.0.1>\r\n"
        "Call-ID: ",
        CallId/binary,
        "\r\nCSeq: 1 OPTIONS\r\n",
        Extra/binary,
        "Content-Length: 0\r\n\r\n"
    >>.

invite_req(CallId, Br, Extra, Body) ->
    Ct =
        case Body of
            <<>> -> <<>>;
            _ -> <<"Content-Type: application/sdp\r\n">>
        end,
    <<
        "INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS a.invalid;branch=",
        Br/binary,
        "\r\n",
        Extra/binary,
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=inv\r\nTo: <sip:app@127.0.0.1>\r\n"
        "Contact: <sip:alice@a.invalid;transport=ws>\r\n"
        "Call-ID: ",
        CallId/binary,
        "\r\nCSeq: 1 INVITE\r\n",
        Ct/binary,
        "Content-Length: ",
        (integer_to_binary(byte_size(Body)))/binary,
        "\r\n\r\n",
        Body/binary
    >>.

ack_non2xx(CallId, Br, TT) ->
    <<
        "ACK sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS a.invalid;branch=",
        Br/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=inv\r\n"
        "To: <sip:app@127.0.0.1>;tag=",
        TT/binary,
        "\r\n"
        "Call-ID: ",
        CallId/binary,
        "\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n"
    >>.

cancel_req(CallId, Br) ->
    <<
        "CANCEL sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS a.invalid;branch=",
        Br/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=inv\r\nTo: <sip:app@127.0.0.1>\r\n"
        "Call-ID: ",
        CallId/binary,
        "\r\nCSeq: 1 CANCEL\r\nContent-Length: 0\r\n\r\n"
    >>.

prack_req(Br, TT, RAck, CSeq) ->
    <<
        "PRACK sip:app@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS a.invalid;branch=",
        Br/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=inv\r\n"
        "To: <sip:app@127.0.0.1>;tag=",
        TT/binary,
        "\r\n"
        "Call-ID: prack@ct\r\nCSeq: ",
        (integer_to_binary(CSeq))/binary,
        " PRACK\r\n"
        "RAck: ",
        RAck/binary,
        "\r\nContent-Length: 0\r\n\r\n"
    >>.

%% an INVITE the test originates to the WS UA bob (the transport adds Via)
out_invite(CallId) ->
    <<
        "INVITE sip:bob@df7jal23ls0d.invalid;transport=ws SIP/2.0\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:app@127.0.0.1>;tag=out\r\nTo: <sip:bob@127.0.0.1>\r\n"
        "Contact: <sip:app@127.0.0.1>\r\n"
        "Call-ID: ",
        CallId/binary,
        "\r\nCSeq: 1 INVITE\r\nContent-Length: 0\r\n\r\n"
    >>.

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
            ok
    end.
