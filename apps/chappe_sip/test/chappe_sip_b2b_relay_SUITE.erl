%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% B2BUA relay over real SIP on loopback.
%%
%% A gen_udp caller (leg A) calls the app, which bridges it with
%% create_b2bua/4 and relay/1 to a gen_udp callee (leg B). The cases cover
%% what the relay carries across the legs once the call is up (re-INVITE,
%% UPDATE, glare, BYE Reason) and while it is ringing (early media, 100rel,
%% CANCEL Reason), and what each leg answers on its own (session refreshes).
-module(chappe_sip_b2b_relay_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([reinvite_a_to_b/1, reinvite_b_to_a/1, update_relayed/1,
         reinvite_failure_relayed/1, glare_491_on_crossing_reinvite/1,
         glare_491_relayed/1, second_reinvite_500/1,
         refresh_answered_per_leg/1, session_timers_per_leg/1,
         early_media_relayed/1, reliable_1xx_each_leg/1,
         reliable_1xx_prack_after_2xx/1, require_100rel_forces_reliable/1, proxy_response_headers_named/1,
         proxy_response_headers_all/1, bye_reason_a_to_b/1,
         bye_reason_b_to_a/1, cancel_reason_relayed/1,
         reinvite_b_right_after_ack/1, bye_b_right_after_ack/1]).
-export([rewrite_sdp_offer_answer/1, rewrite_sdp_two_arity/1,
         rewrite_sdp_reject/1, anchor_call_and_reoffers/1,
         anchor_rejected_reoffer_restores/1, hold_events/1,
         offerless_reinvite_a/1, offerless_reinvite_b/1,
         set_media_anchor_and_back/1, set_media_busy/1,
         early_update_a_to_b/1, early_update_b_to_a/1]).

all() ->
    [reinvite_a_to_b, reinvite_b_to_a, update_relayed,
     reinvite_failure_relayed, glare_491_on_crossing_reinvite,
     glare_491_relayed, second_reinvite_500, refresh_answered_per_leg,
     session_timers_per_leg, early_media_relayed, reliable_1xx_each_leg,
     reliable_1xx_prack_after_2xx, require_100rel_forces_reliable,
     proxy_response_headers_named,
     proxy_response_headers_all, bye_reason_a_to_b, bye_reason_b_to_a,
     cancel_reason_relayed, reinvite_b_right_after_ack,
     bye_b_right_after_ack,
     rewrite_sdp_offer_answer, rewrite_sdp_two_arity, rewrite_sdp_reject,
     anchor_call_and_reoffers, anchor_rejected_reoffer_restores, hold_events,
     offerless_reinvite_a, offerless_reinvite_b, set_media_anchor_and_back,
     set_media_busy, early_update_a_to_b, early_update_b_to_a].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = case whereis(b2b_test_rtpe) of
            undefined -> ok;
            Rtpe -> unregister(b2b_test_rtpe), chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = sys:remove(chappe_sip_engine, b2b_hold),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

-define(UA, chappe_sip_test_ua).

%% ---- in-dialog relay ----

%% A's re-INVITE with a new offer reaches B with that offer; B's answer comes
%% back in A's 2xx and each leg gets its own ACK.
%% req: R3261-238 R3261-239 R3261-14.2-1
reinvite_a_to_b(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        tell(b_acked)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D#{invite_cseq := maps:get(seq, ?UA:cseq(Re))}, EP),
        tell({a_200, R})
    end),
    Re = got(b_reinvite),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(Re)),
    R = got(a_200),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"1">>), ?UA:body(R)),
    ?assertEqual(<<"application/sdp">>, ?UA:hdr(R, <<"content-type">>)),
    ok = ?UA:expect(b_acked).

%% The same from B to A.
%% req: R3261-238 R3261-239 R3261-14.2-1
reinvite_b_to_a(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D#{invite_cseq := maps:get(seq, ?UA:cseq(Re))}, EP),
        tell({b_200, R})
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"caller">>, <<"1">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        tell(a_acked)
    end),
    Re = got(a_reinvite),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"1">>), ?UA:body(Re)),
    R = got(b_200),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(R)),
    ok = ?UA:expect(a_acked).

%% An UPDATE with a new offer is relayed as an UPDATE and its answer comes
%% back in the 2xx.
%% req: R3311-009 R3311-010 R3311-5.2-1
update_relayed(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {U, S} = ?UA:recv_req(Sock, <<"UPDATE">>),
        tell({b_update, U}),
        ?UA:send(Sock, S, ?UA:resp(U, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {U, _} = ?UA:in_dialog(D, <<"UPDATE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, U),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    U = got(b_update),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(U)),
    R = got(a_200),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"1">>), ?UA:body(R)).

%% B refuses the relayed re-INVITE: A gets the same status.
%% req: R3261-233 R3261-14.1-1
reinvite_failure_relayed(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S, ?UA:resp(Re, 488, <<"Not Acceptable Here">>, <<>>, [], <<>>))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_final, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual(488, ?UA:status(got(a_final))).

%% A's re-INVITE is pending on B when B sends its own: B gets 491 (we have
%% an INVITE in progress toward it), then A still gets B's answer.
%% req: R3261-237 R3261-228
glare_491_on_crossing_reinvite(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        {Mine, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)),
        ?UA:send(Sock, EP, Mine),
        tell({b_final, ?UA:recv_any(Sock, 6000)}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"2">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    ?assertEqual(491, ?UA:status(got(b_final))),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"2">>), ?UA:body(got(a_200))).

