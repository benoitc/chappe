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
-include("chappe_sip.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    reinvite_a_to_b/1,
    reinvite_b_to_a/1,
    update_relayed/1,
    reinvite_failure_relayed/1,
    glare_491_on_crossing_reinvite/1,
    glare_491_relayed/1,
    second_reinvite_500/1,
    refresh_answered_per_leg/1,
    session_timers_per_leg/1,
    early_media_relayed/1,
    reliable_1xx_each_leg/1,
    reliable_1xx_prack_after_2xx/1,
    require_100rel_forces_reliable/1,
    proxy_response_headers_named/1,
    proxy_response_headers_all/1,
    bye_reason_a_to_b/1,
    bye_reason_b_to_a/1,
    cancel_reason_relayed/1,
    reinvite_b_right_after_ack/1,
    bye_b_right_after_ack/1
]).
-export([
    rewrite_sdp_offer_answer/1,
    rewrite_sdp_two_arity/1,
    rewrite_sdp_reject/1,
    anchor_call_and_reoffers/1,
    anchor_rejected_reoffer_restores/1,
    hold_events/1,
    offerless_reinvite_a/1,
    offerless_reinvite_b/1,
    set_media_anchor_and_back/1,
    set_media_busy/1,
    early_update_a_to_b/1,
    early_update_b_to_a/1,
    anchor_late_offer/1,
    nated_caller_reached_at_source/1
]).
-export([
    hangup_reason_both_legs/1,
    requests_surfaced/1,
    requests_default_answers/1,
    relay_info_forwarded/1,
    replace_b_anchored/1,
    replace_b_failure_keeps_b/1,
    replace_b_not_anchored/1,
    fork_anchored_per_branch/1,
    replace_b_aborted_when_call_ends/1,
    replace_b_dialog/1,
    replace_b_anchor_params/1,
    relay_async_outlives_handler/1,
    replace_b_keeps_a_ports/1,
    fork_replace_second_answers/1,
    fork_replace_late_2xx_gets_bye/1,
    fork_replace_all_busy/1,
    fork_replace_timer_c/1,
    fork_replace_caller_hangs_up/1,
    fork_replace_failed_then_replace/1,
    fork_replace_own_flags/1,
    fork_replace_own_flags_fail/1,
    fork_replace_late_offer/1,
    fork_replace_empty/1,
    fork_replace_offer_refused/1,
    fork_replace_offer_half_refused/1,
    fork_replace_hook_rejects/1,
    fork_replace_helper_dies/1,
    reinvite_helper_dies/1,
    replace_b_new_b_dies/1,
    info_follows_replace/1,
    replace_clears_hold/1,
    replace_b_bad_arguments/1,
    replace_b_failure_other_flags/1,
    replace_b_from/1,
    fork_replace_from/1,
    replace_b_dialog_keeps_from/1,
    replace_b_bad_from/1,
    replace_b_from_refused/1
]).

all() ->
    [
        reinvite_a_to_b,
        reinvite_b_to_a,
        update_relayed,
        reinvite_failure_relayed,
        glare_491_on_crossing_reinvite,
        glare_491_relayed,
        second_reinvite_500,
        refresh_answered_per_leg,
        session_timers_per_leg,
        early_media_relayed,
        reliable_1xx_each_leg,
        reliable_1xx_prack_after_2xx,
        require_100rel_forces_reliable,
        proxy_response_headers_named,
        proxy_response_headers_all,
        bye_reason_a_to_b,
        bye_reason_b_to_a,
        cancel_reason_relayed,
        reinvite_b_right_after_ack,
        bye_b_right_after_ack,
        rewrite_sdp_offer_answer,
        rewrite_sdp_two_arity,
        rewrite_sdp_reject,
        anchor_call_and_reoffers,
        anchor_rejected_reoffer_restores,
        hold_events,
        offerless_reinvite_a,
        offerless_reinvite_b,
        set_media_anchor_and_back,
        set_media_busy,
        early_update_a_to_b,
        early_update_b_to_a,
        anchor_late_offer,
        nated_caller_reached_at_source,
        hangup_reason_both_legs,
        requests_surfaced,
        requests_default_answers,
        relay_info_forwarded,
        replace_b_anchored,
        replace_b_failure_keeps_b,
        replace_b_not_anchored,
        fork_anchored_per_branch,
        replace_b_aborted_when_call_ends,
        replace_b_dialog,
        replace_b_anchor_params,
        relay_async_outlives_handler,
        replace_b_keeps_a_ports,
        fork_replace_second_answers,
        fork_replace_late_2xx_gets_bye,
        fork_replace_all_busy,
        fork_replace_timer_c,
        fork_replace_caller_hangs_up,
        fork_replace_failed_then_replace,
        fork_replace_own_flags,
        fork_replace_own_flags_fail,
        fork_replace_late_offer,
        fork_replace_empty,
        fork_replace_offer_refused,
        fork_replace_offer_half_refused,
        fork_replace_hook_rejects,
        fork_replace_helper_dies,
        reinvite_helper_dies,
        replace_b_new_b_dies,
        info_follows_replace,
        replace_clears_hold,
        replace_b_bad_arguments,
        replace_b_failure_other_flags,
        replace_b_from,
        fork_replace_from,
        replace_b_dialog_keeps_from,
        replace_b_bad_from,
        replace_b_from_refused
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
    _ =
        case whereis(b2b_test_rtpe) of
            undefined ->
                ok;
            Rtpe ->
                unregister(b2b_test_rtpe),
                chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = sys:remove(chappe_sip_engine, b2b_hold),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

-define(NEW_FROM, <<"\"Alice\" <sip:alice@example.com>">>).
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        ),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        tell(b_acked)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D#{invite_cseq := maps:get(seq, ?UA:cseq(Re))}, EP),
        tell({b_200, R})
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        ),
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                U,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {U, _} = ?UA:in_dialog(
            D, <<"UPDATE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(Re, 488, <<"Not Acceptable Here">>, <<>>, [], <<>>)
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        {Mine, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Mine),
        tell({b_final, ?UA:recv_any(Sock, 6000)}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"2">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        ?UA:send(
            Sock, S, ?UA:resp(Re, 491, <<"Request Pending">>, <<>>, [], <<>>)
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re1, D1} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re1),
        timer:sleep(300),
        {Re2, _} = ?UA:in_dialog(
            D1, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"2">>)
        ),
        ?UA:send(Sock, EP, Re2),
        tell({a_second, ?UA:recv_any(Sock, 6000)})
    end),
    R = got(a_second),
    ?assertEqual(500, ?UA:status(R)),
    RA = binary_to_integer(
        hd(binary:split(?UA:hdr(R, <<"retry-after">>), <<" ">>))
    ),
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
    callee(
        CP,
        #{
            headers => [
                {<<"Session-Expires">>, <<"4;refresher=uac">>},
                {<<"Require">>, <<"timer">>},
                {<<"Allow">>, <<"INVITE, ACK, BYE, UPDATE">>}
            ]
        },
        fun(Sock, _D) ->
            T0 = now_ms(),
            {U, S} = ?UA:recv_req(Sock, <<"UPDATE">>, 6000),
            tell({b_update, U, now_ms() - T0}),
            ?UA:send(
                Sock,
                S,
                ?UA:resp(
                    U,
                    200,
                    <<"OK">>,
                    <<>>,
                    [{<<"Session-Expires">>, <<"4;refresher=uac">>}],
                    <<>>
                )
            )
        end
    ),
    caller(
        EP,
        #{
            headers => [
                {<<"Supported">>, <<"timer">>},
                {<<"Session-Expires">>, <<"3">>}
            ]
        },
        fun(Sock, D) ->
            timer:sleep(1000),
            {U, _} = ?UA:in_dialog(
                D,
                <<"UPDATE">>,
                [
                    {<<"Supported">>, <<"timer">>},
                    {<<"Session-Expires">>, <<"3;refresher=uac">>}
                ],
                <<>>
            ),
            ?UA:send(Sock, EP, U),
            R = ?UA:recv_status(Sock, 200),
            %% the A leg's first expiry (2 s after its INVITE) passes: no BYE
            ok = ?UA:no_req(Sock, <<"BYE">>, 1500),
            tell({a_refreshed, R})
        end
    ),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                183,
                <<"Session Progress">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"early">>)
            )
        ),
        timer:sleep(300),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => ?UA:tag()
        }),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                183,
                <<"Session Progress">>,
                Tag,
                [
                    contact(Sock),
                    {<<"Require">>, <<"100rel">>},
                    {<<"RSeq">>, <<"7">>}
                ],
                ?UA:sdp(<<"early">>)
            )
        ),
        {Pr, PS} = ?UA:recv_req(Sock, <<"PRACK">>),
        tell({b_prack, Pr}),
        ?UA:send(Sock, PS, ?UA:resp(Pr, 200, <<"OK">>, <<>>, [], <<>>)),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Call = ?UA:callid(),
        FT = ?UA:tag(),
        Inv = ?UA:invite(Sock, EP, #{
            call_id => Call,
            from_tag => FT,
            headers => [{<<"Supported">>, <<"100rel">>}]
        }),
        ?UA:send(Sock, EP, Inv),
        R183 = ?UA:recv_status(Sock, 183),
        %% the 2xx must not come before our PRACK
        Early =
            receive
                {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>> = B} -> B
            after 800 -> none
            end,
        Pr = prack(Sock, Inv, R183),
        ?UA:send(Sock, EP, Pr),
        R200 = recv_invite_2xx(Sock),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        tell({a_side, R183, Early, R200})
    end),
    BInv = got(b_invite),
    ?assert(
        lists:member(<<"100rel">>, tokens(?UA:hdrs(BInv, <<"supported">>)))
    ),
    BPr = got(b_prack),
    ?assertEqual(<<"7 1 INVITE">>, ?UA:hdr(BPr, <<"rack">>)),
    receive
        {a_side, R183, Early, R200} ->
            ?assertEqual(none, Early),
            ?assertNotEqual(undefined, ?UA:hdr(R183, <<"rseq">>)),
            ?assert(
                lists:member(
                    <<"100rel">>, tokens(?UA:hdrs(R183, <<"require">>))
                )
            ),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                180,
                <<"Ringing">>,
                Tag,
                [
                    contact(Sock),
                    {<<"Require">>, <<"100rel">>},
                    {<<"RSeq">>, <<"1">>}
                ],
                <<>>
            )
        ),
        {Pr, PS} = ?UA:recv_req(Sock, <<"PRACK">>),
        ?UA:send(Sock, PS, ?UA:resp(Pr, 200, <<"OK">>, <<>>, [], <<>>)),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(),
            from_tag => ?UA:tag(),
            headers => [{<<"Supported">>, <<"100rel">>}]
        }),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(Inv, 180, <<"Ringing">>, Tag, [contact(Sock)], <<>>)
        ),
        timer:sleep(1500),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(),
            from_tag => ?UA:tag(),
            headers => [{<<"Require">>, <<"100rel">>}]
        }),
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
    callee(
        CP,
        #{
            headers => [
                {<<"X-Custom">>, <<"foo">>},
                {<<"X-Other">>, <<"bar">>}
            ]
        },
        fun(_Sock, _D) -> ok end
    ),
    R = caller_2xx(EP, #{}),
    ?assertEqual(<<"foo">>, ?UA:hdr(R, <<"x-custom">>)),
    ?assertEqual(undefined, ?UA:hdr(R, <<"x-other">>)).

%% all copies B's headers except the ones that belong to one leg: the
%% dialog, the session timer and the extensions in force.
%% req: R3261-8.2.6-1 R4028-4-3
proxy_response_headers_all(_Config) ->
    {EP, CP} = setup(#{proxy_response_headers => all}),
    callee(
        CP,
        #{
            headers => [
                {<<"X-Custom">>, <<"foo">>},
                {<<"Session-Expires">>, <<"1800;refresher=uac">>},
                {<<"Require">>, <<"timer">>}
            ]
        },
        fun(_Sock, _D) -> ok end
    ),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(Inv, 487, <<"Request Terminated">>, Tag, [], <<>>)
        ),
        tell({b_cancel, Cancel})
    end),
    ?UA:peer(0, fun(Sock) ->
        Br = ?UA:branch(),
        Call = ?UA:callid(),
        FT = ?UA:tag(),
        Inv = ?UA:invite(Sock, EP, #{
            call_id => Call, from_tag => FT, branch => Br
        }),
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
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_any(Sock, 6000),
        ?UA:ack(D#{invite_cseq := maps:get(seq, ?UA:cseq(Re))}, EP),
        tell({b_final, R})
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        )
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    ?assert(has(?UA:body(got(b_reinvite)), <<"a=x-a-offer">>)),
    ?assert(has(?UA:body(got(a_200)), <<"a=x-b-answer">>)).

