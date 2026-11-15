%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Transfers a B2BUA carries out itself (transfer => auto), over real SIP
%% on loopback through a fake rtpengine.
%%
%% A gen_udp caller (leg A) calls the app, which bridges it to a gen_udp
%% callee (leg B) with media anchored and relays the call. One leg sends a
%% REFER; the B2BUA calls the target on that leg's side, so the other leg
%% keeps its media, and reports to the referrer with NOTIFYs. The flows
%% are RFC 5589's: blind (6), consultation hold (7) and attended (7.3).
-module(chappe_sip_b2b_transfer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([peer_node_calls/2]).
-export([notify_accept/1, notify_reject/1, notify_retarget/1,
         notify_from_another_node/1]).
-export([attended_ending_dialog_declined/1, attended_join_across_nodes/1]).
-export([attended_join_fails_keeps_calls/1, attended_needs_principal/1,
         attended_policy_sees_principals/1]).
-export([maddr_refused/1, own_host_other_port_refused/1, no_user_refused/1,
         domain_port_refused/1, redirect_not_followed/1]).
-export([attended_local_join/1, attended_remote_replaces/1,
         attended_other_party_refused/1]).
-export([blind_from_a/1, blind_keeps_identity/1, blind_keeps_call_ref/1,
         blind_progress_notified/1]).
-export([transferor_bye_keeps_transferee/1,
         transferor_bye_then_failure_ends_call/1]).
-export([blind_from_b/1, blind_target_fails/1, offnet_refused/1,
         policy_rejects/1, policy_sees_untrusted_referred_by/1,
         direct_media_refused/1, transfer_limit/1, bye_method_refused/1,
         one_transfer_at_a_time/1, transfer_crash_call_goes_on/1,
         call_end_stops_transfer/1, multiple_refer_unsupported/1]).

all() ->
    [blind_from_b, blind_from_a, blind_keeps_identity, blind_keeps_call_ref,
     blind_progress_notified, transferor_bye_keeps_transferee,
     transferor_bye_then_failure_ends_call,
     blind_target_fails, attended_local_join, attended_join_fails_keeps_calls,
     attended_needs_principal, attended_policy_sees_principals,
     attended_ending_dialog_declined, attended_join_across_nodes, attended_remote_replaces,
     attended_other_party_refused, notify_accept, notify_reject,
     notify_retarget, notify_from_another_node, offnet_refused,
     maddr_refused, own_host_other_port_refused, no_user_refused,
     domain_port_refused, redirect_not_followed, policy_rejects,
     policy_sees_untrusted_referred_by, direct_media_refused, transfer_limit,
     bye_method_refused, one_transfer_at_a_time, transfer_crash_call_goes_on,
     call_end_stops_transfer, multiple_refer_unsupported].

-define(UA, chappe_sip_test_ua).

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
    _ = case whereis(xfer_test_rtpe) of
            undefined -> ok;
            Rtpe -> unregister(xfer_test_rtpe), chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = [unregister(xfer_test) || whereis(xfer_test) =/= undefined],
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% ---- blind transfer (RFC 5589 6) ----

%% The callee (Bob, the transferor) REFERs the caller (Alice, the
%% transferee) to Carol. The B2BUA answers the REFER 200, never 202, sends
%% NOTIFY 100 Trying, calls Carol with Alice's media through rtpengine
%% (Alice sees no re-INVITE), sends Bob the final NOTIFY 200 with
%% terminated;reason=noresource, and only then hangs Bob up.
%% req: R7647-04 R3515-10 R3515-13 R3515-14 R3515-18 R3515-23
%% req: R5589-01 R5589-02 R5589-03 R5589-04
blind_from_b(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, answer),
    caller(EP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 4000),
        tell(caller_no_reinvite)
    end),
    #{b2b := {_, Ref}} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    N1 = got(notify),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(N1)),
    ?assertMatch(<<"message/sipfrag", _/binary>>,
                 ?UA:hdr(N1, <<"content-type">>)),
    ?assertMatch(<<"refer", _/binary>>, ?UA:hdr(N1, <<"event">>)),
    ?assertMatch(<<"active", _/binary>>, ?UA:hdr(N1, <<"subscription-state">>)),
    Inv = got(target_invite),
    ?assert(chappe_sip_test_rtpe:marked(?UA:body(Inv), offer)),
    N2 = got(notify),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(N2)),
    ?assertEqual(<<"terminated;reason=noresource">>,
                 ?UA:hdr(N2, <<"subscription-state">>)),
    %% the BYE comes after the final NOTIFY
    _ = got(bye),
    ok = ?UA:expect(caller_no_reinvite, 6000),
    ok = expect_event(Ref, {transfer, b}),
    ok = expect_event(Ref, {replaced, b}),
    ok = expect_event(Ref, {transferred, b}).

%% The caller (Alice) transfers the callee (Bob) to Carol: the leg that
%% sent the REFER is the one replaced, from either side. Bob keeps his
%% media and sees no re-INVITE; Alice gets the NOTIFYs, then the BYE.
%% req: R5589-01 R5589-02 R5589-03 R5589-04
blind_from_a(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee(CP, fun(Sock) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 4000),
        tell(callee_no_reinvite)
    end),
    target(NP, answer),
    caller(EP, fun(Sock, D) ->
        {Refer, _} = ?UA:in_dialog(D, <<"REFER">>,
                                   [{<<"Refer-To">>, refer_to(NP)}], <<>>),
        ?UA:send(Sock, EP, Refer),
        serve(Sock, <<>>)
    end),
    #{b2b := {_, Ref}} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(got(notify))),
    Inv = got(target_invite),
    ?assert(chappe_sip_test_rtpe:marked(?UA:body(Inv), offer)),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(got(notify))),
    _ = got(bye),
    ok = ?UA:expect(callee_no_reinvite, 6000),
    ok = expect_event(Ref, {replaced, a}),
    ok = expect_event(Ref, {transferred, a}).

