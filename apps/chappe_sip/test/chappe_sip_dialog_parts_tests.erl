%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The pure parts of the dialog fsm: offer/answer overlap, claimed finals,
%% target refresh, the automatic answers, the Require and CSeq checks, the
%% NOTIFY headers, the session timer on a response, and the in-dialog
%% request a B2BUA's early leg sends.
-module(chappe_sip_dialog_parts_tests).
-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip.hrl").
-include("../src/dialog/chappe_sip_dialog_fsm.hrl").

-define(OFFER, chappe_sip_dialog_offer).
-define(ROUTE, chappe_sip_dialog_route).
-define(SUB, chappe_sip_dialog_sub).
-define(ST, chappe_sip_dialog_st).

-define(OFFER_SDP, <<"v=0\r\no=- 2 2 IN IP4 10.0.0.2\r\ns=-\r\n">>).
-define(LOCAL_SDP, <<"v=0\r\no=- 1 1 IN IP4 10.0.0.1\r\ns=-\r\n">>).

%% ---- overlap (RFC 3261 14, RFC 3311 5.2) ----

overlap_invite_glare_test() ->
    D = data(#{txning => {undefined, 3, {reinvite, ?LOCAL_SDP}}}),
    ?assertEqual(
        {491, <<"Request Pending">>, []}, ?OFFER:overlap(<<"INVITE">>, <<>>, D)
    ).

overlap_invite_st_refresh_test() ->
    D = data(#{txning => {undefined, 3, {st_refresh, <<"INVITE">>}}}),
    ?assertMatch({491, _, []}, ?OFFER:overlap(<<"INVITE">>, <<>>, D)).

overlap_invite_pending_test() ->
    D = data(#{srv_invite => {4, <<>>}}),
    ?assertMatch(
        {500, <<"Server Internal Error">>, [{<<"Retry-After">>, _}]},
        ?OFFER:overlap(<<"INVITE">>, <<>>, D)
    ).

overlap_update_pending_test() ->
    D = data(#{srv_update => {4, <<>>}}),
    ?assertMatch({500, _, [_]}, ?OFFER:overlap(<<"UPDATE">>, <<>>, D)).

overlap_update_crosses_offer_test() ->
    D = data(#{txning => {undefined, 3, {update, ?LOCAL_SDP}}}),
    ?assertMatch({491, _, []}, ?OFFER:overlap(<<"UPDATE">>, ?OFFER_SDP, D)),
    Early = data(#{uac => self(), local_sdp => ?LOCAL_SDP}),
    ?assertMatch(
        {491, _, []}, ?OFFER:overlap(<<"UPDATE">>, ?OFFER_SDP, Early)
    ).

overlap_update_on_unanswered_offer_test() ->
    D = data(#{srv_invite => {4, ?OFFER_SDP}}),
    ?assertMatch({500, _, [_]}, ?OFFER:overlap(<<"UPDATE">>, ?OFFER_SDP, D)).

overlap_none_test() ->
    D = data(#{}),
    ?assertEqual(ok, ?OFFER:overlap(<<"UPDATE">>, <<>>, D)),
    ?assertEqual(ok, ?OFFER:overlap(<<"UPDATE">>, ?OFFER_SDP, D)),
    ?assertEqual(ok, ?OFFER:overlap(<<"INFO">>, <<>>, D)).

%% ---- claimed finals ----

claimed_invite_answer_test() ->
    D = data(#{srv_invite => {7, ?OFFER_SDP}}),
    D1 = ?OFFER:claimed_final(7, 200, ?LOCAL_SDP, D),
    ?assertEqual(undefined, D1#data.srv_invite),
    ?assert(D1#data.ack_wait),
    ?assertEqual(?OFFER_SDP, D1#data.remote_sdp),
    ?assertEqual(?LOCAL_SDP, D1#data.local_sdp).

claimed_invite_offerless_test() ->
    D = data(#{srv_invite => {7, <<>>}}),
    D1 = ?OFFER:claimed_final(7, 200, ?LOCAL_SDP, D),
    ?assert(D1#data.ack_answer),
    ?assertEqual(?LOCAL_SDP, D1#data.local_sdp).

claimed_invite_rejected_test() ->
    D = data(#{srv_invite => {7, ?OFFER_SDP}}),
    D1 = ?OFFER:claimed_final(7, 486, <<>>, D),
    ?assertNot(D1#data.ack_wait),
    ?assertEqual(<<>>, D1#data.remote_sdp).

claimed_update_answer_test() ->
    D = data(#{srv_update => {8, ?OFFER_SDP}}),
    D1 = ?OFFER:claimed_final(8, 200, ?LOCAL_SDP, D),
    ?assertEqual(undefined, D1#data.srv_update),
    ?assertEqual(?OFFER_SDP, D1#data.remote_sdp),
    ?assertEqual(?LOCAL_SDP, D1#data.local_sdp).

claimed_refresh_target_test() ->
    D = data(#{refresh => #{7 => <<"sip:new@10.0.0.9">>}}),
    D1 = ?OFFER:claimed_final(7, 200, <<>>, D),
    ?assertEqual(<<"sip:new@10.0.0.9">>, D1#data.remote_target),
    ?assertEqual(#{}, D1#data.refresh),
    D2 = ?OFFER:claimed_final(7, 488, <<>>, D),
    ?assertEqual(<<"sip:b@example.com">>, D2#data.remote_target),
    ?assertEqual(#{}, D2#data.refresh),
    D3 = ?OFFER:claimed_final(7, 180, <<>>, D),
    ?assertEqual(D, D3).

claimed_unknown_test() ->
    D = data(#{}),
    ?assertEqual(D, ?OFFER:claimed_final(9, 200, ?LOCAL_SDP, D)).

%% ---- target refresh ----

refresh_target_test() ->
    Ctc = [{<<"Contact">>, <<"<sip:new@10.0.0.9>">>}],
    ?assertEqual(
        <<"sip:new@10.0.0.9">>,
        ?OFFER:refresh_target(<<"INVITE">>, req(<<"INVITE">>, Ctc, <<>>))
    ),
    ?assertEqual(
        <<"sip:new@10.0.0.9">>,
        ?OFFER:refresh_target(<<"UPDATE">>, req(<<"UPDATE">>, Ctc, <<>>))
    ),
    ?assertEqual(
        undefined,
        ?OFFER:refresh_target(<<"INVITE">>, req(<<"INVITE">>, [], <<>>))
    ),
    ?assertEqual(
        undefined,
        ?OFFER:refresh_target(<<"INFO">>, req(<<"INFO">>, Ctc, <<>>))
    ).

%% ---- automatic answers ----

auto_answer_modify_test() ->
    D = data(#{local_sdp => ?LOCAL_SDP, local_contact => <<"<sip:a@h>">>}),
    Offer = req(<<"INVITE">>, [], ?OFFER_SDP),
    {200, <<"OK">>, Hdrs, ?LOCAL_SDP, D1} = ?OFFER:auto_answer(modify, Offer, D),
    ?assertEqual(
        [
            {<<"Content-Type">>, <<"application/sdp">>},
            {<<"Contact">>, <<"<sip:a@h>">>}
        ],
        Hdrs
    ),
    ?assertEqual(?OFFER_SDP, D1#data.remote_sdp),
    {200, _, _, ?LOCAL_SDP, D2} =
        ?OFFER:auto_answer(modify, req(<<"INVITE">>, [], <<>>), D),
    ?assert(D2#data.ack_answer),
    ?assertMatch(
        {488, <<"Not Acceptable Here">>, [{<<"Warning">>, _}], <<>>, _},
        ?OFFER:auto_answer(modify, Offer, data(#{}))
    ).

auto_answer_update_test() ->
    D = data(#{local_contact => <<"<sip:a@h>">>}),
    ?assertMatch(
        {200, <<"OK">>, [{<<"Contact">>, <<"<sip:a@h>">>}], <<>>, _},
        ?OFFER:auto_answer(update, req(<<"UPDATE">>, [], <<>>), D)
    ),
    ?assertMatch(
        {488, _, _, <<>>, _},
        ?OFFER:auto_answer(update, req(<<"UPDATE">>, [], ?OFFER_SDP), D)
    ).

auto_answer_others_test() ->
    D = data(#{}),
    R = req(<<"INFO">>, [], <<>>),
    ?assertMatch({603, <<"Declined">>, [], <<>>, _}, ?OFFER:auto_answer(refer, R, D)),
    {200, <<"OK">>, Opts, <<>>, _} = ?OFFER:auto_answer(options, R, D),
    ?assertEqual(
        [<<"Allow">>, <<"Accept">>, <<"Supported">>], [N || {N, _} <- Opts]
    ),
    ?assertMatch(
        {481, _, [], <<>>, _}, ?OFFER:auto_answer({method, <<"PRACK">>}, R, D)
    ),
    ?assertMatch(
        {405, _, [{<<"Allow">>, ?ALLOW}], <<>>, _},
        ?OFFER:auto_answer(publish, R, D)
    ),
    ?assertMatch(
        {405, _, [{<<"Allow">>, ?ALLOW}], <<>>, _},
        ?OFFER:auto_answer({method, <<"REGISTER">>}, R, D)
    ),
    ?assertMatch(
        {501, <<"Not Implemented">>, _, <<>>, _},
        ?OFFER:auto_answer({method, <<"FOO">>}, R, D)
    ),
    ?assertMatch({200, <<"OK">>, [], <<>>, _}, ?OFFER:auto_answer(info, R, D)).

%% ---- the CSeq and Require checks ----

in_order_test() ->
    D = data(#{remote_cseq => 5}),
    ?assertEqual(out_of_order, ?ROUTE:in_order(req_cseq(4), D)),
    {ok, D1} = ?ROUTE:in_order(req_cseq(5), D),
    ?assertEqual(5, D1#data.remote_cseq),
    {ok, D2} = ?ROUTE:in_order(req_cseq(9), D),
    ?assertEqual(9, D2#data.remote_cseq).

require_check_test() ->
    Engine = mock_engine(self()),
    D = data(#{}),
    R = req(<<"INFO">>, [{<<"Require">>, <<"foo, bar">>}], <<>>),
    ?assertEqual({keep_state, D}, ?ROUTE:require_check(41, R, D)),
    receive
        {engine_call, {txn, {dialog_respond, 41, 420, Reason, Hdrs, <<>>, <<>>}}} ->
            ?assertEqual(<<"Bad Extension">>, Reason),
            ?assertEqual(<<"Unsupported: foo, bar\r\n">>, Hdrs)
    after 2000 -> ?assert(false)
    end,
    exit(Engine, kill),
    flush().

%% ---- NOTIFY headers (RFC 6665 4.2.1, RFC 3515) ----

notify_headers_test() ->
    D = data(#{}),
    ?assertEqual({error, no_event}, ?SUB:notify_headers(#{state => active}, D)),
    ?assertEqual(
        {error, no_subscription},
        ?SUB:notify_headers(#{event => <<"presence">>, state => active}, D)
    ),
    ?assertEqual(
        {ok,
            [
                {<<"Event">>, <<"refer">>},
                {<<"Subscription-State">>, <<"terminated;reason=noresource">>}
            ],
            false},
        ?SUB:notify_headers(
            #{event => <<"refer">>, state => {terminated, noresource}}, D
        )
    ),
    Sub = chappe_sip_subscription:new(
        #{expires => 60, event => <<"presence">>}, undefined
    ),
    {ok, Hdrs, false} = ?SUB:notify_headers(
        #{state => active}, data(#{sub => Sub})
    ),
    ?assertMatch(
        [{<<"Event">>, <<"presence">>}, {<<"Subscription-State">>, _}], Hdrs
    ),
    ?assertMatch(
        {ok, _, true},
        ?SUB:notify_headers(
            #{state => {terminated, timeout}}, data(#{sub => Sub})
        )
    ),
    ?assertEqual(
        {error, badarg},
        ?SUB:notify_headers(#{state => bogus}, data(#{sub => Sub}))
    ).

%% ---- the session timer on a response (RFC 4028 7.2) ----

st_response_test() ->
    D = data(#{}),
    Se = [{<<"Session-Expires">>, <<"1800;refresher=uac">>}],
    {D1, Acts} = ?ST:st_response(200, resp(200, <<"UPDATE">>, Se), D),
    ?assertMatch(#{interval := 1800, refresher := local}, D1#data.st),
    ?assertMatch([{{timeout, st_refresh}, _, refresh}, _], Acts),
    ?assertEqual({D, []}, ?ST:st_response(200, resp(200, <<"UPDATE">>, []), D)),
    ?assertEqual({D, []}, ?ST:st_response(200, resp(200, <<"INFO">>, Se), D)),
    ?assertEqual({D, []}, ?ST:st_response(486, resp(486, <<"INVITE">>, Se), D)),
    %% a 2xx without Session-Expires keeps a running timer and re-arms it
    St = #{interval => 90, refresher => local, min_se => 0, peer_update => false},
    {D2, Rearm} = ?ST:st_response(200, resp(200, <<"INVITE">>, []), data(#{st => St})),
    ?assertEqual(St, D2#data.st),
    ?assertEqual(chappe_sip_session_timer:timeouts(St), Rearm).

%% ---- the request of a dialog that has no fsm yet ----

indialog_request_loose_test() ->
    Dlg = dlg(#{route_set => [<<"<sip:p1.example.com;lr>">>]}),
    {Raw, Route} = chappe_sip_dialog_fsm:indialog_request(
        Dlg, <<"INFO">>, [{<<"X-A">>, <<"1">>}], <<"hi">>
    ),
    ?assertEqual(
        <<"INFO sip:b@10.0.0.2 SIP/2.0\r\n"
          "Route: <sip:p1.example.com;lr>\r\n"
          "From: <sip:a@example.com>;tag=a\r\n"
          "To: <sip:b@example.com>;tag=b\r\n"
          "Call-ID: c1\r\nCSeq: 7 INFO\r\nMax-Forwards: 70\r\n"
          "X-A: 1\r\nSupported: timer\r\nContent-Length: 2\r\n\r\nhi">>,
        Raw
    ),
    ?assertEqual(<<"sip:p1.example.com;lr">>, Route).

indialog_request_strict_test() ->
    Dlg = dlg(#{route_set => [<<"<sip:p1.example.com>">>]}),
    {Raw, _} = chappe_sip_dialog_fsm:indialog_request(
        Dlg, <<"UPDATE">>, [], <<>>
    ),
    ?assertEqual(
        <<"UPDATE sip:p1.example.com SIP/2.0\r\n"
          "Route: <sip:b@10.0.0.2>\r\n"
          "From: <sip:a@example.com>;tag=a\r\n"
          "To: <sip:b@example.com>;tag=b\r\n"
          "Call-ID: c1\r\nCSeq: 7 UPDATE\r\nMax-Forwards: 70\r\n"
          "Contact: <sip:a@10.0.0.1>\r\nSupported: timer\r\n"
          "Content-Length: 0\r\n\r\n">>,
        Raw
    ).

indialog_request_no_route_test() ->
    {Raw, Route} = chappe_sip_dialog_fsm:indialog_request(
        dlg(#{local_contact => undefined}),
        <<"ACK">>,
        [{<<"Contact">>, <<"<sip:x@h>">>}],
        <<>>
    ),
    ?assertEqual(undefined, Route),
    ?assertEqual(
        <<"ACK sip:b@10.0.0.2 SIP/2.0\r\n"
          "From: <sip:a@example.com>;tag=a\r\n"
          "To: <sip:b@example.com>;tag=b\r\n"
          "Call-ID: c1\r\nCSeq: 7 ACK\r\nMax-Forwards: 70\r\n"
          "Contact: <sip:x@h>\r\nContent-Length: 0\r\n\r\n">>,
        Raw
    ).

%% ---- helpers ----

dlg(Over) ->
    maps:merge(
        #{
            remote_target => <<"sip:b@10.0.0.2">>,
            local_addr => <<"<sip:a@example.com>;tag=a">>,
            remote_addr => <<"<sip:b@example.com>;tag=b">>,
            call_id => <<"c1">>,
            route_set => [],
            local_contact => <<"<sip:a@10.0.0.1>">>,
            cseq => 7
        },
        Over
    ).

data(Over) ->
    D = #data{
        leg = 1,
        local_tag = <<"a">>,
        local_addr = <<"<sip:a@example.com>;tag=a">>,
        remote_addr = <<"<sip:b@example.com>;tag=b">>,
        remote_target = <<"sip:b@example.com">>,
        call_id = <<"c1">>,
        owner = self(),
        owner_mon = make_ref(),
        on_owner_exit = destroy,
        handled = []
    },
    maps:fold(fun set/3, D, Over).

set(txning, V, D) -> D#data{txning = V};
set(srv_invite, V, D) -> D#data{srv_invite = V};
set(srv_update, V, D) -> D#data{srv_update = V};
set(uac, V, D) -> D#data{uac = V};
set(local_sdp, V, D) -> D#data{local_sdp = V};
set(refresh, V, D) -> D#data{refresh = V};
set(local_contact, V, D) -> D#data{local_contact = V};
set(remote_cseq, V, D) -> D#data{remote_cseq = V};
set(sub, V, D) -> D#data{sub = V};
set(st, V, D) -> D#data{st = V}.

req(Method, Hdrs, Body) ->
    Extra = iolist_to_binary([[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs]),
    CL = integer_to_binary(byte_size(Body)),
    Raw = <<Method/binary, " sip:a@example.com SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 10.0.0.2;branch=z9hG4bKparts\r\n"
            "From: <sip:b@example.com>;tag=b\r\n"
            "To: <sip:a@example.com>;tag=a\r\n"
            "Call-ID: c1\r\nCSeq: 3 ", Method/binary, "\r\n",
            Extra/binary, "Content-Length: ", CL/binary, "\r\n\r\n",
            Body/binary>>,
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_req:new(Msg, 41, #{}, undefined).

req_cseq(N) ->
    Raw = <<"INFO sip:a@example.com SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 10.0.0.2;branch=z9hG4bKparts\r\n"
            "Call-ID: c1\r\nCSeq: ", (integer_to_binary(N))/binary, " INFO\r\n"
            "Content-Length: 0\r\n\r\n">>,
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_req:new(Msg, 41, #{}, undefined).

resp(Status, Method, Hdrs) ->
    Extra = iolist_to_binary([[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs]),
    <<"SIP/2.0 ", (integer_to_binary(Status))/binary, " X\r\n"
      "Via: SIP/2.0/UDP 10.0.0.1;branch=z9hG4bKparts\r\n"
      "From: <sip:a@example.com>;tag=a\r\n"
      "To: <sip:b@example.com>;tag=b\r\n"
      "Call-ID: c1\r\nCSeq: 2 ", Method/binary, "\r\n",
      Extra/binary, "Content-Length: 0\r\n\r\n">>.

mock_engine(Test) ->
    Pid = spawn(fun() -> engine_loop(Test) end),
    true = register(chappe_sip_engine, Pid),
    Pid.

engine_loop(Test) ->
    receive
        {'$gen_call', From, Req} ->
            Test ! {engine_call, Req},
            gen_server:reply(From, {ok, 999}),
            engine_loop(Test);
        _ ->
            engine_loop(Test)
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.
