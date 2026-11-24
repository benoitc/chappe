%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Unit tests for the pure message code of the WebSocket transport: Via
%% and branch handling, the CANCEL, ACK and response builders, and the
%% header checks.
-module(chappe_sip_ws_msg_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, chappe_sip_ws_msg).

-define(INVITE, <<
    "INVITE sip:bob@example.com SIP/2.0\r\n"
    "Via: SIP/2.0/WS abc.invalid;branch=z9hG4bKinv1;rport\r\n"
    "Via: SIP/2.0/UDP 10.0.0.9:5060;branch=z9hG4bKdown\r\n"
    "Record-Route: <sip:p1.example.com;lr>\r\n"
    "Record-Route: <sip:p2.example.com;lr>\r\n"
    "Route: <sip:edge.example.com;lr>\r\n"
    "Max-Forwards: 70\r\n"
    "From: <sip:alice@example.com>;tag=ftag\r\n"
    "To: <sip:bob@example.com>\r\n"
    "Call-ID: call-1\r\n"
    "CSeq: 7 INVITE\r\n"
    "Supported: timer, 100rel\r\n"
    "Content-Length: 0\r\n"
    "\r\n"
>>).

msg(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    M.

%% ---- Via ----

add_received_rport_test() ->
    ?assertEqual(
        <<
            "SIP/2.0/WS abc.invalid;branch=z9hG4bKx;received=192.0.2.1;"
            "rport=4321"
        >>,
        ?M:add_received(
            <<"SIP/2.0/WS abc.invalid;branch=z9hG4bKx;rport">>,
            {{192, 0, 2, 1}, 4321}
        )
    ).

add_received_no_rport_test() ->
    ?assertEqual(
        <<"SIP/2.0/WS abc.invalid;branch=z9hG4bKx;received=192.0.2.1">>,
        ?M:add_received(
            <<"SIP/2.0/WS abc.invalid;branch=z9hG4bKx">>,
            {{192, 0, 2, 1}, 4321}
        )
    ).

add_received_same_host_test() ->
    %% the sent-by host is the source: no received, no rport asked
    ?assertEqual(
        <<"SIP/2.0/WS 192.0.2.1:80;branch=z9hG4bKx">>,
        ?M:add_received(
            <<"SIP/2.0/WS 192.0.2.1:80;branch=z9hG4bKx">>,
            {{192, 0, 2, 1}, 4321}
        )
    ).

add_received_replaces_test() ->
    %% values the client put there are replaced, never repeated
    ?assertEqual(
        <<
            "SIP/2.0/WS abc.invalid;branch=z9hG4bKx;received=192.0.2.1;"
            "rport=4321"
        >>,
        ?M:add_received(
            <<
                "SIP/2.0/WS abc.invalid;received=1.1.1.1;branch=z9hG4bKx;"
                "rport=9"
            >>,
            {{192, 0, 2, 1}, 4321}
        )
    ).

add_received_ipv6_test() ->
    ?assertEqual(
        <<"SIP/2.0/WS [2001:db8::1]:80;branch=z9hG4bKx">>,
        ?M:add_received(
            <<"SIP/2.0/WS [2001:db8::1]:80;branch=z9hG4bKx">>,
            {{16#2001, 16#db8, 0, 0, 0, 0, 0, 1}, 80}
        )
    ).

add_received_no_peer_test() ->
    ?assertEqual(
        <<"SIP/2.0/WS h;b">>, ?M:add_received(<<"SIP/2.0/WS h;b">>, undefined)
    ).

insert_via_test() ->
    Raw = <<"OPTIONS sip:a@b SIP/2.0\r\nCall-ID: x\r\n\r\n">>,
    ?assertEqual(
        <<
            "OPTIONS sip:a@b SIP/2.0\r\n"
            "Via: SIP/2.0/WS chappe.invalid;branch=z9hG4bKb1\r\n"
            "Call-ID: x\r\n\r\n"
        >>,
        ?M:insert_via(Raw, ws, <<"z9hG4bKb1">>)
    ),
    ?assertEqual(
        <<
            "OPTIONS sip:a@b SIP/2.0\r\n"
            "Via: SIP/2.0/WSS chappe.invalid;branch=z9hG4bKb1\r\n"
            "Call-ID: x\r\n\r\n"
        >>,
        ?M:insert_via(Raw, wss, <<"z9hG4bKb1">>)
    ),
    ?assertEqual(
        <<"Via: SIP/2.0/WS chappe.invalid;branch=z9hG4bKb1\r\nnoline">>,
        ?M:insert_via(<<"noline">>, ws, <<"z9hG4bKb1">>)
    ).

ensure_via_test() ->
    WithVia =
        <<"ACK sip:a@b SIP/2.0\r\nVia: SIP/2.0/WS h;branch=z9hG4bKq\r\n\r\n">>,
    ?assertEqual(WithVia, ?M:ensure_via(WithVia, ws)),
    Added = ?M:ensure_via(<<"ACK sip:a@b SIP/2.0\r\nCall-ID: x\r\n\r\n">>, wss),
    ?assertMatch(
        <<"ACK sip:a@b SIP/2.0\r\nVia: SIP/2.0/WSS chappe.invalid;branch=z9hG4bK",
            _/binary>>,
        Added
    ).

via_branch_test() ->
    ?assertEqual(<<"z9hG4bKinv1">>, ?M:via_branch(msg(?INVITE))),
    NoBranch = <<
        "OPTIONS sip:a@b SIP/2.0\r\nVia: SIP/2.0/WS h\r\n"
        "From: <sip:a@b>;tag=1\r\nTo: <sip:a@b>\r\nCall-ID: c\r\n"
        "CSeq: 1 OPTIONS\r\n\r\n"
    >>,
    ?assertEqual(<<>>, ?M:via_branch(msg(NoBranch))),
    NoVia = <<
        "OPTIONS sip:a@b SIP/2.0\r\n"
        "From: <sip:a@b>;tag=1\r\nTo: <sip:a@b>\r\nCall-ID: c\r\n"
        "CSeq: 1 OPTIONS\r\n\r\n"
    >>,
    ?assertEqual(<<>>, ?M:via_branch(msg(NoVia))).

%% ---- CANCEL and ACK ----

build_cancel_test() ->
    ?assertEqual(
        {ok, <<
            "CANCEL sip:bob@example.com SIP/2.0\r\n"
            "Via: SIP/2.0/WS abc.invalid;branch=z9hG4bKinv1;rport\r\n"
            "Route: <sip:edge.example.com;lr>\r\n"
            "Max-Forwards: 70\r\n"
            "From: <sip:alice@example.com>;tag=ftag\r\n"
            "To: <sip:bob@example.com>\r\n"
            "Call-ID: call-1\r\n"
            "CSeq: 7 CANCEL\r\n"
            "Reason: SIP;cause=200\r\n"
            "Content-Length: 0\r\n\r\n"
        >>},
        ?M:build_cancel(?INVITE, <<"Reason: SIP;cause=200\r\n">>)
    ),
    ?assertEqual(error, ?M:build_cancel(<<"garbage">>, <<>>)).

%% ---- responses ----

%% RFC 3261 17.1.1.3: the INVITE's R-URI, top Via, From, Call-ID, CSeq
%% number and Route, the To of the response
build_ack_test() ->
    Resp = msg(<<
        "SIP/2.0 486 Busy Here\r\n"
        "Via: SIP/2.0/WS abc.invalid;branch=z9hG4bKinv1;rport\r\n"
        "From: <sip:alice@example.com>;tag=ftag\r\n"
        "To: <sip:bob@example.com>;tag=busy\r\n"
        "Call-ID: call-1\r\n"
        "CSeq: 7 INVITE\r\n"
        "Content-Length: 0\r\n\r\n"
    >>),
    ?assertEqual(
        {ok, <<
            "ACK sip:bob@example.com SIP/2.0\r\n"
            "Via: SIP/2.0/WS abc.invalid;branch=z9hG4bKinv1;rport\r\n"
            "Route: <sip:edge.example.com;lr>\r\n"
            "Max-Forwards: 70\r\n"
            "From: <sip:alice@example.com>;tag=ftag\r\n"
            "To: <sip:bob@example.com>;tag=busy\r\n"
            "Call-ID: call-1\r\n"
            "CSeq: 7 ACK\r\n"
            "Content-Length: 0\r\n\r\n"
        >>},
        ?M:build_ack(?INVITE, Resp)
    ),
    ?assertEqual(error, ?M:build_ack(<<"garbage">>, Resp)).

record_route_test() ->
    Req = msg(?INVITE),
    RR = [
        [<<"Record-Route: ">>, <<"<sip:p1.example.com;lr>">>, <<"\r\n">>],
        [<<"Record-Route: ">>, <<"<sip:p2.example.com;lr>">>, <<"\r\n">>]
    ],
    ?assertEqual(RR, ?M:record_route(180, Req, <<>>)),
    ?assertEqual(RR, ?M:record_route(200, Req, [<<"X: y\r\n">>])),
    ?assertEqual([], ?M:record_route(100, Req, <<>>)),
    ?assertEqual([], ?M:record_route(300, Req, <<>>)),
    ?assertEqual([], ?M:record_route(486, Req, <<>>)),
    %% the caller put its own
    ?assertEqual(
        [], ?M:record_route(200, Req, [<<"record-ROUTE: <sip:x>\r\n">>])
    ).

build_response_test() ->
    Req = msg(?INVITE),
    ?assertEqual(
        <<
            "SIP/2.0 180 Ringing\r\n"
            "Via: SIP/2.0/WS abc.invalid;branch=z9hG4bKinv1;"
            "received=192.0.2.1;rport=4321\r\n"
            "Via: SIP/2.0/UDP 10.0.0.9:5060;branch=z9hG4bKdown\r\n"
            "Record-Route: <sip:p1.example.com;lr>\r\n"
            "Record-Route: <sip:p2.example.com;lr>\r\n"
            "From: <sip:alice@example.com>;tag=ftag\r\n"
            "To: <sip:bob@example.com>;tag=tt\r\n"
            "Call-ID: call-1\r\n"
            "CSeq: 7 INVITE\r\n"
            "X-A: 1\r\n"
            "Content-Length: 3\r\n\r\n"
            "abc"
        >>,
        ?M:build_response(
            Req,
            180,
            <<>>,
            [<<"X-A: 1\r\n">>],
            <<"abc">>,
            <<"tt">>,
            {{192, 0, 2, 1}, 4321}
        )
    ).

build_response_100_test() ->
    %% a 100 carries no To-tag and no Record-Route
    ?assertEqual(
        <<
            "SIP/2.0 100 Trying\r\n"
            "Via: SIP/2.0/WS abc.invalid;branch=z9hG4bKinv1;rport\r\n"
            "Via: SIP/2.0/UDP 10.0.0.9:5060;branch=z9hG4bKdown\r\n"
            "From: <sip:alice@example.com>;tag=ftag\r\n"
            "To: <sip:bob@example.com>\r\n"
            "Call-ID: call-1\r\n"
            "CSeq: 7 INVITE\r\n"
            "Content-Length: 0\r\n\r\n"
        >>,
        ?M:build_response(msg(?INVITE), 100, <<>>, <<>>, <<>>, <<>>, undefined)
    ).

build_response_mints_tag_test() ->
    Raw = ?M:build_response(
        msg(?INVITE), 486, <<"Nope">>, <<>>, <<>>, <<>>, undefined
    ),
    R = msg(Raw),
    ?assertEqual(486, chappe_sip_msg:status(R)),
    ?assertEqual(<<"Nope">>, chappe_sip_msg:reason(R)),
    ?assertMatch(<<_, _/binary>>, chappe_sip_msg:to_tag(R)).

build_response_keeps_tag_test() ->
    InDialog = binary:replace(
        ?INVITE,
        <<"To: <sip:bob@example.com>">>,
        <<"To: <sip:bob@example.com>;tag=have">>
    ),
    R = msg(
        ?M:build_response(
            msg(InDialog), 200, <<>>, <<>>, <<>>, <<"x">>, undefined
        )
    ),
    ?assertEqual(<<"have">>, chappe_sip_msg:to_tag(R)),
    ?assertEqual(<<"OK">>, chappe_sip_msg:reason(R)).

build_response_missing_headers_test() ->
    %% a request missing headers can still be answered 400
    Bare = msg(<<"OPTIONS sip:a@b SIP/2.0\r\nCall-ID: c\r\n\r\n">>),
    ?assertEqual(
        <<"SIP/2.0 400 Bad Request\r\nCall-ID: c\r\nContent-Length: 0\r\n\r\n">>,
        ?M:build_response(Bare, 400, <<>>, <<>>, <<>>, <<>>, undefined)
    ).

reason_test() ->
    ?assertEqual(<<"Request Terminated">>, ?M:reason(487)),
    ?assertEqual(<<"Call/Transaction Does Not Exist">>, ?M:reason(481)),
    ?assertEqual(<<"OK">>, ?M:reason(299)).

%% ---- header checks ----

content_length_test() ->
    Base = <<
        "MESSAGE sip:a@b SIP/2.0\r\nVia: SIP/2.0/WS h;branch=z9hG4bK1\r\n"
        "From: <sip:a@b>;tag=1\r\nTo: <sip:a@b>\r\nCall-ID: c\r\n"
        "CSeq: 1 MESSAGE\r\n"
    >>,
    ?assertEqual(ok, ?M:content_length(msg(<<Base/binary, "\r\nhi">>))),
    ?assertEqual(
        ok,
        ?M:content_length(msg(<<Base/binary, "Content-Length: 2\r\n\r\nhi">>))
    ),
    ?assertEqual(
        ok,
        ?M:content_length(msg(<<Base/binary, "Content-Length:  2 \r\n\r\nhi">>))
    ),
    ?assertEqual(
        <<"Bad Content-Length">>,
        ?M:content_length(msg(<<Base/binary, "Content-Length: 5\r\n\r\nhi">>))
    ),
    ?assertEqual(
        <<"Bad Content-Length">>,
        ?M:content_length(msg(<<Base/binary, "Content-Length: x\r\n\r\nhi">>))
    ),
    ?assertEqual(
        <<"Bad Content-Length">>,
        ?M:content_length(
            msg(
                <<Base/binary,
                    "Content-Length: 2\r\nContent-Length: 2\r\n\r\nhi">>
            )
        )
    ).

rack_test() ->
    P = fun(RAck) ->
        msg(
            <<"PRACK sip:a@b SIP/2.0\r\n", RAck/binary,
                "Call-ID: c\r\nCSeq: 2 PRACK\r\n\r\n">>
        )
    end,
    ?assertEqual({ok, 5, 7}, ?M:rack(P(<<"RAck: 5 7 INVITE\r\n">>))),
    ?assertEqual({ok, 5, 7}, ?M:rack(P(<<"RAck:  5\t7  INVITE \r\n">>))),
    ?assertEqual(error, ?M:rack(P(<<"RAck: 5 7\r\n">>))),
    ?assertEqual(error, ?M:rack(P(<<"RAck: x 7 INVITE\r\n">>))),
    ?assertEqual(error, ?M:rack(P(<<>>))).

cseq_test() ->
    M = msg(?INVITE),
    ?assertEqual(<<"INVITE">>, ?M:cseq_method(M)),
    ?assertEqual(7, ?M:req_seq(M)),
    ?assertEqual(<<"INVITE">>, ?M:request_method(?INVITE)),
    ?assertEqual(<<>>, ?M:request_method(<<"x">>)).

peer_100rel_test() ->
    ?assert(?M:peer_100rel(msg(?INVITE))),
    NoRel = binary:replace(?INVITE, <<"timer, 100rel">>, <<"timer">>),
    ?assertNot(?M:peer_100rel(msg(NoRel))).

tag_of_test() ->
    ?assertEqual(<<"t1">>, ?M:tag_of(<<"<sip:a@b>;tag=t1">>)),
    ?assertEqual(<<>>, ?M:tag_of(<<"<sip:a@b>">>)).

frame_test() ->
    ?assertEqual({text, <<"OPTIONS é"/utf8>>}, ?M:frame(<<"OPTIONS é"/utf8>>)),
    ?assertEqual({binary, <<16#FF, 16#FE>>}, ?M:frame(<<16#FF, 16#FE>>)).