%% Carol's INVITE presents the identity Bob saw on his leg (the From Bob
%% got: Alice's), and carries Bob's Referred-By unchanged (RFC 3892 2.2).
%% req: R3892-02 R3892-05
blind_keeps_identity(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    RB = <<"\"Bob\" <sip:bob@example.com>;cid=\"x@example.com\"">>,
    callee_refers(CP, EP, refer_to(NP), [{<<"Referred-By">>, RB}]),
    target(NP, answer),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    Inv = got(target_invite),
    ?assertEqual(RB, ?UA:hdr(Inv, <<"referred-by">>)),
    {ok, #{uri := From}} =
        chappe_sip_hdr:name_addr(?UA:hdr(Inv, <<"from">>)),
    ?assertMatch(<<"sip:caller@127.0.0.1:", _/binary>>, From).

%% The transferee keeps its call_ref: Carol's leg carries it as
%% X-Chappe-Call, and its call record names it with related, the call it
%% came from (the guide's "Follow a call").
blind_keeps_call_ref(_Config) ->
    ok = chappe_sip_cdr:subscribe(self()),
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, answer),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b, call_ref := CallRef} = got(legs),
    Inv = got(target_invite),
    ?assertEqual(CallRef, ?UA:hdr(Inv, <<"x-chappe-call">>)),
    _ = got(bye),
    ?assertMatch(#{call_ref := CallRef}, chappe_sip_b2b:info(B2b)),
    ?assert(related_record(CallRef, 50)).

%% Carol rings before she answers: Bob hears it, a NOTIFY 180 between
%% 100 Trying and the final 200 (RFC 3515 2.4.4, RFC 5589 6.1), each one
%% a second or more after the last (RFC 3515 3.10).
%% req: R3515-11 R3515-26 R5589-02
blind_progress_notified(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, ring_then_answer),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    T0 = erlang:monotonic_time(millisecond),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(got(notify))),
    ?assertEqual(<<"SIP/2.0 180 Ringing\r\n">>, ?UA:body(got(notify))),
    T1 = erlang:monotonic_time(millisecond),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(got(notify))),
    T2 = erlang:monotonic_time(millisecond),
    ?assert(T2 - T1 >= 900),
    ?assert(T1 - T0 >= 0),
    _ = got(bye).

%% Bob hangs up as soon as his REFER has its 200, while Carol still rings
%% (RFC 5589 6: the transferor may BYE once the REFER transaction
%% completes). The transfer goes on: Carol is not CANCELled, she takes
%% Bob's place when she answers, and Alice gets no BYE.
%% req: R5589-01
transferor_bye_keeps_transferee(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers_then_bye(CP, EP, refer_to(NP)),
    target(NP, ring_then_answer),
    caller(EP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"BYE">>, 5000),
        tell(caller_kept)
    end),
    #{b2b := {_, Ref} = B2b} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    ok = ?UA:expect(bob_hung_up, 10000),
    ok = expect_event(Ref, {replaced, b}),
    ok = expect_event(Ref, {transferred, b}),
    ok = ?UA:expect(caller_kept, 8000),
    #{parties := #{b := Party}} = chappe_sip_b2b:info(B2b),
    ?assertMatch(<<"<sip:carol@", _/binary>>, Party).