%% B answers the relayed re-INVITE 491: A gets 491 and retries later.
%% req: R3261-14.1-1
glare_491_relayed(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S, ?UA:resp(Re, 491, <<"Request Pending">>, <<>>, [], <<>>))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_final, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual(491, ?UA:status(got(a_final))).

%% A second re-INVITE from A while its first is still unanswered: 500 with
%% Retry-After between 0 and 10.
%% req: R3261-236
second_reinvite_500(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        timer:sleep(1500),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re1, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re1),
        timer:sleep(300),
        {Re2, _} = ?UA:in_dialog(D1, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"2">>)),
        ?UA:send(Sock, EP, Re2),
        tell({a_second, ?UA:recv_any(Sock, 6000)})
    end),
    R = got(a_second),
    ?assertEqual(500, ?UA:status(R)),
    RA = binary_to_integer(hd(binary:split(?UA:hdr(R, <<"retry-after">>), <<" ">>))),
    ?assert(RA >= 0 andalso RA =< 10).

%% A re-INVITE with the unchanged SDP (same o= version) and an UPDATE
%% without a body are session refreshes: the A leg answers them on its own
%% with its current SDP; B sees nothing.
%% req: R4028-26 R3261-238 R3311-009 R4028-4-2
refresh_answered_per_leg(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 1500),
        ok = ?UA:no_req(Sock, <<"UPDATE">>, 100),
        tell(b_quiet)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>)),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D1, EP),
        {U, _} = ?UA:in_dialog(D1, <<"UPDATE">>, [], <<>>),
        ?UA:send(Sock, EP, U),
        tell({a_200s, R, ?UA:recv_status(Sock, 200)})
    end),
    {R, U} = got2(a_200s),
    %% the A leg's SDP is what A got in the first 2xx: B's answer
    ?assertEqual(?UA:sdp(<<"callee">>), ?UA:body(R)),
    ?assertEqual(<<>>, ?UA:body(U)),
    ok = ?UA:expect(b_quiet).

%% Each leg runs its own session timer: A refreshes the A leg (3 s,
%% refresher=uac) and is answered locally; the app refreshes the B leg at
%% half of B's 4 s by an UPDATE naming B's interval.
%% req: R4028-31 R4028-37 R4028-38 R4028-4-3
session_timers_per_leg(_Config) ->
    %% min_se lets the test use second-long intervals on both legs
    {EP, CP} = setup(#{min_se => 1}),
    callee(CP, #{headers => [{<<"Session-Expires">>, <<"4;refresher=uac">>},
                             {<<"Require">>, <<"timer">>},
                             {<<"Allow">>, <<"INVITE, ACK, BYE, UPDATE">>}]},
           fun(Sock, _D) ->
        T0 = now_ms(),
        {U, S} = ?UA:recv_req(Sock, <<"UPDATE">>, 6000),
        tell({b_update, U, now_ms() - T0}),
        ?UA:send(Sock, S, ?UA:resp(U, 200, <<"OK">>, <<>>,
                                   [{<<"Session-Expires">>, <<"4;refresher=uac">>}], <<>>))
    end),
    caller(EP, #{headers => [{<<"Supported">>, <<"timer">>},
                             {<<"Session-Expires">>, <<"3">>}]},
           fun(Sock, D) ->
        timer:sleep(1000),
        {U, _} = ?UA:in_dialog(D, <<"UPDATE">>,
                               [{<<"Supported">>, <<"timer">>},
                                {<<"Session-Expires">>, <<"3;refresher=uac">>}], <<>>),
        ?UA:send(Sock, EP, U),
        R = ?UA:recv_status(Sock, 200),
        %% the A leg's first expiry (2 s after its INVITE) passes: no BYE
        ok = ?UA:no_req(Sock, <<"BYE">>, 1500),
        tell({a_refreshed, R})
    end),
    {U, Dt} = got2(b_update),
    ?assertEqual(<<"4;refresher=uac">>, ?UA:hdr(U, <<"session-expires">>)),
    ?assert(Dt >= 1500 andalso Dt < 3500),
    R = got(a_refreshed),
    ?assertEqual(<<"3;refresher=uac">>, ?UA:hdr(R, <<"session-expires">>)),
    ?assertEqual([<<"timer">>], ?UA:hdrs(R, <<"require">>)).

%% ---- while ringing ----