%% The older fun(Leg, Sdp) still works.
%% req: R3264-8-1
rewrite_sdp_two_arity(_Config) ->
    Rw = fun(Leg, Sdp) ->
        <<Sdp/binary, "a=x-", (atom_to_binary(Leg))/binary, "\r\n">>
    end,
    {EP, CP} = setup(#{rewrite_sdp => Rw}),
    callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_reinvite, Re}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        tell({a_200, ?UA:recv_status(Sock, 200)})
    end),
    ?assert(has(?UA:body(got(b_reinvite)), <<"a=x-a\r\n">>)),
    ?assert(has(?UA:body(got(a_200)), <<"a=x-b\r\n">>)).

%% The hook refuses an offer: the offering leg gets the code, the other
%% leg sees nothing.
%% req: R3261-233
rewrite_sdp_reject(_Config) ->
    Rw = fun
        (a, offer, Sdp) ->
            case has(Sdp, <<"o=caller 1 1 ">>) of
                true -> {reject, 488};
                false -> Sdp
            end;
        (_, _, Sdp) ->
            Sdp
    end,
    {EP, CP} = setup(#{rewrite_sdp => Rw}),
    callee(CP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 1500),
        tell(b_quiet)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        {Re, D1} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"callee">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(D1, EP),
        tell({b_200, R}),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => <<"atag">>
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP),
        tell({a_200, R}),
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        ),
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(Re, 488, <<"Not Acceptable Here">>, <<>>, [], <<>>)
        ),
        {Re2, S2} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock,
            S2,
            ?UA:resp(
                Re2,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        tell({a_first, ?UA:recv_any(Sock, 6000)}),
        {Re2, _} = ?UA:in_dialog(
            D1, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"2">>)
        ),
        ?UA:send(Sock, EP, Re2),
        tell({a_second, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual(488, ?UA:status(got(a_first))),
    ?assertEqual(200, ?UA:status(got(a_second))),
    Cmds = [
        maps:get(<<"command">>, C)
     || {rtpe_cmd, C} <- drain(),
        maps:is_key(<<"sdp">>, C)
    ],
    %% initial offer/answer, the refused re-offer and its restoring answer,
    %% then the second re-offer and its answer
    ?assertEqual(
        [
            <<"offer">>,
            <<"answer">>,
            <<"offer">>,
            <<"answer">>,
            <<"offer">>,
            <<"answer">>
        ],
        Cmds
    ).

%% A re-offer whose streams stop receiving puts its leg on hold; the
%% notify process sees hold, then unhold.
%% req: R3264-8.4-1
hold_events(_Config) ->
    {EP, CP} = setup(#{notify => self()}),
    callee(CP, fun(Sock, _D) ->
        lists:foreach(
            fun(V) ->
                {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
                ?UA:send(
                    Sock,
                    S,
                    ?UA:resp(
                        Re,
                        200,
                        <<"OK">>,
                        <<>>,
                        [contact(Sock)],
                        ?UA:sdp(<<"callee">>, V)
                    )
                )
            end,
            [<<"1">>, <<"2">>]
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, D1} = ?UA:in_dialog(
            D,
            <<"INVITE">>,
            [],
            sdp_dir(<<"caller">>, <<"1">>, <<"sendonly">>)
        ),
        ?UA:send(Sock, EP, Re),
        _ = ?UA:recv_status(Sock, 200),
        {Re2, _} = ?UA:in_dialog(
            D1,
            <<"INVITE">>,
            [],
            sdp_dir(<<"caller">>, <<"2">>, <<"sendrecv">>)
        ),
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        ),
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
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        ),
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
        lists:foreach(
            fun(V) ->
                {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
                tell({b_reinvite, Re}),
                ?UA:send(
                    Sock,
                    S,
                    ?UA:resp(
                        Re,
                        200,
                        <<"OK">>,
                        <<>>,
                        [contact(Sock)],
                        ?UA:sdp(<<"callee">>, V)
                    )
                ),
                {_, _} = ?UA:recv_req(Sock, <<"ACK">>)
            end,
            [<<"1">>, <<"2">>]
        )
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        lists:foreach(
            fun(V) ->
                {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
                ?UA:send(
                    Sock,
                    S,
                    ?UA:resp(
                        Re,
                        200,
                        <<"OK">>,
                        <<>>,
                        [contact(Sock)],
                        ?UA:sdp(<<"caller">>, V)
                    )
                ),
                {Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
                tell({a_ack, Re, Ack})
            end,
            [<<"1">>, <<"2">>]
        )
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
    ?assertMatch(
        #{media := direct, session := undefined},
        chappe_sip_b2b:info(B2b)
    ),
    ?assert(
        lists:any(
            fun({rtpe_cmd, C}) ->
                maps:get(<<"command">>, C) =:= <<"delete">>
            end,
            drain()
        )
    ).

%% While an offer of the call is pending, set_media/2 is busy.
%% req: R3261-14.2-1
set_media_busy(_Config) ->
    {EP, CP} = setup(#{}),
    Callee = callee(CP, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell(b_got_reinvite),
        receive
            go -> ok
        after 5000 -> ok
        end,
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>, <<"1">>)
            )
        )
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                183,
                <<"Session Progress">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"early">>)
            )
        ),
        {U, US} = ?UA:recv_req(Sock, <<"UPDATE">>),
        tell({b_update, U}),
        ?UA:send(
            Sock,
            US,
            ?UA:resp(
                U,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"early">>, <<"1">>)
            )
        ),
        receive
            go -> ok
        after 5000 -> ok
        end,
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"early">>, <<"1">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => ?UA:tag()
        }),
        ?UA:send(Sock, EP, Inv),
        R183 = ?UA:recv_status(Sock, 183),
        D = ?UA:dialog_from_2xx(Sock, Inv, R183),
        {U, _} = ?UA:in_dialog(
            D, <<"UPDATE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
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
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                183,
                <<"Session Progress">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"early">>)
            )
        ),
        D = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        timer:sleep(300),
        {U, D1} = ?UA:in_dialog(
            D, <<"UPDATE">>, [], ?UA:sdp(<<"early">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, U),
        tell({b_update_200, ?UA:recv_status(Sock, 200)}),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"early">>, <<"1">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {Re, _} = ?UA:in_dialog(
            D1, <<"INVITE">>, [], ?UA:sdp(<<"early">>, <<"2">>)
        ),
        ?UA:send(Sock, EP, Re),
        _ = ?UA:recv_status(Sock, 200),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => ?UA:tag()
        }),
        ?UA:send(Sock, EP, Inv),
        _ = ?UA:recv_status(Sock, 183),
        {U, US} = ?UA:recv_req(Sock, <<"UPDATE">>),
        tell({a_update, U}),
        ?UA:send(
            Sock,
            US,
            ?UA:resp(
                U,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        ),
        R200 = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R200), EP),
        {Re, RS} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(
            Sock,
            RS,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"2">>)
            )
        ),
        timer:sleep(infinity)
    end),
    U = got(a_update),
    ?assertEqual(?UA:sdp(<<"early">>, <<"1">>), ?UA:body(U)),
    ?assertEqual(?UA:sdp(<<"caller">>, <<"1">>), ?UA:body(got(b_update_200))),
    Re = got(a_reinvite),
    ?assert(maps:get(seq, ?UA:cseq(Re)) > maps:get(seq, ?UA:cseq(U))).

