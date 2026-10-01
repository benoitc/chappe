%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Session timers (RFC 4028) over real SIP on loopback.
%%
%% A gen_udp peer calls the app (the app is the UAS) or answers the app's
%% INVITE (the app is the UAC). The intervals are seconds long: the min_se
%% opt drops the 90 s floor for the test, the defaults keep it.
-module(chappe_sip_session_timer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([uas_require_timer_accepted/1, uas_422_below_min_se/1,
         uas_default_min_se_is_90/1, uas_no_timer_support/1,
         uas_keeps_uac_choice/1, uas_reduces_interval/1,
         uas_inserts_when_configured/1, uas_no_timer_by_default/1,
         uas_refreshes_by_update/1, uas_refreshes_by_reinvite/1,
         uas_bye_on_expiry/1, uas_refresh_rearms/1,
         uas_refresh_below_min_se/1,
         uac_supported_timer_always/1, uac_requests_when_configured/1,
         uac_retries_after_422/1, uac_refreshes_when_refresher/1,
         uac_refreshes_without_uas_support/1, uac_bye_when_peer_silent/1,
         uac_bye_on_refresh_481/1, uac_arms_on_unrequested_se/1,
         uac_refresh_422_raises_min_se/1]).

all() ->
    [uas_require_timer_accepted, uas_422_below_min_se,
     uas_default_min_se_is_90, uas_no_timer_support, uas_keeps_uac_choice,
     uas_reduces_interval, uas_inserts_when_configured,
     uas_no_timer_by_default, uas_refreshes_by_update,
     uas_refreshes_by_reinvite, uas_bye_on_expiry, uas_refresh_rearms,
     uas_refresh_below_min_se,
     uac_supported_timer_always, uac_requests_when_configured,
     uac_retries_after_422, uac_refreshes_when_refresher,
     uac_refreshes_without_uas_support, uac_bye_when_peer_silent,
     uac_bye_on_refresh_481, uac_arms_on_unrequested_se,
     uac_refresh_422_raises_min_se].

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
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

-define(UA, chappe_sip_test_ua).

%% ---- the app as UAS (section 9) ----

%% Require: timer is understood (no 420); the 2xx copies Session-Expires,
%% names the refresher and carries Require: timer.
%% req: R3261-083 R4028-31 R4028-34 R4028-35 R4028-04
uas_require_timer_accepted(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>)}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>},
                      {<<"Require">>, <<"timer">>},
                      {<<"Session-Expires">>, <<"1800">>}]),
    ?assertEqual(200, ?UA:status(R)),
    ?assertEqual(<<"1800;refresher=uac">>, ?UA:hdr(R, <<"session-expires">>)),
    ?assertEqual([<<"timer">>], ?UA:hdrs(R, <<"require">>)),
    %% Min-SE only ever goes in a 422
    ?assertEqual(undefined, ?UA:hdr(R, <<"min-se">>)).

%% Supported: timer and an interval below the local minimum: 422 with the
%% minimum in Min-SE.
%% req: R4028-28 R4028-29 R4028-05
uas_422_below_min_se(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), min_se => 120}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>},
                      {<<"Session-Expires">>, <<"100">>}]),
    ?assertEqual(422, ?UA:status(R)),
    ?assertEqual(<<"120">>, ?UA:hdr(R, <<"min-se">>)),
    ok = ?UA:expect({uas_result, {error, {session_interval_too_small, 120}}}).

%% With no min_se configured the floor is 90 s: 89 is refused, 91 taken.
%% req: R4028-02 R4028-28 R4028-29 R4028-30 R4028-03
uas_default_min_se_is_90(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>)}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>},
                      {<<"Session-Expires">>, <<"89">>}]),
    ?assertEqual(422, ?UA:status(R)),
    ?assertEqual(<<"90">>, ?UA:hdr(R, <<"min-se">>)),
    R2 = call_app(EP, [{<<"Supported">>, <<"timer">>},
                       {<<"Session-Expires">>, <<"91">>}]),
    ?assertEqual(200, ?UA:status(R2)),
    ?assertEqual(<<"91;refresher=uac">>, ?UA:hdr(R2, <<"session-expires">>)).