%% B's 183 with SDP reaches A with the same body. It is not reliable but
%% carries A's To-tag, so it sets up an early dialog and has our Contact.
%% req: R3261-13.3.1.1-1 R3261-124
early_media_relayed(_Config) ->
    {EP, CP} = setup_raw(#{}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 183, <<"Session Progress">>, Tag,
                                     [contact(Sock)], ?UA:sdp(<<"early">>))),
        timer:sleep(300),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag()}),
        ?UA:send(Sock, EP, Inv),
        R183 = ?UA:recv_status(Sock, 183),
        R200 = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        tell({a_183, R183, R200})
    end),
    {R183, R200} = got2(a_183),
    ?assertEqual(?UA:sdp(<<"early">>), ?UA:body(R183)),
    ?assertEqual(<<"application/sdp">>, ?UA:hdr(R183, <<"content-type">>)),
    ?assertEqual(undefined, ?UA:hdr(R183, <<"rseq">>)),
    ?assertMatch(<<"<sip:", _/binary>>, ?UA:hdr(R183, <<"contact">>)),
    ?assertEqual(?UA:to_tag(R183), ?UA:to_tag(R200)).

%% A and B both support 100rel. B's reliable 183 is PRACKed on the B leg by
%% the app; A gets its own reliable 183 (RSeq, Require: 100rel, the SDP)
%% and the 2xx waits for A's PRACK since the 183 carried SDP.
%% req: R3262-001 R3262-010 R3262-014 R3262-025 R3262-049 R3262-033 R3262-029
reliable_1xx_each_leg(_Config) ->
    {EP, CP} = setup_raw(#{}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_invite, Inv}),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 183, <<"Session Progress">>, Tag,
                                     [contact(Sock), {<<"Require">>, <<"100rel">>},
                                      {<<"RSeq">>, <<"7">>}], ?UA:sdp(<<"early">>))),
        {Pr, PS} = ?UA:recv_req(Sock, <<"PRACK">>),
        tell({b_prack, Pr}),
        ?UA:send(Sock, PS, ?UA:resp(Pr, 200, <<"OK">>, <<>>, [], <<>>)),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Call = ?UA:callid(),
        FT = ?UA:tag(),
        Inv = ?UA:invite(Sock, EP, #{call_id => Call, from_tag => FT,
                                     headers => [{<<"Supported">>, <<"100rel">>}]}),
        ?UA:send(Sock, EP, Inv),
        R183 = ?UA:recv_status(Sock, 183),
        %% the 2xx must not come before our PRACK
        Early = receive {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>> = B} -> B
                after 800 -> none end,
        Pr = prack(Sock, Inv, R183),
        ?UA:send(Sock, EP, Pr),
        R200 = recv_invite_2xx(Sock),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        tell({a_side, R183, Early, R200})
    end),
    BInv = got(b_invite),
    ?assert(lists:member(<<"100rel">>, tokens(?UA:hdrs(BInv, <<"supported">>)))),
    BPr = got(b_prack),
    ?assertEqual(<<"7 1 INVITE">>, ?UA:hdr(BPr, <<"rack">>)),
    receive
        {a_side, R183, Early, R200} ->
            ?assertEqual(none, Early),
            ?assertNotEqual(undefined, ?UA:hdr(R183, <<"rseq">>)),
            ?assert(lists:member(<<"100rel">>, tokens(?UA:hdrs(R183, <<"require">>)))),
            ?assertEqual(?UA:sdp(<<"early">>), ?UA:body(R183)),
            %% B answered in its 183; the different SDP of its 200 is
            %% ignored (RFC 3261 13.2.1), so A's 200 repeats the answer
            ?assertEqual(?UA:sdp(<<"early">>), ?UA:body(R200))
    after 10000 -> ct:fail(no_a_side)
    end.

%% A reliable 1xx without SDP does not hold the 2xx back, and A's PRACK
%% arriving after the 2xx is still answered 200 (the engine used to free
%% the PRACK callback's context with the INVITE and crash the VM here).
%% req: R3262-024 R3262-026
reliable_1xx_prack_after_2xx(_Config) ->
    {EP, CP} = setup_raw(#{}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag,
                                     [contact(Sock), {<<"Require">>, <<"100rel">>},
                                      {<<"RSeq">>, <<"1">>}], <<>>)),
        {Pr, PS} = ?UA:recv_req(Sock, <<"PRACK">>),
        ?UA:send(Sock, PS, ?UA:resp(Pr, 200, <<"OK">>, <<>>, [], <<>>)),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     headers => [{<<"Supported">>, <<"100rel">>}]}),
        ?UA:send(Sock, EP, Inv),
        R180 = ?UA:recv_status(Sock, 180),
        R200 = recv_invite_2xx(Sock),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        ?UA:send(Sock, EP, prack(Sock, Inv, R180)),
        tell({a_side, R180, ?UA:recv_any(Sock, 4000)})
    end),
    {R180, PrackResp} = got2(a_side),
    ?assertNotEqual(undefined, ?UA:hdr(R180, <<"rseq">>)),
    ?assertEqual(200, ?UA:status(PrackResp)),
    ?assertEqual(<<"PRACK">>, maps:get(method, ?UA:cseq(PrackResp))).

