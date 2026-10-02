%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 3261 core duties of chappe as a UAS, on the wire.
%%
%% A raw gen_udp peer (chappe_sip_core_peer) plays the caller against the
%% real engine on loopback: dialog construction (12.1.1), in-dialog request
%% rules (12.2), response construction (8.2.6), INVITE and non-INVITE server
%% transactions (17.2), BYE (15.1.2), CANCEL (9.2), OPTIONS (11.2) and the
%% server transport (18.2). The stack sends 100 Trying at once to every
%% INVITE; the cases skip it unless they are about it.
-module(chappe_sip_core_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [
    open/0, port/1, send/3, recv/3, recv_none/3, collect/3, drain/1,
    request/3, response/3, hdr/2, hdrs/2, status/1, method/1, uri/1,
    cseq/1, to_tag/1, from_tag/1, body/1, top_via/1, via_branch/1,
    branch/0, tag/0, call_id/0, sdp/0
]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([invite_dialog_forming/1, indialog_requests_follow_dialog/1,
         indialog_no_route_set/1, remote_cseq_rules/1,
         bye_no_dialog_481/1, bye_ends_dialog/1, unknown_to_tag_481/1,
         bye_waits_for_ack/1, no_ack_ends_session/1,
         invite_retransmit_gets_provisional/1, error_response_retransmits/1,
         error_response_timer_h/1, non_invite_final_only/1,
         non_invite_provisionals/1, non_invite_timer_j/1,
         cancel_pending_invite/1, cancel_no_match_481/1,
         options_default/1, received_param/1, response_to_sent_by/1,
         tcp_listener/1, large_udp_request/1, trailing_bytes_dropped/1,
         short_datagram_400/1, unsupported_scheme_416/1, tel_to_accepted/1,
         empty_user_rejected/1, missing_mandatory_400/1, cseq_range/1,
         require_unknown_420/1, no_reliable_without_support/1,
         bad_header_named_400/1, bye_answers_pending_reinvite/1,
         target_refresh_accepted/1, target_refresh_rejected/1,
         reinvite_waits_for_ack/1, reinvite_one_at_a_time/1,
         request_during_reinvite/1, early_uas_no_bye/1,
         indialog_481_ends_dialog/1, session_over_at_bye/1,
         indialog_timeout_ends_dialog/1, bye_timeout_ends_dialog/1,
         offerless_invite/1, offerless_reinvite/1, reoffer_bumps_version/1,
         tagless_from_accepted/1, merged_request_482/1, contact_reachable/1,
         reliable_provisional_require/1, unsupported_body_415/1,
         cseq_method_mismatch_400/1, no_max_forwards_served/1,
         uas_ignores_proxy_require/1, proxy_route_checks_proxy_require/1,
         siprec_require/1, indialog_require_420/1,
         ack_cancel_require_ignored/1]).
-export([tcp_no_content_length/1, via_maddr_response/1,
         unknown_encoding_415/1, na_request_headers_ignored/1,
         provisional_every_minute/1]).

all() ->
    [{group, wire}, {group, timers}, {group, minute}].

groups() ->
    [{wire, [], [invite_dialog_forming, indialog_requests_follow_dialog,
     indialog_no_route_set, remote_cseq_rules, bye_no_dialog_481,
     bye_ends_dialog, unknown_to_tag_481, bye_waits_for_ack,
     invite_retransmit_gets_provisional, error_response_retransmits,
     non_invite_final_only, non_invite_provisionals, cancel_pending_invite,
     cancel_no_match_481, options_default, received_param,
     response_to_sent_by, tcp_listener, large_udp_request,
     trailing_bytes_dropped, short_datagram_400, unsupported_scheme_416,
     tel_to_accepted, empty_user_rejected, missing_mandatory_400, cseq_range,
     require_unknown_420, no_reliable_without_support,
     bad_header_named_400, bye_answers_pending_reinvite,
     target_refresh_accepted, target_refresh_rejected, reinvite_waits_for_ack,
     reinvite_one_at_a_time, request_during_reinvite, early_uas_no_bye,
     indialog_481_ends_dialog, session_over_at_bye, offerless_invite,
     offerless_reinvite, reoffer_bumps_version, tagless_from_accepted,
     merged_request_482, contact_reachable, reliable_provisional_require,
     unsupported_body_415, cseq_method_mismatch_400, no_max_forwards_served,
     uas_ignores_proxy_require, proxy_route_checks_proxy_require,
     siprec_require, indialog_require_420, ack_cancel_require_ignored,
     tcp_no_content_length, via_maddr_response, unknown_encoding_415,
     na_request_headers_ignored]},
     %% each waits 64*T1 (32 s)
     {timers, [],
      [no_ack_ends_session, error_response_timer_h, non_invite_timer_j,
       indialog_timeout_ends_dialog, bye_timeout_ends_dialog]},
     %% waits for the 180 resent after a minute (66 s)
     {minute, [], [provisional_every_minute]}].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    Port = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(Port)}),
    Sock = open(),
    [{port, Port}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- UAS dialog construction ----

%% The app rings then answers an INVITE that went through two
%% record-routing proxies. Every response echoes From, Call-ID, CSeq and the
%% Via list (8.2.6.2); 180 and 200 share one To tag (13.3.1); the 200 copies
%% the Record-Route list in order (12.1.1), carries a sip: Contact, the SDP
%% answer (13.3.1.4), Allow and Supported, and a correct Content-Length and
%% Content-Type (20.14, 20.15). Unknown headers, header parameters and URI
%% parameters are ignored (8.2.2, 19.1.1, 20).
%% req: R3261-104 R3261-105 R3261-106 R3261-107 R3261-109 R3261-110
%% req: R3261-123 R3261-124 R3261-125 R3261-212 R3261-211 R3261-219
%% req: R3261-188 R3261-220 R3261-311 R3261-312 R3261-314 R3261-439
%% req: R3261-442 R3261-074 R3261-389 R3261-420 R3261-006 R3261-075
%% req: R3261-432 R3261-422 R3261-189 R3261-411
invite_dialog_forming(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {invite, Req},
        ok = chappe_sip_res:send(Res, 180),
        ok = chappe_sip_res:send(Res, 183, #{body => sdp(),
                                             headers => [{<<"Content-Type">>,
                                                          <<"application/sdp">>}]}),
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    LP = port(Sock),
    P = integer_to_binary(LP),
    RR = [<<"<sip:p2.example.invalid;lr;x-u=1>;x-p=2">>,
          <<"<sip:p1.example.invalid;lr>">>],
    Vias = <<"SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
             ", SIP/2.0/UDP 192.0.2.9:5070;branch=z9hG4bKlower;received=192.0.2.9">>,
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1;x-unknown=yes">>,
                  #{port => LP, via => Vias, body => sdp(),
                    to => <<"<sip:app@127.0.0.1;x-unknown=yes>;x-hp=1">>,
                    contact => <<"<sip:peer@127.0.0.1:", P/binary,
                                 ";x-cp=1>;x-hp=2">>,
                    headers => [{<<"Record-Route">>, lists:nth(1, RR)},
                                {<<"Record-Route">>, lists:nth(2, RR)},
                                {<<"X-Foo">>, <<"bar">>},
                                {<<"Date">>, <<"not a date">>},
                                {<<"Expires">>, <<"soon">>}]}),
    send(Sock, Port, Inv),
    receive {invite, _} -> ok after 3000 -> ct:log("~p", [collect(Sock, any, 500)]), ct:fail(no_invite) end,
    {R180, _} = recv(Sock, {status, 180}, 3000),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    {R200, _} = recv(Sock, {status, 200}, 3000),
    InvM = chappe_sip_core_peer:parse(Inv),
    Tag = to_tag(R200),
    ?assertNotEqual(undefined, Tag),
    [begin
         ?assertEqual(hdr(<<"from">>, InvM), hdr(<<"from">>, R)),
         ?assertEqual(hdr(<<"call-id">>, InvM), hdr(<<"call-id">>, R)),
         ?assertEqual(hdr(<<"cseq">>, InvM), hdr(<<"cseq">>, R)),
         ?assertEqual(via_list(InvM), via_list(R)),
         ?assertEqual(Tag, to_tag(R)),
         ?assertEqual(to_uri(InvM), to_uri(R))
     end || R <- [R180, R183, R200]],
    ?assertEqual(RR, hdrs(<<"record-route">>, R200)),
    Contact = hdr(<<"contact">>, R200),
    ?assertMatch(<<"<sip:", _/binary>>, Contact),
    ?assertMatch(<<"v=0", _/binary>>, body(R200)),
    ?assertEqual(body(R183), body(R200)),
    ?assert(byte_size(Tag) >= 8),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, R200)),
    ?assertEqual(integer_to_binary(byte_size(body(R200))),
                 hdr(<<"content-length">>, R200)),
    ?assertEqual(<<"0">>, hdr(<<"content-length">>, R180)),
    ?assertNotEqual(undefined, hdr(<<"allow">>, R200)),
    ?assertNotEqual(undefined, hdr(<<"supported">>, R200)),
    receive {dialog, _} -> ok after 3000 -> ct:fail(no_dialog) end.