%% A UAC without timer support (a proxy asked for the timer): refresher is
%% uas and no Require: timer, even below min_se (a 422 would fail the call).
%% req: R4028-34
uas_no_timer_support(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), min_se => 120}),
    R = call_app(EP, [{<<"Session-Expires">>, <<"100">>}]),
    ?assertEqual(200, ?UA:status(R)),
    ?assertEqual(<<"100;refresher=uas">>, ?UA:hdr(R, <<"session-expires">>)),
    ?assertEqual([], ?UA:hdrs(R, <<"require">>)).

%% The UAS cannot override the UAC's refresher choice.
%% req: R4028-34 R4028-36
uas_keeps_uac_choice(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), session_refresher => uac}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>},
                      {<<"Session-Expires">>, <<"1800;refresher=uas">>}]),
    ?assertEqual(<<"1800;refresher=uas">>, ?UA:hdr(R, <<"session-expires">>)),
    ?assertEqual([<<"timer">>], ?UA:hdrs(R, <<"require">>)).

%% The UAS may reduce the interval, never below the request's Min-SE.
%% req: R4028-32 R4028-33
uas_reduces_interval(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), session_expires => 300}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>},
                      {<<"Min-SE">>, <<"600">>},
                      {<<"Session-Expires">>, <<"1800">>}]),
    ?assertEqual(<<"600;refresher=uac">>, ?UA:hdr(R, <<"session-expires">>)).

%% Supported: timer and no Session-Expires: a configured UAS asks for one.
%% req: R4028-34 R4028-36 R4028-9-1
uas_inserts_when_configured(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), session_expires => 1200,
             session_refresher => uas}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>}]),
    ?assertEqual(<<"1200;refresher=uas">>, ?UA:hdr(R, <<"session-expires">>)),
    ?assertEqual([<<"timer">>], ?UA:hdrs(R, <<"require">>)).

%% Not configured and not asked: no Session-Expires, no timer.
%% req: R4028-4-1
uas_no_timer_by_default(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>)}),
    R = call_app(EP, [{<<"Supported">>, <<"timer">>}]),
    ?assertEqual(200, ?UA:status(R)),
    ?assertEqual(undefined, ?UA:hdr(R, <<"session-expires">>)).