%% A requires 100rel: every provisional it gets is reliable, even when B's
%% was not.
%% req: R3262-002 R3262-010
require_100rel_forces_reliable(_Config) ->
    {EP, CP} = setup_raw(#{}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag, [contact(Sock)], <<>>)),
        timer:sleep(1500),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     headers => [{<<"Require">>, <<"100rel">>}]}),
        ?UA:send(Sock, EP, Inv),
        R180 = ?UA:recv_status(Sock, 180),
        ?UA:send(Sock, EP, prack(Sock, Inv, R180)),
        tell({a_180, R180})
    end),
    R180 = got(a_180),
    ?assertNotEqual(undefined, ?UA:hdr(R180, <<"rseq">>)),
    ?assert(lists:member(<<"100rel">>, tokens(?UA:hdrs(R180, <<"require">>)))).

%% ---- headers ----

%% proxy_response_headers names headers copied from B's 2xx to A's.
%% req: R3261-8.2.6-1
proxy_response_headers_named(_Config) ->
    {EP, CP} = setup(#{proxy_response_headers => [<<"X-Custom">>]}),
    callee(CP, #{headers => [{<<"X-Custom">>, <<"foo">>},
                             {<<"X-Other">>, <<"bar">>}]}, fun(_Sock, _D) -> ok end),
    R = caller_2xx(EP, #{}),
    ?assertEqual(<<"foo">>, ?UA:hdr(R, <<"x-custom">>)),
    ?assertEqual(undefined, ?UA:hdr(R, <<"x-other">>)).

%% all copies B's headers except the ones that belong to one leg: the
%% dialog, the session timer and the extensions in force.
%% req: R3261-8.2.6-1 R4028-4-3
proxy_response_headers_all(_Config) ->
    {EP, CP} = setup(#{proxy_response_headers => all}),
    callee(CP, #{headers => [{<<"X-Custom">>, <<"foo">>},
                             {<<"Session-Expires">>, <<"1800;refresher=uac">>},
                             {<<"Require">>, <<"timer">>}]}, fun(_Sock, _D) -> ok end),
    R = caller_2xx(EP, #{}),
    ?assertEqual(<<"foo">>, ?UA:hdr(R, <<"x-custom">>)),
    ?assertEqual(undefined, ?UA:hdr(R, <<"session-expires">>)),
    ?assertEqual([], ?UA:hdrs(R, <<"require">>)),
    ?assertEqual(1, length(?UA:hdrs(R, <<"contact">>))).

%% ---- Reason (RFC 3326) ----

%% A's BYE Reason goes out on B's BYE.
%% req: R3326-01 R3326-03 R3326-2-1
bye_reason_a_to_b(_Config) ->
    {EP, CP} = setup(#{}),
    Reason = <<"Q.850;cause=16;text=\"Normal call clearing\"">>,
    callee(CP, fun(Sock, _D) ->
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({b_bye, Bye})
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [{<<"Reason">>, Reason}], <<>>),
        ?UA:send(Sock, EP, Bye),
        _ = ?UA:recv_status(Sock, 200)
    end),
    ?assertEqual([Reason], ?UA:hdrs(got(b_bye), <<"reason">>)),
    ok = ?UA:expect({relay_done, {done, a_bye}}).

%% B's BYE Reason goes out on A's BYE.
%% req: R3326-01 R3326-2-1
bye_reason_b_to_a(_Config) ->
    {EP, CP} = setup(#{}),
    Reason = <<"SIP;cause=480;text=\"Temporarily Unavailable\"">>,
    callee(CP, fun(Sock, D) ->
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [{<<"Reason">>, Reason}], <<>>),
        ?UA:send(Sock, EP, Bye),
        _ = ?UA:recv_status(Sock, 200)
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({a_bye, Bye})
    end),
    ?assertEqual([Reason], ?UA:hdrs(got(a_bye), <<"reason">>)),
    ok = ?UA:expect({relay_done, {done, b_bye}}).

%% A's CANCEL Reason goes out on the CANCEL to B.
%% req: R3326-02
cancel_reason_relayed(_Config) ->
    {EP, CP} = setup_raw(#{}),
    Reason = <<"SIP;cause=200;text=\"Call completed elsewhere\"">>,
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag, [], <<>>)),
        {Cancel, CS} = ?UA:recv_req(Sock, <<"CANCEL">>),
        ?UA:send(Sock, CS, ?UA:resp(Cancel, 200, <<"OK">>, Tag, [], <<>>)),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 487, <<"Request Terminated">>, Tag, [], <<>>)),
        tell({b_cancel, Cancel})
    end),
    ?UA:peer(0, fun(Sock) ->
        Br = ?UA:branch(),
        Call = ?UA:callid(),
        FT = ?UA:tag(),
        Inv = ?UA:invite(Sock, EP, #{call_id => Call, from_tag => FT, branch => Br}),
        ?UA:send(Sock, EP, Inv),
        _ = ?UA:recv_status(Sock, 180),
        ?UA:send(Sock, EP, cancel(Inv, Reason)),
        _ = ?UA:recv_status(Sock, 487)
    end),
    ?assertEqual([Reason], ?UA:hdrs(got(b_cancel), <<"reason">>)).

%% ---- B in-dialog right after its ACK ----

%% B's re-INVITE goes out the moment B has our ACK, while the B-leg UAC is
%% held right after sending it: the B dialog exists already, so the
%% re-INVITE is relayed to A rather than answered 481.
%% req: R3261-238 R3261-14.2-1
reinvite_b_right_after_ack(_Config) ->
    {EP, CP} = setup(#{}),
    hold_uac_after_ack(500),
    callee(CP, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_any(Sock, 6000),
        ?UA:ack(D#{invite_cseq := maps:get(seq, ?UA:cseq(Re))}, EP),
        tell({b_final, R})
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"caller">>, <<"1">>)))
    end),
    ok = ?UA:expect(uac_released),
    ?assertEqual(200, ?UA:status(got(b_final))),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"1">>), ?UA:body(got(a_reinvite))).