%% After the dialog is formed from an INVITE with a Record-Route, the app's
%% in-dialog requests (INFO then BYE) follow the UAS dialog state: Route is
%% the recorded route in order and the Request-URI the caller's Contact
%% (12.1.1, 12.2.1.1 loose routing); Call-ID, tags and URIs are swapped
%% from the INVITE; CSeq starts below 2**31 and grows by one; each request
%% has Max-Forwards 70, one Via with a z9hG4bK branch unique per request
%% and a sent-by of ours, and Content-Length 0.
%% req: R3261-129 R3261-131 R3261-133 R3261-134 R3261-135 R3261-137
%% req: R3261-150 R3261-151 R3261-152 R3261-153 R3261-155 R3261-156
%% req: R3261-158 R3261-162 R3261-011 R3261-016 R3261-017 R3261-018
%% req: R3261-019 R3261-020 R3261-021 R3261-022 R3261-023 R3261-461
%% req: R3261-344 R3261-441 R3261-128 R3261-122 R3261-148 R3261-427
%% req: R3261-417
indialog_requests_follow_dialog(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    P = integer_to_binary(LP),
    RR = <<"<sip:127.0.0.1:", P/binary, ";lr;x-rr=1>">>,
    Contact = <<"sip:peer@127.0.0.1:", P/binary, ";x-c=1">>,
    {Inv, D, R200} = call(Sock, Port, #{
        contact => <<"<", Contact/binary, ">">>,
        headers => [{<<"Record-Route">>, RR}]}),
    LocalTag = to_tag(R200),
    RemoteTag = from_tag(Inv),
    Infos = [begin
                 Info = async(fun() ->
                     chappe_sip_dialog:request(D, #{method => <<"INFO">>})
                 end),
                 {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
                 send(Sock, Port, response(InfoReq, 200, #{})),
                 {ok, _} = await(Info),
                 InfoReq
             end || _ <- [1, 2]],
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, Port, response(ByeReq, 200, #{})),
    ok = await(Bye),
    Sent = Infos ++ [ByeReq],
    [begin
         ?assertEqual(Contact, uri(R)),
         ?assertEqual([RR], hdrs(<<"route">>, R)),
         ?assertEqual(hdr(<<"call-id">>, Inv), hdr(<<"call-id">>, R)),
         ?assertEqual(LocalTag, from_tag(R)),
         ?assertEqual(RemoteTag, to_tag(R)),
         ?assertEqual(to_uri(Inv), from_uri(R)),
         ?assertEqual(from_uri(Inv), to_uri(R)),
         ?assertEqual(<<"70">>, hdr(<<"max-forwards">>, R)),
         ?assertEqual(<<"0">>, hdr(<<"content-length">>, R)),
         [Via] = via_list(R),
         ?assertMatch(<<"SIP/2.0/UDP 127.0.0.1:", _/binary>>, Via),
         ?assertEqual(integer_to_binary(Port), sent_by_port(Via)),
         ?assertMatch(<<"z9hG4bK", _/binary>>, via_branch(Via))
     end || R <- Sent],
    %% Contact is not applicable to BYE (RFC 3261 20, table 3)
    ?assertEqual(undefined, hdr(<<"contact">>, ByeReq)),
    [{N1, <<"INFO">>}, {N2, <<"INFO">>}, {N3, <<"BYE">>}] = [cseq(R) || R <- Sent],
    ?assert(N1 < 1 bsl 31),
    ?assertEqual([N1 + 1, N1 + 2], [N2, N3]),
    Branches = [via_branch(top_via(R)) || R <- Sent],
    ?assertEqual(3, length(lists:usort(Branches))).

%% Without Record-Route in the INVITE the route set is empty: the app's
%% in-dialog request carries no Route and goes to the Contact URI
%% (12.1.1, 12.2.1.1).
%% req: R3261-130 R3261-160 R3261-161
indialog_no_route_set(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    Contact = <<"sip:peer@127.0.0.1:", (integer_to_binary(LP))/binary>>,
    {_Inv, D, _R200} = call(Sock, Port, #{}),
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
    send(Sock, Port, response(InfoReq, 200, #{})),
    {ok, _} = await(Info),
    ?assertEqual(Contact, uri(InfoReq)),
    ?assertEqual([], hdrs(<<"route">>, InfoReq)).

%% The remote CSeq starts at the INVITE's (12.1.1): an in-dialog request
%% below it is out of order and gets 500 (12.2.2). A jump of more than one
%% is fine, and the remote CSeq then moves to it.
%% req: R3261-132 R3261-174 R3261-175 R3261-176 R3261-173 R3261-256
remote_cseq_rules(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, _D, R200} = call(Sock, Port, #{cseq => 5}),
    InDialog = fun(Method, N) ->
        request(Method, <<"sip:app@127.0.0.1">>,
                #{port => LP, call_id => hdr(<<"call-id">>, Inv),
                  from_tag => from_tag(Inv), to_tag => to_tag(R200),
                  cseq => N})
    end,
    send(Sock, Port, InDialog(<<"INFO">>, 3)),
    {R1, _} = recv(Sock, final, 3000),
    ?assertEqual(500, status(R1)),
    send(Sock, Port, InDialog(<<"INFO">>, 10)),
    {R2, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R2)),
    send(Sock, Port, InDialog(<<"INFO">>, 9)),
    {R3, _} = recv(Sock, final, 3000),
    ?assertEqual(500, status(R3)),
    send(Sock, Port, InDialog(<<"BYE">>, 8)),
    {R4, _} = recv(Sock, final, 3000),
    ?assertEqual(500, status(R4)),
    send(Sock, Port, InDialog(<<"BYE">>, 11)),
    {R5, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R5)).

%% ---- BYE (15.1.2) ----

%% A BYE naming no dialog gets 481, even with no BYE handler registered.
%% req: R3261-255
bye_no_dialog_481(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 486) end),
    Bye = request(<<"BYE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), to_tag => tag(), cseq => 2}),
    send(Sock, Port, Bye),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(481, status(R)).

%% A BYE on the dialog gets 200 and the app is told the session is over;
%% with ACK and INVITE before it, a UA taking INVITE takes ACK and BYE
%% (13.1; CANCEL: cancel_pending_invite).
%% req: R3261-258 R3261-248 R3261-257 R3261-178
bye_ends_dialog(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}),
    Bye = request(<<"BYE">>, <<"sip:app@127.0.0.1">>,
                  #{port => LP, call_id => hdr(<<"call-id">>, Inv),
                    from_tag => from_tag(Inv), to_tag => to_tag(R200),
                    cseq => 2}),
    send(Sock, Port, Bye),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R)),
    receive {chappe_sip_dialog, D, destroy, _} -> ok
    after 3000 -> ct:fail(no_destroy)
    end.

%% An in-dialog request whose To tag names no dialog is not taken as a new
%% call: it gets 481 (12.2.2).
%% req: R3261-172
unknown_to_tag_481(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {invite, Req},
        chappe_sip_res:send(Res, 486)
    end),
    ok = chappe_sip:info(fun(Req, Res) ->
        Test ! {info, Req},
        chappe_sip_res:send(Res, 200)
    end),
    [begin
         R0 = request(M, <<"sip:app@127.0.0.1">>,
                      #{port => port(Sock), to_tag => tag(), cseq => 7,
                        body => case M of <<"INVITE">> -> sdp(); _ -> <<>> end}),
         send(Sock, Port, R0),
         {R, _} = recv(Sock, final, 3000),
         ?assertEqual(481, status(R)),
         case M of
             <<"INVITE">> -> send(Sock, Port, chappe_sip_core_peer:ack_for(R, #{}));
             _ -> ok
         end
     end || M <- [<<"INVITE">>, <<"INFO">>]],
    receive {Kind, _} -> ct:fail({handler_ran, Kind}) after 300 -> ok end.

%% ---- dialog state and overlapping transactions (8.2, 12.2, 14, 15) ----

%% A BYE arrives while the app holds an incoming re-INVITE: the re-INVITE
%% gets 487, then the BYE 200 (15.1.2).
%% req: R3261-259 R3261-260
bye_answers_pending_reinvite(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}, #{handled_events => [modify]}),
    ReInv = indialog(<<"INVITE">>, Inv, R200, LP, 2, #{body => sdp()}),
    send(Sock, Port, ReInv),
    receive {chappe_sip_dialog, D, modify, _, _} -> ok
    after 3000 -> ct:fail(no_modify)
    end,
    send(Sock, Port, indialog(<<"BYE">>, Inv, R200, LP, 3, #{})),
    {R487, _} = recv(Sock, {status, 487, <<"INVITE">>}, 3000),
    {_, _} = recv(Sock, {status, 200, <<"BYE">>}, 3000),
    send(Sock, Port, ack_non2xx(ReInv, R487)).

%% A re-INVITE the dialog accepts, Contact and Record-Route included, moves
%% the remote target to its Contact and adopts its offer; the app's next
%% request goes to the new Contact (8.2, 12.2, 12.2.2).
%% req: R3261-177 R3261-067 R3261-149
target_refresh_accepted(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}),
    NewContact = <<"sip:moved@127.0.0.1:", (integer_to_binary(LP))/binary>>,
    Offer = chappe_sip_core_peer:sdp(40002),
    ReInv = indialog(<<"INVITE">>, Inv, R200, LP, 2,
                     #{body => Offer,
                       contact => <<"<", NewContact/binary, ">">>,
                       headers => [{<<"Record-Route">>,
                                    <<"<sip:rr.example.invalid;lr>">>}]}),
    send(Sock, Port, ReInv),
    {R2, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R2, #{port => LP})),
    ?assertEqual(Offer, chappe_sip_dialog:remote_sdp(D)),
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
    send(Sock, Port, response(InfoReq, 200, #{})),
    {ok, _} = await(Info),
    ?assertEqual(NewContact, uri(InfoReq)),
    %% the route set is fixed when the dialog forms (12.2)
    ?assertEqual([], hdrs(<<"route">>, InfoReq)).

%% A re-INVITE the app rejects changes nothing: the remote target and the
%% remote session stay as they were (8.2).
%% req: R3261-068
target_refresh_rejected(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}, #{handled_events => [modify]}),
    OldSdp = chappe_sip_dialog:remote_sdp(D),
    NewContact = <<"sip:moved@127.0.0.1:", (integer_to_binary(LP))/binary>>,
    ReInv = indialog(<<"INVITE">>, Inv, R200, LP, 2,
                     #{body => chappe_sip_core_peer:sdp(40004),
                       contact => <<"<", NewContact/binary, ">">>}),
    send(Sock, Port, ReInv),
    receive
        {chappe_sip_dialog, D, modify, _, Res} ->
            ok = chappe_sip_res:send(Res, 488)
    after 3000 -> ct:fail(no_modify)
    end,
    {R488, _} = recv(Sock, {status, 488}, 3000),
    send(Sock, Port, ack_non2xx(ReInv, R488)),
    ?assertEqual(OldSdp, chappe_sip_dialog:remote_sdp(D)),
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
    send(Sock, Port, response(InfoReq, 200, #{})),
    {ok, _} = await(Info),
    ?assertNotEqual(NewContact, uri(InfoReq)).

%% Our re-INVITE waits while an INVITE server transaction of the dialog is
%% not confirmed: the peer's re-INVITE we answered 200 but that it has not
%% ACKed yet. The ACK releases it (14.1).
%% req: R3261-228 R3261-230
reinvite_waits_for_ack(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}),
    ReInv = indialog(<<"INVITE">>, Inv, R200, LP, 2, #{body => sdp()}),
    send(Sock, Port, ReInv),
    {R2, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    Mod = async(fun() -> chappe_sip_dialog:modify(D, hold) end),
    recv_none(Sock, {method, <<"INVITE">>}, 1500),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R2, #{port => LP})),
    {Ours, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, Port, response(Ours, 200, #{body => sdp()})),
    {ok, _} = await(Mod),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual(element(1, cseq(Ours)), element(1, cseq(Ack))).

%% A second re-INVITE from the app waits for the first to complete: one
%% INVITE client transaction at a time, and no new offer before the last
%% one is answered (13.2.1, 14.1).
%% req: R3261-229 R3261-192
reinvite_one_at_a_time(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, Port, #{}),
    M1 = async(fun() -> chappe_sip_dialog:modify(D, hold) end),
    {First, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    M2 = async(fun() -> chappe_sip_dialog:modify(D, unhold) end),
    %% retransmissions of the first are fine, a new INVITE is not
    FirstSeq = cseq(First),
    recv_none(Sock, fun(B) ->
                            method(B) =:= <<"INVITE">> andalso
                                cseq(B) =/= FirstSeq
                    end, 1500),
    send(Sock, Port, response(First, 200, #{body => sdp()})),
    {ok, _} = await(M1),
    {Second, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, Port, response(Second, 200, #{body => sdp()})),
    {ok, _} = await(M2).

%% While the app holds an incoming re-INVITE it can still send other
%% requests in the dialog (14.1).
%% req: R3261-231
request_during_reinvite(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}, #{handled_events => [modify]}),
    ReInv = indialog(<<"INVITE">>, Inv, R200, LP, 2, #{body => sdp()}),
    send(Sock, Port, ReInv),
    Res = receive {chappe_sip_dialog, D, modify, _, Res0} -> Res0
          after 3000 -> ct:fail(no_modify)
          end,
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
    send(Sock, Port, response(InfoReq, 200, #{})),
    {ok, _} = await(Info),
    ok = chappe_sip_res:send(Res, 200, #{body => sdp(),
                                        headers => [{<<"Content-Type">>,
                                                     <<"application/sdp">>}]}),
    {R2, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R2, #{port => LP})).

%% The app hangs up an early dialog it answered 180: no BYE on an early
%% dialog from the callee, the INVITE gets a final error instead (15).
%% req: R3261-250
early_uas_no_bye(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{status => 180,
                                                    reason => <<"Ringing">>,
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp()}),
    send(Sock, Port, Inv),
    {_, _} = recv(Sock, {status, 180}, 3000),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    Seen = collect(Sock, any, 1500),
    ?assertEqual([], [B || {_, B} <- Seen, method(B) =:= <<"BYE">>]),
    [Final | _] = [B || {_, B} <- Seen, is_integer(status(B)), status(B) >= 300],
    ct:log("final: ~s", [hd(binary:split(Final, <<"\r\n">>))]),
    ok = await(Bye),
    send(Sock, Port, ack_non2xx(Inv, Final)).

%% A 481 to an in-dialog request ends the dialog (12.2.1.2).
%% req: R3261-169
indialog_481_ends_dialog(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, Port, #{}),
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
    send(Sock, Port, response(InfoReq, 481, #{})),
    {ok, _} = await(Info),
    receive {chappe_sip_dialog, D, destroy, {request_failed, 481}} -> ok
    after 3000 -> ct:fail(dialog_kept)
    end,
    recv_none(Sock, {method, <<"BYE">>}, 500).

%% Once our BYE is out the session is over for the app: the dialog takes
%% no new request while the BYE waits for its response (15.1.1).
%% req: R3261-253
session_over_at_bye(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, Port, #{}),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    ?assertEqual({error, terminating},
                 chappe_sip_dialog:request(D, #{method => <<"INFO">>})),
    send(Sock, Port, response(ByeReq, 200, #{})),
    ok = await(Bye).


%% ---- offer/answer as UAS (13.2.1, 13.3.1, 14.1, 14.2) ----

%% An INVITE without an offer: the app's 200 carries the offer and the
%% caller's ACK the answer, which becomes the remote session.
%% req: R3261-210 R3261-221 R3261-194
offerless_invite(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    LP = port(Sock),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => LP})),
    {R200, _} = recv(Sock, {status, 200}, 3000),
    ?assertEqual(sdp(), body(R200)),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    Answer = chappe_sip_core_peer:sdp(45000),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R200, #{
        port => LP, body => Answer,
        headers => [{<<"Content-Type">>, <<"application/sdp">>}]})),
    receive {chappe_sip_dialog, D, ack, _, _} -> ok
    after 3000 -> ct:fail(no_ack)
    end,
    ?assertEqual(Answer, chappe_sip_dialog:remote_sdp(D)).

%% A re-INVITE without an offer gets a 200 whose offer is the full local
%% session, the same streams and formats as before; the ACK answer becomes
%% the remote session (14.2).
%% req: R3261-244 R3261-245 R3261-246
offerless_reinvite(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, D, R200} = call(Sock, Port, #{}),
    send(Sock, Port, indialog(<<"INVITE">>, Inv, R200, LP, 2, #{})),
    {R2, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    ?assertEqual(mlines(body(R200)), mlines(body(R2))),
    Answer = chappe_sip_core_peer:sdp(46000),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R2, #{
        port => LP, body => Answer,
        headers => [{<<"Content-Type">>, <<"application/sdp">>}]})),
    receive {chappe_sip_dialog, D, ack, _, _} -> ok
    after 3000 -> ct:fail(no_ack)
    end,
    ?assertEqual(Answer, chappe_sip_dialog:remote_sdp(D)).

%% A new offer of ours (hold) carries a higher o= session version (14.1).
%% req: R3261-226
reoffer_bumps_version(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, R200} = call(Sock, Port, #{}),
    Mod = async(fun() -> chappe_sip_dialog:modify(D, hold) end),
    {ReInv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, Port, response(ReInv, 200, #{body => sdp()})),
    {ok, _} = await(Mod),
    ct:log("before: ~p after: ~p", [sdp_version(body(R200)), sdp_version(body(ReInv))]),
    ?assert(sdp_version(body(ReInv)) > sdp_version(body(R200))).

%% ---- tags (12.1.1, 12.2.1.1, 19.3) ----

%% An INVITE whose From has no tag (RFC 2543) still forms a dialog; our
%% requests in it then carry no To tag (the remote tag is null).
%% req: R3261-136 R3261-154
tagless_from_accepted(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, Port, #{from_tag => none}),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, Port, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertEqual(undefined, to_tag(ByeReq)),
    ?assertEqual(nomatch, binary:match(hdr(<<"to">>, ByeReq), <<"tag=">>)).

%% The same INVITE (From tag, Call-ID, CSeq) arriving again on another
%% branch while the first is pending is a merged request: 482 (8.2.2.2).
%% req: R3261-081 R3261-082
merged_request_482(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180),
        receive stop -> ok after 3000 -> chappe_sip_res:send(Res, 486) end
    end),
    Base = #{port => port(Sock), body => sdp(), call_id => call_id(),
             from_tag => tag()},
    Inv1 = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>, Base),
    send(Sock, Port, Inv1),
    {_, _} = recv(Sock, {status, 180}, 3000),
    Inv2 = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>, Base#{branch => branch()}),
    send(Sock, Port, Inv2),
    {R482, _} = recv(Sock, {status, 482}, 3000),
    ?assertEqual(via_branch(top_via(Inv2)), via_branch(top_via(R482))),
    send(Sock, Port, ack_non2xx(Inv2, R482)),
    {R486, _} = recv(Sock, {status, 486}, 5000),
    send(Sock, Port, ack_non2xx(Inv1, R486)).

%% The Contact of our 200 reaches chappe out of the dialog (12.1.1).
%% req: R3261-127
contact_reachable(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    {_Inv, _D, R200} = call(Sock, Port, #{}),
    {ok, #{uri := Contact}} = chappe_sip_hdr:name_addr(hdr(<<"contact">>, R200)),
    send(Sock, Port, request(<<"OPTIONS">>, Contact, #{port => port(Sock)})),
    {R, _} = recv(Sock, {status, 200, <<"OPTIONS">>}, 3000),
    ?assertEqual(200, status(R)).

%% A reliable 183 the caller allowed lists 100rel in Require and carries
%% RSeq (8.2.4); a caller that did not offer 100rel never gets a 421.
%% req: R3261-097 R3261-096
reliable_provisional_require(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        ok = chappe_sip_res:send_reliable(
               Res, #{status => 183, body => sdp(), to_tag => <<"rel2">>,
                      headers => [{<<"Content-Type">>, <<"application/sdp">>}]}),
        {ok, _} = chappe_sip_res:await_prack(Res, 5000),
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    local_tag => <<"rel2">>,
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    LP = port(Sock),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => LP, body => sdp(),
                    headers => [{<<"Supported">>, <<"100rel">>}]}),
    send(Sock, Port, Inv),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    ?assertEqual(<<"100rel">>, hdr(<<"require">>, R183)),
    RSeq = hdr(<<"rseq">>, R183),
    ?assertNotEqual(undefined, RSeq),
    {N, _} = cseq(Inv),
    Prack = request(<<"PRACK">>, <<"sip:app@127.0.0.1">>,
                    #{port => LP, call_id => hdr(<<"call-id">>, Inv),
                      from_tag => from_tag(Inv), to_tag => to_tag(R183),
                      cseq => N + 1,
                      headers => [{<<"RAck">>, <<RSeq/binary, " ",
                                                  (integer_to_binary(N))/binary,
                                                  " INVITE">>}]}),
    send(Sock, Port, Prack),
    {_, _} = recv(Sock, {status, 200, <<"PRACK">>}, 3000),
    {R200, _} = recv(Sock, {status, 200, <<"INVITE">>}, 3000),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R200, #{port => LP})).

%% An INVITE whose body is of a type we cannot read gets 415 with Accept
%% and never reaches the app; a multipart (SDP plus other parts) and an
%% optional part of an unknown type go through (8.2.3, 20.11).
%% req: R3261-088 R3261-089 R3261-491
unsupported_body_415(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {handler, chappe_sip_req:get(<<"content-type">>, Req)},
        chappe_sip_res:send(Res, 486)
    end),
    Try = fun(Hdrs, CT) ->
        Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                      #{port => port(Sock), body => <<"opaque">>,
                        content_type => CT, headers => Hdrs}),
        send(Sock, Port, Inv),
        {R, _} = recv(Sock, final, 3000),
        send(Sock, Port, ack_non2xx(Inv, R)),
        R
    end,
    R415 = Try([], <<"application/x-foo">>),
    ?assertEqual(415, status(R415)),
    ?assertMatch({match, _}, re:run(hdr(<<"accept">>, R415), "application/sdp")),
    receive {handler, _} -> ct:fail(handler_ran) after 300 -> ok end,
    ?assertEqual(486, status(Try([], <<"multipart/mixed;boundary=x">>))),
    ?assertEqual(486, status(Try([{<<"Content-Disposition">>,
                                   <<"render;handling=optional">>}],
                                 <<"application/x-foo">>))).

%% An INVITE whose SDP carries a Content-Encoding we do not apply (br; nta
%% itself decodes gzip and deflate) gets 415 with Accept-Encoding listing
%% what we take, and never reaches the app (8.2.3).
%% req: R3261-090
unknown_encoding_415(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 486)
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp(),
                    headers => [{<<"Content-Encoding">>, <<"br">>}]}),
    send(Sock, Port, Inv),
    {R, _} = recv(Sock, final, 3000),
    send(Sock, Port, ack_non2xx(Inv, R)),
    ?assertEqual(415, status(R)),
    ?assertEqual(<<"identity">>, hdr(<<"accept-encoding">>, R)),
    receive handler -> ct:fail(handler_ran) after 300 -> ok end.

%% Header fields not applicable to an INVITE (WWW-Authenticate,
%% Min-Expires, Server, Retry-After, Unsupported: response or other-method
%% headers, RFC 3261 20 tables 2 and 3) are ignored: the call is answered
%% as usual.
%% req: R3261-418
na_request_headers_ignored(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
    end),
    LP = port(Sock),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => LP, body => sdp(),
                               headers => [{<<"WWW-Authenticate">>,
                                            <<"Digest realm=\"x\", nonce=\"y\"">>},
                                           {<<"Min-Expires">>, <<"3600">>},
                                           {<<"Server">>, <<"misplaced/1.0">>},
                                           {<<"Retry-After">>, <<"120">>},
                                           {<<"Unsupported">>, <<"100rel">>}]})),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R)),
    ?assertMatch(<<"v=0", _/binary>>, body(R)),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R, #{port => LP})).

%% ---- ACK of our 2xx (13.3.1.4, 15) ----

%% The app hangs up before the caller ACKs its 200: the 200 keeps being
%% retransmitted and no BYE goes out until the ACK arrives (15). The BYE
%% follows the ACK.
%% req: R3261-251
bye_waits_for_ack(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    LP = port(Sock),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => LP, body => sdp()})),
    {R200, _} = recv(Sock, {status, 200}, 3000),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    Seen = collect(Sock, any, 2500),
    ?assertEqual([], [B || {_, B} <- Seen, method(B) =:= <<"BYE">>]),
    Retx = [T || {T, B} <- Seen, status(B) =:= 200],
    ct:log("200 retransmissions before the ACK: ~p", [length(Retx)]),
    ?assert(length(Retx) >= 2),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R200, #{port => LP})),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, Port, response(ByeReq, 200, #{})),
    ok = await(Bye).

%% The caller never ACKs: the 200 is retransmitted with intervals doubling
%% from T1 up to T2 for 64*T1, then chappe ends the session with a BYE and
%% tells the owner (13.3.1.4, 14.2).
%% req: R3261-222 R3261-241
no_ack_ends_session(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => sdp()})),
    Seen = collect(Sock, any, 36000),
    [{T0, _} | _] = Oks = [{T, B} || {T, B} <- Seen, status(B) =:= 200],
    ct:log("200 at ~p", [[T - T0 || {T, _} <- Oks]]),
    check_backoff([T || {T, _} <- Oks], 500, 4000),
    [{TB, ByeReq} | _] = [{T, B} || {T, B} <- Seen, method(B) =:= <<"BYE">>],
    ct:log("BYE after ~p ms", [TB - T0]),
    ?assert(TB - T0 >= 31500),
    send(Sock, Port, response(ByeReq, 200, #{})),
    D = receive {dialog, D0} -> D0 after 0 -> ct:fail(no_dialog) end,
    receive {chappe_sip_dialog, D, destroy, no_ack} -> ok
    after 3000 -> ct:fail(no_destroy)
    end.

%% ---- INVITE server transaction (17.2.1) ----

%% While the app holds the call after a 180, a retransmitted INVITE gets
%% the 180 again and does not reach the app twice.
%% req: R3261-313
invite_retransmit_gets_provisional(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        Test ! {handler, self()},
        ok = chappe_sip_res:send(Res, 180),
        receive go -> chappe_sip_res:send(Res, 486) after 10000 -> ok end
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp()}),
    send(Sock, Port, Inv),
    H = receive {handler, H0} -> H0 after 3000 -> ct:fail(no_handler) end,
    {_, _} = recv(Sock, {status, 180}, 3000),
    send(Sock, Port, Inv),
    {_, _} = recv(Sock, {status, 180}, 1000),
    receive {handler, _} -> ct:fail(handler_ran_twice) after 300 -> ok end,
    H ! go,
    {R486, _} = recv(Sock, {status, 486}, 3000),
    send(Sock, Port, ack_non2xx(Inv, R486)).

%% The app rejects with 486 and the caller does not ACK: the 486 is
%% retransmitted at T1, 2*T1, 4*T1 and answers a retransmitted INVITE. The
%% ACK stops it (Confirmed); a retransmitted INVITE still belongs to the
%% transaction until Timer I (T4) fires, then it is a new one.
%% req: R3261-316 R3261-318 R3261-319 R3261-321 R3261-499 R3261-215
error_response_retransmits(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 486)
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp()}),
    send(Sock, Port, Inv),
    Busy = [{T, B} || {T, B} <- collect(Sock, any, 4200),
                      status(B) =:= 486],
    ?assertEqual(ok, receive handler -> ok after 0 -> none end),
    check_backoff([T || {T, _} <- Busy], 500, 4000),
    ?assert(length(Busy) >= 4),
    send(Sock, Port, Inv),
    {_, _} = recv(Sock, {status, 486}, 1000),
    [{_, B486} | _] = Busy,
    send(Sock, Port, ack_non2xx(Inv, B486)),
    recv_none(Sock, {status, 486}, 4000),
    send(Sock, Port, Inv),
    receive handler -> ct:fail(handler_ran_in_confirmed) after 1000 -> ok end,
    drain(Sock),
    %% Timer I (T4, 5 s from the ACK) has fired: the INVITE is new again
    timer:sleep(2000),
    send(Sock, Port, Inv),
    {R2, _} = recv(Sock, {status, 486}, 3000),
    receive handler -> ok after 1000 -> ct:fail(no_new_transaction) end,
    send(Sock, Port, ack_non2xx(Inv, R2)).

%% Without an ACK the 486 is retransmitted until Timer H (64*T1), then
%% no more.
%% req: R3261-317
error_response_timer_h(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 486) end),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => sdp()})),
    Busy = [T || {T, B} <- collect(Sock, any, 38000), status(B) =:= 486],
    [T0 | _] = Busy,
    ct:log("486 at ~p", [[T - T0 || T <- Busy]]),
    check_backoff(Busy, 500, 4000),
    Last = lists:last(Busy) - T0,
    ?assert(Last >= 27000),
    ?assert(Last =< 32000 + 1500).

%% The app leaves an INVITE ringing with a 180: the 180 goes out again
%% every minute so a proxy does not cancel the call (13.3.1.1). nta
%% resends the last provisional each 60 s (NTATAG_PROGRESS default).
%% req: R3261-213
provisional_every_minute(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{status => 180,
                                                    owner => Test}),
        Test ! {dialog, D}
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp()}),
    send(Sock, Port, Inv),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    Seen = [{T, B} || {T, B} <- collect(Sock, any, 66000), status(B) =:= 180],
    ct:log("180 at ~p", [[T - element(1, hd(Seen)) || {T, _} <- Seen]]),
    ?assert(length(Seen) >= 2),
    [?assert(I >= 59000 andalso I =< 63000, {interval, I})
     || I <- intervals([T || {T, _} <- Seen])],
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {Final, _} = recv(Sock, final, 3000),
    ok = await(Bye),
    send(Sock, Port, ack_non2xx(Inv, Final)).

%% ---- non-INVITE server transaction (17.2.2) ----

%% OPTIONS, INFO and BYE answered by the app get their final response
%% first, with no provisional, before Timer E would retransmit (8.2.6.1,
%% 17.1).
%% req: R3261-099 R3261-100 R3261-261 R3261-108
non_invite_final_only(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    LP = port(Sock),
    T0 = erlang:monotonic_time(millisecond),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => LP})),
    {R1, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R1)),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 500),
    {Inv, _D, R200} = call(Sock, Port, #{}),
    InDialog = fun(Method, N) ->
        request(Method, <<"sip:app@127.0.0.1">>,
                #{port => LP, call_id => hdr(<<"call-id">>, Inv),
                  from_tag => from_tag(Inv), to_tag => to_tag(R200),
                  cseq => N})
    end,
    [begin
         Req = InDialog(M, N),
         send(Sock, Port, Req),
         {R, _} = recv(Sock, any, 3000),
         ?assertEqual(200, status(R)),
         ?assertEqual(hdr(<<"to">>, Req), hdr(<<"to">>, R))
     end || {M, N} <- [{<<"INFO">>, 2}, {<<"BYE">>, 3}]].

%% Provisionals the app sends to a MESSAGE go out and the last one answers
%% a retransmission; the final goes out and answers the next one; a second
%% final from the app is not sent.
%% req: R3261-323 R3261-324 R3261-325 R3261-326 R3261-327 R3261-329
%% req: R3261-330
non_invite_provisionals(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:message(fun(_Req, Res) ->
        Test ! {handler, self()},
        ok = chappe_sip_res:send(Res, 100),
        receive p2 -> ok = chappe_sip_res:send(Res, 181) end,
        receive final -> ok = chappe_sip_res:send(Res, 200) end,
        Test ! {again, chappe_sip_res:send(Res, 202)}
    end),
    Msg = request(<<"MESSAGE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => <<"hi">>,
                    content_type => <<"text/plain">>}),
    send(Sock, Port, Msg),
    H = receive {handler, H0} -> H0 after 3000 -> ct:fail(no_handler) end,
    {_, _} = recv(Sock, {status, 100}, 3000),
    H ! p2,
    {_, _} = recv(Sock, {status, 181}, 3000),
    send(Sock, Port, Msg),
    {_, _} = recv(Sock, {status, 181}, 1000),
    H ! final,
    {_, _} = recv(Sock, {status, 200}, 3000),
    send(Sock, Port, Msg),
    {_, _} = recv(Sock, {status, 200}, 1000),
    receive {again, Again} -> ?assertEqual({error, already_final}, Again)
    after 3000 -> ct:fail(no_second_final)
    end,
    recv_none(Sock, {status, 202}, 500),
    receive {handler, _} -> ct:fail(handler_ran_twice) after 0 -> ok end.

%% A retransmitted OPTIONS gets the same final response from the completed
%% transaction for 64*T1 (Timer J); after that it is a new request.
%% req: R3261-328 R3261-331
non_invite_timer_j(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 200)
    end),
    Opt = request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock)}),
    send(Sock, Port, Opt),
    {_, _} = recv(Sock, {status, 200}, 3000),
    receive handler -> ok after 1000 -> ct:fail(no_handler) end,
    timer:sleep(30000),
    send(Sock, Port, Opt),
    {_, _} = recv(Sock, {status, 200}, 1000),
    receive handler -> ct:fail(new_transaction_before_timer_j)
    after 300 -> ok
    end,
    timer:sleep(3500),
    send(Sock, Port, Opt),
    {_, _} = recv(Sock, {status, 200}, 3000),
    receive handler -> ok after 1000 -> ct:fail(timer_j_never_fired) end.