%% The UAS refreshes at half the interval, by UPDATE since the peer allows
%% it, with no body and Session-Expires naming itself (uac of the UPDATE);
%% the 2xx re-arms the next refresh.
%% req: R4028-37 R4028-38 R4028-19 R4028-21 R4028-22 R4028-23 R4028-24 R4028-06
uas_refreshes_by_update(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), min_se => 1}),
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        {_, D} = establish(Sock, EP, [{<<"Session-Expires">>, <<"4">>},
                                      {<<"Min-SE">>, <<"3">>},
                                      {<<"Allow">>, <<"INVITE, ACK, BYE, UPDATE">>}]),
        T0 = now_ms(),
        {U1, S1} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        T1 = now_ms(),
        ?UA:send(Sock, S1, ?UA:resp(U1, 200, <<"OK">>, <<>>,
                                    [{<<"Session-Expires">>, <<"4;refresher=uac">>}], <<>>)),
        {U2, S2} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        T2 = now_ms(),
        ?UA:send(Sock, S2, ?UA:resp(U2, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {updates, U1, T1 - T0, T2 - T1, D}
    end),
    receive
        {updates, U1, Dt1, Dt2, _} ->
            ?assertEqual(<<"4;refresher=uac">>, ?UA:hdr(U1, <<"session-expires">>)),
            %% the INVITE's Min-SE is repeated on every refresh
            ?assertEqual(<<"3">>, ?UA:hdr(U1, <<"min-se">>)),
            ?assertEqual([<<"timer">>], ?UA:hdrs(U1, <<"supported">>)),
            ?assertEqual(<<>>, ?UA:body(U1)),
            ct:pal("refresh after ~p ms, then ~p ms", [Dt1, Dt2]),
            ?assert(Dt1 >= 1700 andalso Dt1 < 3500),
            ?assert(Dt2 >= 1700 andalso Dt2 < 3500)
    after 12000 -> ct:fail(no_updates)
    end.

%% Without UPDATE in the peer's Allow the refresh is a re-INVITE carrying
%% the unchanged SDP (same o= line), which the UAS ACKs.
%% req: R4028-37 R4028-23 R4028-24 R4028-25
uas_refreshes_by_reinvite(_Config) ->
    EP = setup(),
    AppSdp = ?UA:sdp(<<"app">>),
    answer(#{local_sdp => AppSdp, min_se => 1}),
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        {_, _D} = establish(Sock, EP, [{<<"Session-Expires">>, <<"4">>}]),
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>, 8000),
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>,
                                   [{<<"Contact">>, <<"<sip:caller@127.0.0.1>">>},
                                    {<<"Session-Expires">>, <<"4;refresher=uac">>}],
                                   ?UA:sdp(<<"caller">>))),
        {Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Test ! {reinvite, Re, Ack}
    end),
    receive
        {reinvite, Re, Ack} ->
            ?assertEqual(<<"4;refresher=uac">>, ?UA:hdr(Re, <<"session-expires">>)),
            ?assertEqual(AppSdp, ?UA:body(Re)),
            ?assertEqual(maps:get(seq, ?UA:cseq(Re)), maps:get(seq, ?UA:cseq(Ack)))
    after 12000 -> ct:fail(no_reinvite)
    end.

%% The peer refreshes (refresher=uac) and stays silent: the UAS sends BYE
%% at interval - min(32, interval/3), 2 s for 3 s, and the owner learns
%% session_expired.
%% req: R4028-41 R4028-42 R4028-06
uas_bye_on_expiry(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), min_se => 1}),
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        {R, _} = establish(Sock, EP, [{<<"Supported">>, <<"timer">>},
                                      {<<"Session-Expires">>, <<"3">>}]),
        T0 = now_ms(),
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>, 8000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {bye, R, Bye, Dt}
    end),
    receive
        {bye, R, Bye, Dt} ->
            ?assertEqual(<<"3;refresher=uac">>, ?UA:hdr(R, <<"session-expires">>)),
            ?assertEqual([<<"timer">>], ?UA:hdrs(Bye, <<"supported">>)),
            ct:pal("BYE after ~p ms", [Dt]),
            ?assert(Dt >= 1700 andalso Dt < 2900)
    after 12000 -> ct:fail(no_bye)
    end,
    ok = ?UA:expect({destroyed, session_expired}).

%% A refresh from the peer is answered with the interval and Require: timer
%% and pushes the expiry out by a full interval.
%% req: R4028-31 R4028-35 R4028-41
uas_refresh_rearms(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), min_se => 1}),
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        {_, D} = establish(Sock, EP, [{<<"Supported">>, <<"timer">>},
                                      {<<"Session-Expires">>, <<"3">>}]),
        timer:sleep(1000),
        {U, _} = ?UA:in_dialog(D, <<"UPDATE">>,
                               [{<<"Supported">>, <<"timer">>},
                                {<<"Session-Expires">>, <<"3;refresher=uac">>}], <<>>),
        ?UA:send(Sock, EP, U),
        R = ?UA:recv_status(Sock, 200),
        T0 = now_ms(),
        %% the first expiry (2 s after the INVITE) passes without a BYE
        ok = ?UA:no_req(Sock, <<"BYE">>, 1500),
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>, 4000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {refreshed, R, Dt}
    end),
    receive
        {refreshed, R, Dt} ->
            ?assertEqual(<<"3;refresher=uac">>, ?UA:hdr(R, <<"session-expires">>)),
            ?assertEqual([<<"timer">>], ?UA:hdrs(R, <<"require">>)),
            ct:pal("BYE ~p ms after the refresh", [Dt]),
            ?assert(Dt >= 1700 andalso Dt < 2900)
    after 12000 -> ct:fail(no_refresh)
    end.

