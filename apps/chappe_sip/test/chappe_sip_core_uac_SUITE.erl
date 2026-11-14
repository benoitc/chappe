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
-export([preloaded_route_set/1, method_param_in_uri/1,
         redirect_drops_method_param/1, use_proxy_305/1,
         redirect_keep_uri/1, auth_fun/1]).
-export([early_update_from_callee/1, early_bye_from_callee/1,
         early_update_from_caller/1, early_forks_ended/1,
         early_ended_by_final/1]).
-export([large_request_over_tcp/1, tcp_response_paths/1,
         request_uri_params_kept/1, invalid_uri_not_sent/1,
         uac_ignores_na_headers/1, redirect_not_cached/1,
         service_unavailable_no_retry/1, session_privacy_sdp_clear/1]).

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
                 create_uac_timeout_cancels,
                 preloaded_route_set, method_param_in_uri,
                 redirect_drops_method_param, use_proxy_305, redirect_keep_uri,
                 auth_fun,
                 early_update_from_callee, early_bye_from_callee,
                 early_update_from_caller, early_forks_ended,
                 early_ended_by_final, large_request_over_tcp,
                 tcp_response_paths, request_uri_params_kept,
                 invalid_uri_not_sent, uac_ignores_na_headers,
                 redirect_not_cached, service_unavailable_no_retry,
                 session_privacy_sdp_clear]},
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
%% req: R3261-297 R3261-006 R3261-392 R3261-421 R3261-411 R3261-384
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
    %% no uri-parameter name twice in any URI we generated (19.1.1)
    [?assertEqual([], chappe_sip_core_peer:repeated_uri_params(U), U)
     || R <- Sent,
        U <- [uri(R) | [addr_uri(hdr(H, R))
                        || H <- [<<"from">>, <<"to">>, <<"contact">>],
                           hdr(H, R) =/= undefined]]],
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
%% req: R3261-354 R3261-416 R3261-349 R3261-350
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
%% Route and the remote target last (12.2.1.1). The strict router listens
%% on its own socket: the ACK and the BYE are sent to it, the address the
%% Request-URI resolves to (8.1.2), and never to the remote target.
%% req: R3261-163 R3261-164 R3261-165 R3261-034
strict_route_set(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Router = open(),
    LP = integer_to_binary(port(Sock)),
    RP = integer_to_binary(port(Router)),
    Strict = <<"sip:127.0.0.1:", RP/binary, ";x-a=1">>,
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
    {Ack, _} = recv(Router, {method, <<"ACK">>}, 3000),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Router, {method, <<"BYE">>}, 3000),
    send(Router, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    recv_none(Sock, fun(B) -> lists:member(method(B), [<<"ACK">>, <<"BYE">>])
                    end, 300),
    chappe_sip_core_peer:close(Router),
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

%% auth as a fun of the challenge: it gets the parsed challenge and picks
%% the credentials; none (or a crash) sends no credentials.
auth_fun(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Test = self(),
    Auth = fun(#{params := #{<<"realm">> := Realm}}) ->
        Test ! {asked, Realm},
        #{user => <<"alice">>, pass => <<"secret">>}
    end,
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), auth_opts(#{auth => Auth})),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    Chal = <<"Digest realm=\"uas\", nonce=\"nfun\", qop=\"auth\"">>,
    send(Sock, EP, response(Inv1, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ok = check_creds(Inv2, <<"authorization">>, Chal),
    receive {asked, <<"uas">>} -> ok after 1000 -> ct:fail(not_asked) end,
    D = answer(Sock, EP, Inv2, Ref),
    hang_up(Sock, EP, D),
    {ok, Ref2} = chappe_sip_uac:start(callee(Sock), auth_opts(#{
        auth => fun(_) -> error(no_credentials_here) end})),
    {Inv3, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv3, 401, #{
        to_tag => tag(), headers => [{<<"WWW-Authenticate">>, Chal}]})),
    receive
        {chappe_sip_uac, Ref2, {error, #chappe_sip_error{status = 401}}} -> ok
    after 3000 -> ct:fail(no_401)
    end.

%% The ACK of the 2xx to an authenticated INVITE carries the INVITE's
%% credentials (13.2.2.4).
%% req: R3261-202 R3261-486
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
%% req: R3261-22.3-1 R3261-22.3-2 R3261-22.3-3 R3261-486
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
%% credentials configured for it (RFC 8760 2.4, RFC 3261 22.3), each on its
%% own header line, never joined with a comma (20.7).
%% req: R8760-04 R3261-22.3-2 R3261-22.3-3 R3261-429
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
    Lines = [L || L <- binary:split(Inv2, <<"\r\n">>, [global]),
                  re:run(L, "^Authorization\\s*:", [caseless]) =/= nomatch],
    ct:log("Authorization lines:~n~p", [Lines]),
    ?assertEqual(2, length(Lines)),
    [?assertEqual(1, length(binary:matches(L, <<"Digest ">>))) || L <- Lines],
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

%% ---- preloaded route set and the method parameter (8.1.1.1, 19.1.5) ----

%% A route set given outside a dialog shapes the request as in a dialog
%% (12.2.1.1): a loose first route keeps the target in the Request-URI and
%% lists the routes; a strict one takes the Request-URI and the target goes
%% last in Route. Either way the request goes to the first route.
%% req: R3261-004
preloaded_route_set(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Target = <<"sip:far@far.invalid">>,
    Loose = <<"<sip:127.0.0.1:", LP/binary, ";lr>">>,
    Next = <<"<sip:next.invalid;lr>">>,
    {ok, _} = chappe_sip:request(Target, #{route_set => [Loose, Next]}),
    {R1, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    send(Sock, EP, response(R1, 200, #{to_tag => tag()})),
    ?assertEqual(Target, uri(R1)),
    ?assertEqual([Loose, Next], route_values(R1)),
    Strict = <<"sip:127.0.0.1:", LP/binary, ";x-a=1">>,
    {ok, _} = chappe_sip:request(Target,
                                 #{route_set => [<<"<", Strict/binary, ">">>,
                                                 Next]}),
    {R2, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    send(Sock, EP, response(R2, 200, #{to_tag => tag()})),
    ?assertEqual(Strict, uri(R2)),
    ?assertEqual([Next, <<"<", Target/binary, ">">>], route_values(R2)).

%% A URI with a method parameter makes that request when the caller names
%% no method, and the parameter is not in the Request-URI (19.1.5).
%% req: R3261-399 R3261-400
method_param_in_uri(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Bare = <<"sip:b@127.0.0.1:", LP/binary>>,
    {ok, _} = chappe_sip:request(<<Bare/binary, ";method=REFER">>,
                                 #{headers => [{<<"Refer-To">>, Bare}]}),
    {R1, _} = recv(Sock, {method, <<"REFER">>}, 3000),
    send(Sock, EP, response(R1, 202, #{to_tag => tag()})),
    ?assertEqual(Bare, uri(R1)),
    ?assertEqual(Bare, addr_uri(hdr(<<"to">>, R1))),
    %% an explicit method wins; the parameter still leaves the URI
    {ok, _} = chappe_sip:request(<<Bare/binary, ";Method=MESSAGE;x=1">>,
                                 #{method => <<"OPTIONS">>}),
    {R2, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    send(Sock, EP, response(R2, 200, #{to_tag => tag()})),
    ?assertEqual(<<Bare/binary, ";x=1">>, uri(R2)).

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

%% A 302 Contact with a method parameter and a ?headers part: the next
%% INVITE takes the whole URI as Request-URI minus both (8.1.3.4).
%% req: R3261-055
redirect_drops_method_param(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    Next = <<"sip:x@127.0.0.1:", LP/binary, ";x-k=1">>,
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     follow_redirects => true,
                                                     notify => self()}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 302, #{
        to_tag => tag(),
        headers => [{<<"Contact">>, <<"<sip:x@127.0.0.1:", LP/binary,
                                      ";method=REFER;x-k=1?Subject=a>">>}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(Next, uri(Inv2)),
    ?assertEqual(<<"INVITE">>, method(Inv2)),
    ?assertEqual(undefined, hdr(<<"subject">>, Inv2)),
    D = answer(Sock, EP, Inv2, Ref),
    hang_up(Sock, EP, D).

%% A 305 names the proxy to reach the resource through: the next INVITE
%% keeps the Request-URI and goes to the Contact of the 305 (21.3.6).
%% req: R3261-480
use_proxy_305(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Proxy = open(),
    PP = integer_to_binary(port(Proxy)),
    Uri = callee(Sock),
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => sdp(),
                                            follow_redirects => true,
                                            notify => self()}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 305, #{
        to_tag => tag(),
        headers => [{<<"Contact">>, <<"<sip:127.0.0.1:", PP/binary, ">">>}]})),
    {Inv2, _} = recv(Proxy, {method, <<"INVITE">>}, 3000),
    ?assertEqual(Uri, uri(Inv2)),
    recv_none(Sock, {method, <<"INVITE">>}, 300),
    D = answer(Proxy, EP, Inv2, Ref),
    hang_up(Proxy, EP, D),
    chappe_sip_core_peer:close(Proxy).

%% keep_uri_on_redirect (drachtio's keepUriOnRedirect): a 302 Contact is
%% only the next hop; the Request-URI and the To stay those of the first
%% INVITE.
redirect_keep_uri(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Next = open(),
    NP = integer_to_binary(port(Next)),
    Uri = callee(Sock),
    {ok, Ref} = chappe_sip_uac:start(Uri, #{local_sdp => sdp(),
                                            follow_redirects => true,
                                            keep_uri_on_redirect => true,
                                            notify => self()}),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 302, #{
        to_tag => tag(),
        headers => [{<<"Contact">>, <<"<sip:moved@127.0.0.1:", NP/binary, ">">>}]})),
    {Inv2, _} = recv(Next, {method, <<"INVITE">>}, 3000),
    ?assertEqual(Uri, uri(Inv2)),
    ?assertEqual(hdr(<<"to">>, Inv1), hdr(<<"to">>, Inv2)),
    D = answer(Next, EP, Inv2, Ref),
    hang_up(Next, EP, D),
    chappe_sip_core_peer:close(Next).

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

%% ---- early dialogs of our INVITE (12.1, 13.2.2.4, RFC 3311 5.1) ----

%% A tagged 183 forms an early dialog: the app gets its handle before the
%% provisional. The callee's UPDATE in it is answered 200 with our SDP. The
%% 200 with that To tag confirms the same dialog, and the route set and the
%% remote target of the dialog are taken again from the 200.
%% req: R3261-198 R3311-001
early_update_from_callee(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    LP = integer_to_binary(port(Sock)),
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    Early = <<"sip:early@127.0.0.1:", LP/binary>>,
    R183 = response(Inv, 183, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Contact">>, <<"<", Early/binary, ">">>}]}),
    send(Sock, EP, R183),
    ED = early_dialog(Ref),
    ?assertEqual(ToTag, chappe_sip_dialog:remote_tag(ED)),
    Offer = chappe_sip_core_peer:sdp(45000),
    send(Sock, EP, callee_request(Sock, <<"UPDATE">>, Inv, R183, 1,
                                  #{body => Offer})),
    {R, _} = recv(Sock, {status, 200, <<"UPDATE">>}, 3000),
    ?assertEqual(sdp(), body(R)),
    receive {chappe_sip_dialog, ED, {auto_answered, update}, _} -> ok
    after 3000 -> ct:fail(no_update_event)
    end,
    RR = <<"<sip:127.0.0.1:", LP/binary, ";lr;x-final=1>">>,
    send(Sock, EP, response(Inv, 200, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Record-Route">>, RR},
                    {<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    ?assertEqual(ED, D),
    ?assertEqual(Offer, chappe_sip_dialog:remote_sdp(D)),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual(callee(Sock), uri(Ack)),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    ?assertEqual(callee(Sock), uri(ByeReq)),
    ?assertEqual([RR], route_values(ByeReq)).

%% The callee's BYE in the early dialog gets 200 and ends that dialog (its
%% owner gets destroy with the BYE); the INVITE then completes with the
%% callee's final response.
%% req: R3261-258 R3261-256
early_bye_from_callee(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    R180 = response(Inv, 180, #{
        to_tag => ToTag,
        headers => [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]}),
    send(Sock, EP, R180),
    ED = early_dialog(Ref),
    send(Sock, EP, callee_request(Sock, <<"BYE">>, Inv, R180, 1, #{})),
    {R, _} = recv(Sock, {status, 200, <<"BYE">>}, 3000),
    ?assertEqual(200, status(R)),
    receive {chappe_sip_dialog, ED, destroy, Req} ->
                ?assertEqual(<<"BYE">>, chappe_sip_req:method(Req))
    after 3000 -> ct:fail(no_destroy)
    end,
    send(Sock, EP, response(Inv, 487, #{to_tag => ToTag})),
    ?assertMatch({error, #chappe_sip_error{status = 487}},
                 chappe_sip_uac:await(Ref, 3000)).

%% The caller sends UPDATE in the early dialog formed by a reliable 183:
%% to the 183's Contact with its To tag, a CSeq above the PRACK's; its
%% answer becomes the session, which the 200 to the INVITE leaves alone.
%% req: R3311-001
early_update_from_caller(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     rel100 => supported,
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    send(Sock, EP, response(Inv, 183, #{
        to_tag => ToTag, body => sdp(),
        headers => [{<<"Require">>, <<"100rel">>},
                    {<<"RSeq">>, <<"1">>} | Contact]})),
    {Prack, _} = recv(Sock, {method, <<"PRACK">>}, 3000),
    send(Sock, EP, response(Prack, 200, #{})),
    ED = early_dialog(Ref),
    New = chappe_sip_core_peer:sdp(46000),
    Answer = chappe_sip_core_peer:sdp(47000),
    Upd = async(fun() ->
        chappe_sip_dialog:request(ED, #{method => <<"UPDATE">>, body => New,
                                        content_type => <<"application/sdp">>})
    end),
    {U, _} = recv(Sock, {method, <<"UPDATE">>}, 3000),
    ?assertEqual(callee(Sock), uri(U)),
    ?assertEqual(ToTag, to_tag(U)),
    ?assertEqual(from_tag(Inv), from_tag(U)),
    ?assertEqual(hdr(<<"call-id">>, Inv), hdr(<<"call-id">>, U)),
    ?assertEqual(New, body(U)),
    {PN, _} = cseq(Prack),
    {UN, _} = cseq(U),
    ?assert(UN > PN),
    send(Sock, EP, response(U, 200, #{body => Answer})),
    {ok, _} = await(Upd),
    ?assertEqual(New, chappe_sip_dialog:local_sdp(ED)),
    ?assertEqual(Answer, chappe_sip_dialog:remote_sdp(ED)),
    send(Sock, EP, response(Inv, 200, #{to_tag => ToTag, body => sdp(),
                                        headers => Contact})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    ?assertEqual(ED, D),
    ?assertEqual(Answer, chappe_sip_dialog:remote_sdp(D)),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    Bye = async(fun() -> chappe_sip_dialog:destroy(D) end),
    {ByeReq, _} = recv(Sock, {method, <<"BYE">>}, 3000),
    send(Sock, EP, response(ByeReq, 200, #{})),
    ok = await(Bye),
    {BN, _} = cseq(ByeReq),
    ?assert(BN > UN).

%% Two forks each form an early dialog. The 200 of one confirms its
%% dialog; the other one ends (its owner gets destroy) and a request in it
%% then gets 481.
%% req: R3261-122
early_forks_ended(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    {TagA, TagB} = {tag(), tag()},
    Contact = [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}],
    RA = response(Inv, 180, #{to_tag => TagA, headers => Contact}),
    RB = response(Inv, 180, #{to_tag => TagB, headers => Contact}),
    send(Sock, EP, RA),
    EA = early_dialog(Ref),
    send(Sock, EP, RB),
    EB = early_dialog(Ref),
    ?assertNotEqual(EA, EB),
    ?assertEqual(TagB, chappe_sip_dialog:remote_tag(EB)),
    send(Sock, EP, response(Inv, 200, #{to_tag => TagA, body => sdp(),
                                        headers => Contact})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    ?assertEqual(EA, D),
    receive {chappe_sip_dialog, EB, destroy, {early_ended, 200}} -> ok
    after 3000 -> ct:fail(fork_not_ended)
    end,
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    send(Sock, EP, callee_request(Sock, <<"INFO">>, Inv, RB, 1, #{})),
    {R, _} = recv(Sock, {status, 481, <<"INFO">>}, 3000),
    ?assertEqual(481, status(R)),
    hang_up(Sock, EP, D).

%% A non-2xx final ends the early dialogs of the INVITE: the owner gets
%% destroy and the callee's UPDATE in one then gets 481.
%% req: R3261-122
early_ended_by_final(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ToTag = tag(),
    R180 = response(Inv, 180, #{
        to_tag => ToTag,
        headers => [{<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]}),
    send(Sock, EP, R180),
    ED = early_dialog(Ref),
    send(Sock, EP, response(Inv, 486, #{to_tag => ToTag})),
    ?assertMatch({error, #chappe_sip_error{status = 486}},
                 chappe_sip_uac:await(Ref, 3000)),
    receive {chappe_sip_dialog, ED, destroy, {early_ended, 486}} -> ok
    after 3000 -> ct:fail(early_not_ended)
    end,
    send(Sock, EP, callee_request(Sock, <<"UPDATE">>, Inv, R180, 1,
                                  #{body => sdp()})),
    {R, _} = recv(Sock, {status, 481, <<"UPDATE">>}, 3000),
    ?assertEqual(481, status(R)).

%% ---- transport choice and response paths (18.1.1, 18.1.2, 18.3) ----

%% A request over 1300 bytes to a peer listening on UDP and TCP at the
%% same port (path MTU unknown) goes over TCP, never as a datagram, with
%% SIP/2.0/TCP in its top Via and a Content-Length; the 200 the peer sends
%% back on that connection completes it.
%% req: R3261-338 R3261-339 R3261-340 R3261-346 R3261-374 R3261-440
large_request_over_tcp(Config) ->
    Sock = ?config(sock, Config),
    L = chappe_sip_core_peer:tcp_listen(port(Sock)),
    Pad = binary:copy(<<"p">>, 1400),
    {ok, Ref} = chappe_sip:request(callee(Sock), #{
        method => <<"OPTIONS">>, notify => self(),
        headers => [{<<"X-Pad">>, Pad}]}),
    {ok, C} = gen_tcp:accept(L, 3000),
    Req = chappe_sip_core_peer:tcp_recv(C, 3000),
    ct:log("over TCP (~p bytes):~n~s", [byte_size(Req), Req]),
    ?assert(byte_size(Req) > 1300),
    ?assertEqual(<<"OPTIONS">>, method(Req)),
    ?assertMatch(<<"SIP/2.0/TCP ", _/binary>>, top_via(Req)),
    ?assertEqual(Pad, hdr(<<"x-pad">>, Req)),
    ?assertEqual(integer_to_binary(byte_size(body(Req))),
                 hdr(<<"content-length">>, Req)),
    ok = gen_tcp:send(C, response(Req, 200, #{to_tag => tag()})),
    {ok, Resp} = chappe_sip_uac:await_response(Ref, 3000),
    ?assertEqual(200, chappe_sip_msg:status(Resp)),
    recv_none(Sock, {method, <<"OPTIONS">>}, 500),
    gen_tcp:close(C),
    gen_tcp:close(L).

%% Over transport=tcp the peer answers on the connection that carried the
%% request; for a second request it closes that connection, connects to
%% the Via sent-by (our TCP listener at the UDP port, the RFC 3263 server
%% address of our Contact) and answers there: both reach their
%% transaction. Each request carries Content-Length.
%% req: R3261-346 R3261-347 R3261-348 R3261-374 R3261-440
tcp_response_paths(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    L = chappe_sip_core_peer:tcp_listen(0),
    {ok, TP} = inet:port(L),
    Uri = <<"sip:callee@127.0.0.1:", (integer_to_binary(TP))/binary,
            ";transport=tcp">>,
    {ok, Ref1} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>,
                                           notify => self()}),
    {ok, C} = gen_tcp:accept(L, 3000),
    Req1 = chappe_sip_core_peer:tcp_recv(C, 3000),
    ?assertMatch(<<"SIP/2.0/TCP ", _/binary>>, top_via(Req1)),
    ?assertEqual(<<"0">>, hdr(<<"content-length">>, Req1)),
    ok = gen_tcp:send(C, response(Req1, 200, #{to_tag => tag()})),
    {ok, R1} = chappe_sip_uac:await_response(Ref1, 3000),
    ?assertEqual(200, chappe_sip_msg:status(R1)),
    {ok, Ref2} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>,
                                           notify => self()}),
    Req2 = chappe_sip_core_peer:tcp_recv(C, 3000),
    ok = gen_tcp:close(C),
    Via = top_via(Req2),
    ct:log("second request Via: ~s", [Via]),
    {match, [Host, SentBy]} =
        re:run(Via, "^SIP/2.0/TCP ([^:;]+):([0-9]+)",
               [{capture, all_but_first, list}]),
    ?assertEqual(EP, list_to_integer(SentBy)),
    {ok, C2} = gen_tcp:connect(Host, list_to_integer(SentBy),
                               [binary, {active, false}], 3000),
    ok = gen_tcp:send(C2, response(Req2, 200, #{to_tag => tag()})),
    {ok, R2} = chappe_sip_uac:await_response(Ref2, 3000),
    ?assertEqual(200, chappe_sip_msg:status(R2)),
    gen_tcp:close(C2),
    gen_tcp:close(L),
    _ = Sock.

%% ---- Request-URI construction (8.1.1.1, 19.1.1) ----

%% The transport, maddr, ttl and user parameters of the target URI, and an
%% unknown one, are all in the Request-URI as given.
%% req: R3261-398 R3261-401
request_uri_params_kept(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Uri = <<"sip:b@127.0.0.1:", (integer_to_binary(port(Sock)))/binary,
            ";transport=udp;maddr=127.0.0.1;ttl=1;user=phone;x-foo=bar">>,
    {ok, Ref} = chappe_sip:request(Uri, #{method => <<"OPTIONS">>,
                                          notify => self()}),
    {Opt, _} = recv(Sock, {method, <<"OPTIONS">>}, 3000),
    [Line | _] = binary:split(Opt, <<"\r\n">>),
    ?assertEqual(<<"OPTIONS ", Uri/binary, " SIP/2.0">>, Line),
    send(Sock, EP, response(Opt, 200, #{to_tag => tag()})),
    {ok, _} = chappe_sip_uac:await_response(Ref, 3000).

%% A target that cannot make a valid Request-URI (no host) is refused
%% locally: an error for the app, nothing on the wire.
%% req: R3261-407
invalid_uri_not_sent(Config) ->
    Sock = ?config(sock, Config),
    R = chappe_sip:request(<<"sip:b@">>, #{method => <<"OPTIONS">>,
                                           notify => self()}),
    ct:log("~p", [R]),
    Result = case R of
                 {error, _} -> R;
                 {ok, Ref} -> chappe_sip_uac:await_response(Ref, 3000)
             end,
    ct:log("result: ~p", [Result]),
    ?assertMatch({error, _}, Result),
    recv_none(Sock, any, 1000).

%% ---- not-applicable headers, redirects, 503 (8.1.3, 20, 21.5.4) ----

%% A 200 carrying Route, Max-Forwards and Proxy-Require (not applicable
%% to a response) still sets up the call: the UAC ignores them. This is the
%% UAC half of R3261-419, a deviation row: nta puts Record-Route in its
%% stateless 400s.
uac_ignores_na_headers(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv, 200, #{
        to_tag => tag(), body => sdp(),
        headers => [{<<"Route">>, <<"<sip:nowhere.invalid;lr>">>},
                    {<<"Max-Forwards">>, <<"0">>},
                    {<<"Proxy-Require">>, <<"x-unknown">>},
                    {<<"Contact">>, <<"<", (callee(Sock))/binary, ">">>}]})),
    {ok, D} = chappe_sip_uac:await(Ref, 3000),
    {Ack, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    ?assertEqual([], hdrs(<<"route">>, Ack)),
    hang_up(Sock, EP, D).

%% A 302 Contact without an expiration is used for that call only: the
%% next call to the original URI goes to it, not to the old Contact.
%% req: R3261-478
redirect_not_cached(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Moved = <<"sip:moved@127.0.0.1:", (integer_to_binary(port(Sock)))/binary>>,
    Opts = #{local_sdp => sdp(), follow_redirects => true, notify => self()},
    {ok, Ref1} = chappe_sip_uac:start(callee(Sock), Opts),
    {Inv1, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv1, 302, #{
        to_tag => tag(),
        headers => [{<<"Contact">>, <<"<", Moved/binary, ">">>}]})),
    {Inv2, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(Moved, uri(Inv2)),
    D1 = answer(Sock, EP, Inv2, Ref1),
    hang_up(Sock, EP, D1),
    {ok, Ref2} = chappe_sip_uac:start(callee(Sock), Opts),
    {Inv3, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(callee(Sock), uri(Inv3)),
    D2 = answer(Sock, EP, Inv3, Ref2),
    hang_up(Sock, EP, D2).

%% A 503 without Retry-After is a failure like a 500: the app gets the
%% 503 and the request is not sent again.
%% req: R3261-509
service_unavailable_no_retry(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    {ok, Ref} = chappe_sip_uac:start(callee(Sock), #{local_sdp => sdp(),
                                                     notify => self()}),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    send(Sock, EP, response(Inv, 503, #{to_tag => tag()})),
    ?assertMatch({error, #chappe_sip_error{status = 503}},
                 chappe_sip_uac:await(Ref, 3000)),
    {_, _} = recv(Sock, {method, <<"ACK">>}, 3000),
    recv_none(Sock, {method, <<"INVITE">>}, 2000).

%% A call asking for session privacy (Privacy: session) still carries its
%% SDP in the clear: application/sdp, a body that starts v=0 (RFC 3323
%% 4.2).
%% req: R3323-06
session_privacy_sdp_clear(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    Call = async(fun() ->
        chappe_sip:create_uac(callee(Sock), #{
            local_sdp => sdp(), timeout => 5000,
            headers => [{<<"Privacy">>, <<"session">>}]})
    end),
    {Inv, _} = recv(Sock, {method, <<"INVITE">>}, 3000),
    ?assertEqual(<<"session">>, hdr(<<"privacy">>, Inv)),
    ?assertEqual(<<"application/sdp">>, hdr(<<"content-type">>, Inv)),
    ?assertEqual(undefined, hdr(<<"content-encoding">>, Inv)),
    ?assertEqual(sdp(), body(Inv)),
    ?assertMatch(<<"v=0\r\n", _/binary>>, body(Inv)),
    send(Sock, EP, response(Inv, 486, #{to_tag => tag()})),
    ?assertMatch({error, #chappe_sip_error{status = 486}}, await(Call)).

%% the early dialog handle the next tagged provisional formed
early_dialog(Ref) ->
    receive {chappe_sip_uac, Ref, {early_dialog, D}} -> D
    after 3000 -> ct:fail(no_early_dialog)
    end.

%% a request the callee sends in the dialog its response Resp formed
callee_request(Sock, Method, Inv, Resp, CSeq, Opts) ->
    request(Method, addr_uri(hdr(<<"contact">>, Inv)),
            maps:merge(#{port => port(Sock),
                         call_id => hdr(<<"call-id">>, Inv),
                         from => addr(hdr(<<"to">>, Resp)),
                         from_tag => to_tag(Resp),
                         to => addr(hdr(<<"from">>, Inv)),
                         to_tag => from_tag(Inv), cseq => CSeq}, Opts)).

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