%% ---- CANCEL (9.2) ----

%% The app rings and waits; a CANCEL (with a Require that must be ignored,
%% 8.2.2.3) gets 200 and the INVITE 487, both with the To tag of the 180.
%% req: R3261-C-013 R3261-C-014 R3261-086 R3261-178
cancel_pending_invite(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) ->
        ok = chappe_sip_res:send(Res, 180),
        receive stop -> ok after 5000 -> ok end
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp()}),
    send(Sock, Port, Inv),
    {R180, _} = recv(Sock, {status, 180}, 3000),
    send(Sock, Port, cancel_for(Inv, [{<<"Require">>, <<"foo">>}])),
    {C200, _} = recv(Sock, {status, 200, <<"CANCEL">>}, 3000),
    {R487, _} = recv(Sock, {status, 487, <<"INVITE">>}, 3000),
    ?assertEqual(to_tag(R180), to_tag(C200)),
    ?assertEqual(to_tag(R180), to_tag(R487)),
    send(Sock, Port, ack_non2xx(Inv, R487)).

%% A CANCEL matching no transaction gets 481.
%% req: R3261-C-012
cancel_no_match_481(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 486) end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp()}),
    send(Sock, Port, cancel_for(Inv, [])),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(481, status(R)).

%% ---- OPTIONS (11) ----