%% ---- late offer and NAT ----

%% An INVITE without an offer, anchored: B's offer in its 2xx goes through
%% rtpengine to A, and A's answer in its ACK goes through it to B's ACK.
%% req: R3264-8-1 R3261-14.2-2
anchor_late_offer(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_invite, Inv}),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"btag">>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        tell({b_ack, Ack}),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(),
            from_tag => <<"atag">>,
            body => <<>>
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        tell({a_200, R}),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:send(Sock, EP, ack_with(D, ?UA:sdp(<<"caller">>))),
        timer:sleep(infinity)
    end),
    ?assertEqual(<<>>, ?UA:body(got(b_invite))),
    ?assert(has(?UA:body(got(a_200)), <<"a=rtpe-offer:btag">>)),
    ?assert(has(?UA:body(got(b_ack)), <<"a=rtpe-answer:atag">>)).

%% A caller whose Contact is a private address it cannot be reached at
%% (behind a NAT) gets the requests of its dialog where its INVITE came
%% from: B's BYE reaches it.
%% req: R3261-12.2.2-1
nated_caller_reached_at_source(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, D) ->
        {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, Bye),
        _ = ?UA:recv_status(Sock, 200)
    end),
    ?UA:peer(0, fun(Sock) ->
        P = integer_to_binary(?UA:lport(Sock)),
        Inv0 = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => ?UA:tag()
        }),
        Inv = binary:replace(
            Inv0,
            <<"Contact: <sip:caller@127.0.0.1:", P/binary, ">">>,
            <<"Contact: <sip:caller@10.99.99.99:5999>">>
        ),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP),
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({a_bye, Bye}),
        timer:sleep(infinity)
    end),
    _ = got(a_bye),
    ok = ?UA:expect({relay_done, {done, b_bye}}).

%% ---- hangup/2 ----

