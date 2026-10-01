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
                 retry_after_420]},
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