%% With no OPTIONS handler registered chappe still answers OPTIONS: 200
%% with Allow (ACK and CANCEL included), Accept and Supported.
%% req: R3261-O-001 R3261-O-007 R3261-426 R3261-422
options_default(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(_Req, Res) -> chappe_sip_res:send(Res, 486) end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock)})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R)),
    Allow = [string:trim(M) || M <- binary:split(hdr(<<"allow">>, R), <<",">>,
                                                  [global])],
    [?assert(lists:member(M, Allow), M)
     || M <- [<<"INVITE">>, <<"ACK">>, <<"CANCEL">>, <<"BYE">>, <<"OPTIONS">>]],
    ?assertMatch(<<"application/sdp", _/binary>>, hdr(<<"accept">>, R)),
    ?assertNotEqual(undefined, hdr(<<"supported">>, R)).

%% ---- server transport (18.2) ----

%% A Via sent-by naming a host that is not the source address gets a
%% received parameter with the source address, and the response goes to
%% that address at the sent-by port (no rport here).
%% req: R3261-359 R3261-360 R3261-361 R3261-368 R3261-362
received_param(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    LP = integer_to_binary(port(Sock)),
    Via = <<"SIP/2.0/UDP peer.example.invalid:", LP/binary, ";branch=",
            (branch())/binary>>,
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), via => Via})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R)),
    ?assertMatch({match, _}, re:run(top_via(R), ";received=127\\.0\\.0\\.1")).