%% An in-dialog refresh below min_se is refused 422 with Min-SE.
%% req: R4028-28 R4028-29 R4028-05
uas_refresh_below_min_se(_Config) ->
    EP = setup(),
    answer(#{local_sdp => ?UA:sdp(<<"app">>), min_se => 2}),
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        {_, D} = establish(Sock, EP, [{<<"Supported">>, <<"timer">>},
                                      {<<"Session-Expires">>, <<"30">>}]),
        {U, _} = ?UA:in_dialog(D, <<"UPDATE">>,
                               [{<<"Supported">>, <<"timer">>},
                                {<<"Session-Expires">>, <<"1">>}], <<>>),
        ?UA:send(Sock, EP, U),
        Test ! {resp, ?UA:recv_any(Sock, 6000)}
    end),
    receive
        {resp, R} ->
            ?assertEqual(422, ?UA:status(R)),
            ?assertEqual(<<"2">>, ?UA:hdr(R, <<"min-se">>))
    after 8000 -> ct:fail(no_response)
    end.

%% ---- the app as UAC (section 7) ----

%% Every INVITE says Supported: timer; with nothing configured it asks for
%% no Session-Expires.
%% req: R4028-06 R4028-07 R4028-08
uac_supported_timer_always(_Config) ->
    {EP, UP} = setup2(),
    Inv = uac_first_invite(EP, UP, #{}),
    ?assert(lists:member(<<"timer">>, tokens(?UA:hdrs(Inv, <<"supported">>)))),
    ?assertEqual([], ?UA:hdrs(Inv, <<"require">>)),
    ?assertEqual([], ?UA:hdrs(Inv, <<"proxy-require">>)),
    ?assertEqual(undefined, ?UA:hdr(Inv, <<"session-expires">>)),
    ?assertEqual(undefined, ?UA:hdr(Inv, <<"min-se">>)).

%% session_expires set: the INVITE carries it without a refresher param.
%% req: R4028-10
uac_requests_when_configured(_Config) ->
    {EP, UP} = setup2(),
    Inv = uac_first_invite(EP, UP, #{session_expires => 1800}),
    ?assertEqual(<<"1800">>, ?UA:hdr(Inv, <<"session-expires">>)),
    ?assertEqual(undefined, ?UA:hdr(Inv, <<"min-se">>)).

%% After a 422 the UAC retries: same Call-ID, From tag and To, CSeq + 1,
%% Session-Expires and Min-SE raised to the 422's Min-SE.
%% req: R4028-16 R4028-17 R4028-09 R4028-19 R4028-20
uac_retries_after_422(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {I1, S1} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S1, ?UA:resp(I1, 422, <<"Session Interval Too Small">>,
                                    ?UA:tag(), [{<<"Min-SE">>, <<"1800">>}], <<>>)),
        {I2, S2} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S2, ?UA:resp(I2, 486, <<"Busy Here">>, ?UA:tag(), [], <<>>)),
        Test ! {invites, I1, I2}
    end),
    {error, _} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                     local_sdp => ?UA:sdp(<<"app">>),
                                                     session_expires => 900}),
    receive
        {invites, I1, I2} ->
            ?assertEqual(<<"900">>, ?UA:hdr(I1, <<"session-expires">>)),
            ?assertEqual(<<"1800">>, ?UA:hdr(I2, <<"session-expires">>)),
            ?assertEqual(<<"1800">>, ?UA:hdr(I2, <<"min-se">>)),
            ?assertEqual(?UA:hdr(I1, <<"call-id">>), ?UA:hdr(I2, <<"call-id">>)),
            ?assertEqual(?UA:hdr(I1, <<"from">>), ?UA:hdr(I2, <<"from">>)),
            ?assertEqual(?UA:hdr(I1, <<"to">>), ?UA:hdr(I2, <<"to">>)),
            ?assertEqual(maps:get(seq, ?UA:cseq(I1)) + 1, maps:get(seq, ?UA:cseq(I2)))
    after 8000 -> ct:fail(no_retry)
    end.