%% Bob hangs up while Carol rings, and Carol is busy: nobody is left for
%% Alice, so the call ends cleanly, Alice with a BYE.
%% req: R5589-05
transferor_bye_then_failure_ends_call(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers_then_bye(CP, EP, refer_to(NP)),
    target(NP, ring_then_busy),
    caller(EP, fun(Sock, _D) ->
        {Bye, Src} = ?UA:recv_req(Sock, <<"BYE">>, 8000),
        ?UA:send(Sock, Src, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        tell(caller_byed)
    end),
    #{b2b := {_, Ref}} = got(legs),
    ok = ?UA:expect(bob_hung_up, 10000),
    ok = expect_event(Ref, {transfer_failed, b}),
    ok = ?UA:expect(caller_byed, 8000),
    ?assertEqual({done, b_bye}, got(relay_done)).

%% Carol is busy: Bob's final NOTIFY carries 486, Bob keeps the call and
%% gets no BYE, and Alice saw nothing.
%% req: R5589-02 R5589-05
blind_target_fails(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, busy),
    caller(EP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 3000),
        tell(caller_no_reinvite)
    end),
    #{b2b := {_, Ref} = B2b} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    _ = got(notify),
    N2 = got(notify),
    ?assertEqual(<<"SIP/2.0 486 Busy Here\r\n">>, ?UA:body(N2)),
    ok = expect_event(Ref, {transfer_failed, b}),
    ok = ?UA:expect(caller_no_reinvite, 6000),
    no_message(bye, 500),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% ---- attended transfer (RFC 5589 7.3) ----

%% Alice calls Bob; Bob calls Carol (both through the B2BUA), then REFERs
%% Alice to Carol with a Replaces naming his call with Carol. That dialog
%% is a leg of a call of this node: Carol's leg leaves her call with Bob
%% (Bob's leg there gets a BYE) and takes Bob's place in Alice's call
%% with a re-INVITE from rtpengine; no new INVITE goes out, Alice sees
%% nothing, and Bob gets the final NOTIFY, then a BYE on his first call.
%% req: R5589-04 R5589-10
attended_local_join(_Config) ->
    {EP, CP} = setup(#{principals => bob()}),
    NP = route_carol(?UA:pick()),
    carol(NP),
    bob_consults(CP, EP, fun(_C2, _BT2, _TT2) -> NP end),
    caller(EP, fun(Sock, _D) ->
        ok = ?UA:no_req(Sock, <<"INVITE">>, 5000),
        tell(caller_no_reinvite)
    end),
    #{b2b := {_, Ref}} = got(legs),
    #{b2b := B2b2} = got(legs_carol),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(got(notify))),
    ReInv = got(carol_reinvite),
    ?assert(chappe_sip_test_rtpe:marked(?UA:body(ReInv), offer)),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(got(notify))),
    Byes = lists:sort([?UA:hdr(got(bye), <<"call-id">>) || _ <- [1, 2]]),
    ?assertEqual(2, length(lists:usort(Byes))),
    ok = expect_event(Ref, {transferred, b}),
    ok = ?UA:expect({relay_done_carol, {done, transferred}}),
    ?assertEqual({error, noproc}, chappe_sip_b2b:info(B2b2)),
    ok = ?UA:expect(caller_no_reinvite, 8000),
    no_message(carol_invite, 200).

%% The local join fails: Carol refuses the re-INVITE that would take her
%% into Alice's call. Her leg goes back to her call with Bob, so nobody is
%% hung up: Bob's final NOTIFY carries the 488, and both calls go on.
%% req: R5589-05
attended_join_fails_keeps_calls(_Config) ->
    {EP, CP} = setup(#{principals => bob()}),
    NP = route_carol(?UA:pick()),
    carol(NP, refuse_reinvite),
    bob_consults(CP, EP, fun(_C2, _BT2, _TT2) -> NP end),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b1} = got(legs),
    #{b2b := B2b2} = got(legs_carol),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(got(notify))),
    _ = got(carol_reinvite),
    ?assertEqual(<<"SIP/2.0 488 Not Acceptable Here\r\n">>,
                 ?UA:body(got(notify))),
    no_message(carol_bye, 1000),
    no_message(bye, 200),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b1)),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b2)),
    %% the leg is call 2's again: hanging that call up reaches Carol
    ok = chappe_sip_b2b:hangup(B2b2, #{}),
    _ = got(carol_bye).

%% Bob names his own call with Carol, under the same From on both calls,
%% but the app recorded no principal for him: nothing authenticated that
%% From, so the join is refused 403 and Carol's call is left alone (RFC
%% 3891 3).
%% req: R3891-07
attended_needs_principal(_Config) ->
    {EP, CP} = setup(#{}),
    NP = route_carol(?UA:pick()),
    carol(NP),
    bob_consults(CP, EP, fun(_C2, _BT2, _TT2) -> NP end),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    #{b2b := B2b2} = got(legs_carol),
    ?assertEqual(403, ?UA:status(got(refer_answer))),
    no_message(carol_reinvite, 500),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b2)).