%% Without rport or received, the response goes to the sent-by address and
%% port, not the packet source port.
%% req: R3261-370
response_to_sent_by(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    Other = open(),
    OP = integer_to_binary(port(Other)),
    Via = <<"SIP/2.0/UDP 127.0.0.1:", OP/binary, ";branch=", (branch())/binary>>,
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), via => Via})),
    {R, _} = recv(Other, any, 3000),
    ?assertEqual(200, status(R)),
    chappe_sip_core_peer:close(Other).

%% chappe listens on TCP on the same port and interface as UDP. The Via
%% sent-by names the client's own port, where nobody listens: the response
%% comes back on the connection that carried the request, with a
%% Content-Length.
%% req: R3261-336 R3261-358 R3261-363 R3261-374 R3261-440
tcp_listener(Config) ->
    Port = ?config(port, Config),
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    {ok, T} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, LP} = inet:port(T),
    P = integer_to_binary(LP),
    Via = <<"SIP/2.0/TCP 127.0.0.1:", P/binary, ";branch=", (branch())/binary>>,
    ok = gen_tcp:send(T, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                                 #{port => LP, via => Via})),
    R = chappe_sip_core_peer:tcp_recv(T, 3000),
    ?assertEqual(200, status(R)),
    ?assertEqual(integer_to_binary(byte_size(body(R))),
                 hdr(<<"content-length">>, R)),
    gen_tcp:close(T).

%% An OPTIONS over TCP without Content-Length cannot be framed: it never
%% gets a 200 and never reaches the app; the same request with
%% Content-Length on the next connection is answered.
%% req: R3261-374
tcp_no_content_length(Config) ->
    Port = ?config(port, Config),
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 200)
    end),
    {T1, Got} = tcp_options(Port, true),
    ct:log("without Content-Length: ~p", [Got]),
    case Got of
        {ok, Bin} -> ?assertNotEqual(200, status(Bin));
        {error, _} -> ok
    end,
    receive handler -> ct:fail(handler_ran) after 0 -> ok end,
    gen_tcp:close(T1),
    {T2, {ok, R}} = tcp_options(Port, false),
    ?assertEqual(200, status(R)),
    gen_tcp:close(T2).