%% The 2xx names the UAC refresher: the UAC refreshes by UPDATE at half the
%% interval.
%% req: R4028-11 R4028-13 R4028-14 R4028-15 R4028-23
uac_refreshes_when_refresher(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {_D, T0} = uas_answer(Sock, [{<<"Session-Expires">>, <<"4;refresher=uac">>},
                                     {<<"Require">>, <<"timer">>},
                                     {<<"Allow">>, <<"INVITE, ACK, BYE, UPDATE">>}]),
        {U, S} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S, ?UA:resp(U, 200, <<"OK">>, <<>>,
                                   [{<<"Session-Expires">>, <<"4;refresher=uac">>}], <<>>)),
        Test ! {update, U, Dt}
    end),
    {ok, _Dlg} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                     local_sdp => ?UA:sdp(<<"app">>),
                                                     session_expires => 4,
                                                     min_se => 1}),
    receive
        {update, U, Dt} ->
            ?assertEqual(<<"4;refresher=uac">>, ?UA:hdr(U, <<"session-expires">>)),
            ct:pal("UPDATE after ~p ms", [Dt]),
            ?assert(Dt >= 1700 andalso Dt < 3500)
    after 12000 -> ct:fail(no_update)
    end.

%% The UAS ignores the timer (no Session-Expires in the 2xx): the UAC that
%% asked for one refreshes itself, by re-INVITE with its unchanged SDP.
%% req: R4028-14 R4028-24 R4028-25 R4028-7.2-1
uac_refreshes_without_uas_support(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    AppSdp = ?UA:sdp(<<"app">>),
    ?UA:peer(UP, fun(Sock) ->
        {_D, T0} = uas_answer(Sock, []),
        {Re, S} = ?UA:recv_req(Sock, <<"INVITE">>, 8000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S, ?UA:resp(Re, 200, <<"OK">>, <<>>,
                                   [{<<"Contact">>, contact(UP)}], ?UA:sdp(<<"callee">>))),
        {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
        Test ! {reinvite, Re, Dt}
    end),
    {ok, _Dlg} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                     local_sdp => AppSdp,
                                                     session_expires => 4,
                                                     min_se => 1}),
    receive
        {reinvite, Re, Dt} ->
            ?assertEqual(AppSdp, ?UA:body(Re)),
            ?assertEqual(<<"4;refresher=uac">>, ?UA:hdr(Re, <<"session-expires">>)),
            ct:pal("re-INVITE after ~p ms", [Dt]),
            ?assert(Dt >= 1700 andalso Dt < 3500)
    after 12000 -> ct:fail(no_reinvite)
    end.

%% refresher=uas and the UAS never refreshes: the UAC sends BYE at
%% interval - min(32, interval/3).
%% req: R4028-13 R4028-41 R4028-42
uac_bye_when_peer_silent(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {_D, T0} = uas_answer(Sock, [{<<"Session-Expires">>, <<"3;refresher=uas">>},
                                     {<<"Require">>, <<"timer">>}]),
        {Bye, S} = ?UA:recv_req(Sock, <<"BYE">>, 8000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {bye, Dt}
    end),
    {ok, Dlg} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                    local_sdp => ?UA:sdp(<<"app">>),
                                                    min_se => 1}),
    receive
        {bye, Dt} ->
            ct:pal("BYE after ~p ms", [Dt]),
            ?assert(Dt >= 1700 andalso Dt < 2900)
    after 12000 -> ct:fail(no_bye)
    end,
    receive {chappe_sip_dialog, Dlg, destroy, session_expired} -> ok
    after 4000 -> ct:fail(no_destroy)
    end.