%% hangup/2 ends both legs, each BYE carrying the Reason and the headers.
%% req: R3326-01
hangup_reason_both_legs(_Config) ->
    {EP, CP} = setup(#{}),
    Bye = fun(Tag) ->
        fun(Sock, _D) ->
            {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
            ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
            tell({Tag, B})
        end
    end,
    callee(CP, Bye(b_bye)),
    caller(EP, #{}, Bye(a_bye)),
    #{b2b := B2b} = got(legs),
    Reason = <<"Q.850;cause=16">>,
    ok = chappe_sip_b2b:hangup(B2b, #{
        reason => Reason,
        headers => [{<<"X-Why">>, <<"done">>}]
    }),
    lists:foreach(
        fun(Tag) ->
            B = got(Tag),
            ?assertEqual([Reason], ?UA:hdrs(B, <<"reason">>)),
            ?assertEqual([<<"done">>], ?UA:hdrs(B, <<"x-why">>))
        end,
        [a_bye, b_bye]
    ),
    ok = ?UA:expect({relay_done, {done, hangup}}).

%% ---- in-dialog requests (requests, relay_info) ----

%% REFER from A and MESSAGE from B reach the notify process, which answers
%% them; an INFO the call does not claim still gets the dialog's 200.
requests_surfaced(_Config) ->
    {EP, CP} = setup(#{requests => [refer, message], notify => self()}),
    callee(CP, fun(Sock, D) ->
        receive
        after 300 -> ok
        end,
        {M, _} = ?UA:in_dialog(D, <<"MESSAGE">>, [], <<"hello">>),
        ?UA:send(Sock, EP, M),
        tell({b_final, ?UA:recv_any(Sock, 6000)})
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {R, D1} = ?UA:in_dialog(
            D,
            <<"REFER">>,
            [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}],
            <<>>
        ),
        ?UA:send(Sock, EP, R),
        tell({a_refer_final, ?UA:recv_any(Sock, 6000)}),
        {I, _} = ?UA:in_dialog(D1, <<"INFO">>, [], <<"x">>),
        ?UA:send(Sock, EP, I),
        tell({a_info_final, ?UA:recv_any(Sock, 6000)})
    end),
    #{b2b := {_, Ref}} = got(legs),
    {a, refer, _, RRes} = b2b_request(Ref),
    _ = chappe_sip_res:send(RRes, 202, #{reason => <<"Accepted">>}),
    ?assertEqual(202, ?UA:status(got(a_refer_final))),
    ?assertEqual(200, ?UA:status(got(a_info_final))),
    {b, message, MReq, MRes} = b2b_request(Ref),
    ?assertEqual(<<"hello">>, chappe_sip_req:body(MReq)),
    _ = chappe_sip_res:send(MRes, 200, #{reason => <<"OK">>}),
    ?assertEqual(200, ?UA:status(got(b_final))),
    receive
        {chappe_sip_b2b, Ref, {request, _, _, _, _} = Extra} ->
            ct:fail({unexpected, Extra})
    after 300 -> ok
    end.

%% Without a notify process the claimed requests get what a dialog
%% answers: REFER 603.
requests_default_answers(_Config) ->
    {EP, _CP} = setup_callee(#{requests => [refer]}),
    caller(EP, #{}, fun(Sock, D) ->
        {R, _} = ?UA:in_dialog(
            D,
            <<"REFER">>,
            [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}],
            <<>>
        ),
        ?UA:send(Sock, EP, R),
        tell({a_refer_final, ?UA:recv_any(Sock, 6000)})
    end),
    ?assertEqual(603, ?UA:status(got(a_refer_final))).

%% relay_info: A's INFO reaches B with its body and Info-Package, and B's
%% final comes back to A.
relay_info_forwarded(_Config) ->
    {EP, CP} = setup(#{relay_info => true}),
    Body = <<"Signal=5\r\nDuration=160\r\n">>,
    callee(CP, fun(Sock, _D) ->
        {I, S} = ?UA:recv_req(Sock, <<"INFO">>),
        tell({b_info, I}),
        ?UA:send(Sock, S, ?UA:resp(I, 202, <<"Accepted">>, <<>>, [], <<>>))
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {I, _} = ?UA:in_dialog(
            D,
            <<"INFO">>,
            [{<<"Info-Package">>, <<"dtmf">>}],
            Body
        ),
        ?UA:send(Sock, EP, I),
        tell({a_final, ?UA:recv_any(Sock, 6000)})
    end),
    I = got(b_info),
    ?assertEqual(Body, ?UA:body(I)),
    ?assertEqual([<<"dtmf">>], ?UA:hdrs(I, <<"info-package">>)),
    ?assertEqual(202, ?UA:status(got(a_final))).

%% ---- replace_b/3 ----

%% An anchored call gets a new B: its INVITE carries rtpengine's offer for
%% A's side, rtpengine takes its answer under leg B's tag, the old B gets
%% a BYE, A sees no re-INVITE, and the call then runs with the new B (A's
%% BYE reaches it).
replace_b_anchored(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor, notify => self()}),
    NP = ?UA:pick(),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({old_b_bye, B})
    end),
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({new_b_invite, Inv}),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"newtag">>,
                [contact(Sock)],
                ?UA:sdp(<<"newcallee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({new_b_bye, B}),
        timer:sleep(infinity)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        register(b2b_test_caller, self()),
        receive
            go -> ok
        end,
        ok = ?UA:no_req(Sock, <<"INVITE">>, 1000),
        {B, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, B),
        tell({a_bye_final, ?UA:recv_any(Sock, 6000)})
    end),
    #{b2b := {_, Ref} = B2b, uac := OldB} = got(legs),
    OldTag = chappe_sip_dialog:remote_tag(OldB),
    _ = drain(),
    NewUri = <<"sip:new@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    ok = chappe_sip_b2b:replace_b(B2b, NewUri, #{}),
    receive
        {chappe_sip_b2b, Ref, {replaced, b}} -> ok
    after 5000 -> ct:fail(no_replaced_event)
    end,
    ?assert(has(?UA:body(got(new_b_invite)), <<"a=rtpe-offer:">>)),
    _ = got(old_b_bye),
    Answers = [
        C
     || {rtpe_cmd, #{<<"command">> := <<"answer">>} = C} <- drain()
    ],
    %% rtpengine keeps leg B under its first tag: a new to-tag would be a
    %% new branch, with ports the new B was never given
    ?assertMatch([#{<<"to-tag">> := OldTag}], Answers),
    caller_go(),
    ?assertEqual(200, ?UA:status(got(a_bye_final))),
    _ = got(new_b_bye),
    ok = ?UA:expect({relay_done, {done, a_bye}}).

%% A new B on another network: the anchor_params of replace_b/3 go with
%% rtpengine's offer for it, and the call keeps them afterwards.
replace_b_anchor_params(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{
        media => anchor,
        anchor_params => #{b => #{direction => [<<"host">>, <<"docker">>]}}
    }),
    NP = ?UA:pick(),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>))
    end),
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"newtag">>,
                [contact(Sock)],
                ?UA:sdp(<<"mixer">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    caller(EP, #{}, fun(_Sock, _D) -> timer:sleep(infinity) end),
    #{b2b := B2b} = got(legs),
    _ = drain(),
    NewUri = <<"sip:new@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    Host = #{direction => [<<"host">>, <<"host">>]},
    ok = chappe_sip_b2b:replace_b(B2b, NewUri, #{anchor_params => #{b => Host}}),
    [Offer] = [C || {rtpe_cmd, #{<<"command">> := <<"offer">>} = C} <- drain()],
    ?assertEqual([<<"host">>, <<"host">>], maps:get(<<"direction">>, Offer)).

%% A never sees the offer of replace_b/3: the answer asks rtpengine to
%% keep A's ports (an answer to a re-offer moves them otherwise), while
%% the offer lets the new B's side move.
replace_b_keeps_a_ports(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    NP = ?UA:pick(),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>))
    end),
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"newtag">>,
                [contact(Sock)],
                ?UA:sdp(<<"new">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    caller(EP, #{}, fun(_Sock, _D) -> timer:sleep(infinity) end),
    #{b2b := B2b} = got(legs),
    _ = drain(),
    NewUri = <<"sip:new@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    ok = chappe_sip_b2b:replace_b(B2b, NewUri, #{}),
    Cmds = [C || {rtpe_cmd, C} <- drain(), maps:is_key(<<"sdp">>, C)],
    ?assertMatch(
        [#{<<"command">> := <<"offer">>}, #{<<"command">> := <<"answer">>}],
        Cmds
    ),
    [Offer, Answer] = Cmds,
    ?assertNot(
        lists:member(<<"port-latching">>, maps:get(<<"flags">>, Offer, []))
    ),
    ?assert(lists:member(<<"port-latching">>, maps:get(<<"flags">>, Answer))).

%% relay_async/2 carries an anchored call in its own process: the handler
%% returns at once, the call (and its rtpengine session) lives on, the
%% handle still drives it, and the notify process hears how it ended.
relay_async_outlives_handler(_Config) ->
    rtpe(),
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    Test = self(),
    register(b2b_relay_test, Test),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{
            media => anchor
        }),
        Test ! b2b_up,
        Test !
            {async, chappe_sip_b2b:relay_async(Legs, #{notify => Test}), self()}
    end),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>, 20000),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({b_bye, B})
    end),
    caller(EP, #{}, fun(Sock, D) ->
        register(b2b_test_caller, self()),
        receive
            go -> ok
        end,
        {B, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, B),
        tell({a_bye_final, ?UA:recv_any(Sock, 6000)})
    end),
    {{ok, {Relay, Ref} = B2b}, Worker} = got2(async),
    WRef = monitor(process, Worker),
    receive
        {'DOWN', WRef, process, Worker, _} -> ok
    after 5000 -> ct:fail(handler_still_running)
    end,
    ?assertNotEqual(Worker, Relay),
    timer:sleep(200),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)),
    ?assertEqual([], [
        C
     || {rtpe_cmd, #{<<"command">> := <<"delete">>} = C} <- drain()
    ]),
    caller_go(),
    ?assertEqual(200, ?UA:status(got(a_bye_final))),
    _ = got(b_bye),
    receive
        {chappe_sip_b2b, Ref, {done, {done, a_bye}}} -> ok
    after 5000 -> ct:fail(no_done)
    end.

%% The new B refuses: replace_b/3 fails with its status, rtpengine gets
%% the old B's SDP back, and the old B keeps the call.
replace_b_failure_keeps_b(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    NP = ?UA:pick(),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell(old_b_bye)
    end),
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock, Src, ?UA:resp(Inv, 486, <<"Busy Here">>, ?UA:tag(), [], <<>>)
        ),
        timer:sleep(infinity)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        register(b2b_test_caller, self()),
        receive
            go -> ok
        end,
        {B, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, B),
        tell({a_bye_final, ?UA:recv_any(Sock, 6000)})
    end),
    #{b2b := B2b, uac := OldB} = got(legs),
    _ = drain(),
    NewUri = <<"sip:new@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    ?assertMatch(
        {error, #chappe_sip_error{status = 486}},
        chappe_sip_b2b:replace_b(B2b, NewUri, #{})
    ),
    Cmds = [C || {rtpe_cmd, C} <- drain(), maps:is_key(<<"sdp">>, C)],
    ?assertMatch(
        [
            #{<<"command">> := <<"offer">>},
            #{<<"command">> := <<"answer">>}
        ],
        Cmds
    ),
    [_, Restore] = Cmds,
    ?assertEqual(
        chappe_sip_dialog:remote_tag(OldB), maps:get(<<"to-tag">>, Restore)
    ),
    caller_go(),
    ?assertEqual(200, ?UA:status(got(a_bye_final))),
    ok = ?UA:expect(old_b_bye),
    ok = ?UA:expect({relay_done, {done, a_bye}}).

%% A direct call has no anchor to re-offer from.
replace_b_not_anchored(_Config) ->
    {EP, _CP} = setup_callee(#{}),
    caller(EP, #{}, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    ?assertEqual(
        {error, not_anchored},
        chappe_sip_b2b:replace_b(B2b, <<"sip:x@127.0.0.1">>, #{})
    ).

%% An anchored fork: each branch gets the same rtpengine offer, and each
%% branch's answer goes to rtpengine under that branch's To-tag.
fork_anchored_per_branch(_Config) ->
    rtpe(),
    EP = ?UA:pick(),
    C1 = ?UA:pick(),
    C2 = ?UA:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    Test = self(),
    register(b2b_relay_test, Test),
    Uris = [
        <<"sip:c@127.0.0.1:", (integer_to_binary(P))/binary>>
     || P <- [C1, C2]
    ],
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(
            Req,
            Res,
            {parallel, Uris},
            #{media => anchor}
        ),
        Test ! b2b_up,
        Test ! {relay_done, chappe_sip_b2b:relay(Legs)}
    end),
    ?UA:peer(C1, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({c1_invite, Inv}),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                183,
                <<"Session Progress">>,
                <<"c1tag">>,
                [contact(Sock)],
                ?UA:sdp(<<"early1">>)
            )
        ),
        {C, CS} = ?UA:recv_req(Sock, <<"CANCEL">>),
        ?UA:send(Sock, CS, ?UA:resp(C, 200, <<"OK">>, <<"c1tag">>, [], <<>>)),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                487,
                <<"Request Terminated">>,
                <<"c1tag">>,
                [],
                <<>>
            )
        ),
        timer:sleep(infinity)
    end),
    ?UA:peer(C2, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({c2_invite, Inv}),
        timer:sleep(300),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"c2tag">>,
                [contact(Sock)],
                ?UA:sdp(<<"callee2">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => <<"atag">>
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP),
        tell({a_200, R}),
        timer:sleep(infinity)
    end),
    ?assert(has(?UA:body(got(c1_invite)), <<"a=rtpe-offer:atag">>)),
    ?assert(has(?UA:body(got(c2_invite)), <<"a=rtpe-offer:atag">>)),
    ?assert(has(?UA:body(got(a_200)), <<"a=rtpe-answer:c2tag">>)),
    Cmds = drain(),
    Offers = [C || {rtpe_cmd, #{<<"command">> := <<"offer">>} = C} <- Cmds],
    ?assertMatch([_], Offers),
    %% both branches answered the one offer, so they share the callee's
    %% monologue on rtpengine and the winner's answer renamed it: the
    %% losing to-tag is not deleted (from rtpengine 13 on it is an alias of
    %% the winner, and its delete would end the call)
    Deletes = [
        C
     || {rtpe_cmd, #{<<"command">> := <<"delete">>} = C} <- Cmds
    ],
    ?assertEqual([], Deletes).

%% A hangs up while the new B of replace_b/3 still rings: that INVITE is
%% CANCELled at once (the app's process lives on), and replace_b/3 says
%% the call ended.
replace_b_aborted_when_call_ends(_Config) ->
    rtpe(),
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    NP = ?UA:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    Test = self(),
    register(b2b_relay_test, Test),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Callee, #{
            media => anchor
        }),
        Test ! {legs, Legs},
        Test ! b2b_up,
        Test ! {relay_done, chappe_sip_b2b:relay(Legs)},
        %% the app goes on after the call
        timer:sleep(6000)
    end),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>))
    end),
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, <<"ntag">>, [], <<>>)
        ),
        tell(new_b_ringing),
        {C, CS} = ?UA:recv_req(Sock, <<"CANCEL">>),
        tell(new_b_cancel),
        ?UA:send(Sock, CS, ?UA:resp(C, 200, <<"OK">>, <<"ntag">>, [], <<>>)),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                487,
                <<"Request Terminated">>,
                <<"ntag">>,
                [],
                <<>>
            )
        ),
        timer:sleep(infinity)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        register(b2b_test_caller, self()),
        receive
            go -> ok
        end,
        {B, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, B),
        _ = ?UA:recv_any(Sock, 6000)
    end),
    #{b2b := B2b} = got(legs),
    NewUri = <<"sip:new@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    spawn_link(fun() ->
        Test ! {replace_result, chappe_sip_b2b:replace_b(B2b, NewUri, #{})}
    end),
    ok = ?UA:expect(new_b_ringing),
    T0 = now_ms(),
    caller_go(),
    ok = ?UA:expect(new_b_cancel),
    ?assert(now_ms() - T0 < 3000),
    ?assertEqual({error, call_ended}, got(replace_result)),
    ok = ?UA:expect({relay_done, {done, a_bye}}).

%% replace_b/3 with a dialog the app made: the relay takes it over, so a
%% re-INVITE from the new B is relayed to A.
replace_b_dialog(_Config) ->
    _ = dialog_replace(#{}),
    ok.

%% A re-INVITE stays in the dialog, so it keeps the dialog's From (RFC
%% 3261 12.2.1.1) and from does not apply to it.
replace_b_dialog_keeps_from(_Config) ->
    Re = dialog_replace(#{from => ?NEW_FROM}),
    ?assertNot(has(?UA:hdr(Re, <<"from">>), <<"Alice">>)),
    ?assertEqual(
        from_tag(?UA:hdr(got(first_invite), <<"from">>)),
        from_tag(?UA:hdr(Re, <<"from">>))
    ).

dialog_replace(Opts) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    NP = ?UA:pick(),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell(old_b_bye)
    end),
    EpPeer = ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({first_invite, Inv}),
        Tag = <<"dtag">>,
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"endpoint">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({reinvite, Re}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"endpoint">>, <<"1">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        receive
            go -> ok
        end,
        D = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        {Re2, D1} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"endpoint">>, <<"2">>)
        ),
        ?UA:send(Sock, EP, Re2),
        tell({ep_final, ?UA:recv_any(Sock, 6000)}),
        ?UA:ack(D1, EP),
        timer:sleep(infinity)
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({a_reinvite, Re}),
        ?UA:send(
            Sock,
            S,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        ),
        timer:sleep(infinity)
    end),
    #{b2b := B2b} = got(legs),
    %% the app's own dialog with the endpoint, owned by this process
    NewUri = <<"sip:ep@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    {ok, URef} = chappe_sip_uac:start(NewUri, #{local_sdp => ?UA:sdp(<<"app">>)}),
    {ok, D} = chappe_sip_uac:await(URef, 5000),
    ok = chappe_sip_b2b:replace_b(B2b, {dialog, D}, Opts),
    Re = got(reinvite),
    ?assert(has(?UA:body(Re), <<"a=rtpe-offer:">>)),
    ok = ?UA:expect(old_b_bye),
    EpPeer ! go,
    ?assert(has(?UA:body(got(a_reinvite)), <<"endpoint">>)),
    ?assertEqual(200, ?UA:status(got(ep_final))),
    Re.