%% an OPTIONS over a new TCP connection, Content-Length stripped or not;
%% {Socket, what the first read gives within 2 s}
tcp_options(Port, Strip) ->
    {ok, T} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    {ok, LP} = inet:port(T),
    Via = <<"SIP/2.0/TCP 127.0.0.1:", (integer_to_binary(LP))/binary,
            ";branch=", (branch())/binary>>,
    Req0 = request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                   #{port => LP, via => Via}),
    Req = case Strip of
              true -> binary:replace(Req0, <<"Content-Length: 0\r\n">>, <<>>);
              false -> Req0
          end,
    ok = gen_tcp:send(T, Req),
    {T, gen_tcp:recv(T, 0, 2000)}.

%% A Via with maddr: the response goes to the maddr address at the sent-by
%% port, not to the source of the request (18.2.2). The maddr is a
%% non-loopback address of this host.
%% req: R3261-366
via_maddr_response(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    case local_ipv4() of
        undefined ->
            {skip, "no non-loopback IPv4 address"};
        Ip ->
            ok = chappe_sip:options(fun(_Req, Res) ->
                chappe_sip_res:send(Res, 200)
            end),
            {ok, Far} = gen_udp:open(0, [binary, {active, true}, {ip, Ip}]),
            {ok, FP} = inet:port(Far),
            Addr = list_to_binary(inet:ntoa(Ip)),
            Via = <<"SIP/2.0/UDP 127.0.0.1:", (integer_to_binary(FP))/binary,
                    ";maddr=", Addr/binary, ";branch=", (branch())/binary>>,
            send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                                     #{port => port(Sock), via => Via})),
            Got = receive {udp, Far, _, _, B} -> B
                  after 3000 ->
                      ct:log("~p", [collect(Sock, any, 200)]),
                      ct:fail(nothing_at_maddr)
                  end,
            ?assertEqual(200, status(Got)),
            recv_none(Sock, any, 300),
            gen_udp:close(Far)
    end.

%% A UDP request close to the largest datagram is parsed and answered.
%% req: R3261-341
large_udp_request(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:message(fun(Req, Res) ->
        Test ! {body, byte_size(chappe_sip_req:body(Req))},
        chappe_sip_res:send(Res, 200)
    end),
    Body = binary:copy(<<"x">>, 64000),
    send(Sock, Port, request(<<"MESSAGE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => Body,
                               content_type => <<"text/plain">>})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R)),
    receive {body, N} -> ?assertEqual(64000, N) after 1000 -> ct:fail(no_body) end.

%% Bytes after Content-Length in a datagram are discarded.
%% req: R3261-371
trailing_bytes_dropped(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:message(fun(Req, Res) ->
        Test ! {body, chappe_sip_req:body(Req)},
        chappe_sip_res:send(Res, 200)
    end),
    Req = request(<<"MESSAGE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => <<"hello">>,
                    content_type => <<"text/plain">>}),
    send(Sock, Port, <<Req/binary, "TRAILING-GARBAGE">>),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R)),
    receive {body, B} -> ?assertEqual(<<"hello">>, B)
    after 1000 -> ct:fail(no_body)
    end.

%% A request whose Content-Length is larger than the datagram gets 400.
%% req: R3261-373
short_datagram_400(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:message(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    send(Sock, Port, request(<<"MESSAGE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => <<"hello">>,
                               content_type => <<"text/plain">>,
                               content_length => 500})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(400, status(R)).

%% ---- URIs (8.2.2.1, 19.1) ----

%% A Request-URI scheme chappe does not serve gets 416.
%% req: R3261-079
unsupported_scheme_416(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"mailto:app@example.invalid">>,
                             #{port => port(Sock),
                               to => <<"<sip:app@127.0.0.1>">>})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(416, status(R)).

%% A To header with a tel: URI does not stop the request.
%% req: R3261-077
tel_to_accepted(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
    end),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => sdp(),
                               to => <<"<tel:+15551234567>">>})),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R)),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R, #{port => port(Sock)})).

%% A SIP URI with an @ and an empty user part is malformed: 400.
%% req: R3261-379
empty_user_rejected(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 200)
    end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:@127.0.0.1">>,
                             #{port => port(Sock)})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(400, status(R)),
    receive handler -> ct:fail(handler_ran) after 0 -> ok end.

%% ---- header rules (8.2.2, 20) ----

%% A request missing a mandatory header gets 400 and never reaches the app.
%% req: R3261-415
missing_mandatory_400(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 200)
    end),
    [begin
         send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                                  #{port => port(Sock), omit => [H]})),
         {R, _} = recv(Sock, any, 3000),
         ct:log("without ~s: ~s", [H, hd(binary:split(R, <<"\r\n">>))]),
         ?assertEqual(400, status(R))
     end || H <- [<<"call-id">>, <<"from">>, <<"to">>, <<"cseq">>]],
    receive handler -> ct:fail(handler_ran) after 0 -> ok end.