%% The same for B's BYE: A gets it with B's Reason.
%% req: R3326-01 R3326-2-1
bye_b_right_after_ack(_Config) ->
    {EP, CP} = setup(#{}),
    hold_uac_after_ack(500),
    Reason = <<"SIP;cause=480;text=\"Temporarily Unavailable\"">>,
    callee(CP, fun(Sock, D) ->
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [{<<"Reason">>, Reason}], <<>>),
        ?UA:send(Sock, EP, Bye),
        tell({b_final, ?UA:recv_any(Sock, 6000)})
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({a_bye, Bye})
    end),
    ok = ?UA:expect(uac_released),
    ?assertEqual(200, ?UA:status(got(b_final))),
    ?assertEqual([Reason], ?UA:hdrs(got(a_bye), <<"reason">>)),
    ok = ?UA:expect({relay_done, {done, b_bye}}).

%% ---- SDP hook (offer / answer aware) ----

%% A 3-arity rewrite_sdp sees which leg sent the SDP and whether it is an
%% offer or an answer.
%% req: R3264-8-1
rewrite_sdp_offer_answer(_Config) ->
    Rw = fun(Leg, Kind, Sdp) ->
                 <<Sdp/binary, "a=x-", (atom_to_binary(Leg))/binary, "-",
                   (atom_to_binary(Kind))/binary, "\r\n">>
         end,
    {EP, CP} = setup(#{rewrite_sdp => Rw}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    ?assert(has(?UA:body(got(b_reinvite)), <<"a=x-a-offer">>)),
    ?assert(has(?UA:body(got(a_200)), <<"a=x-b-answer">>)).

%% The older fun(Leg, Sdp) still works.
%% req: R3264-8-1
rewrite_sdp_two_arity(_Config) ->
    Rw = fun(Leg, Sdp) -> <<Sdp/binary, "a=x-", (atom_to_binary(Leg))/binary, "\r\n">> end,
    {EP, CP} = setup(#{rewrite_sdp => Rw}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    ?assert(has(?UA:body(got(b_reinvite)), <<"a=x-a\r\n">>)),
    ?assert(has(?UA:body(got(a_200)), <<"a=x-b\r\n">>)).

%% The hook refuses an offer: the offering leg gets the code, the other
%% leg sees nothing.
%% req: R3261-233
rewrite_sdp_reject(_Config) ->
    Rw = fun(a, offer, Sdp) ->
                 case has(Sdp, <<"o=caller 1 1 ">>) of
                     true -> {reject, 488};
                     false -> Sdp
                 end;
            (_, _, Sdp) -> Sdp
         end,
    {EP, CP} = setup(#{rewrite_sdp => Rw}),
    callee(CP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 1500),
        tell(b_quiet)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_final, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual(488, ?UA:status(got(a_final))),
    ok = ?UA:expect(b_quiet).

%% ---- built-in media anchor ----

%% media => anchor: the initial offer and answer and every re-offer, from
%% either leg, go through rtpengine; an offer from B is the callee's (its
%% tag is rtpengine's from-tag).
%% req: R3264-8-1 R3261-14.2-1
anchor_call_and_reoffers(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_invite, Inv}),
        Tag = <<"btag">>,
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D1, EP),
        tell({b_200, R}),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => <<"atag">>}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP),
        tell({a_200, R}),
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"caller">>, <<"1">>))),
        timer:sleep(infinity)
    end),
    ?assert(has(?UA:body(got(b_invite)), <<"a=rtpe-offer:atag">>)),
    ?assert(has(?UA:body(got(a_200)), <<"a=rtpe-answer:btag">>)),
    ?assert(has(?UA:body(got(a_reinvite)), <<"a=rtpe-offer:btag">>)),
    ?assert(has(?UA:body(got(b_200)), <<"a=rtpe-answer:atag">>)),
    Offers = [C || {rtpe_cmd, #{<<"command">> := <<"offer">>} = C} <- drain()],
    ?assertMatch([_, _], Offers).

%% B refuses an anchored re-offer: A gets B's status, and rtpengine gets
%% B's last good SDP as the answer, so the next offer goes through.
%% req: R3261-233 R3264-8-1
anchor_rejected_reoffer_restores(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S, ?UA:resp(Re, 488, <<"Not Acceptable Here">>, <<>>, [], <<>>)),
        {Re2, S2} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S2, ?UA:resp(Re2, 200, <<"OK">>, <<>>, [contact(Sock)],
                                    ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_first, ?UA:recv_any(Sock, 6000)}),
        {Re2, _} = ?UA:in_dialog(D1, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"2">>)),
        ?UA:send(Sock, EP, Re2),
        tell({a_second, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual(488, ?UA:status(got(a_first))),
    ?assertEqual(200, ?UA:status(got(a_second))),
    Cmds = [maps:get(<<"command">>, C) || {rtpe_cmd, C} <- drain(),
                                          maps:is_key(<<"sdp">>, C)],
    %% initial offer/answer, the refused re-offer and its restoring answer,
    %% then the second re-offer and its answer
    ?assertEqual([<<"offer">>, <<"answer">>, <<"offer">>, <<"answer">>,
                  <<"offer">>, <<"answer">>], Cmds).

%% A re-offer whose streams stop receiving puts its leg on hold; the
%% notify process sees hold, then unhold.
%% req: R3264-8.4-1
hold_events(_Config) ->
    {EP, CP} = setup(#{notify => self()}),
    callee(CP, fun(Sock, _D) ->
        lists:foreach(fun(V) ->
            {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
            ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                       ?UA:sdp(<<"callee">>, V)))
        end, [<<"1">>, <<"2">>])
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [],
                                 sdp_dir(<<"caller">>, <<"1">>, <<"sendonly">>)),
        ?UA:send(Sock, EP, Re),
        _ = ?UA:recv_status(Sock, 200),
        {Re2, _} = ?UA:in_dialog(D1, <<"INVITE">>, [],
                                 sdp_dir(<<"caller">>, <<"2">>, <<"sendrecv">>)),
        ?UA:send(Sock, EP, Re2),
        _ = ?UA:recv_status(Sock, 200)
    end),
    #{b2b := {_, Ref}} = got(legs),
    ok = ?UA:expect({chappe_sip_b2b, Ref, {hold, a}}),
    ok = ?UA:expect({chappe_sip_b2b, Ref, {unhold, a}}).

%% ---- offerless re-INVITE ----

%% A's re-INVITE without an offer goes to B without one; B's offer comes
%% back in A's 2xx, and the answer in A's ACK goes on in B's ACK.
%% req: R3261-14.2-2
offerless_reinvite_a(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>))),
        {Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        tell({b_ack, Ack})
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], <<>>),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        tell({a_200, R}),
        ?UA:send(Sock, EP, ack_with(D1, ?UA:sdp(<<"caller">>, <<"1">>)))
    end),
    ?assertEqual(<<>>, ?UA:body(got(b_reinvite))),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"1">>), ?UA:body(got(a_200))),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(got(b_ack))).