b2b_request(Ref) ->
    receive
        {chappe_sip_b2b, Ref, {request, Leg, Method, Req, Res}} ->
            {Leg, Method, Req, Res}
    after 6000 -> ct:fail(no_b2b_request)
    end.

%% the caller peers wait for go before they hang up
caller_go() ->
    b2b_test_caller ! go,
    ok.

%% ---- replace_b/3 with {parallel, Dests} ----

%% a destination of a fork: it tells {Name, Invite} and goes on with Fun
fork_dest(Name, Fun) ->
    P = ?UA:pick(),
    ?UA:peer(P, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({Name, Inv}),
        Fun(Sock, Inv, Src),
        timer:sleep(infinity)
    end),
    <<"sip:", (atom_to_binary(Name))/binary, "@127.0.0.1:",
        (integer_to_binary(P))/binary>>.

%% it answers 200 under To-tag Tag after Ms; a BYE then comes to the test
answers(Name, Tag, Ms) ->
    fun(Sock, Inv, Src) ->
        timer:sleep(Ms),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock)],
                ?UA:sdp(<<"forked">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>, 20000),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({bye_of, Name})
    end.

%% it rings until it gets a CANCEL, which comes to the test
rings(Name) ->
    fun(Sock, Inv, Src) ->
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag, [], <<>>)),
        tell({ringing, Name}),
        {C, CS} = ?UA:recv_req(Sock, <<"CANCEL">>, 20000),
        ?UA:send(Sock, CS, ?UA:resp(C, 200, <<"OK">>, Tag, [], <<>>)),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                487,
                <<"Request Terminated">>,
                Tag,
                [],
                <<>>
            )
        ),
        tell({cancel_of, Name, C})
    end.

busy() ->
    fun(Sock, Inv, Src) ->
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                486,
                <<"Busy Here">>,
                ?UA:tag(),
                [],
                <<>>
            )
        )
    end.

%% an anchored call whose old B gets a BYE when it goes, and whose caller
%% sees no re-INVITE and hangs up on caller_go()
fork_call() ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor, notify => self()}),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>, 20000),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell(old_b_bye)
    end),
    caller(EP, #{}, fun(Sock, D) ->
        register(b2b_test_caller, self()),
        receive
            go -> ok
        end,
        ok = ?UA:no_req(Sock, <<"INVITE">>, 100),
        {B, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, B),
        tell({a_bye_final, ?UA:recv_any(Sock, 6000)})
    end),
    #{b2b := B2b, uac := OldB} = got(legs),
    _ = drain(),
    {B2b, chappe_sip_dialog:remote_tag(OldB)}.

%% the caller hangs up and the relay ends on A's BYE
hang_up() ->
    caller_go(),
    ?assertEqual(200, ?UA:status(got(a_bye_final))),
    ok = ?UA:expect({relay_done, {done, a_bye}}).

sdp_cmds() ->
    [C || {rtpe_cmd, C} <- drain(), maps:is_key(<<"sdp">>, C)].