%% A refresh answered 481 ends the session with a BYE.
%% req: R4028-39
uac_bye_on_refresh_481(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {_D, _} = uas_answer(Sock, [{<<"Session-Expires">>, <<"4;refresher=uac">>},
                                    {<<"Allow">>, <<"UPDATE">>}]),
        {U, S} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        ?UA:send(Sock, S, ?UA:resp(U, 481, <<"Call/Transaction Does Not Exist">>,
                                   <<>>, [], <<>>)),
        T0 = now_ms(),
        {Bye, BS} = ?UA:recv_req(Sock, <<"BYE">>, 4000),
        ?UA:send(Sock, BS, ?UA:resp(Bye, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {bye, now_ms() - T0}
    end),
    {ok, Dlg} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                    local_sdp => ?UA:sdp(<<"app">>),
                                                    min_se => 1}),
    receive
        {bye, Dt} -> ?assert(Dt < 1000)
    after 12000 -> ct:fail(no_bye)
    end,
    receive {chappe_sip_dialog, Dlg, destroy, {refresh_failed, 481}} -> ok
    after 4000 -> ct:fail(no_destroy)
    end.

%% The UAC asked for no timer but the 2xx sets one up with it refreshing:
%% it refreshes.
%% req: R4028-12 R4028-13
uac_arms_on_unrequested_se(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {_D, T0} = uas_answer(Sock, [{<<"Session-Expires">>, <<"4;refresher=uac">>},
                                     {<<"Require">>, <<"timer">>},
                                     {<<"Allow">>, <<"UPDATE">>}]),
        {U, S} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S, ?UA:resp(U, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {update, U, Dt}
    end),
    {ok, _Dlg} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                     local_sdp => ?UA:sdp(<<"app">>),
                                                     min_se => 1}),
    receive
        {update, U, Dt} ->
            ?assertEqual(<<"4;refresher=uac">>, ?UA:hdr(U, <<"session-expires">>)),
            ?assert(Dt >= 1700 andalso Dt < 3500)
    after 12000 -> ct:fail(no_update)
    end.

%% A refresh answered 422 is retried at once with the 422's Min-SE as both
%% Session-Expires and Min-SE; later refreshes keep that Min-SE.
%% req: R4028-16 R4028-17 R4028-18 R4028-19 R4028-20
uac_refresh_422_raises_min_se(_Config) ->
    {EP, UP} = setup2(),
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {_D, _} = uas_answer(Sock, [{<<"Session-Expires">>, <<"4;refresher=uac">>},
                                    {<<"Require">>, <<"timer">>},
                                    {<<"Allow">>, <<"UPDATE">>}]),
        {U1, S1} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        ?UA:send(Sock, S1, ?UA:resp(U1, 422, <<"Session Interval Too Small">>, <<>>,
                                    [{<<"Min-SE">>, <<"6">>}], <<>>)),
        T0 = now_ms(),
        {U2, S2} = ?UA:recv_req(Sock, <<"UPDATE">>, 4000),
        Dt = now_ms() - T0,
        ?UA:send(Sock, S2, ?UA:resp(U2, 200, <<"OK">>, <<>>,
                                    [{<<"Session-Expires">>, <<"6;refresher=uac">>}], <<>>)),
        {U3, S3} = ?UA:recv_req(Sock, <<"UPDATE">>, 8000),
        ?UA:send(Sock, S3, ?UA:resp(U3, 200, <<"OK">>, <<>>, [], <<>>)),
        Test ! {updates, U1, U2, U3, Dt}
    end),
    {ok, _Dlg} = chappe_sip:create_uac(callee(UP), #{contact => contact(EP),
                                                     local_sdp => ?UA:sdp(<<"app">>),
                                                     min_se => 1}),
    receive
        {updates, U1, U2, U3, Dt} ->
            ?assertEqual(undefined, ?UA:hdr(U1, <<"min-se">>)),
            ?assertEqual(<<"6;refresher=uac">>, ?UA:hdr(U2, <<"session-expires">>)),
            ?assertEqual(<<"6">>, ?UA:hdr(U2, <<"min-se">>)),
            ?assertEqual(maps:get(seq, ?UA:cseq(U1)) + 1, maps:get(seq, ?UA:cseq(U2))),
            ?assert(Dt < 1000),
            ?assertEqual(<<"6">>, ?UA:hdr(U3, <<"min-se">>)),
            ?assertEqual(<<"6;refresher=uac">>, ?UA:hdr(U3, <<"session-expires">>))
    after 16000 -> ct:fail(no_updates)
    end.