%% A malformed header the request cannot be processed without gets a 400
%% whose reason phrase names it.
%% req: R3261-483
bad_header_named_400(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock),
                               headers => [{<<"Content-Type">>, <<"???">>}]})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(400, status(R)),
    Reason = chappe_sip_msg:reason(chappe_sip_core_peer:parse(R)),
    ct:log("reason: ~s", [Reason]),
    ?assertMatch({match, _}, re:run(Reason, "Content-Type", [caseless])).

%% A CSeq number up to 2**32-1 is accepted; above it the request is
%% malformed.
%% req: R3261-443
cseq_range(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), cseq => (1 bsl 32) - 1})),
    {R1, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R1)),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), cseq => 1 bsl 32})),
    {R2, _} = recv(Sock, any, 3000),
    ?assertEqual(400, status(R2)).

%% An unknown option tag in Require gets 420 with Unsupported listing it.
%% req: R3261-083 R3261-084 R3261-455
require_unknown_420(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
    end),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  #{port => port(Sock), body => sdp(),
                    headers => [{<<"Require">>, <<"foo">>}]}),
    send(Sock, Port, Inv),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(420, status(R)),
    ?assertEqual(<<"foo">>, hdr(<<"unsupported">>, R)),
    send(Sock, Port, ack_non2xx(Inv, R)).

%% A caller that does not support 100rel gets a plain provisional even
%% when the app asks for a reliable one: no Require: 100rel, no RSeq
%% (8.2.4, 21.4).
%% req: R3261-092 R3261-093 R3261-495 R3262-005
no_reliable_without_support(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(Req, Res) ->
        _ = chappe_sip_res:send_reliable(
              Res, #{status => 183, body => sdp(), to_tag => <<"rel1">>,
                     headers => [{<<"Content-Type">>, <<"application/sdp">>}]}),
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    local_tag => <<"rel1">>})
    end),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => sdp()})),
    {R183, _} = recv(Sock, {status, 183}, 3000),
    ?assertEqual(undefined, hdr(<<"rseq">>, R183)),
    ?assertEqual(undefined, hdr(<<"require">>, R183)),
    {R200, _} = recv(Sock, {status, 200}, 3000),
    ?assertEqual(undefined, hdr(<<"require">>, R200)),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R200, #{port => port(Sock)})).

%% ---- in-dialog client transaction timeouts (Timer F) ----

%% The peer never answers an in-dialog INFO: it is retransmitted with
%% intervals doubling up to T2, then after 64*T1 the app gets a 408 and
%% the dialog ends (8.1.3.1, 12.2.1.2, 17.1.2.2). The first interval is
%% 1 s (the vendored sofia floors the initial Timer E there).
%% req: R3261-170 R3261-042 R3261-296 R3261-297 R3261-299
indialog_timeout_ends_dialog(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, Port, #{}),
    T0 = erlang:monotonic_time(millisecond),
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    Sent = [T || {T, _} <- collect(Sock, {method, <<"INFO">>}, 34000)],
    ct:log("INFO at ~p", [[T - T0 || T <- Sent]]),
    [First | _] = intervals(Sent),
    ?assert(First >= 500 - 100),
    check_backoff(Sent, First, 4000),
    ?assert(lists:last(Sent) - hd(Sent) >= 27000),
    {ok, Resp} = await(Info),
    ?assertEqual(408, chappe_sip_msg:status(Resp)),
    receive {chappe_sip_dialog, D, destroy, {request_failed, 408}} -> ok
    after 3000 -> ct:fail(dialog_kept)
    end,
    _ = Port.

%% The peer never answers our BYE: the dialog still ends when the BYE
%% transaction times out (15.1.1).
%% req: R3261-254
bye_timeout_ends_dialog(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    {_Inv, D, _R200} = call(Sock, Port, #{}),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {_, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    receive {Bye, R} -> ct:log("destroy: ~p", [R])
    after 36000 -> ct:fail(bye_never_ended)
    end,
    receive {chappe_sip_dialog, D, destroy, _} -> ok
    after 1000 -> ct:fail(no_destroy)
    end,
    _ = Port.


%% ---- helpers ----

%% a non-loopback, non-link-local IPv4 address of this host, or undefined
local_ipv4() ->
    {ok, Ifs} = inet:getifaddrs(),
    Addrs = [A || {_, Opts} <- Ifs, {addr, {N, M, _, _} = A} <- Opts,
                  N =/= 127, {N, M} =/= {169, 254}],
    case Addrs of
        [A | _] -> A;
        [] -> undefined
    end.

%% the m= lines of an SDP body
mlines(Sdp) ->
    [L || L <- binary:split(Sdp, <<"\r\n">>, [global]),
          binary:match(L, <<"m=">>) =:= {0, 2}].

%% the session version of the o= line
sdp_version(Sdp) ->
    {match, [V]} = re:run(Sdp, "o=\\S+ \\S+ ([0-9]+) ",
                          [{capture, all_but_first, binary}]),
    binary_to_integer(V).

%% An in-dialog request from the caller of a call/3,4 dialog.
indialog(Method, Inv, R200, LP, N, Opts) ->
    request(Method, <<"sip:app@127.0.0.1">>,
            maps:merge(#{port => LP, call_id => hdr(<<"call-id">>, Inv),
                         from_tag => from_tag(Inv), to_tag => to_tag(R200),
                         cseq => N}, Opts)).

%% Retransmission times (ms, the first is the original) whose intervals
%% start at Base and double up to Cap. Load only delays a timer, so an
%% interval shorter than its value is a bug; a longer one gets slack.
check_backoff([_ | _] = Times, Base, Cap) ->
    Intervals = intervals(Times),
    ct:log("intervals ~p", [Intervals]),
    check_intervals(Intervals, Base, Cap).

intervals([A, B | Rest]) -> [B - A | intervals([B | Rest])];
intervals(_) -> [].

check_intervals([], _Want, _Cap) ->
    ok;
check_intervals([I | Rest], Want, Cap) ->
    ?assert(I >= Want - 100, {early, I, Want}),
    ?assert(I =< Want + 400 + Want div 5, {late, I, Want}),
    check_intervals(Rest, min(2 * Want, Cap), Cap).

%% The ACK a caller sends for a non-2xx final: the INVITE's branch, the
%% response's To, CSeq method ACK.
ack_non2xx(InvBin, Resp) ->
    Inv = chappe_sip_core_peer:parse(InvBin),
    {N, _} = cseq(InvBin),
    iolist_to_binary(
      [<<"ACK ">>, uri(Inv), " SIP/2.0\r\n",
       "Via: ", top_via(Inv), "\r\n",
       "Max-Forwards: 70\r\n",
       "From: ", hdr(<<"from">>, Inv), "\r\n",
       "To: ", hdr(<<"to">>, Resp), "\r\n",
       "Call-ID: ", hdr(<<"call-id">>, Inv), "\r\n",
       "CSeq: ", integer_to_binary(N), " ACK\r\n",
       "Content-Length: 0\r\n\r\n"]).

cancel_for(InvBin, Extra) ->
    Inv = chappe_sip_core_peer:parse(InvBin),
    {N, _} = cseq(InvBin),
    iolist_to_binary(
      [<<"CANCEL ">>, uri(Inv), " SIP/2.0\r\n",
       "Via: ", top_via(Inv), "\r\n",
       "Max-Forwards: 70\r\n",
       "From: ", hdr(<<"from">>, Inv), "\r\n",
       "To: ", hdr(<<"to">>, Inv), "\r\n",
       "Call-ID: ", hdr(<<"call-id">>, Inv), "\r\n",
       "CSeq: ", integer_to_binary(N), " CANCEL\r\n",
       [[H, ": ", V, "\r\n"] || {H, V} <- Extra],
       "Content-Length: 0\r\n\r\n"]).


%% Set up a confirmed call from the peer: INVITE (with Opts merged), 200,
%% ACK. The test process owns the dialog. Returns {Invite, Dialog, 200}.
call(Sock, Port, Opts) ->
    call(Sock, Port, Opts, #{}).

call(Sock, Port, Opts, UasOpts) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res,
                                        maps:merge(#{local_sdp => sdp(),
                                                     owner => Test}, UasOpts)),
        Test ! {dialog, D}
    end),
    LP = port(Sock),
    Inv = request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                  maps:merge(#{port => LP, body => sdp()}, Opts)),
    send(Sock, Port, Inv),
    {R200, _} = recv(Sock, {status, 200}, 3000),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R200, #{port => LP})),
    D = receive {dialog, D0} -> D0 after 3000 -> ct:fail(no_dialog) end,
    receive {chappe_sip_dialog, D, ack, _, _} -> ok
    after 3000 -> ct:fail(no_ack)
    end,
    {chappe_sip_core_peer:parse(Inv), D, R200}.

async(F) ->
    Test = self(),
    Ref = make_ref(),
    spawn_link(fun() -> Test ! {Ref, F()} end),
    Ref.

await(Ref) ->
    receive {Ref, R} -> R after 10000 -> ct:fail(no_result) end.

via_list(X) ->
    lists:append([[string:trim(V) || V <- binary:split(H, <<",">>, [global])]
                  || H <- hdrs(<<"via">>, X)]).

sent_by_port(Via) ->
    {match, [P]} = re:run(Via, "^SIP/2.0/[A-Z]+ [^:;]+:([0-9]+)",
                          [{capture, all_but_first, binary}]),
    P.

to_uri(X) -> addr_uri(hdr(<<"to">>, X)).
from_uri(X) -> addr_uri(hdr(<<"from">>, X)).

addr_uri(V) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(V),
    U.

%% ---- extensions and request validation (8.2.2.3, 16.3, RFC 7866) ----

%% A request whose CSeq method is not its own method is malformed: 400,
%% and the app never sees it.
%% req: R3261-U-04
cseq_method_mismatch_400(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:options(fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 200)
    end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), cseq_method => <<"INVITE">>})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(400, status(R)),
    receive handler -> ct:fail(handler_ran) after 0 -> ok end.