%% The same from B to A.
%% req: R3261-14.2-2
offerless_reinvite_b(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(D, <<"INVITE">>, [], <<>>),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        tell({b_200, R}),
        ?UA:send(Sock, EP, ack_with(D1, ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"caller">>, <<"1">>))),
        {Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        tell({a_ack, Ack})
    end),
    ?assertEqual(<<>>, ?UA:body(got(a_reinvite))),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(got(b_200))),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"1">>), ?UA:body(got(a_ack))).

%% ---- set_media/2 ----

%% A direct call goes anchored: A gets an offerless re-INVITE, its offer
%% reaches B through rtpengine, and A's ACK carries B's anchored answer.
%% Then back to direct, which releases the rtpengine session.
%% req: R3261-14.2-2
set_media_anchor_and_back(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        lists:foreach(fun(V) ->
            {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
            tell({b_reinvite, Re}),
            ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                       ?UA:sdp(<<"callee">>, V))),
            {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
        end, [<<"1">>, <<"2">>])
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        lists:foreach(fun(V) ->
            {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
            ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                       ?UA:sdp(<<"caller">>, V))),
            {Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
            tell({a_ack, Re, Ack})
        end, [<<"1">>, <<"2">>])
    end),
    #{b2b := B2b} = got(legs),
    ?assertMatch(#{media := direct}, chappe_sip_b2b:info(B2b)),
    ok = chappe_sip_b2b:set_media(B2b, anchor),
    {Re1, Ack1} = got2(a_ack),
    ?assertEqual(<<>>, ?UA:body(Re1)),
    ?assert(has(?UA:body(got(b_reinvite)), <<"a=rtpe-offer:">>)),
    ?assert(has(?UA:body(Ack1), <<"a=rtpe-answer:">>)),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)),
    ok = chappe_sip_b2b:set_media(B2b, direct),
    {_, Ack2} = got2(a_ack),
    B2 = ?UA:body(got(b_reinvite)),
    ?assertNot(has(B2, <<"a=rtpe-">>)),
    ?assertEqual(?UA:sdp(<<"callee">>, <<"2">>), ?UA:body(Ack2)),
    ?assertMatch(#{media := direct, session := undefined},
                 chappe_sip_b2b:info(B2b)),
    ?assert(lists:any(fun({rtpe_cmd, C}) ->
                              maps:get(<<"command">>, C) =:= <<"delete">>
                      end, drain())).