%% ---- helpers ----

setup() ->
    EP = ?UA:pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>}),
    EP.

setup2() ->
    EP = setup(),
    {EP, ?UA:pick()}.

callee(P) -> <<"sip:callee@127.0.0.1:", (integer_to_binary(P))/binary>>.
contact(P) -> <<"sip:chappe@127.0.0.1:", (integer_to_binary(P))/binary>>.

now_ms() -> erlang:monotonic_time(millisecond).

tokens(Values) ->
    [string:trim(T) || V <- Values, T <- binary:split(V, <<",">>, [global])].

%% The app answers every INVITE with create_uas(Opts) and reports.
answer(Opts) ->
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:create_uas(Req, Res, Opts) of
            {ok, Dlg} ->
                Test ! {uas_result, ok},
                {destroyed, Why} = chappe_sip_dialog:wait(Dlg),
                Test ! {destroyed, Why};
            Err ->
                Test ! {uas_result, Err}
        end
    end).

%% A peer INVITEs the app with Headers and returns the final response.
call_app(EP, Headers) ->
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                     headers => Headers}),
        ?UA:send(Sock, EP, Inv),
        Test ! {final, ?UA:recv_any(Sock, 6000)},
        timer:sleep(infinity)
    end),
    receive {final, R} -> R after 8000 -> ct:fail(no_final) end.

%% In a peer: INVITE the app, ACK its 2xx; returns {The2xx, RawDialog}.
establish(Sock, EP, Headers) ->
    Inv = ?UA:invite(Sock, EP, #{call_id => ?UA:callid(), from_tag => ?UA:tag(),
                                 headers => Headers}),
    ?UA:send(Sock, EP, Inv),
    R = ?UA:recv_status(Sock, 200),
    D = ?UA:dialog_from_2xx(Sock, Inv, R),
    ?UA:ack(D, EP),
    {R, D}.

%% In a peer on the app's callee port: answer the INVITE 200 with Headers,
%% wait for the ACK; returns {RawDialog, TimeOf2xx}.
uas_answer(Sock, Headers) ->
    {Inv, Src} = ?UA:recv_req(Sock, <<"INVITE">>),
    Tag = ?UA:tag(),
    P = integer_to_binary(?UA:lport(Sock)),
    ?UA:send(Sock, Src, ?UA:resp(Inv, 200, <<"OK">>, Tag,
                                 [{<<"Contact">>, <<"<sip:callee@127.0.0.1:", P/binary, ">">>}
                                  | Headers], ?UA:sdp(<<"callee">>))),
    T0 = now_ms(),
    {_Ack, _} = ?UA:recv_req(Sock, <<"ACK">>),
    {?UA:dialog_from_invite(Sock, Inv, Tag, Src), T0}.

%% The app's first INVITE as the peer sees it (the peer then answers 486).
uac_first_invite(EP, UP, Opts) ->
    Test = self(),
    ?UA:peer(UP, fun(Sock) ->
        {Inv, S} = ?UA:recv_req(Sock, <<"INVITE">>),
        ?UA:send(Sock, S, ?UA:resp(Inv, 486, <<"Busy Here">>, ?UA:tag(), [], <<>>)),
        Test ! {invite, Inv}
    end),
    {error, _} = chappe_sip:create_uac(callee(UP), Opts#{contact => contact(EP),
                                                          local_sdp => ?UA:sdp(<<"app">>)}),
    receive {invite, Inv} -> Inv after 6000 -> ct:fail(no_invite) end.