%% Two destinations, the second answers: it is the winner, the first gets
%% a CANCEL with the RFC 3326 reason, the old B a BYE, and A sees no
%% re-INVITE. Both take the same flags, so there is one rtpengine offer,
%% and its answer stays under leg B's tag. The call then runs with the
%% winner.
fork_replace_second_answers(_Config) ->
    {{_, Ref} = B2b, OldTag} = fork_call(),
    U1 = fork_dest(one, rings(one)),
    U2 = fork_dest(two, fun(S, I, Src) ->
        receive
        after 300 -> ok
        end,
        (answers(two, <<"twotag">>, 0))(S, I, Src)
    end),
    ?assertMatch(
        {ok, #{winner := #{uri := U2, index := 2, opts := #{}}}},
        chappe_sip_b2b:replace_b(B2b, {parallel, [U1, U2]}, #{})
    ),
    receive
        {chappe_sip_b2b, Ref, {replaced, b}} -> ok
    after 5000 -> ct:fail(no_replaced_event)
    end,
    ?assert(has(?UA:body(got(one)), <<"a=rtpe-offer:">>)),
    ?assert(has(?UA:body(got(two)), <<"a=rtpe-offer:">>)),
    receive
        {cancel_of, one, Cancel} ->
            ?assert(has(?UA:hdr(Cancel, <<"reason">>), <<"cause=200">>))
    after 5000 -> ct:fail(no_cancel)
    end,
    ok = ?UA:expect(old_b_bye),
    Cmds = sdp_cmds(),
    ?assertMatch(
        [
            #{<<"command">> := <<"offer">>},
            #{
                <<"command">> := <<"answer">>,
                <<"to-tag">> := OldTag
            }
        ],
        Cmds
    ),
    [_, Answer] = Cmds,
    ?assert(lists:member(<<"port-latching">>, maps:get(<<"flags">>, Answer))),
    hang_up(),
    ok = ?UA:expect({bye_of, two}).

%% A branch whose 2xx crosses the CANCEL is ended with a BYE.
fork_replace_late_2xx_gets_bye(_Config) ->
    {B2b, _OldTag} = fork_call(),
    U1 = fork_dest(one, fun(Sock, Inv, Src) ->
        ?UA:send(
            Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, <<"onetag">>, [], <<>>)
        ),
        {C, CS} = ?UA:recv_req(Sock, <<"CANCEL">>),
        ?UA:send(Sock, CS, ?UA:resp(C, 200, <<"OK">>, <<"onetag">>, [], <<>>)),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"onetag">>,
                [contact(Sock)],
                ?UA:sdp(<<"one">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell({bye_of, one})
    end),
    U2 = fork_dest(two, fun(S, I, Src) ->
        receive
        after 300 -> ok
        end,
        (answers(two, <<"twotag">>, 0))(S, I, Src)
    end),
    ?assertMatch(
        {ok, #{winner := #{index := 2}}},
        chappe_sip_b2b:replace_b(B2b, {parallel, [U1, U2]}, #{})
    ),
    ok = ?UA:expect({bye_of, one}),
    hang_up(),
    ok = ?UA:expect({bye_of, two}).

%% Every branch is busy: the call keeps the old B (rtpengine gets its SDP
%% back under its tag), and the caller gets the 486.
fork_replace_all_busy(_Config) ->
    {B2b, OldTag} = fork_call(),
    Uris = [fork_dest(one, busy()), fork_dest(two, busy())],
    ?assertMatch(
        {error, #chappe_sip_error{status = 486}},
        chappe_sip_b2b:replace_b(B2b, {parallel, Uris}, #{})
    ),
    ?assertMatch(
        [
            #{<<"command">> := <<"offer">>},
            #{
                <<"command">> := <<"answer">>,
                <<"to-tag">> := OldTag
            }
        ],
        sdp_cmds()
    ),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% Timer C covers the whole fork: every branch gets a CANCEL, the call
%% keeps the old B, and a 180 does not restart the timer.
fork_replace_timer_c(_Config) ->
    {B2b, OldTag} = fork_call(),
    Uris = [fork_dest(one, rings(one)), fork_dest(two, rings(two))],
    ?assertEqual(
        {error, timeout},
        chappe_sip_b2b:replace_b(
            B2b,
            {parallel, Uris},
            #{timer_c => 500}
        )
    ),
    receive
        {cancel_of, one, _} -> ok
    after 5000 -> ct:fail(no_cancel_1)
    end,
    receive
        {cancel_of, two, _} -> ok
    after 5000 -> ct:fail(no_cancel_2)
    end,
    ?assertMatch(
        [
            #{<<"command">> := <<"offer">>},
            #{
                <<"command">> := <<"answer">>,
                <<"to-tag">> := OldTag
            }
        ],
        sdp_cmds()
    ),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% The caller hangs up while the fork rings: every branch gets a CANCEL
%% at once and replace_b/3 says the call ended.
fork_replace_caller_hangs_up(_Config) ->
    {B2b, _OldTag} = fork_call(),
    Uris = [fork_dest(one, rings(one)), fork_dest(two, rings(two))],
    Test = self(),
    spawn_link(fun() ->
        Test !
            {replace_result,
                chappe_sip_b2b:replace_b(B2b, {parallel, Uris}, #{})}
    end),
    ok = ?UA:expect({ringing, one}),
    ok = ?UA:expect({ringing, two}),
    T0 = now_ms(),
    hang_up(),
    receive
        {cancel_of, one, _} -> ok
    after 3000 -> ct:fail(no_cancel_1)
    end,
    receive
        {cancel_of, two, _} -> ok
    after 3000 -> ct:fail(no_cancel_2)
    end,
    ?assert(now_ms() - T0 < 3000),
    ?assertEqual({error, call_ended}, got(replace_result)).

%% A failed fork leaves the call able to go on: a second fork and then a
%% plain replace work, each to a new B.
fork_replace_failed_then_replace(_Config) ->
    {B2b, _OldTag} = fork_call(),
    Busy = [fork_dest(one, busy()), fork_dest(two, busy())],
    {error, #chappe_sip_error{status = 486}} =
        chappe_sip_b2b:replace_b(B2b, {parallel, Busy}, #{}),
    Dests = [
        fork_dest(three, rings(three)),
        fork_dest(four, answers(four, <<"fourtag">>, 200))
    ],
    ?assertMatch(
        {ok, #{winner := #{index := 2}}},
        chappe_sip_b2b:replace_b(B2b, {parallel, Dests}, #{})
    ),
    ok = ?UA:expect(old_b_bye),
    Uri = fork_dest(five, answers(five, <<"fivetag">>, 0)),
    ?assertEqual(ok, chappe_sip_b2b:replace_b(B2b, Uri, #{})),
    ok = ?UA:expect({bye_of, four}),
    hang_up(),
    ok = ?UA:expect({bye_of, five}).

%% Destinations with their own flags: one rtpengine offer each, under a
%% via-branch of its own and without a to-tag (rtpengine takes them for
%% leg B otherwise). The winner's answer names its via-branch under its
%% To-tag, and the call keeps that tag: a later offer names it and no
%% via-branch. Its anchor_params keep latching A's ports.
fork_replace_own_flags(_Config) ->
    {B2b, _OldTag} = fork_call(),
    U1 = fork_dest(one, rings(one)),
    Own = #{
        anchor_params => #{
            a => #{flags => [<<"x-a">>]},
            b => #{<<"x-leg">> => <<"two">>}
        }
    },
    U2 = fork_dest(two, fun(S, I, Src) ->
        receive
        after 300 -> ok
        end,
        (answers(two, <<"twotag">>, 0))(S, I, Src)
    end),
    ?assertMatch(
        {ok, #{winner := #{index := 2, opts := Own}}},
        chappe_sip_b2b:replace_b(B2b, {parallel, [U1, {U2, Own}]}, #{})
    ),
    One = ?UA:body(got(one)),
    Two = ?UA:body(got(two)),
    Cmds = sdp_cmds(),
    [Offer1, Offer2, Answer] = Cmds,
    ?assertMatch(
        #{
            <<"command">> := <<"offer">>,
            <<"via-branch">> := <<"chappe-1">>
        },
        Offer1
    ),
    ?assertMatch(
        #{
            <<"command">> := <<"offer">>,
            <<"via-branch">> := <<"chappe-2">>,
            <<"x-leg">> := <<"two">>
        },
        Offer2
    ),
    ?assertNot(maps:is_key(<<"to-tag">>, Offer1)),
    ?assertNot(maps:is_key(<<"to-tag">>, Offer2)),
    ?assert(has(One, <<"a=rtpe-via:chappe-1">>)),
    ?assert(has(Two, <<"a=rtpe-via:chappe-2">>)),
    ?assertMatch(
        #{
            <<"command">> := <<"answer">>,
            <<"to-tag">> := <<"twotag">>,
            <<"via-branch">> := <<"chappe-2">>
        },
        Answer
    ),
    ?assert(lists:member(<<"port-latching">>, maps:get(<<"flags">>, Answer))),
    ?assert(lists:member(<<"x-a">>, maps:get(<<"flags">>, Answer))),
    ok = ?UA:expect(old_b_bye),
    %% a plain replace now reopens the winner's leg
    Uri = fork_dest(five, answers(five, <<"fivetag">>, 0)),
    ?assertEqual(ok, chappe_sip_b2b:replace_b(B2b, Uri, #{})),
    Later = sdp_cmds(),
    ?assertMatch(
        [
            #{<<"command">> := <<"offer">>, <<"to-tag">> := <<"twotag">>},
            #{<<"command">> := <<"answer">>, <<"to-tag">> := <<"twotag">>}
        ],
        Later
    ),
    ?assertEqual([], [C || C <- Later, maps:is_key(<<"via-branch">>, C)]),
    ok = ?UA:expect({bye_of, two}),
    hang_up(),
    ok = ?UA:expect({bye_of, five}).

%% A failed fork with several offers: rtpengine gets the old B's SDP back
%% under the old tag and no via-branch, with the flags the old B had.
fork_replace_own_flags_fail(_Config) ->
    {B2b, OldTag} = fork_call(),
    Own = #{anchor_params => #{b => #{<<"x-leg">> => <<"two">>}}},
    Dests = [fork_dest(one, busy()), {fork_dest(two, busy()), Own}],
    {error, #chappe_sip_error{status = 486}} =
        chappe_sip_b2b:replace_b(B2b, {parallel, Dests}, #{}),
    [_Offer1, _Offer2, Restore, Reopen, Reanswer] = sdp_cmds(),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag},
        Restore
    ),
    %% the first offer took the old B's media: one more exchange gives it
    %% its flags back
    ?assertMatch(
        #{<<"command">> := <<"offer">>, <<"to-tag">> := OldTag}, Reopen
    ),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag}, Reanswer
    ),
    [
        begin
            ?assertNot(maps:is_key(<<"via-branch">>, C)),
            ?assertNot(maps:is_key(<<"x-leg">>, C))
        end
     || C <- [Restore, Reopen, Reanswer]
    ],
    Uri = fork_dest(three, answers(three, <<"threetag">>, 0)),
    ?assertEqual(ok, chappe_sip_b2b:replace_b(B2b, Uri, #{})),
    ?assertMatch(
        [
            #{<<"command">> := <<"offer">>, <<"to-tag">> := OldTag},
            #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag}
        ],
        sdp_cmds()
    ),
    ok = ?UA:expect(old_b_bye),
    hang_up(),
    ok = ?UA:expect({bye_of, three}).

%% After a late offer B is rtpengine's caller: a fork with one set of
%% flags goes on, several sets cannot be offered and the call stays.
fork_replace_late_offer(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                <<"btag">>,
                [contact(Sock)],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell(old_b_bye),
        timer:sleep(infinity)
    end),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(),
            from_tag => <<"atag">>,
            body => <<>>
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:send(Sock, EP, ack_with(D, ?UA:sdp(<<"caller">>))),
        timer:sleep(infinity)
    end),
    #{b2b := B2b} = got(legs),
    timer:sleep(300),
    _ = drain(),
    Own = #{anchor_params => #{b => #{<<"x-leg">> => <<"two">>}}},
    ?assertEqual(
        {error, {rejected, 488}},
        chappe_sip_b2b:replace_b(
            B2b,
            {parallel, [
                <<"sip:x@127.0.0.1">>,
                {<<"sip:y@127.0.0.1">>, Own}
            ]},
            #{}
        )
    ),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    %% no offer went out, so rtpengine gets nothing at all
    ?assertEqual([], drain()),
    Uris = [
        fork_dest(one, busy()),
        fork_dest(two, answers(two, <<"twotag">>, 100))
    ],
    ?assertMatch(
        {ok, #{winner := #{index := 2}}},
        chappe_sip_b2b:replace_b(B2b, {parallel, Uris}, #{})
    ),
    ok = ?UA:expect(old_b_bye).

%% A failed replace to another interface: rtpengine gets the old B's
%% answer, then an exchange with the old flags, which brings the old B's
%% media back from that interface. Without other flags there is none (see
%% replace_b_failure_keeps_b).
replace_b_failure_other_flags(_Config) ->
    {B2b, OldTag} = fork_call(),
    Uri = fork_dest(one, busy()),
    Other = #{anchor_params => #{b => #{<<"x-leg">> => <<"other">>}}},
    ?assertMatch(
        {error, #chappe_sip_error{status = 486}},
        chappe_sip_b2b:replace_b(B2b, Uri, Other)
    ),
    [Offer, Restore, Reopen, Reanswer] = sdp_cmds(),
    ?assertMatch(#{<<"x-leg">> := <<"other">>}, Offer),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag}, Restore
    ),
    ?assertMatch(
        #{<<"command">> := <<"offer">>, <<"to-tag">> := OldTag}, Reopen
    ),
    ?assertNot(maps:is_key(<<"x-leg">>, Reopen)),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag}, Reanswer
    ),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% rtpengine refuses every offer: nothing to take back, so no answer.
fork_replace_offer_refused(_Config) ->
    {B2b, _OldTag} = fork_call(),
    Fail = #{anchor_params => #{b => #{<<"x-fail">> => <<"1">>}}},
    Dests = [{<<"sip:x@127.0.0.1">>, Fail}, {<<"sip:y@127.0.0.1">>, Fail}],
    ?assertEqual(
        {error, {rejected, 500}},
        chappe_sip_b2b:replace_b(B2b, {parallel, Dests}, #{})
    ),
    ?assertMatch([#{<<"command">> := <<"offer">>}], sdp_cmds()),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% rtpengine takes the first offer and refuses the second: it gets the
%% old B's SDP back for the one it took.
fork_replace_offer_half_refused(_Config) ->
    {B2b, OldTag} = fork_call(),
    Fail = #{anchor_params => #{b => #{<<"x-fail">> => <<"1">>}}},
    Dests = [<<"sip:x@127.0.0.1">>, {<<"sip:y@127.0.0.1">>, Fail}],
    ?assertEqual(
        {error, {rejected, 500}},
        chappe_sip_b2b:replace_b(B2b, {parallel, Dests}, #{})
    ),
    Restore = lists:last(sdp_cmds()),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag},
        Restore
    ),
    ?assertNot(maps:is_key(<<"via-branch">>, Restore)),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% The app's hook refuses A's SDP: rtpengine hears nothing.
fork_replace_hook_rejects(_Config) ->
    rtpe(),
    Hook = fun(_Leg, _Kind, Sdp) -> hook_answer(Sdp) end,
    {EP, CP} = setup(#{media => anchor, rewrite_sdp => Hook}),
    callee(CP, fun(_Sock, _D) -> ok end),
    caller(EP, #{}, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    _ = drain(),
    persistent_term:put(b2b_hook_reject, true),
    R = chappe_sip_b2b:replace_b(B2b, {parallel, [<<"sip:x@127.0.0.1">>]}, #{}),
    persistent_term:erase(b2b_hook_reject),
    ?assertEqual({error, {rejected, 488}}, R),
    ?assertEqual([], drain()).

hook_answer(Sdp) ->
    case persistent_term:get(b2b_hook_reject, false) of
        true -> {reject, 488};
        false -> Sdp
    end.

%% the process that keeps the replace_b/3 going: what the relay monitors
%% beyond its two dialogs
helper(Relay, #{uas := A, uac := B}) ->
    Dialogs = [element(2, D) || D <- [A, B]],
    {monitors, Ms} = process_info(Relay, monitors),
    [Helper] = [P || {process, P} <- Ms, not lists:member(P, Dialogs)],
    Helper.

%% A helper that dies leaves no offer pending: replace_b/3 gets an error,
%% rtpengine the old B's SDP, and the next replace works.
fork_replace_helper_dies(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor, notify => self()}),
    callee(CP, fun(Sock, _D) ->
        {B, S} = ?UA:recv_req(Sock, <<"BYE">>, 20000),
        ?UA:send(Sock, S, ?UA:resp(B, 200, <<"OK">>, <<>>, [], <<>>)),
        tell(old_b_bye)
    end),
    caller(EP, #{}, fun(_Sock, _D) -> ok end),
    #{b2b := {Relay, _} = B2b, uac := OldB} = Legs = got(legs),
    OldTag = chappe_sip_dialog:remote_tag(OldB),
    _ = drain(),
    Test = self(),
    Ringing = fork_dest(one, rings(one)),
    spawn_link(fun() ->
        Test !
            {replace_result,
                chappe_sip_b2b:replace_b(B2b, {parallel, [Ringing]}, #{})}
    end),
    ok = ?UA:expect({ringing, one}),
    exit(helper(Relay, Legs), kill),
    ?assertMatch({error, {helper_down, killed}}, got(replace_result)),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag},
        lists:last(sdp_cmds())
    ),
    Uri = fork_dest(two, answers(two, <<"twotag">>, 0)),
    ?assertEqual(ok, chappe_sip_b2b:replace_b(B2b, Uri, #{})),
    ok = ?UA:expect(old_b_bye).

%% The same for a helper relaying A's re-INVITE: A gets a 500 and no offer
%% stays pending.
reinvite_helper_dies(_Config) ->
    {EP, CP} = setup(#{}),
    callee(CP, fun(Sock, _D) ->
        {Re, _} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({b_reinvite, Re})
    end),
    caller(EP, #{}, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D, <<"INVITE">>, [], ?UA:sdp(<<"caller">>, <<"1">>)
        ),
        ?UA:send(Sock, EP, Re),
        tell({a_refused, ?UA:recv_status(Sock, 500)})
    end),
    #{b2b := {Relay, _} = B2b} = Legs = got(legs),
    _ = got(b_reinvite),
    exit(helper(Relay, Legs), kill),
    _ = got(a_refused),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)).

%% The dialog of the new B dies right after its 2xx: the call keeps the
%% old B. The helper is held so the 2xx is in its mailbox when it dies.
replace_b_new_b_dies(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor}),
    callee(CP, fun(_Sock, _D) -> ok end),
    caller(EP, #{}, fun(_Sock, _D) -> ok end),
    #{b2b := {Relay, _} = B2b, uac := OldB} = Legs = got(legs),
    OldTag = chappe_sip_dialog:remote_tag(OldB),
    _ = drain(),
    Test = self(),
    Uri = fork_dest(one, answers(one, <<"onetag">>, 300)),
    spawn_link(fun() ->
        Test !
            {replace_result,
                chappe_sip_b2b:replace_b(B2b, {parallel, [Uri]}, #{})}
    end),
    _ = got(one),
    Helper = helper(Relay, Legs),
    true = erlang:suspend_process(Helper),
    D = new_b_dialog(Helper, 50),
    exit(element(2, D), kill),
    timer:sleep(50),
    true = erlang:resume_process(Helper),
    ?assertMatch({error, {new_b_down, _}}, got(replace_result)),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    ?assertMatch(
        #{<<"command">> := <<"answer">>, <<"to-tag">> := OldTag},
        lists:last(sdp_cmds())
    ).

new_b_dialog(_Helper, 0) ->
    ct:fail(no_new_b_dialog);
new_b_dialog(Helper, N) ->
    {messages, Ms} = process_info(Helper, messages),
    case [D || {chappe_sip_uac, _, {ok, D}} <- Ms] of
        [D] ->
            D;
        [] ->
            timer:sleep(100),
            new_b_dialog(Helper, N - 1)
    end.

%% info/1 follows leg B: after a fork its winner, after a URI none.
info_follows_replace(_Config) ->
    {B2b, _OldTag} = fork_call(),
    Uris = [
        fork_dest(one, busy()), fork_dest(two, answers(two, <<"twotag">>, 0))
    ],
    {ok, #{winner := Winner}} = chappe_sip_b2b:replace_b(
        B2b, {parallel, Uris}, #{}
    ),
    ?assertMatch(#{index := 2}, Winner),
    ?assertMatch(#{winner := Winner}, chappe_sip_b2b:info(B2b)),
    Uri = fork_dest(three, answers(three, <<"threetag">>, 0)),
    ok = chappe_sip_b2b:replace_b(B2b, Uri, #{}),
    ?assertMatch(#{winner := undefined}, chappe_sip_b2b:info(B2b)),
    hang_up(),
    ok = ?UA:expect({bye_of, three}).

%% The old B had the call on hold: with the new B it is not, and the
%% notify process hears of it.
replace_clears_hold(_Config) ->
    rtpe(),
    {EP, CP} = setup(#{media => anchor, notify => self()}),
    callee(CP, fun(Sock, D) ->
        {Re, _} = ?UA:in_dialog(
            D,
            <<"INVITE">>,
            [],
            sdp_dir(<<"callee">>, <<"1">>, <<"sendonly">>)
        ),
        ?UA:send(Sock, EP, Re),
        tell({b_hold, ?UA:recv_status(Sock, 200)})
    end),
    caller(EP, #{}, fun(Sock, _D) ->
        {Re, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Re,
                200,
                <<"OK">>,
                <<>>,
                [contact(Sock)],
                ?UA:sdp(<<"caller">>, <<"1">>)
            )
        )
    end),
    #{b2b := {_, Ref} = B2b} = got(legs),
    receive
        {chappe_sip_b2b, Ref, {hold, b}} -> ok
    after 6000 -> ct:fail(no_hold)
    end,
    _ = got(b_hold),
    ?assertMatch(#{hold := #{b := true}}, chappe_sip_b2b:info(B2b)),
    Uris = [fork_dest(one, answers(one, <<"onetag">>, 0))],
    {ok, _} = chappe_sip_b2b:replace_b(B2b, {parallel, Uris}, #{}),
    ?assertMatch(#{hold := #{b := false}}, chappe_sip_b2b:info(B2b)),
    receive
        {chappe_sip_b2b, Ref, {unhold, b}} -> ok
    after 2000 -> ct:fail(no_unhold)
    end.

%% A malformed target or options get badarg in the caller: the relay never
%% sees them and the call goes on.
replace_b_bad_arguments(_Config) ->
    {{Relay, _} = B2b, _OldTag} = fork_call(),
    Bad = [
        {{parallel, notalist}, #{}},
        {{parallel, [a | b]}, #{}},
        {{parallel, [123]}, #{}},
        {{parallel, [{<<"sip:x@h">>, notamap}]}, #{}},
        {{parallel, [{notabinary, #{}}]}, #{}},
        {{parallel, [{<<"sip:x@h">>, #{headers => nolist}}]}, #{}},
        {{parallel, [{<<"sip:x@h">>, #{headers => [nottuple]}}]}, #{}},
        {{parallel, [{<<"sip:x@h">>, #{anchor_params => nomap}}]}, #{}},
        {{parallel, [{<<"sip:x@h">>, #{anchor_params => #{c => #{}}}}]}, #{}},
        {
            {parallel, [
                {<<"sip:x@h">>, #{anchor_params => #{a => #{flags => x}}}}
            ]},
            #{}
        },
        {notatarget, #{}},
        {<<"sip:x@h">>, notamap},
        {<<"sip:x@h">>, #{anchor_params => nomap}},
        {<<"sip:x@h">>, #{headers => nolist}},
        {<<"sip:x@h">>, #{anchor_params => #{a => #{flags => x}}}}
    ],
    [
        ?assertEqual({error, badarg}, chappe_sip_b2b:replace_b(B2b, T, O))
     || {T, O} <- Bad
    ],
    ?assert(is_process_alive(Relay)),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    ?assertEqual([], sdp_cmds()),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% ---- from on replace_b/3 ----

%% The INVITE to a new B carries the From the app gives, under a tag of
%% its own, where it would otherwise name this node.
replace_b_from(_Config) ->
    {B2b, _OldTag} = fork_call(),
    Uri = fork_dest(one, answers(one, <<"onetag">>, 0)),
    ok = chappe_sip_b2b:replace_b(B2b, Uri, #{from => ?NEW_FROM}),
    assert_new_from(?UA:hdr(got(one), <<"from">>)),
    ok = ?UA:expect(old_b_bye),
    hang_up(),
    ok = ?UA:expect({bye_of, one}).

%% Every branch of a fork carries it, each under its own tag.
fork_replace_from(_Config) ->
    {B2b, _OldTag} = fork_call(),
    U1 = fork_dest(one, rings(one)),
    U2 = fork_dest(two, fun(S, I, Src) ->
        receive
        after 300 -> ok
        end,
        (answers(two, <<"twotag">>, 0))(S, I, Src)
    end),
    {ok, #{winner := #{index := 2}}} =
        chappe_sip_b2b:replace_b(
            B2b,
            {parallel, [U1, U2]},
            #{from => ?NEW_FROM}
        ),
    F1 = ?UA:hdr(got(one), <<"from">>),
    F2 = ?UA:hdr(got(two), <<"from">>),
    assert_new_from(F1),
    assert_new_from(F2),
    ?assertNotEqual(from_tag(F1), from_tag(F2)),
    ok = ?UA:expect(old_b_bye),
    hang_up(),
    ok = ?UA:expect({bye_of, two}).

%% A From that cannot go on the wire is refused in the caller, whatever
%% the target: no offer, no INVITE, and the call goes on. A CRLF would
%% otherwise add headers to the INVITE.
replace_b_bad_from(_Config) ->
    {{Relay, _} = B2b, _OldTag} = fork_call(),
    Bad = [
        123,
        undefined,
        "sip:alice@example.com",
        <<>>,
        <<"not a uri">>,
        <<"http://example.com/">>,
        <<"<sip:alice@example.com">>,
        <<"\"Alice <sip:alice@example.com>">>,
        <<"<sip:alice@example.com> junk">>,
        <<"sip:alice@example.com junk">>,
        <<"al@ice <sip:alice@example.com>">>,
        <<"<sip:alice@example.com>\r\nX-Injected: 1">>
    ],
    Fork = {parallel, [<<"sip:x@127.0.0.1:9">>]},
    Targets = [<<"sip:x@127.0.0.1:9">>, Fork, {dialog, app_dialog}],
    [
        ?assertEqual(
            {error, badarg},
            chappe_sip_b2b:replace_b(B2b, T, #{from => F, timer_c => 500})
        )
     || F <- Bad, T <- Targets
    ],
    ?assert(is_process_alive(Relay)),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    ?assertEqual([], sdp_cmds()),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% What reads well here but the stack refuses to send is an error too, with
%% the old B still carrying the call.
replace_b_from_refused(_Config) ->
    {{Relay, _} = B2b, _OldTag} = fork_call(),
    Uri = fork_dest(one, busy()),
    ?assertMatch(
        {error, _},
        chappe_sip_b2b:replace_b(B2b, Uri, #{from => <<"<sip:a@b>;=">>})
    ),
    receive
        {one, _} -> ct:fail(invite_sent)
    after 200 -> ok
    end,
    ?assert(is_process_alive(Relay)),
    ?assertMatch(#{pending := false}, chappe_sip_b2b:info(B2b)),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

assert_new_from(From) ->
    ?assertMatch(
        {ok, #{
            display := <<"Alice">>,
            uri := <<"sip:alice@example.com">>,
            params := #{<<"tag">> := _}
        }},
        chappe_sip_hdr:name_addr(From)
    ).

from_tag(From) ->
    {ok, #{params := #{<<"tag">> := Tag}}} = chappe_sip_hdr:name_addr(From),
    Tag.

%% No destination at all.
fork_replace_empty(_Config) ->
    {B2b, _OldTag} = fork_call(),
    ?assertEqual(
        {error, none_up},
        chappe_sip_b2b:replace_b(B2b, {parallel, []}, #{})
    ),
    ?assertEqual([], sdp_cmds()),
    hang_up(),
    ok = ?UA:expect(old_b_bye).

%% a callee that answers and then just stays in the call
setup_callee(Opts) ->
    {EP, CP} = setup(Opts),
    callee(CP, fun(_Sock, _D) -> ok end),
    {EP, CP}.

%% ---- helpers ----

setup(Opts) ->
    {EP, CP} = setup_raw(Opts),
    {EP, CP}.

%% the app bridges every INVITE to the callee port and relays
setup_raw(Opts) ->
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
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
        (
            _,
            {in,
                {'$gen_call', {Pid, _},
                    {txn, {send_stateless, _, <<"ACK ", _/binary>>, _}}}},
            _
        ) ->
            Ref = make_ref(),
            Holder ! {hold, Pid, self(), Ref},
            receive
                {Ref, held} -> done
            after 1000 -> done
            end;
        (St, _, _) ->
            St
    end,
    ok = sys:install(chappe_sip_engine, {b2b_hold, Hold, armed}).

got(Tag) ->
    receive
        {Tag, V} -> V
    after 10000 -> ct:fail({missing, Tag})
    end.

got2(Tag) ->
    receive
        {Tag, V, W} -> {V, W}
    after 10000 -> ct:fail({missing, Tag})
    end.

now_ms() -> erlang:monotonic_time(millisecond).

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%% a fake rtpengine (chappe_sip_test_rtpe) the anchored cases go through
rtpe() ->
    register(b2b_test_rtpe, chappe_sip_test_rtpe:start(self())),
    ok.

drain() ->
    receive
        {rtpe_cmd, _} = C -> [C | drain()]
    after 200 -> []
    end.

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
    {<<"Contact">>,
        <<"<sip:peer@127.0.0.1:", (integer_to_binary(?UA:lport(Sock)))/binary,
            ">">>}.

%% The callee (leg B): answers 200 with Headers, waits for the ACK, then
%% runs Fun(Sock, RawDialog).
callee(CP, Fun) -> callee(CP, #{}, Fun).

callee(CP, Opts, Fun) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(
            Sock,
            Src,
            ?UA:resp(
                Inv,
                200,
                <<"OK">>,
                Tag,
                [contact(Sock) | maps:get(headers, Opts, [])],
                ?UA:sdp(<<"callee">>)
            )
        ),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Fun(Sock, ?UA:dialog_from_invite(Sock, Inv, Tag, Src)),
        timer:sleep(infinity)
    end).

%% The caller (leg A): INVITEs the app, ACKs its 2xx, then runs
%% Fun(Sock, RawDialog).
caller(EP, Opts, Fun) ->
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(),
            from_tag => ?UA:tag(),
            headers => maps:get(headers, Opts, [])
        }),
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
        [
            <<"PRACK sip:app@127.0.0.1 SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/UDP 127.0.0.1:">>,
            P,
            <<";rport;branch=">>,
            ?UA:branch(),
            <<"\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: ">>,
            chappe_sip_msg:get(<<"from">>, I),
            <<"\r\n">>,
            <<"To: ">>,
            chappe_sip_msg:get(<<"to">>, R),
            <<"\r\n">>,
            <<"Call-ID: ">>,
            chappe_sip_msg:call_id(I),
            <<"\r\n">>,
            <<"CSeq: 2 PRACK\r\n">>,
            <<"RAck: ">>,
            RSeq,
            <<" 1 INVITE\r\n">>,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ).

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
        [
            <<"CANCEL ">>,
            chappe_sip_msg:uri(I),
            <<" SIP/2.0\r\n">>,
            <<"Via: ">>,
            chappe_sip_msg:get(<<"via">>, I),
            <<"\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: ">>,
            chappe_sip_msg:get(<<"from">>, I),
            <<"\r\n">>,
            <<"To: ">>,
            chappe_sip_msg:get(<<"to">>, I),
            <<"\r\n">>,
            <<"Call-ID: ">>,
            chappe_sip_msg:call_id(I),
            <<"\r\n">>,
            <<"CSeq: 1 CANCEL\r\n">>,
            <<"Reason: ">>,
            Reason,
            <<"\r\n">>,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ).