%% A request without Max-Forwards (an RFC 2543 peer) is still served.
%% req: R3261-U-05
no_max_forwards_served(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), max_forwards => false})),
    {R, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R)).

%% Proxy-Require is for proxies: a UAS takes the request.
%% req: R3261-U-08
uas_ignores_proxy_require(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
    end),
    send(Sock, Port, request(<<"INVITE">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock), body => sdp(),
                               headers => [{<<"Proxy-Require">>, <<"foo">>}]})),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R)),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R, #{port => port(Sock)})).

%% A route registered as a proxy leaves Require to the far UAS and answers
%% 420 to a Proxy-Require it does not support.
%% req: R3261-U-07
proxy_route_checks_proxy_require(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    Test = self(),
    ok = chappe_sip:handle(<<"OPTIONS">>, fun(_Req, Res) ->
        Test ! handler,
        chappe_sip_res:send(Res, 200)
    end, #{proxy => true}),
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock),
                               headers => [{<<"Require">>, <<"foo">>}]})),
    {R1, _} = recv(Sock, any, 3000),
    ?assertEqual(200, status(R1)),
    receive handler -> ok after 1000 -> ct:fail(handler_not_run) end,
    send(Sock, Port, request(<<"OPTIONS">>, <<"sip:app@127.0.0.1">>,
                             #{port => port(Sock),
                               headers => [{<<"Proxy-Require">>, <<"foo">>}]})),
    {R2, _} = recv(Sock, any, 3000),
    ?assertEqual(420, status(R2)),
    ?assertEqual(<<"foo">>, hdr(<<"unsupported">>, R2)),
    receive handler -> ct:fail(handler_ran) after 0 -> ok end.

%% An SRC's INVITE requires siprec: a plain route answers 420 (a UA that
%% is not a recording server), a route that takes siprec answers it, and
%% so does its dialog's in-dialog requests. The supported_option_tags
%% setting does the same for every route.
%% req: R7866-6.1.1-1 R7866-6.1.1-2 R3261-083
siprec_require(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    Test = self(),
    Answer = fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp(),
                                                    owner => Test}),
        Test ! {dialog, D}
    end,
    Siprec = [{<<"Require">>, <<"siprec">>}],
    ok = chappe_sip:invite(Answer),
    Inv1 = request(<<"INVITE">>, <<"sip:srs@127.0.0.1">>,
                   #{port => LP, body => sdp(), headers => Siprec}),
    send(Sock, Port, Inv1),
    {R1, _} = recv(Sock, final, 3000),
    ?assertEqual(420, status(R1)),
    ?assertEqual(<<"siprec">>, hdr(<<"unsupported">>, R1)),
    send(Sock, Port, ack_non2xx(Inv1, R1)),
    ok = chappe_sip:handle(<<"INVITE">>, Answer, #{option_tags => [<<"siprec">>]}),
    Inv2 = request(<<"INVITE">>, <<"sip:srs@127.0.0.1">>,
                   #{port => LP, body => sdp(), headers => Siprec}),
    send(Sock, Port, Inv2),
    {R2, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R2)),
    send(Sock, Port, chappe_sip_core_peer:ack_for(R2, #{port => LP})),
    receive {dialog, _} -> ok after 3000 -> ct:fail(no_dialog) end,
    {ok, I2} = chappe_sip_msg:parse(Inv2),
    Info = request(<<"INFO">>, <<"sip:srs@127.0.0.1">>,
                   #{port => LP, call_id => chappe_sip_msg:call_id(I2),
                     from_tag => chappe_sip_msg:from_tag(I2),
                     to_tag => to_tag(R2), cseq => 2, headers => Siprec}),
    send(Sock, Port, Info),
    {R3, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R3)),
    application:set_env(chappe_sip, supported_option_tags,
                        [<<"100rel">>, <<"replaces">>, <<"timer">>, <<"siprec">>]),
    try
        ok = chappe_sip:invite(Answer),
        Inv3 = request(<<"INVITE">>, <<"sip:srs@127.0.0.1">>,
                       #{port => LP, body => sdp(), headers => Siprec}),
        send(Sock, Port, Inv3),
        {R4, _} = recv(Sock, final, 3000),
        ?assertEqual(200, status(R4)),
        send(Sock, Port, chappe_sip_core_peer:ack_for(R4, #{port => LP}))
    after
        application:unset_env(chappe_sip, supported_option_tags)
    end.

%% In a dialog, an unknown option tag in Require gets 420 with Unsupported
%% too; the dialog goes on.
%% req: R3261-083 R3261-084
indialog_require_420(Config) ->
    {Port, Sock} = {?config(port, Config), ?config(sock, Config)},
    LP = port(Sock),
    {Inv, _D, R200} = call(Sock, Port, #{}),
    InDialog = fun(N, Hdrs) ->
        request(<<"INFO">>, <<"sip:app@127.0.0.1">>,
                #{port => LP, call_id => hdr(<<"call-id">>, Inv),
                  from_tag => from_tag(Inv), to_tag => to_tag(R200),
                  cseq => N, headers => Hdrs})
    end,
    send(Sock, Port, InDialog(2, [{<<"Require">>, <<"foo, timer">>}])),
    {R1, _} = recv(Sock, final, 3000),
    ?assertEqual(420, status(R1)),
    ?assertEqual(<<"foo">>, hdr(<<"unsupported">>, R1)),
    send(Sock, Port, InDialog(3, [{<<"Proxy-Require">>, <<"foo">>}])),
    {R2, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R2)).

%% ACK and CANCEL are never refused for their Require (they must not carry
%% one, and its values are ignored): the request worker passes them on.
%% req: R3261-086
ack_cancel_require_ignored(_Config) ->
    Test = self(),
    [begin
         Res = chappe_sip_res:new(99, fun(_, Code, _Opts) ->
             Test ! {response, Code}, ok
         end),
         Raw = worker_req(Method, <<"Require: foo\r\nProxy-Require: bar\r\n">>),
         {ok, _} = chappe_sip_request_worker:start_link(
                     #{raw => Raw, txn => 99, meta => #{}, res => Res,
                       middlewares => [],
                       handler => fun(_, _) -> Test ! {handler, Method} end}),
         receive {handler, Method} -> ok
         after 1000 -> ct:fail({not_dispatched, Method})
         end,
         receive {response, Code} -> ct:fail({answered, Method, Code})
         after 0 -> ok
         end
     end || Method <- [<<"ACK">>, <<"CANCEL">>]],
    %% the probe: an INVITE requiring siprec on a route without it is a 420
    Res = chappe_sip_res:new(99, fun(_, Code, Opts) ->
        Test ! {response, Code, Opts}, ok
    end),
    {ok, _} = chappe_sip_request_worker:start_link(
                #{raw => worker_req(<<"INVITE">>, <<"Require: siprec\r\n">>),
                  txn => 99, meta => #{}, res => Res, middlewares => [],
                  handler => fun(_, _) -> Test ! handler_called end}),
    receive {response, 420, #{headers := H}} ->
        ?assertEqual([{<<"Unsupported">>, <<"siprec">>}], H)
    after 1000 -> ct:fail(no_420)
    end.

worker_req(Method, Extra) ->
    iolist_to_binary(
      [Method, <<" sip:example.com SIP/2.0\r\n"
                 "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bKw\r\n"
                 "From: <sip:alice@example.com>;tag=a\r\n"
                 "To: <sip:alice@example.com>\r\n"
                 "Call-ID: worker\r\nCSeq: 10 ">>, Method,
       <<"\r\nMax-Forwards: 70\r\n">>, Extra, <<"Content-Length: 0\r\n\r\n">>]).