%% While an offer of the call is pending, set_media/2 is busy.
%% req: R3261-14.2-1
set_media_busy(_Config) ->
    {EP, CP} = setup(#{}),
    Callee = callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell(b_got_reinvite),
        receive go -> ok after 5000 -> ok end,
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                   ?UA:sdp(<<"callee">>, <<"1">>)))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, Re),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    #{b2b := B2b} = got(legs),
    ok = ?UA:expect(b_got_reinvite),
    ?assertEqual({error, busy}, chappe_sip_b2b:set_media(B2b, anchor)),
    Callee ! go,
    _ = got(a_200).

%% ---- UPDATE while B rings (RFC 3311 5.1) ----

%% A's UPDATE in its early dialog reaches B's early dialog with A's offer,
%% and B's answer comes back in A's 2xx.
%% req: R3311-5.1-1
early_update_a_to_b(_Config) ->
    {EP, CP} = setup_raw(#{}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 183, <<"Session Progress">>, Tag,
                                     [contact(Sock)], ?UA:sdp(<<"early">>))),
        {U, US} = ?UA:recv_req(Sock, <<"UPDATE">>),
        tell({b_update, U}),
        ?UA:send(Sock, US, ?UA:resp(U, 200, <<"OK">>, <<>>, [contact(Sock)],
                                    ?UA:sdp(<<"early">>, <<"1">>))),
        receive go -> ok after 5000 -> ok end,
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"early">>, <<"1">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag()}),
        ?UA:send(Sock, EP, Inv),
        R183 = ?UA:recv_status(Sock, 183),
        D = ?UA:dialog_from_2xx(Sock, Inv, R183),
        {U, _} = ?UA:in_dialog(D, <<"UPDATE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)),
        ?UA:send(Sock, EP, U),
        tell({a_update_200, ?UA:recv_status(Sock, 200)}),
        R200 = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        timer:sleep(infinity)
    end),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(got(b_update))),
    R = got(a_update_200),
    ?assertEqual(<<"UPDATE">>, maps:get(method, ?UA:cseq(R))),
    ?assertEqual(?UA:sdp(<<"early">>, <<"1">>), ?UA:body(R)).

%% B's UPDATE in its early dialog reaches A's early dialog, A's answer
%% comes back to B, and A's dialog numbers its later requests past it.
%% req: R3311-5.1-1
early_update_b_to_a(_Config) ->
    {EP, CP} = setup_raw(#{}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 183, <<"Session Progress">>, Tag,
                                     [contact(Sock)], ?UA:sdp(<<"early">>))),
        D = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        timer:sleep(300),
        {U, D1} = ?UA:in_dialog(D, <<"UPDATE">>, [], ?UA:sdp(<<"early">>, <<"1">>)),
        ?UA:send(Sock, EP, U),
        tell({b_update_200, ?UA:recv_status(Sock, 200)}),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"early">>, <<"1">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {Re, _} = ?UA:in_dialog(D1, <<"INVITE">>, [], ?UA:sdp(<<"early">>, <<"2">>)),
        ?UA:send(Sock, EP, Re),
        _ = ?UA:recv_status(Sock, 200),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag()}),
        ?UA:send(Sock, EP, Inv),
        _ = ?UA:recv_status(Sock, 183),
        {U, US} = ?UA:recv_req(Sock, <<"UPDATE">>),
        tell({a_update, U}),
        ?UA:send(Sock, US, ?UA:resp(U, 200, <<"OK">>, <<>>, [contact(Sock)],
                                    ?UA:sdp(<<"caller">>, <<"1">>))),
        R200 = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        {Re, RS} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(Sock, RS, ?UA:resp(Re, 200, <<"OK">>, <<>>, [contact(Sock)],
                                    ?UA:sdp(<<"caller">>, <<"2">>))),
        timer:sleep(infinity)
    end),
    U = got(a_update),
    ?assertEqual(?UA:sdp(<<"early">>, <<"1">>), ?UA:body(U)),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(got(b_update_200))),
    Re = got(a_reinvite),
    ?assert(maps:get(seq, ?UA:cseq(Re)) > maps:get(seq, ?UA:cseq(U))).

%% ---- helpers ----

setup(Opts) ->
    {EP, CP} = setup_raw(Opts),
    {EP, CP}.

%% the app bridges every INVITE to the callee port and relays
setup_raw(Opts) ->
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>}),
    Test = self(),
    register(b2b_relay_test, Test),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:create_b2bua(Req, Res, Callee, Opts) of
            {ok, Legs} ->
                Test ! {legs, Legs},
                Test ! b2b_up,
                Test ! {relay_done, chappe_sip_b2b:relay(Legs)};
            Err ->
                Test ! {b2b_result, Err}
        end
    end),
    {EP, CP}.

tell(Msg) -> b2b_relay_test ! Msg.

%% Widen the window a slow runner opens after the B-leg UAC sends its 2xx
%% ACK: the engine suspends the UAC fsm as it handles that send, and a
%% holder resumes it Ms later (then tells uac_released).
hold_uac_after_ack(Ms) ->
    Test = self(),
    Holder = spawn(fun() ->
        receive
            {hold, Pid, From, Ref} ->
                true = erlang:suspend_process(Pid),
                From ! {Ref, held},
                timer:sleep(Ms),
                true = erlang:resume_process(Pid),
                Test ! uac_released
        end
    end),
    Hold = fun
        (_, {in, {'$gen_call', {Pid, _},
                  {send_stateless, _, <<"ACK ", _/binary>>, _}}}, _) ->
            Ref = make_ref(),
            Holder ! {hold, Pid, self(), Ref},
            receive {Ref, held} -> done after 1000 -> done end;
        (St, _, _) ->
            St
    end,
    ok = sys:install(chappe_sip_engine, {b2b_hold, Hold, armed}).