%% Bob names his call with Carol while that call ends (its BYE to Bob is
%% in flight): the REFER gets 603, as an INVITE naming a terminated dialog
%% does (RFC 3891 3). Not 481: in a dialog a 481 tells Bob his call with
%% Alice is gone (RFC 3261 12.2.1.2).
attended_ending_dialog_declined(_Config) ->
    {EP, CP} = setup(#{principals => bob()}),
    NP = route_carol(?UA:pick()),
    carol(NP),
    Test = self(),
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D1 = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        C2 = ?UA:callid(),
        BT2 = ?UA:tag(),
        Inv2 = binary:replace(
                 ?UA:invite(Sock, EP, #{call_id => C2, from_tag => BT2,
                                        ruri => <<"sip:carol@127.0.0.1">>}),
                 <<"From: <sip:caller@">>, <<"From: <sip:callee@">>),
        ?UA:send(Sock, EP, Inv2),
        R2 = ?UA:recv_status(Sock, 200),
        ?UA:ack(?UA:dialog_from_2xx(Sock, Inv2, R2), EP),
        Test ! bob_consulted,
        %% the BYE of his call with Carol: left unanswered
        {_Bye, _} = ?UA:recv_req(Sock, <<"BYE">>),
        RT = chappe_sip_hdr:refer_to_value(#{
            uri => <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
            replaces => #{call_id => C2, to_tag => ?UA:to_tag(R2),
                          from_tag => BT2}
        }),
        {Refer, _} = ?UA:in_dialog(D1, <<"REFER">>,
                                   [{<<"Refer-To">>, RT}], <<>>),
        ?UA:send(Sock, EP, Refer),
        refer_answer(Sock)
    end),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    #{b2b := B2b2} = got(legs_carol),
    ok = ?UA:expect(bob_consulted, 10000),
    _ = spawn(fun() -> chappe_sip_b2b:hangup(B2b2, #{}) end),
    ?assertEqual(603, ?UA:status(got(refer_answer))).

%% tell the test of the REFER's final; nothing else is answered
refer_answer(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} ->
            refer_answer(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = R} ->
            case maps:get(method, ?UA:cseq(R)) of
                <<"REFER">> -> tell({refer_answer, R});
                _ -> ok
            end,
            refer_answer(Sock);
        {udp, Sock, _, _, _} ->
            refer_answer(Sock)
    end.

%% An app policy decides a local join: it sees the principal of the
%% referrer's leg and the one of the leg the Replaces names.
attended_policy_sees_principals(_Config) ->
    Test = self(),
    Policy = fun(Info) -> Test ! {policy_info, Info}, false end,
    {EP, CP} = setup(#{principals => {#{b => <<"bob">>}, #{a => <<"eve">>}},
                       transfer_opts => #{policy => Policy}}),
    NP = route_carol(?UA:pick()),
    carol(NP),
    bob_consults(CP, EP, fun(_C2, _BT2, _TT2) -> NP end),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    _ = got(legs_carol),
    ?assertMatch(#{kind := attended, local := true, principal := <<"bob">>,
                   replaces_principal := <<"eve">>},
                 got(policy_info)),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% Bob is the callee of the first call and the caller of his call with
%% Carol: the app recorded him on both
bob() ->
    {#{b => <<"bob">>}, #{a => <<"bob">>}}.

%% The Replaces names no dialog of this node: the target gets an INVITE
%% carrying it, with Require: replaces, and the Referred-By.
%% req: R3891-15 R5589-11
attended_remote_replaces(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    RT = chappe_sip_hdr:refer_to_value(#{
        uri => <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
        replaces => #{call_id => <<"elsewhere@h">>, to_tag => <<"t1">>,
                      from_tag => <<"f1">>}
    }),
    callee_refers(CP, EP, RT, []),
    target(NP, answer),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    Inv = got(target_invite),
    ?assertEqual(<<"elsewhere@h;to-tag=t1;from-tag=f1">>,
                 ?UA:hdr(Inv, <<"replaces">>)),
    ?assertEqual(<<"replaces">>, ?UA:hdr(Inv, <<"require">>)),
    _ = got(notify),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(got(notify))).

%% Bob names a dialog of this node he is not a party to (Dave's call with
%% Carol): refused 403, and Dave's call goes on untouched.
%% req: R3891-07 R5589-12
attended_other_party_refused(_Config) ->
    {EP, CP} = setup(#{}),
    NP = route_carol(?UA:pick()),
    carol(NP),
    %% Dave calls Carol
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(),
                                     from_tag => ?UA:tag(),
                                     ruri => <<"sip:carol@127.0.0.1">>}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Test ! {dave_call, D, ?UA:to_tag(R)},
        serve(Sock, <<>>)
    end),
    #{b2b := DaveCall} = got(legs_carol),
    {#{call_id := C2, from := DFrom}, TT2} = got2(dave_call),
    {ok, #{params := #{<<"tag">> := DTag}}} = chappe_sip_hdr:name_addr(DFrom),
    RT = chappe_sip_hdr:refer_to_value(#{
        uri => <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
        replaces => #{call_id => C2, to_tag => TT2, from_tag => DTag}
    }),
    callee_refers(CP, EP, RT, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))),
    timer:sleep(300),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(DaveCall)),
    no_message(bye, 300).

%% ---- transfer => notify ----

