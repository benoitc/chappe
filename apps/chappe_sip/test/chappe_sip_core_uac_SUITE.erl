%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% RFC 3261 core duties of chappe as a UAC, on the wire.
%%
%% The app originates (chappe_sip_uac:start/2, chappe_sip:request/2) and a
%% raw gen_udp peer (chappe_sip_core_peer) plays the UAS: request
%% construction (8.1.1), the INVITE and non-INVITE client transactions
%% (17.1), ACK for 2xx and non-2xx (13.2.2, 17.1.1.3), the UAC dialog
%% (12.1.2, 12.2.1), CANCEL (9.1) and offer/answer in the 2xx (13.2.1).
-module(chappe_sip_core_uac_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("chappe_sip.hrl").

-import(chappe_sip_core_peer, [
    open/0, port/1, send/3, recv/3, recv_none/3, collect/3, drain/1,
    request/3, response/3, hdr/2, hdrs/2, status/1, method/1, uri/1,
    cseq/1, to_tag/1, from_tag/1, body/1, top_via/1, via_branch/1,
    branch/0, tag/0, sdp/0
]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([request_construction/1, ack_2xx_and_bye/1, no_record_route/1,
         retransmitted_2xx_reacked/1, non2xx_ack/1,
         cancel_after_provisional/1, cancel_waits_for_provisional/1,
         no_cancel_after_final/1, invite_retransmits/1, forked_2xx/1,
         late_final_ignored/1, unknown_codes/1, offer_in_2xx/1,
         answer_in_first_sdp/1, non_invite_retransmits/1,
         response_matching/1, invite_timeout/1, offer_in_2xx_rejected/1,
         uac_first_remote_cseq/1, uac_tagless_2xx/1, uac_target_refresh/1,
         transport_error_503/1, uac_timer_d/1, uac_timer_f_proceeding/1,
         non_invite_absorbs_retransmit/1, retry_after_420/1]).
-export([reinvite_provisional_then_2xx/1, strict_route_set/1,
         hold_each_stream/1, unhold_each_stream/1, uac_digest_401/1,
         ack_carries_credentials/1, auth_407_then_401/1,
         auth_stale_nonce/1, auth_prefers_sha256/1, auth_nonce_count/1,
         auth_two_realms/1, auth_basic_refused/1,
         prack_follows_route_set/1, rseq_without_require/1,
         redirect_q_order_fallback/1, delayed_ack_3pcc/1,
         create_uac_timeout_cancels/1]).

all() ->
    [{group, wire}, {group, timers}].

groups() ->
    [{wire, [], [request_construction, ack_2xx_and_bye, no_record_route,
                 retransmitted_2xx_reacked, non2xx_ack,
                 cancel_after_provisional, cancel_waits_for_provisional,
                 no_cancel_after_final, invite_retransmits, forked_2xx,
                 late_final_ignored, unknown_codes, offer_in_2xx,
                 answer_in_first_sdp, non_invite_retransmits,
                 response_matching, offer_in_2xx_rejected,
                 uac_first_remote_cseq, uac_tagless_2xx, uac_target_refresh,
                 transport_error_503, non_invite_absorbs_retransmit,
                 retry_after_420,
                 reinvite_provisional_then_2xx, strict_route_set,
                 hold_each_stream, unhold_each_stream, uac_digest_401,
                 ack_carries_credentials, auth_407_then_401,
                 auth_stale_nonce, auth_prefers_sha256, auth_nonce_count,
                 auth_two_realms, auth_basic_refused,
                 prack_follows_route_set, rseq_without_require,
                 redirect_q_order_fallback, delayed_ack_3pcc,
                 create_uac_timeout_cancels]},
     %% each waits 64*T1 (32 s)
     {timers, [], [invite_timeout, uac_timer_d, uac_timer_f_proceeding]}].

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
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    Sock = open(),
    [{ep, EP}, {sock, Sock} | Config].

end_per_testcase(_Case, Config) ->
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- request construction (8.1.1, 13.2.1, 18.1.1) ----

%% Two INVITEs (with and without an offer) and an OPTIONS: each carries
%% To, From with a fresh tag, a new random Call-ID, CSeq below 2**31 with
%% the method, Max-Forwards 70 and one Via SIP/2.0/UDP with a z9hG4bK
%% branch and our sent-by; no To tag; the Request-URI is the To URI. An
%% INVITE has exactly one sip: Contact reachable out of dialog, Allow
%% listing the in-dialog methods and Supported with standards-track tags
%% only.
%% req: R3261-001 R3261-002 R3261-008 R3261-010 R3261-013 R3261-014
%% req: R3261-016 R3261-017 R3261-018 R3261-019 R3261-020 R3261-021
%% req: R3261-022 R3261-023 R3261-461 R3261-024 R3261-025 R3261-138
%% req: R3261-179 R3261-180 R3261-181 R3261-027 R3261-028 R3261-031
%% req: R3261-457 R3261-409 R3261-186 R3261-032 R3261-344 R3261-263
%% req: R3261-297 R3261-006 R3261-392 R3261-421 R3261-411
request_construction(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = callee(Sock),
    {ok, _} = chappe_sip_uac:start(Uri, #{local_sdp => sdp()}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 486, #{to_tag => tag()})),
    {ok, _} = chappe_sip_uac:start(Uri, #{}),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv2, 486, #{to_tag => tag()})),
    {ok, _} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>}),
    {Opt, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    send(Sock, EP, response(Opt, 200, #{to_tag => tag()})),
    Sent = [Inv1, Inv2, Opt],
    [begin
         ?assertEqual(Uri, uri(R)),
         ?assertEqual(Uri, addr_uri(hdr(<<"to">>, R))),
         ?assertEqual(undefined, to_tag(R)),
         ?assertNotEqual(undefined, from_tag(R)),
         {N, M} = cseq(R),
         ?assertEqual(method(R), M),
         ?assert(N < 1 bsl 31),
         ?assertEqual(<<"70">>, hdr(<<"max-forwards">>, R)),
         [Via] = via_list(R),
         ?assertMatch(<<"SIP/2.0/UDP 127.0.0.1:", _/binary>>, Via),
         ?assertEqual(integer_to_binary(EP), sent_by_port(Via)),
         ?assertMatch(<<"z9hG4bK", _/binary>>, via_branch(Via)),
         ?assert(byte_size(hdr(<<"call-id">>, R)) >= 16)
     end || R <- Sent],
    ?assertEqual(3, length(lists:usort([hdr(<<"call-id">>, R) || R <- Sent]))),
    [begin
         ?assertEqual(nomatch, re:run(uri(R), "[\\x00-\\x20\\x7f]")),
         [?assertMatch(<<"<", _/binary>>, hdr(H, R))
          || H <- [<<"from">>, <<"to">>, <<"contact">>], hdr(H, R) =/= undefined]
     end || R <- Sent],
    ?assertEqual(3, length(lists:usort([from_tag(R) || R <- Sent]))),
    [?assert(byte_size(from_tag(R)) >= 8) || R <- Sent],
    ?assertEqual(3, length(lists:usort([via_branch(top_via(R)) || R <- Sent]))),
    ?assertMatch(<<"v=0", _/binary>>, body(Inv1)),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, Inv1)),
    ?assertEqual(<<>>, body(Inv2)),
    ?assertEqual(<<"0">>, hdr(<<"content-length">>, Inv2)),
    [begin
         [Contact] = hdrs(<<"contact">>, Inv),
         ContactUri = addr_uri(Contact),
         ?assertMatch(<<"sip:", _/binary>>, ContactUri),
         Allow = split(hdr(<<"allow">>, Inv)),
         [?assert(lists:member(M, Allow), M)
          || M <- [<<"INVITE">>, <<"ACK">>, <<"CANCEL">>, <<"BYE">>,
                   <<"INFO">>, <<"REFER">>, <<"UPDATE">>, <<"NOTIFY">>]],
         Supported = split(hdr(<<"supported">>, Inv)),
         ?assertEqual([], Supported -- standards_track())
     end || Inv <- [Inv1, Inv2]],
    %% the INVITE Contact reaches chappe out of any dialog
    Contact1 = addr_uri(hdr(<<"contact">>, Inv1)),
    {match, [CPort]} = re:run(Contact1, ":([0-9]+)(;|$)",
                              [{capture, [1], binary}]),
    ?assertEqual(integer_to_binary(EP), CPort),
    drain(Sock),
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200) end),
    send(Sock, EP, request(<<"OPTIONS">>, Contact1, #{port => port(Sock)})),
    {R, _} = recv(Sock, {status, 200, <<"OPTIONS">>}, 3000),
    ?assertEqual(200, status(R)).

%% ---- ACK for 2xx and the UAC dialog (12.1.2, 12.2.1, 13.2.2) ----

%% 100, 180 and a 183 with SDP and its own reason phrase reach the app;
%% the 200 has two Record-Route and a Contact. The ACK is a new
%% transaction to the Contact, Route is the Record-Route reversed, CSeq is
%% the INVITE's with method ACK, and it has no Require. The BYE follows
%% the same dialog state with CSeq one higher.
%% req: R3261-200 R3261-201 R3261-287 R3261-087 R3261-140 R3261-142
%% req: R3261-143 R3261-145 R3261-147 R3261-150 R3261-151 R3261-152
%% req: R3261-153 R3261-155 R3261-162 R3261-285 R3261-275 R3261-277
%% req: R3261-278 R3261-046 R3261-464 R3261-465 R3261-469 R3261-011
%% req: R3261-198 R3261-122
ack_2xx_and_bye(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Uri = callee(Sock),
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => sdp(), notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    RR = [<<"<sip:127.0.0.1:", LP/binary, ";lr;x-a=1>">>,
          <<"<sip:127.0.0.1:", LP/binary, ";lr;x-b=2>">>],
    Contact = <<"sip:callee@127.0.0.1:", LP/binary, ";x-c=1">>,
    send(Sock, EP, response(Inv, 100, #{})),
    send(Sock, EP, response(Inv, 180, #{to_tag => ToTag})),
    send(Sock, EP, response(Inv, 183, #{to_tag => ToTag, body => sdp(),
                                        reason => <<"Queued">>})),
    send(Sock, EP, response(Inv, 200, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Record-Route">>, lists:nth(1, RR)},
                    {<<"Record-Route">>, lists:nth(2, RR)},
                    {<<"Contact">>, <<"<", Contact/binary, ">">>}]})),
    Provisionals = provisionals(Ref, []),
    ct:log("provisionals ~p", [Provisionals]),
    ?assert(lists:member({180, <<"Ringing">>}, Provisionals)),
    ?assert(lists:member({183, <<"Queued">>}, Provisionals)),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    {N, <<"INVITE">>} = cseq(Inv),
    ?assertEqual({N, <<"ACK">>}, cseq(Ack)),
    ?assertNotEqual(via_branch(top_via(Inv)), via_branch(top_via(Ack))),
    ?assertEqual(undefined, hdr(<<"require">>, Ack)),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertEqual({N + 1, <<"BYE">>}, cseq(ByeReq)),
    [begin
         ?assertEqual(Contact, uri(R)),
         ?assertEqual(lists:reverse(RR), hdrs(<<"route">>, R)),
         ?assertEqual(from_tag(Inv), from_tag(R)),
         ?assertEqual(ToTag, to_tag(R)),
         ?assertEqual(addr_uri(hdr(<<"to">>, Inv)), addr_uri(hdr(<<"to">>, R))),
         ?assertEqual(addr_uri(hdr(<<"from">>, Inv)), addr_uri(hdr(<<"from">>, R))),
         ?assertEqual(hdr(<<"call-id">>, Inv), hdr(<<"call-id">>, R))
     end || R <- [Ack, ByeReq]].

%% Without Record-Route in the 200 the route set is empty: no Route on the
%% ACK or the BYE (12.1.2).
%% req: R3261-141
no_record_route(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {D, _Inv, _R200} = answered_call(Sock, EP, #{}),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertEqual([], hdrs(<<"route">>, Ack)),
    ?assertEqual([], hdrs(<<"route">>, ByeReq)).

%% Each retransmission of the 200 gets the ACK again, also once the INVITE
%% transaction is gone: nta matches it to the ACK it sent (13.2.2, 18.1.2).
%% req: R3261-205 R3261-355
retransmitted_2xx_reacked(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_D, _Inv, R200} = answered_call(Sock, EP, #{}),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    send(Sock, EP, R200),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 1000),
    timer:sleep(5000),
    drain(Sock),
    send(Sock, EP, R200),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 1000).

%% A 486 to an INVITE sent through a Route is ACKed by the transaction:
%% same address, Request-URI, Call-ID, From and CSeq number, the response
%% To, one Via equal to the INVITE's top Via, the Route copied, no body and
%% no Require. A retransmitted 486 gets the ACK again and does not reach
%% the app twice; the app does not retry the request.
%% req: R3261-279 R3261-280 R3261-281 R3261-283 R3261-288 R3261-289
%% req: R3261-290 R3261-291 R3261-292 R3261-294 R3261-085 R3261-482
%% req: R3261-484 R3261-039 R3261-462
non2xx_ack(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Route = <<"<sip:127.0.0.1:", LP/binary, ";lr>">>,
    Uri = <<"sip:callee@callee.example.invalid">>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => sdp(), notify => self(),
                                            rel100 => require,
                                            headers => [{<<"Route">>, Route}]}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(Uri, uri(Inv)),
    R403 = response(Inv, 403, #{to_tag => tag(),
                                headers => [{<<"Warning">>,
                                             <<"399 peer \"try elsewhere\"">>}]}),
    send(Sock, EP, R403),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertMatch({error, #chappe_sip_error{status = 403}},
                 chappe_sip_uac:await(Ref, 3000)),
    ?assertEqual(uri(Inv), uri(Ack)),
    ?assertEqual(hdr(<<"call-id">>, Inv), hdr(<<"call-id">>, Ack)),
    ?assertEqual(hdr(<<"from">>, Inv), hdr(<<"from">>, Ack)),
    ?assertEqual(to_tag(R403), to_tag(Ack)),
    ?assertEqual([top_via(Inv)], hdrs(<<"via">>, Ack)),
    {N, _} = cseq(Inv),
    ?assertEqual({N, <<"ACK">>}, cseq(Ack)),
    ?assertEqual(hdrs(<<"route">>, Inv), hdrs(<<"route">>, Ack)),
    ?assertEqual(<<>>, body(Ack)),
    ?assertEqual(undefined, hdr(<<"require">>, Ack)),
    ?assertEqual(undefined, hdr(<<"proxy-require">>, Ack)),
    send(Sock, EP, R403),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 1000),
    receive {chappe_sip_uac, Ref, {error, _} = Again} -> ct:fail({told_twice, Again})
    after 500 -> ok
    end,
    recv_none(Sock, {method, <<"INVITE">>}, 2000).

%% ---- CANCEL (9.1) ----

%% After a 180 the app cancels: the CANCEL copies the INVITE's
%% Request-URI, Call-ID, To, From and CSeq number, has one Via equal to the
%% INVITE's top Via, CSeq method CANCEL, the INVITE's Route, no Require or
%% Proxy-Require, and goes where the INVITE went. The 487 is ACKed.
%% req: R3261-C-001 R3261-C-002 R3261-C-003 R3261-C-004 R3261-C-005
%% req: R3261-C-006 R3261-C-010 R3261-085 R3261-417
cancel_after_provisional(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Route = <<"<sip:127.0.0.1:", LP/binary, ";lr>">>,
    Uri = <<"sip:callee@callee.example.invalid">>,
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => sdp(), notify => self(),
                                            rel100 => require,
                                            headers => [{<<"Route">>, Route}]}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    send(Sock, EP, response(Inv, 180, #{to_tag => ToTag})),
    receive {chappe_sip_uac, Ref, {provisional, _}} -> ok
    after 3000 -> ct:fail(no_provisional)
    end,
    ok = chappe_sip_uac:cancel(Ref),
    {Cancel, _} = recv(Sock, {method, <<"CANCEL">>}, 3000),
    ?assertEqual(uri(Inv), uri(Cancel)),
    [?assertEqual(hdr(H, Inv), hdr(H, Cancel))
     || H <- [<<"call-id">>, <<"to">>, <<"from">>]],
    {N, _} = cseq(Inv),
    ?assertEqual({N, <<"CANCEL">>}, cseq(Cancel)),
    ?assertEqual([top_via(Inv)], hdrs(<<"via">>, Cancel)),
    ?assertEqual(hdrs(<<"route">>, Inv), hdrs(<<"route">>, Cancel)),
    ?assertEqual(undefined, hdr(<<"require">>, Cancel)),
    ?assertEqual(undefined, hdr(<<"proxy-require">>, Cancel)),
    ?assertEqual(undefined, hdr(<<"contact">>, Cancel)),
    send(Sock, EP, response(Cancel, 200, #{to_tag => ToTag})),
    R487 = response(Inv, 487, #{to_tag => ToTag}),
    send(Sock, EP, R487),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual(undefined, hdr(<<"require">>, Ack)),
    ?assertMatch({error, #chappe_sip_error{status = 487}},
                 chappe_sip_uac:await(Ref, 3000)).

%% The app cancels before any provisional: no CANCEL goes out until the
%% first provisional arrives (9.1).
%% req: R3261-C-007 R3261-C-008
cancel_waits_for_provisional(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ok = chappe_sip_uac:cancel(Ref),
    recv_none(Sock, {method, <<"CANCEL">>}, 1200),
    ToTag = tag(),
    send(Sock, EP, response(Inv, 180, #{to_tag => ToTag})),
    {Cancel, _} = recv(Sock, {method, <<"CANCEL">>}, 3000),
    send(Sock, EP, response(Cancel, 200, #{to_tag => ToTag})),
    send(Sock, EP, response(Inv, 487, #{to_tag => ToTag})),
    ?assertMatch({error, #chappe_sip_error{status = 487}},
                 chappe_sip_uac:await(Ref, 3000)).

%% A cancel after the final response sends no CANCEL (9.1).
%% req: R3261-C-009
no_cancel_after_final(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv, 486, #{to_tag => tag()})),
    ?assertMatch({error, #chappe_sip_error{status = 486}},
                 chappe_sip_uac:await(Ref, 3000)),
    ok = chappe_sip_uac:cancel(Ref),
    recv_none(Sock, {method, <<"CANCEL">>}, 1500).

%% ---- INVITE client transaction (17.1.1) ----

%% An unanswered INVITE is retransmitted with intervals doubling each
%% time (Timer A); once a provisional arrives the retransmissions stop.
%% The first interval is 1 s, not T1: the vendored sofia (freeswitch fork)
%% floors the initial Timer A/E at 1000 ms. This case checks it is never
%% shorter than T1 and that it doubles from there.
%% req: R3261-262 R3261-267 R3261-269 R3261-273 R3261-270 R3261-276
invite_retransmits(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    T0 = erlang:monotonic_time(millisecond),
    Sent = collect(Sock, {method, <<"INVITE">>}, 4200),
    ct:log("INVITE at ~p", [[T - T0 || {T, _} <- Sent]]),
    [First | _] = Intervals = intervals([T || {T, _} <- Sent]),
    ?assert(First >= 500 - 100),
    check_backoff([T || {T, _} <- Sent], First, 1 bsl 30),
    ?assert(length(Intervals) >= 2),
    [{_, Inv} | _] = Sent,
    ToTag = tag(),
    send(Sock, EP, response(Inv, 180, #{to_tag => ToTag})),
    recv_none(Sock, {method, <<"INVITE">>}, 4500),
    send(Sock, EP, response(Inv, 486, #{to_tag => ToTag})),
    ?assertMatch({error, #chappe_sip_error{status = 486}},
                 chappe_sip_uac:await(Ref, 3000)).

%% An INVITE nobody answers ends in a 408 for the app after 64*T1 (Timer
%% B).
%% req: R3261-266 R3261-274 R3261-042
invite_timeout(Config) ->
    Sock = ?config(sock, Config),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    R = chappe_sip_uac:await(Ref, 40000),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:log("~p after ~p ms", [R, Took]),
    ?assertMatch({error, #chappe_sip_error{status = 408}}, R),
    ?assert(Took >= 31500).

%% ---- forked and late responses (13.2.2) ----

%% Two 200s with different To tags: each is ACKed; the second dialog is
%% then released with a BYE in that dialog; the app keeps the first.
%% req: R3261-199 R3261-206 R3261-252 R3261-249
forked_2xx(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    {TagA, TagB} = {tag(), tag()},
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    send(Sock, EP, response(Inv, 200, #{to_tag => TagA, body => sdp(),
                                        headers => Contact})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    send(Sock, EP, response(Inv, 200, #{to_tag => TagB, body => sdp(),
                                        headers => Contact})),
    Seen = collect(Sock, any, 2000),
    Acked = [to_tag(B) || {_, B} <- Seen, method(B) =:= <<"ACK">>],
    ?assert(lists:member(TagA, Acked)),
    ?assert(lists:member(TagB, Acked)),
    Byes = [B || {_, B} <- Seen, method(B) =:= <<"BYE">>],
    ?assertMatch([_ | _], Byes),
    [begin
         ?assertEqual(TagB, to_tag(B)),
         ?assertEqual(from_tag(Inv), from_tag(B)),
         ?assertEqual(hdr(<<"call-id">>, Inv), hdr(<<"call-id">>, B))
     end || B <- Byes],
    ?assertEqual(TagA, chappe_sip_dialog:remote_tag(D)).

%% A final response after the 200 changes nothing: the app is not told and
%% the dialog carries on (13.2.2).
%% req: R3261-197
late_final_ignored(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    send(Sock, EP, response(Inv, 200, #{to_tag => ToTag, body => sdp(),
                                        headers => Contact})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    send(Sock, EP, response(Inv, 486, #{to_tag => ToTag})),
    receive {chappe_sip_uac, Ref, {error, _} = Late} -> ct:fail({told, Late})
    after 1000 -> ok
    end,
    Info = async(fun() -> chappe_sip_dialog:request(D, #{method => <<"INFO">>}) end),
    {InfoReq, _} = recv(Sock, {method, <<"INFO">>}, 3000),
    send(Sock, EP, response(InfoReq, 200, #{})),
    {ok, _} = await(Info).

%% A 1xx we do not know is taken as 183 and a 2xx we do not know as 200:
%% the call is set up and ACKed; a 4xx we do not know fails the call like
%% a 400 (8.1.3.2).
%% req: R3261-044 R3261-045
unknown_codes(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    send(Sock, EP, response(Inv, 199, #{to_tag => ToTag})),
    receive {chappe_sip_uac, Ref, {provisional, P}} ->
                ?assertEqual(199, chappe_sip_msg:status(P))
    after 3000 -> ct:fail(no_provisional)
    end,
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    send(Sock, EP, response(Inv, 299, #{to_tag => ToTag, body => sdp(),
                                        headers => Contact})),
    {ok, _D} = chappe_sip_uac:await(Ref, 3000),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    {ok, Ref2} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                      notify => self()}),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv2, 499, #{to_tag => tag()})),
    ?assertMatch({error, #chappe_sip_error{status = 499}},
                 chappe_sip_uac:await(Ref2, 3000)),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000).

%% ---- offer/answer (13.2.1) ----

%% An INVITE without an offer: the 200 carries the offer and our ACK the
%% answer the app gives for it.
%% req: R3261-191 R3261-203 R3261-194 R3261-187
offer_in_2xx(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Answer = chappe_sip_core_peer:sdp(41000),
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{
        notify => self(), answer => fun(_Offer) -> {ok, Answer} end}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(<<>>, body(Inv)),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    Offer = chappe_sip_core_peer:sdp(42000),
    send(Sock, EP, response(Inv, 200, #{to_tag => tag(), body => Offer,
                                        headers => Contact})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual(Answer, body(Ack)),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, Ack)),
    ?assertEqual(Offer, chappe_sip_dialog:remote_sdp(D)).

%% The first SDP the UAC receives (in a 183) is the answer; a different SDP
%% in the 200 is ignored (13.2.1).
%% req: R3261-190
answer_in_first_sdp(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    First = chappe_sip_core_peer:sdp(43000),
    send(Sock, EP, response(Inv, 183, #{to_tag => ToTag, body => First})),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    send(Sock, EP, response(Inv, 200, #{to_tag => ToTag, headers => Contact,
                                        body => chappe_sip_core_peer:sdp(44000)})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    ?assertEqual(First, chappe_sip_dialog:remote_sdp(D)).

%% ---- non-INVITE client transaction and response matching (17.1.2, 18.1.2) ----

%% An unanswered OPTIONS is retransmitted with intervals doubling up to
%% T2 (the first is 1 s, see invite_retransmits); after a 1xx every T2; a
%% 1xx and the final reach the app.
%% req: R3261-300 R3261-301 R3261-302 R3261-304
non_invite_retransmits(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip:request(callee(Sock), #{method => <<"OPTIONS">>,
                                                   notify => self()}),
    Sent = collect(Sock, {method, <<"OPTIONS">>}, 3500),
    [First | _] = intervals([T || {T, _} <- Sent]),
    ?assert(First >= 500 - 100),
    check_backoff([T || {T, _} <- Sent], First, 4000),
    [{_, Opt} | _] = Sent,
    send(Sock, EP, response(Opt, 100, #{})),
    After = [T || {T, _} <- collect(Sock, {method, <<"OPTIONS">>}, 9000)],
    ct:log("after the 100: ~p", [intervals(After)]),
    ?assert(length(After) >= 2),
    [?assert(I >= 4000 - 100 andalso I =< 4000 + 1500, {interval, I})
     || I <- intervals(After)],
    send(Sock, EP, response(Opt, 200, #{to_tag => tag()})),
    {ok, Resp} = chappe_sip_uac:await_response(Ref, 3000),
    ?assertEqual(200, chappe_sip_msg:status(Resp)).

%% A response missing a mandatory header, or for another method on the
%% same branch, is dropped; the matching one (branch and CSeq method, back
%% at our source address and sent-by port) reaches its transaction
%% (18.1.1, 18.1.2, 20). A response whose Content-Length runs past the
%% datagram is taken by nta (RFC 3261 18.3 wants it dropped): not
%% checked here, see the report.
%% req: R3261-354 R3261-416 R3261-349
response_matching(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip:request(callee(Sock), #{method => <<"OPTIONS">>,
                                                   notify => self()}),
    {Opt, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    NoCallId = binary:replace(response(Opt, 482, #{to_tag => tag()}),
                              <<"Call-ID: ">>, <<"X-Call-ID: ">>),
    send(Sock, EP, NoCallId),
    %% a response to another method with the same branch
    OtherMethod = binary:replace(response(Opt, 484, #{to_tag => tag()}),
                                 <<" OPTIONS\r\n">>, <<" INFO\r\n">>),
    send(Sock, EP, OtherMethod),
    receive {chappe_sip_uac, Ref, {response, Early}} ->
                ct:fail({taken, chappe_sip_msg:status(Early)})
    after 1000 -> ok
    end,
    send(Sock, EP, response(Opt, 200, #{to_tag => tag()})),
    {ok, Resp} = chappe_sip_uac:await_response(Ref, 3000),
    ?assertEqual(200, chappe_sip_msg:status(Resp)).

%% An offer in the 200 the app does not answer: the ACK still carries a
%% valid answer (every stream refused), then a BYE ends the call and the
%% app gets an error (13.2.2.4).
%% req: R3261-204
offer_in_2xx_rejected(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    ToTag = tag(),
    send(Sock, EP, response(Inv, 200, #{to_tag => ToTag, body => sdp(),
                                        headers => Contact})),
    ?assertEqual({error, offer_not_acceptable}, chappe_sip_uac:await(Ref, 3000)),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertMatch({match, _}, re:run(body(Ack), "m=audio 0 RTP/AVP 0")),
    {Bye, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    ?assertEqual(ToTag, to_tag(Bye)),
    send(Sock, EP, response(Bye, 200, #{})).

%% The first request the peer sends in our dialog may carry any CSeq; the
%% next one lower than it is out of order (12.1.2, 12.2.2).
%% req: R3261-144
uac_first_remote_cseq(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {_D, Inv, R200} = answered_call(Sock, EP, #{}),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Req = fun(N) ->
        request(<<"INFO">>, addr_uri(hdr(<<"contact">>, Inv)),
                #{port => port(Sock), call_id => hdr(<<"call-id">>, Inv),
                  from => addr(hdr(<<"to">>, R200)), from_tag => to_tag(R200),
                  to => addr(hdr(<<"from">>, Inv)), to_tag => from_tag(Inv),
                  cseq => N})
    end,
    send(Sock, EP, Req(999)),
    {R1, _} = recv(Sock, {status, 200, <<"INFO">>}, 3000),
    ?assertEqual(200, status(R1)),
    send(Sock, EP, Req(5)),
    {R2, _} = recv(Sock, final, 3000),
    ?assertEqual(500, status(R2)).

%% A 200 without a To tag (RFC 2543) still forms the dialog; our requests
%% in it then carry no To tag (12.1.2, 12.2.1.1).
%% req: R3261-146 R3261-154
uac_tagless_2xx(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    send(Sock, EP, response(Inv, 200, #{body => sdp(), headers => Contact})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertEqual(nomatch, binary:match(hdr(<<"to">>, ByeReq), <<"tag=">>)).

%% Our re-INVITE carries the Contact of the INVITE; the Contact of its 200
%% becomes the remote target of the ACK and of the next requests
%% (12.2.1.1, 12.2.1.2).
%% req: R3261-166 R3261-168
uac_target_refresh(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {D, Inv, _R200} = answered_call(Sock, EP, #{}),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Mod = async(fun() -> chappe_sip_dialog:modify(D, hold) end),
    {ReInv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(hdr(<<"contact">>, Inv), hdr(<<"contact">>, ReInv)),
    Moved = <<"sip:moved@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>,
    send(Sock, EP, response(ReInv, 200, #{body => sdp(),
                                          headers => [{<<"Contact">>,
                                                       <<"<", Moved/binary, ">">>}]})),
    {ok, _} = await(Mod),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual(Moved, uri(Ack)),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertEqual(Moved, uri(ByeReq)).

%% A request over TCP to a port nobody listens on fails with 503 for the
%% app: the connection failure is a fatal transport error (8.1.3.1).
%% req: R3261-043
transport_error_503(_Config) ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Dead} = inet:port(L),
    ok = gen_tcp:close(L),
    Uri = <<"sip:nobody@127.0.0.1:", (integer_to_binary(Dead))/binary,
            ";transport=tcp">>,
    {ok, Ref} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>,
                                          notify => self()}),
    R = chappe_sip_uac:await_response(Ref, 5000),
    ct:log("~p", [R]),
    case R of
        {ok, Resp} -> ?assertEqual(503, chappe_sip_msg:status(Resp));
        {error, #chappe_sip_error{status = S}} -> ?assertEqual(503, S)
    end.

%% ---- Timers D, F and K (17.1.1.2, 17.1.2.2) ----

%% After the ACK of a 486 the client transaction stays for Timer D (32 s):
%% a retransmitted 486 at 20 s is ACKed again and not passed up; after
%% Timer D a late copy is no longer ACKed.
%% req: R3261-282 R3261-284
uac_timer_d(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    R486 = response(Inv, 486, #{to_tag => tag()}),
    send(Sock, EP, R486),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertMatch({error, #chappe_sip_error{status = 486}},
                 chappe_sip_uac:await(Ref, 3000)),
    timer:sleep(20000),
    send(Sock, EP, R486),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 1000),
    timer:sleep(14000),
    drain(Sock),
    send(Sock, EP, R486),
    recv_none(Sock, {method, <<"ACK">>}, 1500).

%% An OPTIONS answered only with a 100 times out at Timer F: the app gets
%% a 408 (17.1.2.2 Proceeding).
%% req: R3261-303
uac_timer_f_proceeding(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    T0 = erlang:monotonic_time(millisecond),
    {ok, Ref} = chappe_sip:request(callee(Sock), #{method => <<"OPTIONS">>,
                                                   notify => self()}),
    {Opt, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    send(Sock, EP, response(Opt, 100, #{})),
    R = chappe_sip_uac:await_response(Ref, 40000),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:log("~p after ~p ms", [R, Took]),
    ?assertMatch({error, #chappe_sip_error{status = 408}}, R),
    ?assert(Took >= 31500).

%% A retransmitted 200 to our OPTIONS is absorbed by the completed
%% transaction (Timer K): the app hears of the response once.
%% req: R3261-305
non_invite_absorbs_retransmit(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip:request(callee(Sock), #{method => <<"OPTIONS">>,
                                                   notify => self()}),
    {Opt, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    R200 = response(Opt, 200, #{to_tag => tag()}),
    send(Sock, EP, R200),
    {ok, _} = chappe_sip_uac:await_response(Ref, 3000),
    send(Sock, EP, R200),
    receive {chappe_sip_uac, Ref, {response, _}} -> ct:fail(told_twice)
    after 1000 -> ok
    end.

%% An INVITE that needs 100rel requires it; a 420 naming it makes the
%% INVITE go again without it, same Call-ID, To and From, CSeq one higher
%% (8.1.1.9, 8.1.3.5).
%% req: R3261-065 R3261-066 R3261-029
retry_after_420(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     rel100 => require,
                                                     notify => self()}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(<<"100rel">>, hdr(<<"require">>, Inv1)),
    send(Sock, EP, response(Inv1, 420, #{to_tag => tag(),
                                         headers => [{<<"Unsupported">>,
                                                      <<"100rel">>}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(undefined, hdr(<<"require">>, Inv2)),
    [?assertEqual(hdr(H, Inv1), hdr(H, Inv2))
     || H <- [<<"call-id">>, <<"from">>, <<"to">>]],
    {N, _} = cseq(Inv1),
    ?assertEqual({N + 1, <<"INVITE">>}, cseq(Inv2)),
    send(Sock, EP, response(Inv2, 486, #{to_tag => tag()})),
    ?assertMatch({error, #chappe_sip_error{status = 486}},
                 chappe_sip_uac:await(Ref, 3000)).

%% ---- re-INVITE, hold, strict routing (12.2.1.1, 14.1) ----

%% A 180 to our hold re-INVITE leaves the transaction open: no ACK, no
%% result for the app, and no second INVITE meanwhile; the 200 then
%% completes it and gets the ACK (14.1, 17.1.1).
%% req: R3261-228 R3261-229
reinvite_provisional_then_2xx(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {D, _Inv, _R200} = answered_call(Sock, EP, #{}),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Mod = async(fun() -> chappe_sip_dialog:modify(D, hold) end),
    {ReInv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(ReInv, 180, #{})),
    recv_none(Sock, {method, <<"ACK">>}, 500),
    send(Sock, EP, response(ReInv, 200, #{body => sdp()})),
    ?assertMatch({ok, <<"v=0", _/binary>>}, await(Mod)),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    {N, <<"INVITE">>} = cseq(ReInv),
    ?assertEqual({N, <<"ACK">>}, cseq(Ack)),
    hang_up(Sock, EP, D).

%% A 200 whose first Record-Route lacks lr (a strict router): our ACK and
%% BYE put that route in the Request-URI, the rest of the route set in
%% Route and the remote target last (12.2.1.1).
%% req: R3261-163 R3261-164 R3261-165
strict_route_set(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Strict = <<"sip:127.0.0.1:", LP/binary, ";x-a=1">>,
    Loose = <<"<sip:127.0.0.1:", LP/binary, ";lr;x-b=2>">>,
    Target = <<"sip:callee@127.0.0.1:", LP/binary, ";x-c=1">>,
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv, 200, #{
        to_tag => tag(), body => sdp(),
        headers => [{<<"Record-Route">>, Loose},
                    {<<"Record-Route">>, <<"<", Strict/binary, ">">>},
                    {<<"Contact">>, <<"<", Target/binary, ">">>}]})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    [begin
         ?assertEqual(Strict, uri(R)),
         ?assertEqual([Loose, <<"<", Target/binary, ">">>],
                      route_values(R))
     end || R <- [Ack, ByeReq]].

%% Hold marks each live stream of our last offer: sendrecv (here the
%% session-level default) becomes sendonly, recvonly becomes inactive, a
%% rejected stream (port 0) is left as it is; every m= section carries its
%% own direction and o= has the next version (RFC 3264 8.4, 14.1).
%% req: R3264-8.4-1 R3261-226
hold_each_stream(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {D, _Inv, _R200} = answered_call(Sock, EP, #{local_sdp => multi_sdp()}),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Held = reinvite(Sock, EP, D, hold),
    ?assertEqual([<<"sendonly">>, <<"inactive">>, none], directions(Held)),
    ?assertEqual(none, session_direction(Held)),
    ?assertMatch({match, _}, re:run(Held, "^o=- 10 11 ", [multiline])),
    hang_up(Sock, EP, D).

%% Unhold reverses hold stream by stream: sendonly back to sendrecv,
%% inactive back to recvonly, with the next o= version again.
%% req: R3264-8.4-1 R3261-226
unhold_each_stream(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {D, _Inv, _R200} = answered_call(Sock, EP, #{local_sdp => multi_sdp()}),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    _ = reinvite(Sock, EP, D, hold),
    Resumed = reinvite(Sock, EP, D, unhold),
    ?assertEqual([<<"sendrecv">>, <<"recvonly">>, none], directions(Resumed)),
    ?assertMatch({match, _}, re:run(Resumed, "^o=- 10 12 ", [multiline])),
    ?assertEqual(Resumed, chappe_sip_dialog:local_sdp(D)),
    hang_up(Sock, EP, D).

%% ---- digest (22.2, 22.3, RFC 7616, RFC 8760) ----

%% A 401 with a WWW-Authenticate: the INVITE goes again with an
%% Authorization answering it, the next CSeq, and the call is set up.
%% req: R3261-061 R3261-22.2-1 R3261-22.2-2 R2617-01
uac_digest_401(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(undefined, hdr(<<"authorization">>, Inv1)),
    Chal = <<"Digest realm=\"uas\", nonce=\"n401\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    {N, _} = cseq(Inv1),
    ?assertEqual({N + 1, <<"INVITE">>}, cseq(Inv2)),
    ok = check_creds(Inv2, <<"authorization">>, Chal),
    ?assertEqual(undefined, hdr(<<"proxy-authorization">>, Inv2)),
    D = answer(Sock, EP, Inv2, Ref),
    hang_up(Sock, EP, D).

%% The ACK of the 2xx to an authenticated INVITE carries the INVITE's
%% credentials (13.2.2.4).
%% req: R3261-202
ack_carries_credentials(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Chal = <<"Digest realm=\"px\", nonce=\"nack\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 407, #{
        to_tag => tag(), headers => [{<<"Proxy-Authenticate">>, Chal}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    D = answer(Sock, EP, Inv2, Ref),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Creds = hdr(<<"proxy-authorization">>, Inv2),
    ?assertNotEqual(undefined, Creds),
    ?assertEqual(Creds, hdr(<<"proxy-authorization">>, Ack)),
    hang_up(Sock, EP, D).

%% A proxy challenges (407), then the callee (401): the third INVITE
%% answers both, a Proxy-Authorization for the proxy realm and an
%% Authorization for the callee realm (22.3).
%% req: R3261-22.3-1 R3261-22.3-2 R3261-22.3-3
auth_407_then_401(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    PChal = <<"Digest realm=\"proxy\", nonce=\"np\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 407, #{
        to_tag => tag(), headers => [{<<"Proxy-Authenticate">>, PChal}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ok = check_creds(Inv2, <<"proxy-authorization">>, PChal),
    UChal = <<"Digest realm=\"callee\", nonce=\"nu\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv2, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, UChal}]})),
    {Inv3, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ok = check_creds(Inv3, <<"proxy-authorization">>, PChal),
    ok = check_creds(Inv3, <<"authorization">>, UChal),
    D = answer(Sock, EP, Inv3, Ref),
    hang_up(Sock, EP, D).

%% A challenge with stale=true only renews the nonce: the request goes
%% again with the new one; a second plain challenge for the same realm
%% means the credentials were refused and the app gets the 401.
%% req: R7616-02
auth_stale_nonce(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Chal1 = <<"Digest realm=\"uas\", nonce=\"old\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal1}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ok = check_creds(Inv2, <<"authorization">>, Chal1),
    Chal2 = <<"Digest realm=\"uas\", nonce=\"new\", qop=\"auth\", stale=true">>,
    send(Sock, EP, response(Inv2, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal2}]})),
    {Inv3, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ok = check_creds(Inv3, <<"authorization">>, Chal2),
    Chal3 = <<"Digest realm=\"uas\", nonce=\"other\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv3, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal3}]})),
    ?assertMatch({error, #chappe_sip_error{status = 401}},
                 chappe_sip_uac:await(Ref, 3000)),
    recv_none(Sock, {method, <<"INVITE">>}, 500).

%% Two challenges for one realm, MD5 listed first: we answer the SHA-256
%% one (RFC 8760 2.4, RFC 7616 5.6: the strongest we support). A third
%% one with an algorithm we lack is ignored.
%% req: R8760-01 R8760-03 R7616-01
auth_prefers_sha256(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Md5 = <<"Digest realm=\"uas\", nonce=\"ns\", qop=\"auth\", algorithm=MD5">>,
    Sha = <<"Digest realm=\"uas\", nonce=\"ns\", qop=\"auth\", algorithm=SHA-256">>,
    Odd = <<"Digest realm=\"uas\", nonce=\"ns\", qop=\"auth\", algorithm=SHA-512-256">>,
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(),
        headers => [{<<"WWW-Authenticate">>, Odd},
                    {<<"WWW-Authenticate">>, Md5},
                    {<<"WWW-Authenticate">>, Sha}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    [_] = hdrs(<<"authorization">>, Inv2),
    ok = check_creds(Inv2, <<"authorization">>, Sha),
    ?assertMatch({_, _}, binary:match(hdr(<<"authorization">>, Inv2),
                                      <<"algorithm=SHA-256">>)),
    D = answer(Sock, EP, Inv2, Ref),
    hang_up(Sock, EP, D).

%% Each request sent with one nonce counts: after a 420 the retried
%% INVITE reuses the nonce with nc=00000002 and a fresh response
%% (RFC 7616 3.4).
%% req: R7616-03
auth_nonce_count(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{
        headers => [{<<"Require">>, <<"x-foo">>}]})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Chal = <<"Digest realm=\"uas\", nonce=\"nn\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(<<"00000001">>, auth_param(<<"nc">>, Inv2)),
    send(Sock, EP, response(Inv2, 420, #{
        to_tag => tag(), headers => [{<<"Unsupported">>, <<"x-foo">>}]})),
    {Inv3, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(<<"00000002">>, auth_param(<<"nc">>, Inv3)),
    ok = check_creds(Inv3, <<"authorization">>, Chal),
    D = answer(Sock, EP, Inv3, Ref),
    hang_up(Sock, EP, D).

%% A 401 naming two realms: one Authorization per realm, each with the
%% credentials configured for it (RFC 8760 2.4, RFC 3261 22.3).
%% req: R8760-04 R3261-22.3-2 R3261-22.3-3
auth_two_realms(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Auth = [#{realm => <<"a">>, user => <<"alice">>, pass => <<"secret">>},
            #{realm => <<"b">>, user => <<"bob">>, pass => <<"other">>}],
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self(),
                                                     auth => Auth}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ChalA = <<"Digest realm=\"a\", nonce=\"na\", qop=\"auth\"">>,
    ChalB = <<"Digest realm=\"b\", nonce=\"nb\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, ChalA},
                                     {<<"WWW-Authenticate">>, ChalB}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Creds = hdrs(<<"authorization">>, Inv2),
    ?assertEqual(2, length(Creds)),
    [ok = check_value(V, Chal, User, Pass)
     || {V, {Chal, User, Pass}} <- lists:zip(
            Creds, [{ChalA, <<"alice">>, <<"secret">>},
                    {ChalB, <<"bob">>, <<"other">>}])],
    D = answer(Sock, EP, Inv2, Ref),
    hang_up(Sock, EP, D).

%% A Basic challenge is never answered: the app gets the 401.
%% req: R8760-07
auth_basic_refused(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(),
        headers => [{<<"WWW-Authenticate">>, <<"Basic realm=\"uas\"">>}]})),
    ?assertMatch({error, #chappe_sip_error{status = 401}},
                 chappe_sip_uac:await(Ref, 3000)),
    recv_none(Sock, {method, <<"INVITE">>}, 500).

%% ---- reliable provisionals (RFC 3262 4) ----

%% The PRACK is a request of the early dialog: Request-URI is the 183's
%% Contact and its Record-Route, reversed, is the Route (12.1.2).
%% req: R3262-033 R3262-032
prack_follows_route_set(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    RR = [<<"<sip:127.0.0.1:", LP/binary, ";lr;x-a=1>">>,
          <<"<sip:127.0.0.1:", LP/binary, ";lr;x-b=2>">>],
    Target = <<"sip:early@127.0.0.1:", LP/binary, ";x-c=1">>,
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     rel100 => supported,
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    send(Sock, EP, response(Inv, 183, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Require">>, <<"100rel">>}, {<<"RSeq">>, <<"1">>},
                    {<<"Record-Route">>, lists:nth(1, RR)},
                    {<<"Record-Route">>, lists:nth(2, RR)},
                    {<<"Contact">>, <<"<", Target/binary, ">">>}]})),
    {Prack, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    ?assertEqual(Target, uri(Prack)),
    ?assertEqual(lists:reverse(RR), route_values(Prack)),
    ?assertEqual(<<"1 1 INVITE">>, hdr(<<"rack">>, Prack)),
    send(Sock, EP, response(Prack, 200, #{})),
    send(Sock, EP, response(Inv, 200, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    hang_up(Sock, EP, D).

%% A 183 with an RSeq but no Require: 100rel is not reliable: no PRACK.
%% req: R3262-033 R3262-010
rseq_without_require(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     rel100 => supported,
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    send(Sock, EP, response(Inv, 183, #{
        to_tag => ToTag, headers => [{<<"RSeq">>, <<"1">>}]})),
    recv_none(Sock, {method, <<"PRACK">>}, 800),
    D = answer(Sock, EP, Inv, Ref, ToTag),
    hang_up(Sock, EP, D).

%% ---- redirection (8.1.3.4) ----

%% A 302 with three Contacts: the sip ones are tried best q first (a tel
%% URI we cannot reach is skipped, a URI's ?headers part is not sent); the
%% first fails 480, so the next one is tried and answers.
%% req: R3261-048 R3261-053 R3261-054 R3261-049 R3261-059
redirect_q_order_fallback(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Low = <<"sip:low@127.0.0.1:", LP/binary>>,
    High = <<"sip:high@127.0.0.1:", LP/binary>>,
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     follow_redirects => true,
                                                     notify => self()}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 302, #{
        to_tag => tag(),
        headers => [{<<"Contact">>, <<"<", Low/binary, ">;q=0.2">>},
                    {<<"Contact">>, <<"<tel:+15551234>;q=1.0, <",
                                      High/binary, "?Subject=hi>;q=0.9">>}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(High, uri(Inv2)),
    ?assertEqual(undefined, hdr(<<"subject">>, Inv2)),
    ?assertNotEqual(via_branch(top_via(Inv1)), via_branch(top_via(Inv2))),
    send(Sock, EP, response(Inv2, 480, #{to_tag => tag()})),
    {Inv3, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(Low, uri(Inv3)),
    D = answer(Sock, EP, Inv3, Ref),
    hang_up(Sock, EP, D).

%% ---- third party call control and give-up (RFC 3725, 9.1) ----

%% no_ack holds the ACK of the 2xx: chappe_sip_dialog:ack/2 sends it
%% later with the answer to the 2xx's offer, the INVITE's CSeq number,
%% and only once.
%% req: R3261-201 R3261-203
delayed_ack_3pcc(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{no_ack => true,
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv, 200, #{
        to_tag => tag(), body => chappe_sip_core_peer:sdp(41000),
        headers => [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    recv_none(Sock, {method, <<"ACK">>}, 500),
    Answer = chappe_sip_core_peer:sdp(42000),
    ok = chappe_sip_dialog:ack(D, #{local_sdp => Answer}),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    {N, <<"INVITE">>} = cseq(Inv),
    ?assertEqual({N, <<"ACK">>}, cseq(Ack)),
    ?assertEqual(Answer, body(Ack)),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, Ack)),
    ?assertEqual(Answer, chappe_sip_dialog:local_sdp(D)),
    ?assertEqual({error, no_pending_ack}, chappe_sip_dialog:ack(D, #{})),
    hang_up(Sock, EP, D).

%% create_uac gives up after its timeout: the ringing INVITE is
%% CANCELled, and the 2xx that crosses the CANCEL is ACKed and BYEd
%% instead of becoming a dialog nobody owns (9.1, 15).
%% req: R3261-206
create_uac_timeout_cancels(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Call = async(fun() ->
        chappe_sip:create_uac(callee(Sock), #{local_sdp => sdp(),
                                              timeout => 1000})
    end),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    send(Sock, EP, response(Inv, 180, #{to_tag => ToTag})),
    ?assertEqual({error, timeout}, await(Call)),
    {Cancel, _} = recv(Sock, {method, <<"CANCEL">>}, 3000),
    send(Sock, EP, response(Cancel, 200, #{to_tag => ToTag})),
    send(Sock, EP, response(Inv, 200, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]})),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    {Bye, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(Bye, 200, #{})),
    ?assertEqual(ToTag, to_tag(Bye)).

%% ---- helpers of the cases above ----

auth_opts(Opts) ->
    maps:merge(#{local_sdp => sdp(), notify => self(),
                 auth => #{user => <<"alice">>, pass => <<"secret">>}}, Opts).

%% the credentials in header Name of Req answer challenge Chal for alice
check_creds(Req, Name, Chal) ->
    case hdrs(Name, Req) of
        [V] -> check_value(V, Chal, <<"alice">>, <<"secret">>);
        Other -> {wrong_count, Name, Other}
    end.

check_value(V, Chal, User, Pass) ->
    {ok, #{params := P}} = chappe_sip_hdr:auth(V),
    {ok, C} = chappe_sip_hdr:auth(Chal),
    #{params := CP} = C,
    ?assertEqual(maps:get(<<"realm">>, CP), maps:get(<<"realm">>, P)),
    ?assertEqual(maps:get(<<"nonce">>, CP), maps:get(<<"nonce">>, P)),
    ?assertEqual(User, maps:get(<<"username">>, P)),
    {ok, Want} = chappe_sip_digest:credentials(
        #{method => <<"INVITE">>, uri => maps:get(<<"uri">>, P),
          username => User, password => Pass, challenge => C,
          nc => binary_to_integer(maps:get(<<"nc">>, P), 16),
          cnonce => maps:get(<<"cnonce">>, P)}),
    {ok, #{params := WP}} = chappe_sip_hdr:auth(Want),
    ?assertEqual(maps:get(<<"response">>, WP), maps:get(<<"response">>, P)),
    ok.

auth_param(Name, Req) ->
    {ok, #{params := P}} = chappe_sip_hdr:auth(hdr(<<"authorization">>, Req)),
    maps:get(Name, P).

%% answer the INVITE 200 with a Contact; the dialog the app gets
answer(Sock, EP, Inv, Ref) ->
    answer(Sock, EP, Inv, Ref, tag()).

answer(Sock, EP, Inv, Ref, ToTag) ->
    send(Sock, EP, response(Inv, 200, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    D.

hang_up(Sock, EP, D) ->
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye).

%% modify the dialog, answer the re-INVITE 200; the offer it carried
reinvite(Sock, EP, D, Spec) ->
    Mod = async(fun() -> chappe_sip_dialog:modify(D, Spec) end),
    {ReInv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(ReInv, 200, #{body => sdp()})),
    {ok, _} = await(Mod),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    body(ReInv).

%% sendrecv at session level, a video stream recvonly, a rejected stream
multi_sdp() ->
    <<"v=0\r\no=- 10 10 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\na=sendrecv\r\nm=audio 40000 RTP/AVP 0\r\n"
      "a=rtpmap:0 PCMU/8000\r\nm=video 40002 RTP/AVP 96\r\na=recvonly\r\n"
      "m=audio 0 RTP/AVP 0\r\n">>.

%% the direction attribute of each m= section (none when absent)
directions(Sdp) ->
    [_ | Media] = re:split(Sdp, "\r\n(?=m=)", [{return, binary}]),
    [section_direction(M) || M <- Media].

session_direction(Sdp) ->
    [Session | _] = re:split(Sdp, "\r\n(?=m=)", [{return, binary}]),
    section_direction(Session).

section_direction(Section) ->
    case re:run(Section, "^a=(sendrecv|sendonly|recvonly|inactive)\r?$",
                [multiline, global, {capture, [1], binary}]) of
        {match, [[D]]} -> D;
        nomatch -> none
    end.

%% the Route values of a request, one per route
route_values(Req) ->
    lists:append([[string:trim(R) || R <- split_routes(V)]
                  || V <- hdrs(<<"route">>, Req)]).

split_routes(V) ->
    {ok, L} = chappe_sip_hdr:name_addr_list(V),
    [<<"<", U/binary, ">">> || #{uri := U} <- L].

%% ---- helpers ----

%% a name-addr without its tag parameter
addr(V) -> re:replace(V, ";tag=[^;]*", "", [{return, binary}]).

callee(Sock) ->
    <<"sip:callee@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>.

%% INVITE (Opts merged into the UAC options) answered 200 with a Contact.
answered_call(Sock, EP, Opts) ->
    {ok, Ref} = chappe_sip_uac:start(callee(Sock),
                                     maps:merge(#{local_sdp => sdp(),
                                                  notify => self()}, Opts)),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    R200 = response(Inv, 200, #{to_tag => tag(), body => sdp(),
                                headers => Contact}),
    send(Sock, EP, R200),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    {D, Inv, R200}.

provisionals(Ref, Acc) ->
    receive
        {chappe_sip_uac, Ref, {provisional, M}} ->
            provisionals(Ref, [{chappe_sip_msg:status(M),
                                chappe_sip_msg:reason(M)} | Acc]);
        {chappe_sip_uac, Ref, {request_sent, _}} ->
            provisionals(Ref, Acc)
    after 1500 -> lists:reverse(Acc)
    end.

standards_track() ->
    [<<"100rel">>, <<"replaces">>, <<"timer">>, <<"norefersub">>,
     <<"tdialog">>, <<"path">>, <<"outbound">>, <<"gruu">>].

split(undefined) -> [];
split(V) -> [string:trim(X) || X <- binary:split(V, <<",">>, [global]),
                               string:trim(X) =/= <<>>].

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

addr_uri(V) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(V),
    U.

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