got(Tag) ->
    receive {Tag, V} -> V after 10000 -> ct:fail({missing, Tag}) end.

got2(Tag) ->
    receive {Tag, V, W} -> {V, W} after 10000 -> ct:fail({missing, Tag}) end.

now_ms() -> erlang:monotonic_time(millisecond).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%% a fake rtpengine (chappe_sip_test_rtpe) the anchored cases go through
rtpe() ->
    register(b2b_test_rtpe, chappe_sip_test_rtpe:start(self())),
    ok.

drain() ->
    receive {rtpe_cmd, _} = C -> [C | drain()] after 200 -> [] end.

sdp_dir(Marker, Version, Dir) ->
    <<(?UA:sdp(Marker, Version))/binary, "a=", Dir/binary, "\r\n">>.

%% the ACK of an offerless re-INVITE's 2xx, carrying the answer (the
%% re-INVITE's CSeq number)
ack_with(#{cseq := N} = D, Body) ->
    {Ack, _} = ?UA:in_dialog(D#{cseq := N - 1}, <<"ACK">>, [], Body),
    Ack.

tokens(Values) ->
    [string:trim(T) || V <- Values, T <- binary:split(V, <<",">>, [global])].

contact(Sock) ->
    {<<"Contact">>, <<"<sip:peer@127.0.0.1:",
                      (integer_to_binary(?UA:lport(Sock)))/binary, ">">>}.

%% The callee (leg B): answers 200 with Headers, waits for the ACK, then
%% runs Fun(Sock, RawDialog).
callee(CP, Fun) -> callee(CP, #{}, Fun).

callee(CP, Opts, Fun) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag,
                                     [contact(Sock) | maps:get(headers, Opts, [])],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Fun(Sock, ?UA:dialog_from_invite(Sock, Inv, Tag, Src)),
        timer:sleep(infinity)
    end).

%% The caller (leg A): INVITEs the app, ACKs its 2xx, then runs
%% Fun(Sock, RawDialog).
caller(EP, Opts, Fun) ->
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     headers => maps:get(headers, Opts, [])}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Fun(Sock, D#{r2xx => R}),
        timer:sleep(infinity)
    end),
    ok = ?UA:expect(b2b_up).

%% The caller's 2xx, for header checks.
caller_2xx(EP, Opts) ->
    caller(EP, Opts, fun(_Sock, #{r2xx := R}) -> tell({caller_2xx, R}) end),
    got(caller_2xx).

%% PRACK for a reliable provisional of our INVITE
prack(Sock, InvBin, R1xx) ->
    P = integer_to_binary(?UA:lport(Sock)),
    {ok, I} = chappe_sip_msg:parse(InvBin),
    {ok, R} = chappe_sip_msg:parse(R1xx),
    RSeq = chappe_sip_msg:get(<<"rseq">>, R),
    iolist_to_binary(
      [<<"PRACK sip:app@127.0.0.1 SIP/2.0\r\n">>,
       <<"Via: SIP/2.0/UDP 127.0.0.1:">>, P, <<";rport;branch=">>, ?UA:branch(), <<"\r\n">>,
       <<"Max-Forwards: 70\r\n">>,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, I), <<"\r\n">>,
       <<"To: ">>, chappe_sip_msg:get(<<"to">>, R), <<"\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(I), <<"\r\n">>,
       <<"CSeq: 2 PRACK\r\n">>,
       <<"RAck: ">>, RSeq, <<" 1 INVITE\r\n">>,
       <<"Content-Length: 0\r\n\r\n">>]).

%% the INVITE's 2xx (the PRACK's own 200 is skipped)
recv_invite_2xx(Sock) ->
    R = ?UA:recv_status(Sock, 200),
    case maps:get(method, ?UA:cseq(R)) of
        <<"INVITE">> -> R;
        _ -> recv_invite_2xx(Sock)
    end.

%% CANCEL for an INVITE (same branch, CSeq number and To)
cancel(InvBin, Reason) ->
    {ok, I} = chappe_sip_msg:parse(InvBin),
    iolist_to_binary(
      [<<"CANCEL ">>, chappe_sip_msg:uri(I), <<" SIP/2.0\r\n">>,
       <<"Via: ">>, chappe_sip_msg:get(<<"via">>, I), <<"\r\n">>,
       <<"Max-Forwards: 70\r\n">>,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, I), <<"\r\n">>,
       <<"To: ">>, chappe_sip_msg:get(<<"to">>, I), <<"\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(I), <<"\r\n">>,
       <<"CSeq: 1 CANCEL\r\n">>,
       <<"Reason: ">>, Reason, <<"\r\n">>,
       <<"Content-Length: 0\r\n\r\n">>]).