%% The app decides: it gets {refer, Info} and accepts; the transfer then
%% runs as with auto.
%% req: R3515-04
notify_accept(_Config) ->
    {EP, CP} = setup(#{transfer => notify}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, answer),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := {_, Ref}} = got(legs),
    Info = refer_event(Ref),
    ?assertMatch(#{kind := blind, leg := b, referrer := <<"<sip:callee@", _/binary>>},
                 Info),
    no_message(refer_answer, 300),
    ok = chappe_sip_b2b_transfer:accept(Info, #{}),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    _ = got(target_invite),
    _ = got(bye),
    ok = expect_event(Ref, {transferred, b}).

%% The app refuses with its code; nothing is called.
notify_reject(_Config) ->
    {EP, CP} = setup(#{transfer => notify}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := {_, Ref}} = got(legs),
    Info = refer_event(Ref),
    ?assertEqual({error, badarg}, chappe_sip_b2b_transfer:reject(Info, 200)),
    ok = chappe_sip_b2b_transfer:reject(Info, 603),
    ?assertEqual(603, ?UA:status(got(refer_answer))),
    no_message(notify, 500).

%% The app sends the transferee somewhere else than the REFER asked.
notify_retarget(_Config) ->
    {EP, CP} = setup(#{transfer => notify}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, <<"<sip:carol@203.0.113.9>">>, []),
    target(NP, answer),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := {_, Ref}} = got(legs),
    Info = refer_event(Ref),
    Other = <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    ok = chappe_sip_b2b_transfer:accept(Info, #{target => Other}),
    Inv = got(target_invite),
    ?assertMatch(<<"INVITE ", Other:(byte_size(Other))/binary, _/binary>>, Inv).

%% chappe-erlang-patterns: the notify process is on another node; it gets
%% {refer, Info} there and accepts from there.
notify_from_another_node(_Config) ->
    ok = chappe_sip_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(),
                                         args => Paths}),
    try
        Test = self(),
        Remote = erpc:call(Node, erlang, spawn, [fun() -> remote_app(Test) end]),
        {EP, CP} = setup(#{transfer => notify, notify => Remote}),
        NP = ?UA:pick(),
        callee_refers(CP, EP, refer_to(NP), []),
        target(NP, answer),
        caller(EP, fun(_Sock, _D) -> ok end),
        _ = got(legs),
        ?assertEqual(Node, got(remote_accepted)),
        ?assertEqual(200, ?UA:status(got(refer_answer))),
        _ = got(target_invite),
        ?assertMatch({transferred, b, _}, got(remote_event))
    after
        peer:stop(Peer)
    end.

%% chappe-erlang-patterns: Bob's call with Carol runs on another node
%% (its own chappe_sip and rtpengine). The transfer finds the dialog the
%% Replaces names through the `chappe_sip' pg scope and the call_ref
%% lookup, and the call there lends Carol's leg: she joins Alice's call
%% with a re-INVITE, and both of Bob's calls end.
%% req: R5589-10
attended_join_across_nodes(_Config) ->
    ok = chappe_sip_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(),
                                         args => Paths}),
    try
        {EP, CP} = setup(#{principal => #{b => <<"bob">>}}),
        NP = ?UA:pick(),
        EP2 = erpc:call(Node, ?MODULE, peer_node_calls, [self(), NP]),
        carol(NP),
        bob_consults(CP, EP, EP2, fun(_C2, _BT2, _TT2) -> NP end),
        caller(EP, fun(Sock, _D) ->
            ok = ?UA:no_req(Sock, <<"INVITE">>, 5000),
            tell(caller_no_reinvite)
        end),
        #{b2b := {_, Ref}} = got(legs),
        #{b2b := {Relay2, _}} = got(legs_carol),
        ?assertEqual(Node, node(Relay2)),
        ?assertEqual(200, ?UA:status(got(refer_answer))),
        ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, ?UA:body(got(notify))),
        ReInv = got(carol_reinvite),
        ?assert(chappe_sip_test_rtpe:marked(?UA:body(ReInv), offer)),
        ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, ?UA:body(got(notify))),
        Byes = lists:sort([?UA:hdr(got(bye), <<"call-id">>) || _ <- [1, 2]]),
        ?assertEqual(2, length(lists:usort(Byes))),
        ok = expect_event(Ref, {transferred, b}),
        ok = ?UA:expect({relay_done_carol, {done, transferred}}, 8000),
        ok = ?UA:expect(caller_no_reinvite, 8000)
    after
        peer:stop(Peer)
    end.

%% On the peer node: chappe_sip on a port of its own, behind a fake
%% rtpengine of its own, bridging every INVITE to Carol (port NP) with
%% Bob recorded as its caller. Returns its port.
peer_node_calls(Test, NP) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    _ = chappe_sip_test_rtpe:start(spawn(fun sink/0)),
    EP2 = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                         (integer_to_binary(EP2))/binary>>}),
    Carol = <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Carol, #{
            media => anchor, principal => #{a => <<"bob">>}
        }),
        Test ! {legs_carol, Legs},
        Test ! {relay_done_carol, chappe_sip_b2b:relay(Legs)}
    end),
    EP2.

%% on the peer node: accept each REFER, pass the call's events on
remote_app(Test) ->
    receive
        {chappe_sip_b2b, _Ref, {refer, Info}} ->
            ok = chappe_sip_b2b_transfer:accept(Info, #{}),
            Test ! {remote_accepted, node()},
            remote_app(Test);
        {chappe_sip_b2b, _Ref, {transferred, _, _} = Ev} ->
            Test ! {remote_event, Ev},
            remote_app(Test);
        _ ->
            remote_app(Test)
    end.


refer_event(Ref) ->
    receive {chappe_sip_b2b, Ref, {refer, Info}} -> Info
    after 10000 -> ct:fail(no_refer_event)
    end.

%% ---- policy and safety ----

%% Without a policy fun a target off this node's domains (another host, a
%% tel: number) is refused 403 before anything is called: a REFER cannot
%% place a call the referrer could not make itself.
%% req: R3515-04 R5589-06
offnet_refused(_Config) ->
    {EP, CP} = setup(#{}),
    callee_refers(CP, EP, <<"<sip:carol@203.0.113.9>">>, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))),
    no_message(notify, 1000).

%% A target on one of the call's domains whose maddr sends the INVITE
%% elsewhere is off-net: refused 403.
%% req: R5589-06
maddr_refused(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, <<"<sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary,
                            ";maddr=203.0.113.9>">>, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))),
    no_message(notify, 500).

%% Without domains, a target must be this node at its own address: the
%% same host on another port is another service, refused 403.
%% req: R5589-06
own_host_other_port_refused(_Config) ->
    {EP, CP} = setup(#{transfer_opts => #{}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))),
    no_message(notify, 500).

%% A target with no user names a server, not a party: refused 403.
%% req: R5589-06
no_user_refused(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, <<"<sip:127.0.0.1:", (integer_to_binary(NP))/binary,
                            ">">>, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A domain that names a port takes only that port.
%% req: R5589-06
domain_port_refused(_Config) ->
    {EP, CP} = setup(#{transfer_opts => #{domains => [<<"127.0.0.1:9">>]}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% The target redirects (302): the transfer leg does not follow it, so a
%% REFER cannot reach through a redirect a target the policy never saw.
%% Bob's final NOTIFY carries the 302, and the call stays as it was.
%% req: R5589-06
redirect_not_followed(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, redirect),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    _ = got(target_invite),
    _ = got(notify),
    ?assertMatch(<<"SIP/2.0 302 ", _/binary>>, ?UA:body(got(notify))),
    no_message(target_invite, 1000),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)).

%% A policy fun decides, with the code it gives.
policy_rejects(_Config) ->
    Policy = fun(#{target := _}) -> {reject, 603} end,
    {EP, CP} = setup(#{transfer_opts => #{policy => Policy}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(603, ?UA:status(got(refer_answer))),
    no_message(notify, 1000).

%% The policy sees the REFER's From (the identity its dialog was formed
%% with) apart from the Referred-By it claims, which nothing checked
%% (RFC 3892 6): a Referred-By naming someone else changes nothing.
%% req: R5589-07
policy_sees_untrusted_referred_by(_Config) ->
    Test = self(),
    Policy = fun(Info) -> Test ! {policy_info, Info}, false end,
    {EP, CP} = setup(#{transfer_opts => #{policy => Policy}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP),
                  [{<<"Referred-By">>, <<"<sip:ceo@example.com>">>}]),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    #{referrer := Referrer, referred_by := Claimed, leg := b, kind := blind} =
        got(policy_info),
    ?assertMatch(<<"<sip:callee@", _/binary>>, Referrer),
    ?assertEqual(<<"<sip:ceo@example.com>">>, Claimed),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A direct-media call cannot take a new party behind the anchor: 488,
%% and the call goes on.
direct_media_refused(_Config) ->
    {EP, CP} = setup_opts(#{media => direct, notify => self(),
                            transfer => auto}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(488, ?UA:status(got(refer_answer))).

%% A call makes at most max_transfers transfers: a loop of REFERs ends.
%% req: R5589-08
transfer_limit(_Config) ->
    {EP, CP} = setup(#{transfer_opts => #{max_transfers => 0}}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A REFER for a BYE on a call is not a transfer.
%% req: R5368-02
bye_method_refused(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    Uri = <<"<sip:new@127.0.0.1:", (integer_to_binary(NP))/binary,
            ";method=BYE>">>,
    callee_refers(CP, EP, Uri, []),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    ?assertEqual(403, ?UA:status(got(refer_answer))).

%% A second REFER while the first one rings is answered 500 with
%% Retry-After; the first goes on.
%% req: R5589-08
one_transfer_at_a_time(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), [], 2),
    target(NP, ring),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    Answers = lists:sort([{?UA:status(R), R} || R <- [got(refer_answer),
                                                      got(refer_answer)]]),
    ?assertMatch([{200, _}, {500, _}], Answers),
    [_, {500, R2}] = Answers,
    ?assertNotEqual(undefined, ?UA:hdr(R2, <<"retry-after">>)).

%% chappe-erlang-patterns: the transfer process crashes while the target
%% rings; the call goes on and takes a new transfer.
transfer_crash_call_goes_on(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, ring),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    ?assertEqual(200, ?UA:status(got(refer_answer))),
    _ = got(target_invite),
    [T] = transfers(),
    exit(T, kill),
    timer:sleep(200),
    ?assertMatch(#{media := anchor}, chappe_sip_b2b:info(B2b)),
    ?assertEqual([], transfers()).

%% chappe-erlang-patterns: the call ends (its relay, the transfer's
%% owner, goes) while the target rings: the transfer stops with it.
call_end_stops_transfer(_Config) ->
    {EP, CP} = setup(#{}),
    NP = ?UA:pick(),
    callee_refers(CP, EP, refer_to(NP), []),
    target(NP, ring),
    caller(EP, fun(_Sock, _D) -> ok end),
    #{b2b := B2b} = got(legs),
    _ = got(target_invite),
    [T] = transfers(),
    Mon = erlang:monitor(process, T),
    ok = chappe_sip_b2b:hangup(B2b, #{}),
    receive {'DOWN', Mon, process, T, _} -> ok
    after 5000 -> ct:fail(transfer_outlived_call)
    end.

%% RFC 5368: a REFER with several targets needs multiple-refer, which a
%% B2BUA call does not support: 420 with Unsupported, nothing called.
%% req: R5368-01
multiple_refer_unsupported(_Config) ->
    {EP, CP} = setup(#{}),
    callee_refers(CP, EP, <<"<cid:list@example.com>">>,
                  [{<<"Require">>, <<"multiple-refer">>}]),
    caller(EP, fun(_Sock, _D) -> ok end),
    _ = got(legs),
    R = got(refer_answer),
    ?assertEqual(420, ?UA:status(R)),
    ?assertEqual(<<"multiple-refer">>, ?UA:hdr(R, <<"unsupported">>)).

%% ---- helpers ----

%% the call's domains take loopback on any port: the targets of these
%% cases are peers on ports of their own
setup(Opts) ->
    setup_opts(maps:merge(#{media => anchor, notify => self(),
                            transfer => auto,
                            transfer_opts => #{domains => [<<"127.0.0.1">>]}},
                          Opts)).

%% the app bridges every INVITE to the callee port and relays
setup_opts(Opts) ->
    rtpe(),
    EP = ?UA:pick(),
    CP = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                         (integer_to_binary(EP))/binary>>}),
    Test = self(),
    register(xfer_test, Test),
    Callee = <<"sip:callee@127.0.0.1:", (integer_to_binary(CP))/binary>>,
    {Main, Carols} = principals(Opts),
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip_uri:parse(chappe_sip_req:uri(Req)) of
            {ok, #{user := <<"carol">>}} ->
                NP = persistent_term:get(xfer_carol),
                Carol = <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
                {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Carol, Carols),
                Test ! {legs_carol, Legs},
                Test ! {relay_done_carol, chappe_sip_b2b:relay(Legs)};
            _ ->
                case chappe_sip:create_b2bua(Req, Res, Callee, Main) of
                    {ok, Legs} ->
                        Test ! {legs, Legs},
                        Test ! b2b_up,
                        Test ! {relay_done, chappe_sip_b2b:relay(Legs)};
                    Err ->
                        Test ! {b2b_result, Err}
                end
        end
    end),
    {EP, CP}.

%% the options of the first call and of Carol's: principals =>
%% {MainPrincipal, CarolsPrincipal} sets the principal of each
principals(#{principals := {PM, PC}} = Opts0) ->
    Opts = maps:remove(principals, Opts0),
    {Opts#{principal => PM}, Opts#{principal => PC}};
principals(Opts) ->
    {Opts, Opts}.

rtpe() ->
    register(xfer_test_rtpe, chappe_sip_test_rtpe:start(spawn(fun sink/0))),
    ok.

sink() -> receive _ -> sink() end.

%% a peer may outlive its case: what it says then goes nowhere
tell(Msg) ->
    case whereis(xfer_test) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.

refer_to(Port) ->
    <<"<sip:carol@127.0.0.1:", (integer_to_binary(Port))/binary, ">">>.

%% The callee (Bob): answers the INVITE, then sends N REFERs to Uri and
%% serves the dialog: each REFER's final is refer_answer, each NOTIFY is
%% answered 200 (notify), a BYE 200 (bye).
callee_refers(CP, EP, ReferTo, Hdrs) ->
    callee_refers(CP, EP, ReferTo, Hdrs, 1).

callee_refers(CP, EP, ReferTo, Hdrs, N) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D0 = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        lists:foldl(
          fun(_, D) ->
              {Refer, D1} = ?UA:in_dialog(D, <<"REFER">>,
                                          [{<<"Refer-To">>, ReferTo} | Hdrs],
                                          <<>>),
              ?UA:send(Sock, EP, Refer),
              D1
          end, D0, lists:seq(1, N)),
        serve(Sock, Tag)
    end).

%% The callee (Bob) REFERs to ReferTo, and sends a BYE as soon as the
%% REFER has its 200 (bob_hung_up).
callee_refers_then_bye(CP, EP, ReferTo) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D0 = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        {Refer, D1} = ?UA:in_dialog(D0, <<"REFER">>,
                                    [{<<"Refer-To">>, ReferTo}], <<>>),
        ?UA:send(Sock, EP, Refer),
        refer_ok(Sock, Tag),
        {Bye, _} = ?UA:in_dialog(D1, <<"BYE">>, [], <<>>),
        ?UA:send(Sock, EP, Bye),
        tell(bob_hung_up),
        serve(Sock, Tag)
    end).

%% wait for the REFER's final, answering NOTIFYs meanwhile
refer_ok(Sock, Tag) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} ->
            refer_ok(Sock, Tag);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = R} ->
            case maps:get(method, ?UA:cseq(R)) of
                <<"REFER">> -> tell({refer_answer, R});
                _ -> refer_ok(Sock, Tag)
            end;
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = N} ->
            ?UA:send(Sock, Src, ?UA:resp(N, 200, <<"OK">>, Tag, [], <<>>)),
            tell({notify, N}),
            refer_ok(Sock, Tag);
        {udp, Sock, _, _, _} ->
            refer_ok(Sock, Tag)
    after 10000 ->
        ok
    end.

%% answer what the B2BUA sends a peer, and tell the test
serve(Sock, Tag) ->
    receive
        {udp, Sock, _, Src, <<"SIP/2.0 1", _/binary>>} when is_integer(Src) ->
            serve(Sock, Tag);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = R} ->
            case maps:get(method, ?UA:cseq(R)) of
                <<"REFER">> -> tell({refer_answer, R});
                _ -> ok
            end,
            serve(Sock, Tag);
        {udp, Sock, _, Src, <<"NOTIFY ", _/binary>> = N} ->
            ?UA:send(Sock, Src, ?UA:resp(N, 200, <<"OK">>, Tag, [], <<>>)),
            tell({notify, N}),
            serve(Sock, Tag);
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = B} ->
            ?UA:send(Sock, Src, ?UA:resp(B, 200, <<"OK">>, Tag, [], <<>>)),
            tell({bye, B}),
            serve(Sock, Tag);
        {udp, Sock, _, _, _} ->
            serve(Sock, Tag)
    end.

%% INVITEs to sip:carol@... go to Carol's port, in a call of their own
route_carol(NP) ->
    persistent_term:put(xfer_carol, NP),
    NP.

%% Carol: answers her INVITE, then a re-INVITE (carol_reinvite); a second
%% INVITE outside her dialog is carol_invite.
carol(NP) ->
    carol(NP, accept_reinvite).

carol(NP, How) ->
    ?UA:peer(NP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"carol">>))),
        {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
        carol_loop(Sock, Tag, How)
    end).

carol_loop(Sock, Tag, How) ->
    receive
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = Inv} ->
            case ?UA:to_tag(Inv) of
                undefined -> tell({carol_invite, Inv});
                _ -> tell({carol_reinvite, Inv})
            end,
            case How of
                accept_reinvite ->
                    ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag,
                                                 [contact(Sock)],
                                                 ?UA:sdp(<<"carol">>, <<"1">>)));
                refuse_reinvite ->
                    ?UA:send(Sock, Src, ?UA:resp(Inv, 488,
                                                 <<"Not Acceptable Here">>,
                                                 Tag, [], <<>>))
            end,
            carol_loop(Sock, Tag, How);
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = B} ->
            ?UA:send(Sock, Src, ?UA:resp(B, 200, <<"OK">>, Tag, [], <<>>)),
            tell({carol_bye, B}),
            carol_loop(Sock, Tag, How);
        {udp, Sock, _, _, _} ->
            carol_loop(Sock, Tag, How)
    end.

%% Bob: answers Alice's call, calls Carol through the B2BUA under the
%% same identity, then REFERs Alice to Carol with a Replaces naming his
%% call with Carol (Port(CallId2, BobTag2, ToTag2) gives Carol's port).
bob_consults(CP, EP, Port) ->
    bob_consults(CP, EP, EP, Port).

%% the same, Bob's call with Carol through the node listening on EP2
bob_consults(CP, EP, EP2, Port) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        D1 = ?UA:dialog_from_invite(Sock, Inv, Tag, Src),
        C2 = ?UA:callid(),
        BT2 = ?UA:tag(),
        Inv2 = binary:replace(
                 ?UA:invite(Sock, EP2, #{call_id => C2, from_tag => BT2,
                                         ruri => <<"sip:carol@127.0.0.1">>}),
                 <<"From: <sip:caller@">>, <<"From: <sip:callee@">>),
        ?UA:send(Sock, EP2, Inv2),
        R2 = ?UA:recv_status(Sock, 200),
        D2 = ?UA:dialog_from_2xx(Sock, Inv2, R2),
        ?UA:ack(D2, EP2),
        TT2 = ?UA:to_tag(R2),
        NP = Port(C2, BT2, TT2),
        RT = chappe_sip_hdr:refer_to_value(#{
            uri => <<"sip:carol@127.0.0.1:", (integer_to_binary(NP))/binary>>,
            replaces => #{call_id => C2, to_tag => TT2, from_tag => BT2}
        }),
        {Refer, _} = ?UA:in_dialog(D1, <<"REFER">>,
                                   [{<<"Refer-To">>, RT}], <<>>),
        ?UA:send(Sock, EP, Refer),
        serve(Sock, Tag)
    end).

%% The callee (Bob) that only answers, then runs Fun(Sock).
callee(CP, Fun) ->
    ?UA:peer(CP, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        Tag = ?UA:tag(),
        ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag, [contact(Sock)],
                                     ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Fun(Sock),
        serve(Sock, Tag)
    end).

%% a call record of the call with related set to it
related_record(_CallRef, 0) ->
    false;
related_record(CallRef, N) ->
    receive
        {chappe_sip_cdr, _, #{call_ref := CallRef, related := CallRef}} -> true;
        {chappe_sip_cdr, _, _} -> related_record(CallRef, N - 1)
    after 5000 -> false
    end.

%% a redirected target: tell the test of any INVITE that follows
serve_invites(Sock) ->
    receive
        {udp, Sock, _, _, <<"INVITE ", _/binary>> = Inv} ->
            tell({target_invite, Inv}),
            serve_invites(Sock);
        {udp, Sock, _, _, _} ->
            serve_invites(Sock)
    end.

%% The transfer target (Carol): answer, busy or ring for ever.
target(Port, How) ->
    ?UA:peer(Port, fun(Sock) ->
        {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
        tell({target_invite, Inv}),
        Tag = ?UA:tag(),
        case How of
            answer ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag,
                                             [contact(Sock)],
                                             ?UA:sdp(<<"carol">>))),
                {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
                serve(Sock, Tag);
            busy ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 486, <<"Busy Here">>, Tag,
                                             [], <<>>)),
                serve(Sock, Tag);
            ring ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag,
                                             [contact(Sock)], <<>>)),
                serve(Sock, Tag);
            redirect ->
                Moved = {<<"Contact">>, <<"<sip:dave@127.0.0.1:",
                                          (integer_to_binary(Port))/binary,
                                          ">">>},
                ?UA:send(Sock, Src, ?UA:resp(Inv, 302, <<"Moved Temporarily">>,
                                             Tag, [Moved], <<>>)),
                serve_invites(Sock);
            ring_then_busy ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag,
                                             [contact(Sock)], <<>>)),
                timer:sleep(1500),
                ?UA:send(Sock, Src, ?UA:resp(Inv, 486, <<"Busy Here">>, Tag,
                                             [], <<>>)),
                serve(Sock, Tag);
            ring_then_answer ->
                ?UA:send(Sock, Src, ?UA:resp(Inv, 180, <<"Ringing">>, Tag,
                                             [contact(Sock)], <<>>)),
                timer:sleep(1500),
                ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag,
                                             [contact(Sock)],
                                             ?UA:sdp(<<"carol">>))),
                {_, _} = ?UA:recv_req(Sock, <<"ACK">>),
                serve(Sock, Tag)
        end
    end).

%% The caller (Alice): INVITEs the app, ACKs its 2xx, then runs Fun.
caller(EP, Fun) ->
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(),
                                     from_tag => ?UA:tag()}),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Fun(Sock, D),
        timer:sleep(infinity)
    end),
    ok = ?UA:expect(b2b_up).

contact(Sock) ->
    {<<"Contact">>, <<"<sip:peer@127.0.0.1:",
                      (integer_to_binary(?UA:lport(Sock)))/binary, ">">>}.

got(Tag) ->
    receive {Tag, V} -> V after 10000 -> ct:fail({missing, Tag}) end.

got2(Tag) ->
    receive {Tag, V, W} -> {V, W} after 10000 -> ct:fail({missing, Tag}) end.

no_message(Tag, Ms) ->
    receive {Tag, V} -> ct:fail({unexpected, Tag, V}) after Ms -> ok end.

%% the next event of the call with this tag and leg
expect_event(Ref, {Tag, Leg}) ->
    receive
        {chappe_sip_b2b, Ref, {Tag, Leg}} -> ok;
        {chappe_sip_b2b, Ref, {Tag, Leg, _}} -> ok
    after 10000 -> ct:fail({no_event, Tag, Leg})
    end.

transfers() ->
    [P || {_, P, _, _} <- supervisor:which_children(chappe_sip_b2b_transfers),
          is_pid(P)].
