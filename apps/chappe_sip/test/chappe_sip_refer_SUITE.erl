%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% REFER (RFC 3515, RFC 7647) over real SIP on loopback, both sides.
%%
%% The test process plays the far end with a gen_udp socket and raw SIP:
%% the referrer when chappe_sip_refer accepts, the referee when it sends.
%% The app side is the test process too: the INVITE handler hands every
%% in-dialog event to it, and the REFER handler runs chappe_sip_refer:accept/3
%% with the options the case put in persistent_term.
-module(chappe_sip_refer_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    in_dialog_refer_200_and_notifies/1,
    second_refer_carries_id/1,
    notify_rate_limit_coalesces/1,
    refer_to_count_400/1,
    refer_to_scheme_416/1,
    referred_by_twice_400/1,
    norefersub_honoured/1,
    refresh_and_unsubscribe/1,
    expiry_terminates/1,
    owner_down_ends_subscription/1,
    refer_bye_needs_authorization/1,
    refer_with_refer/1,
    replaces_in_refer_to/1,
    out_of_dialog_refer_target_dialog/1,
    out_of_dialog_refresh_and_expiry/1,
    send_in_dialog/1,
    send_out_of_dialog/1,
    send_refer_sub_false_and_reject/1,
    send_in_dialog_norefersub/1,
    tel_refer_sip_status_lines/1
]).

all() ->
    [
        in_dialog_refer_200_and_notifies,
        second_refer_carries_id,
        notify_rate_limit_coalesces,
        refer_to_count_400,
        refer_to_scheme_416,
        referred_by_twice_400,
        norefersub_honoured,
        refresh_and_unsubscribe,
        expiry_terminates,
        owner_down_ends_subscription,
        refer_bye_needs_authorization,
        refer_with_refer,
        replaces_in_refer_to,
        out_of_dialog_refer_target_dialog,
        out_of_dialog_refresh_and_expiry,
        send_in_dialog,
        send_out_of_dialog,
        send_refer_sub_false_and_reject,
        send_in_dialog_norefersub,
        tel_refer_sip_status_lines
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
    _ = persistent_term:erase({?MODULE, opts}),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    flush(),
    ok.

-define(FRAG_CT, <<"message/sipfrag;version=2.0">>).

%% ---- recipient, inside an INVITE dialog ----

%% The REFER is answered 200, never 202, with a Contact; a NOTIFY follows
%% at once in the same dialog (Event refer, active with the expiry,
%% message/sipfrag "100 Trying"), and the final one is terminated;
%% reason=noresource with the final status line.
%% req: R7647-04 R3515-01 R3515-10 R3515-11 R3515-12 R3515-13 R3515-14 R3515-18 R3515-23 R3515-24 R3515-29 R6665-09 R6665-15 R3515-27
in_dialog_refer_200_and_notifies(_Config) ->
    {S, D} = call(),
    {R200, {ok, Refer}} =
        refer_in(S, D, 2, [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}]),
    ?assertEqual(200, status(R200)),
    ?assertNotEqual(undefined, hdr(R200, <<"contact">>)),
    ?assertMatch(
        #{method := <<"INVITE">>, target := <<"sip:carol@127.0.0.1">>},
        chappe_sip_refer:target(Refer)
    ),
    {N1, T1} = notify_ok(S),
    ?assertEqual(<<"refer">>, hdr(N1, <<"event">>)),
    ?assertEqual(?FRAG_CT, hdr(N1, <<"content-type">>)),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, body(N1)),
    ?assertEqual(maps:get(call, S), call_id(N1)),
    ?assertEqual(maps:get(tt, S), from_tag(N1)),
    ?assertEqual(maps:get(ft, S), to_tag(N1)),
    {<<"active">>, Exp} = sub_state(N1),
    ?assert(Exp =< 60 andalso Exp >= 55),
    ok = chappe_sip_refer:final(Refer, 200),
    {N2, T2} = notify_ok(S),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(N2, <<"subscription-state">>)
    ),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, body(N2)),
    ?assertEqual(<<"refer">>, hdr(N2, <<"event">>)),
    %% RFC 3515 3.10: a second apart (measured at the receiver, so the
    %% first NOTIFY's own transit is on the wrong side of the gap)
    ?assert(T2 - T1 >= 900),
    no_request(S, <<"NOTIFY">>, 1500),
    hangup(S, D).

%% The second REFER in a dialog tags its NOTIFYs with id=<its CSeq>; the
%% first may go without.
%% req: R3515-22 R3515-30 R3515-13
second_refer_carries_id(_Config) ->
    {S, D} = call(),
    {_, {ok, R1}} =
        refer_in(S, D, 2, [{<<"Refer-To">>, <<"<sip:b@127.0.0.1>">>}]),
    {N1, _} = notify_ok(S),
    ?assertEqual(<<"refer">>, hdr(N1, <<"event">>)),
    {_, {ok, R2}} =
        refer_in(S, D, 3, [{<<"Refer-To">>, <<"<sip:c@127.0.0.1>">>}]),
    {N2, _} = notify_ok(S),
    ?assertEqual(<<"refer;id=3">>, hdr(N2, <<"event">>)),
    ok = chappe_sip_refer:final(R2, 486),
    {N3, _} = notify_ok(S),
    ?assertEqual(<<"refer;id=3">>, hdr(N3, <<"event">>)),
    ?assertEqual(<<"SIP/2.0 486 Busy Here\r\n">>, body(N3)),
    ok = chappe_sip_refer:final(R1, 200),
    {N4, _} = notify_ok(S),
    ?assertEqual(<<"refer">>, hdr(N4, <<"event">>)),
    hangup(S, D).

%% Reports made faster than one a second are coalesced: the newest waits
%% its turn and replaces the one waiting, and the final one is never lost.
%% req: R3515-26 R3515-23
notify_rate_limit_coalesces(_Config) ->
    {S, D} = call(),
    {_, {ok, Refer}} = refer_in(S, D, 2, [
        {<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}
    ]),
    ok = chappe_sip_refer:progress(Refer, 180),
    ok = chappe_sip_refer:progress(Refer, 183),
    ok = chappe_sip_refer:final(Refer, 486),
    {N1, T1} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, body(N1)),
    {N2, T2} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 486 Busy Here\r\n">>, body(N2)),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(N2, <<"subscription-state">>)
    ),
    ?assert(T2 - T1 >= 900),
    no_request(S, <<"NOTIFY">>, 1500),
    %% a report after the final one goes nowhere
    ok = chappe_sip_refer:progress(Refer, 180),
    no_request(S, <<"NOTIFY">>, 1200),
    hangup(S, D).

%% zero, two, or a two-valued Refer-To: 400, and no subscription
%% req: R3515-03 R3515-06
refer_to_count_400(_Config) ->
    {S, D} = call(),
    Cases = [
        {2, []},
        {3, [
            {<<"Refer-To">>, <<"<sip:a@127.0.0.1>">>},
            {<<"Refer-To">>, <<"<sip:b@127.0.0.1>">>}
        ]},
        {4, [{<<"Refer-To">>, <<"<sip:a@127.0.0.1>, <sip:b@127.0.0.1>">>}]}
    ],
    lists:foreach(
        fun({CSeq, Hs}) ->
            ok = send_refer(S, CSeq, Hs),
            {Req, Res} = app_event(refer),
            ?assertEqual(
                {error, {rejected, 400}},
                chappe_sip_refer:accept(D, Req, Res, #{})
            ),
            _ = recv_status(maps:get(sock, S), 400)
        end,
        Cases
    ),
    no_request(S, <<"NOTIFY">>, 1200),
    hangup(S, D).

%% a target the UA cannot reach (http) is refused 416; tel is taken
%% req: R3515-08
refer_to_scheme_416(_Config) ->
    {S, D} = call(),
    ok = send_refer(S, 2, [{<<"Refer-To">>, <<"<http://example.com/x>">>}]),
    {Req, Res} = app_event(refer),
    ?assertEqual(
        {error, {rejected, 416}},
        chappe_sip_refer:accept(D, Req, Res, #{})
    ),
    _ = recv_status(maps:get(sock, S), 416),
    {R200, {ok, Refer}} = refer_in(S, D, 3, [
        {<<"Refer-To">>, <<"<tel:+15551234>">>}
    ]),
    ?assertEqual(200, status(R200)),
    ?assertMatch(#{scheme := <<"tel">>}, chappe_sip_refer:target(Refer)),
    {_, _} = notify_ok(S),
    hangup(S, D).

%% A REFER to a tel: URI still reports in SIP status lines: the first
%% NOTIFY's sipfrag is SIP/2.0 100 Trying, the final one SIP/2.0 200 OK.
%% req: R3515-21
tel_refer_sip_status_lines(_Config) ->
    {S, D} = call(),
    {R200, {ok, Refer}} =
        refer_in(S, D, 2, [{<<"Refer-To">>, <<"<tel:+15551234>">>}]),
    ?assertEqual(200, status(R200)),
    ?assertMatch(#{scheme := <<"tel">>}, chappe_sip_refer:target(Refer)),
    {N1, _} = notify_ok(S),
    ?assertEqual(?FRAG_CT, hdr(N1, <<"content-type">>)),
    ?assertMatch(<<"SIP/2.0 100 ", _/binary>>, body(N1)),
    ok = chappe_sip_refer:final(Refer, 200),
    {N2, _} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, body(N2)),
    hangup(S, D).

%% a REFER carries at most one Referred-By; the one it carries is kept for
%% the request to the target
%% req: R3892-01 R3892-02
referred_by_twice_400(_Config) ->
    {S, D} = call(),
    RB = <<"<sip:alice@127.0.0.1>;cid=\"1@alice\"">>,
    ok = send_refer(S, 2, [
        {<<"Refer-To">>, <<"<sip:c@127.0.0.1>">>},
        {<<"Referred-By">>, RB},
        {<<"Referred-By">>, <<"<sip:x@127.0.0.1>">>}
    ]),
    {Req, Res} = app_event(refer),
    ?assertEqual(
        {error, {rejected, 400}},
        chappe_sip_refer:accept(D, Req, Res, #{})
    ),
    _ = recv_status(maps:get(sock, S), 400),
    {_, {ok, Refer}} = refer_in(S, D, 3, [
        {<<"Refer-To">>, <<"<sip:c@127.0.0.1>">>},
        {<<"Referred-By">>, RB}
    ]),
    ?assertEqual(RB, chappe_sip_refer:referred_by(Refer)),
    {_, _} = notify_ok(S),
    hangup(S, D).

%% Refer-Sub: false with norefersub (Supported or Require): 200 with
%% Refer-Sub: false and no NOTIFY. Without norefersub the subscription is
%% made anyway and the 200 says Refer-Sub: true.
%% req: R4488-01 R4488-02 R4488-03 R4488-04
norefersub_honoured(_Config) ->
    {S, D} = call(),
    RT = {<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>},
    {R1, {ok, Refer}} = refer_in(S, D, 2, [
        RT,
        {<<"Refer-Sub">>, <<"false">>},
        {<<"Supported">>, <<"norefersub">>}
    ]),
    ?assertEqual(200, status(R1)),
    ?assertEqual(<<"false">>, hdr(R1, <<"refer-sub">>)),
    no_request(S, <<"NOTIFY">>, 1500),
    %% progress on a REFER without a subscription is a no-op
    ok = chappe_sip_refer:final(Refer, 200),
    no_request(S, <<"NOTIFY">>, 1200),
    {R2, {ok, _}} = refer_in(S, D, 3, [
        RT,
        {<<"Refer-Sub">>, <<"false">>},
        {<<"Require">>, <<"norefersub">>}
    ]),
    ?assertEqual(<<"false">>, hdr(R2, <<"refer-sub">>)),
    no_request(S, <<"NOTIFY">>, 1200),
    {R3, {ok, _}} = refer_in(S, D, 4, [RT, {<<"Refer-Sub">>, <<"false">>}]),
    ?assertEqual(<<"true">>, hdr(R3, <<"refer-sub">>)),
    {N, _} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, body(N)),
    hangup(S, D).

%% A SUBSCRIBE with the right Event refreshes (200 with the granted
%% Expires, then a NOTIFY); a wrong id is refused 403; Expires: 0 ends it
%% with terminated;reason=timeout, after which the id is refused too.
%% req: R3515-31 R3515-17 R6665-01 R6665-09 R6665-12 R6665-15 R6665-26
refresh_and_unsubscribe(_Config) ->
    {S, D} = call(),
    {_, {ok, _Refer}} = refer_in(
        S, D, 2, [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}], #{
            owner => self(), max_expires => 300
        }
    ),
    {_, _} = notify_ok(S),
    Sock = maps:get(sock, S),
    ok = send_subscribe(S, 3, <<"refer">>, 120),
    R1 = recv_status(Sock, 200),
    ?assertEqual(<<"120">>, hdr(R1, <<"expires">>)),
    {N1, _} = notify_ok(S),
    {<<"active">>, Exp} = sub_state(N1),
    ?assert(Exp =< 120 andalso Exp >= 115),
    %% capped by max_expires
    ok = send_subscribe(S, 4, <<"refer">>, 7200),
    R2 = recv_status(Sock, 200),
    ?assertEqual(<<"300">>, hdr(R2, <<"expires">>)),
    {_, _} = notify_ok(S),
    ok = send_subscribe(S, 5, <<"refer;id=99">>, 60),
    _ = recv_status(Sock, 403),
    ok = send_subscribe(S, 6, <<"refer">>, 0),
    R3 = recv_status(Sock, 200),
    ?assertEqual(<<"0">>, hdr(R3, <<"expires">>)),
    {N3, _} = notify_ok(S),
    ?assertEqual(
        <<"terminated;reason=timeout">>,
        hdr(N3, <<"subscription-state">>)
    ),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, body(N3)),
    timer:sleep(200),
    ok = send_subscribe(S, 7, <<"refer">>, 60),
    _ = recv_status(Sock, 403),
    hangup(S, D).

%% no refresh before expiry: terminated;reason=timeout, still with the
%% sipfrag body every refer NOTIFY carries; the call stays up
%% req: R3515-14 R3515-24 R6665-12
expiry_terminates(_Config) ->
    {S, D} = call(),
    {_, {ok, Refer}} = refer_in(
        S, D, 2, [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}], #{
            owner => self(), expires => 2
        }
    ),
    {N1, _} = notify_ok(S),
    {<<"active">>, 2} = sub_state(N1),
    ok = chappe_sip_refer:progress(Refer, 180),
    {N2, _} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 180 Ringing\r\n">>, body(N2)),
    {N3, _} = notify_ok(S),
    ?assertEqual(
        <<"terminated;reason=timeout">>,
        hdr(N3, <<"subscription-state">>)
    ),
    ?assertEqual(<<"SIP/2.0 180 Ringing\r\n">>, body(N3)),
    ?assertEqual(?FRAG_CT, hdr(N3, <<"content-type">>)),
    hangup(S, D).

%% the application going away ends the subscription with what is known
%% req: R3515-23
owner_down_ends_subscription(_Config) ->
    {S, D} = call(),
    Owner = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    {_, {ok, _}} = refer_in(
        S,
        D,
        2,
        [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}],
        #{owner => Owner}
    ),
    {_, _} = notify_ok(S),
    Owner ! stop,
    {N2, _} = notify_ok(S),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(N2, <<"subscription-state">>)
    ),
    hangup(S, D).

%% RFC 4579 5.11: a REFER asking the focus to BYE a participant needs the
%% application's approval (403 without it)
%% req: R4579-18
refer_bye_needs_authorization(_Config) ->
    {S, D} = call(),
    RT = {<<"Refer-To">>, <<"<sip:carol@127.0.0.1;method=BYE>">>},
    ok = send_refer(S, 2, [RT]),
    {Req1, Res1} = app_event(refer),
    ?assertEqual(
        {error, {rejected, 403}},
        chappe_sip_refer:accept(D, Req1, Res1, #{})
    ),
    _ = recv_status(maps:get(sock, S), 403),
    ok = send_refer(S, 3, [RT]),
    {Req2, Res2} = app_event(refer),
    No = fun(_Target, _Req) -> false end,
    ?assertEqual(
        {error, {rejected, 403}},
        chappe_sip_refer:accept(D, Req2, Res2, #{authorize => No})
    ),
    _ = recv_status(maps:get(sock, S), 403),
    Test = self(),
    Yes = fun(Target, _Req) ->
        Test ! {authorize, Target},
        true
    end,
    {R200, {ok, Refer}} = refer_in(S, D, 4, [RT], #{authorize => Yes}),
    ?assertEqual(200, status(R200)),
    receive
        {authorize, T} ->
            ?assertMatch(
                #{
                    method := <<"BYE">>,
                    target := <<"sip:carol@127.0.0.1">>
                },
                T
            )
    after 1000 -> ct:fail(no_authorize_call)
    end,
    ?assertMatch(#{method := <<"BYE">>}, chappe_sip_refer:target(Refer)),
    {_, _} = notify_ok(S),
    ok = chappe_sip_refer:final(Refer, 200),
    {N, _} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, body(N)),
    hangup(S, D).

%% RFC 4579 5.7: Refer-To with method=REFER and an escaped Refer-To: the
%% focus reads the nested target and REFERs the participant to it (5.6)
%% req: R4579-13
refer_with_refer(_Config) ->
    {S, D} = call(),
    B = peer(maps:get(ep, S), <<"b">>),
    BUri = peer_uri(B),
    RT = <<"<", BUri/binary, ";method=REFER?Refer-To=sip:conf%40127.0.0.1>">>,
    {_, {ok, Refer}} = refer_in(S, D, 2, [{<<"Refer-To">>, RT}]),
    #{method := <<"REFER">>, target := BTarget, headers := Hs} =
        chappe_sip_refer:target(Refer),
    ?assertEqual(BUri, BTarget),
    ?assertEqual([{<<"Refer-To">>, <<"sip:conf@127.0.0.1">>}], Hs),
    {_, _} = notify_ok(S),
    %% the focus REFERs B to the conference
    Nested = proplists:get_value(<<"Refer-To">>, Hs),
    Sender = send_async(BTarget, Nested, #{}),
    {Refer2, Src} = recv_req(B, <<"REFER">>),
    ?assertEqual(<<"<sip:conf@127.0.0.1>">>, hdr(Refer2, <<"refer-to">>)),
    send(B, Src, resp(Refer2, 603, <<"Declined">>, <<"btag">>, [])),
    ?assertMatch({error, {rejected, 603, _}}, sent_result(Sender)),
    ok = chappe_sip_refer:final(Refer, 603),
    {N, _} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 603 Declined\r\n">>, body(N)),
    hangup(S, D).

%% an attended transfer's Refer-To carries an escaped Replaces; the
%% recipient gets it parsed
%% req: R3891-15
replaces_in_refer_to(_Config) ->
    {S, D} = call(),
    RT = <<
        "<sip:dave@127.0.0.1?Replaces=12345%40192.168.118.3%3Bto-tag%3D"
        "12345%3Bfrom-tag%3D5FFE-3994>"
    >>,
    {_, {ok, Refer}} = refer_in(S, D, 2, [{<<"Refer-To">>, RT}]),
    ?assertMatch(
        #{
            target := <<"sip:dave@127.0.0.1">>,
            replaces := #{
                call_id := <<"12345@192.168.118.3">>,
                to_tag := <<"12345">>,
                from_tag := <<"5FFE-3994">>,
                early_only := false
            }
        },
        chappe_sip_refer:target(Refer)
    ),
    {_, _} = notify_ok(S),
    %% a malformed Replaces makes the Refer-To malformed: 400
    Bad = <<"<sip:dave@127.0.0.1?Replaces=12345%3Bto-tag%3D1>">>,
    ok = send_refer(S, 3, [{<<"Refer-To">>, Bad}]),
    {Req2, Res2} = app_event(refer),
    ?assertEqual(
        {error, {rejected, 400}},
        chappe_sip_refer:accept(D, Req2, Res2, #{})
    ),
    _ = recv_status(maps:get(sock, S), 400),
    hangup(S, D).

%% ---- recipient, outside any dialog ----

%% RFC 7647 4: the REFER comes outside the dialog, naming it with
%% Target-Dialog (RFC 4538). The recipient finds that dialog; the 200 forms
%% a new dialog whose NOTIFYs carry the REFER's Call-ID and the 200's tag.
%% req: R7647-03 R7647-04 R4538-012 R4538-014 R3515-01 R3515-10 R3515-12 R3515-13 R3515-23
out_of_dialog_refer_target_dialog(_Config) ->
    {S, D} = call(),
    ok = chappe_sip:refer(ood_handler()),
    TD = <<
        (maps:get(call, S))/binary,
        ";local-tag=",
        (maps:get(tt, S))/binary,
        ";remote-tag=",
        (maps:get(ft, S))/binary
    >>,
    Call = <<"ood-", (rand_hex(4))/binary, "@ct">>,
    R200 = refer_out(S, Call, [
        {<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>},
        {<<"Target-Dialog">>, TD},
        {<<"Require">>, <<"tdialog">>}
    ]),
    ?assertEqual(200, status(R200)),
    ?assertNotEqual(undefined, hdr(R200, <<"contact">>)),
    NewTag = to_tag(R200),
    ?assertNotEqual(undefined, NewTag),
    {TDRes, Refer} = ood_accepted(),
    ?assertEqual({ok, chappe_sip_dialog:id(D)}, TDRes),
    {N1, _} = notify_ok(S),
    ?assertEqual(Call, call_id(N1)),
    ?assertEqual(NewTag, from_tag(N1)),
    ?assertEqual(<<"refer">>, hdr(N1, <<"event">>)),
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, body(N1)),
    {<<"active">>, _} = sub_state(N1),
    ok = chappe_sip_refer:final(Refer, 200),
    {N2, _} = notify_ok(S),
    ?assertEqual(Call, call_id(N2)),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(N2, <<"subscription-state">>)
    ),
    ?assertEqual(<<"SIP/2.0 200 OK\r\n">>, body(N2)),
    %% a Target-Dialog that names no dialog, or lacks a tag, is ignored
    BadTD = <<(maps:get(call, S))/binary, ";local-tag=nope;remote-tag=x">>,
    _ = refer_out(
        S,
        <<"ood2-", (rand_hex(4))/binary, "@ct">>,
        [
            {<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>},
            {<<"Target-Dialog">>, BadTD}
        ]
    ),
    {{error, not_found}, _} = ood_accepted(),
    {_, _} = notify_ok(S),
    _ = refer_out(
        S,
        <<"ood3-", (rand_hex(4))/binary, "@ct">>,
        [
            {<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>},
            {<<"Target-Dialog">>, maps:get(call, S)}
        ]
    ),
    {{error, malformed}, _} = ood_accepted(),
    {_, _} = notify_ok(S),
    hangup(S, D).

%% the subscription dialog a REFER formed: a SUBSCRIBE naming another id is
%% refused 403, the right one refreshes; its expiry NOTIFY still carries
%% the last sipfrag
%% req: R3515-17 R3515-31 R3515-14 R6665-09
out_of_dialog_refresh_and_expiry(_Config) ->
    EP = start_engine(),
    ok = chappe_sip:refer(ood_handler()),
    persistent_term:put({?MODULE, opts}, #{expires => 3}),
    S = peer(EP, <<"a">>),
    Call = <<"oodr-", (rand_hex(4))/binary, "@ct">>,
    R200 = refer_out(S, Call, [{<<"Refer-To">>, <<"<sip:carol@127.0.0.1>">>}]),
    {_, Refer} = ood_accepted(),
    {_, _} = notify_ok(S),
    S1 = S#{call => Call, tt => to_tag(R200), target => contact_uri(R200)},
    Sock = maps:get(sock, S),
    ok = send_subscribe(S1, 2, <<"refer;id=5">>, 60),
    _ = recv_status(Sock, 403),
    ok = chappe_sip_refer:progress(Refer, 183),
    {N2, _} = notify_ok(S),
    ?assertEqual(<<"SIP/2.0 183 Session Progress\r\n">>, body(N2)),
    ok = send_subscribe(S1, 3, <<"refer">>, 2),
    R2 = recv_status(Sock, 200),
    ?assertEqual(<<"2">>, hdr(R2, <<"expires">>)),
    {N3, _} = notify_ok(S),
    {<<"active">>, _} = sub_state(N3),
    {N4, _} = notify_ok(S),
    ?assertEqual(
        <<"terminated;reason=timeout">>,
        hdr(N4, <<"subscription-state">>)
    ),
    ?assertEqual(<<"SIP/2.0 183 Session Progress\r\n">>, body(N4)),
    ?assertEqual(?FRAG_CT, hdr(N4, <<"content-type">>)).

%% ---- sender ----

%% A REFER sent in the dialog: Refer-To and Referred-By as asked; a NOTIFY
%% that beats the 202 is taken; 202 counts as 200; the NOTIFYs reach the
%% owner as refer_progress/refer_done; an unknown id gets 481.
%% req: R7647-04 R6665-21 R3515-32 R3515-02 R3892-10 R6665-32 R6665-33
send_in_dialog(_Config) ->
    {S, D} = call(),
    RB = #{uri => <<"sip:app@127.0.0.1;user=phone">>, cid => <<"7@app">>},
    Sender = send_async(D, <<"sip:carol@127.0.0.1">>, #{referred_by => RB}),
    {Refer, Src} = recv_req(S, <<"REFER">>),
    ?assertEqual(<<"<sip:carol@127.0.0.1>">>, hdr(Refer, <<"refer-to">>)),
    ?assertEqual(
        <<"<sip:app@127.0.0.1;user=phone>;cid=\"7@app\"">>,
        hdr(Refer, <<"referred-by">>)
    ),
    ?assertEqual(maps:get(call, S), call_id(Refer)),
    ?assertEqual(maps:get(ft, S), to_tag(Refer)),
    {ok, #{seq := Seq}} = chappe_sip_msg:cseq(parse(Refer)),
    Id = integer_to_binary(Seq),
    %% the NOTIFY arrives before the REFER's response (RFC 3515 2.4.4)
    ok = send_notify(S, 10, <<"refer">>, <<"active;expires=60">>, 100),
    _ = recv_status(maps:get(sock, S), 200),
    send(S, Src, resp(Refer, 202, <<"Accepted">>, <<"unused">>, [])),
    {ok, RId, #{status := 202, subscription := true}} = sent_result(Sender),
    ?assertEqual({refer_progress, RId, 100}, recv_msg()),
    ok = send_notify(S, 11, <<"refer;id=999">>, <<"active">>, 180),
    _ = recv_status(maps:get(sock, S), 481),
    ok = send_notify(S, 12, <<"refer;id=", Id/binary>>, <<"active">>, 180),
    _ = recv_status(maps:get(sock, S), 200),
    ?assertEqual({refer_progress, RId, 180}, recv_msg()),
    ok = send_notify(
        S,
        13,
        <<"refer;id=", Id/binary>>,
        <<"terminated;reason=noresource">>,
        200
    ),
    _ = recv_status(maps:get(sock, S), 200),
    ?assertEqual({refer_done, RId, 200}, recv_msg()),
    %% the subscription is gone
    ok = send_notify(S, 14, <<"refer">>, <<"active">>, 180),
    _ = recv_status(maps:get(sock, S), 481),
    hangup(S, D).

%% A REFER sent outside any dialog (RFC 7647 4) to the transfer target:
%% Target-Dialog names our dialog with the peer (tags as the recipient
%% sees them) with Require: tdialog, the Replaces rides escaped in
%% Refer-To, and the NOTIFYs come back outside any dialog to the handler.
%% req: R7647-02 R7647-03 R4538-006 R4538-007 R4538-008 R4538-009 R3891-15 R6665-32
send_out_of_dialog(_Config) ->
    {S, D} = call(),
    ok = chappe_sip:notify(chappe_sip_refer:notify_handler()),
    B = peer(maps:get(ep, S), <<"b">>),
    Rep = #{
        call_id => <<"x@h">>,
        to_tag => <<"t1">>,
        from_tag => <<"f1">>,
        early_only => false
    },
    Sender = send_async(
        peer_uri(B),
        <<"sip:carol@127.0.0.1">>,
        #{target_dialog => D, replaces => Rep}
    ),
    {Refer, Src} = recv_req(B, <<"REFER">>),
    ?assertEqual(undefined, to_tag(Refer)),
    ?assertEqual(
        {ok, #{
            call_id => maps:get(call, S),
            local_tag => maps:get(ft, S),
            remote_tag => maps:get(tt, S)
        }},
        chappe_sip_hdr:target_dialog(hdr(Refer, <<"target-dialog">>))
    ),
    ?assertEqual(<<"tdialog">>, hdr(Refer, <<"require">>)),
    ?assertMatch(
        {ok, #{replaces := Rep, target := <<"sip:carol@127.0.0.1">>}},
        chappe_sip_hdr:refer_to(hdr(Refer, <<"refer-to">>))
    ),
    send(
        B,
        Src,
        resp(
            Refer,
            200,
            <<"OK">>,
            <<"btag">>,
            [{<<"Contact">>, <<"<", (peer_uri(B))/binary, ">">>}]
        )
    ),
    {ok, RId, #{status := 200, subscription := true}} = sent_result(Sender),
    B1 = B#{
        call => call_id(Refer),
        tt => from_tag(Refer),
        ft => <<"btag">>,
        target => contact_uri(Refer)
    },
    ok = send_notify(
        B1,
        1,
        <<"refer">>,
        <<"terminated;reason=noresource">>,
        503
    ),
    _ = recv_status(maps:get(sock, B), 200),
    ?assertEqual({refer_done, RId, 503}, recv_msg()),
    %% a NOTIFY for no REFER of ours: 481
    ok = send_notify(
        B1#{tt => <<"nosuchtag">>},
        2,
        <<"refer">>,
        <<"active">>,
        180
    ),
    _ = recv_status(maps:get(sock, B), 481),
    hangup(S, D).

%% Refer-Sub: false (with Supported: norefersub) granted by the recipient:
%% no subscription, and a NOTIFY for it is refused 481; a rejected REFER
%% is an error with the status.
%% req: R4488-01 R4488-02 R6665-32
send_refer_sub_false_and_reject(_Config) ->
    {S, D} = call(),
    Sender = send_async(D, <<"sip:carol@127.0.0.1">>, #{refer_sub => false}),
    {Refer, Src} = recv_req(S, <<"REFER">>),
    ?assertEqual(<<"false">>, hdr(Refer, <<"refer-sub">>)),
    %% timer rides along: RFC 4028 7.1 lists it on every request
    Tags = [
        string:trim(T)
     || T <- binary:split(
            hdr(Refer, <<"supported">>),
            <<",">>,
            [global]
        )
    ],
    ?assert(lists:member(<<"norefersub">>, Tags)),
    send(
        S,
        Src,
        resp(
            Refer,
            200,
            <<"OK">>,
            <<"unused">>,
            [{<<"Refer-Sub">>, <<"false">>}]
        )
    ),
    {ok, _, #{subscription := false}} = sent_result(Sender),
    ok = send_notify(S, 10, <<"refer">>, <<"active">>, 100),
    _ = recv_status(maps:get(sock, S), 481),
    Sender2 = send_async(D, <<"sip:carol@127.0.0.1">>, #{}),
    {Refer2, Src2} = recv_req(S, <<"REFER">>),
    send(S, Src2, resp(Refer2, 603, <<"Declined">>, <<"unused">>, [])),
    ?assertMatch({error, {rejected, 603, _}}, sent_result(Sender2)),
    no_msg(500),
    hangup(S, D).

%% RFC 7647 4: a REFER asked to create no subscription (Refer-Sub: false,
%% Supported: norefersub) may go in the dialog, with the dialog's own
%% Contact. A recipient may still create one (RFC 4488 4: a 2xx without
%% Refer-Sub: false): its NOTIFYs then come in that dialog and reach the
%% owner.
%% req: R7647-06 R4488-02
send_in_dialog_norefersub(_Config) ->
    {S, D} = call(),
    Sender = send_async(D, <<"sip:carol@127.0.0.1">>, #{refer_sub => false}),
    {Refer, Src} = recv_req(S, <<"REFER">>),
    ?assertEqual(<<"false">>, hdr(Refer, <<"refer-sub">>)),
    ?assertEqual(maps:get(ft, S), to_tag(Refer)),
    {ok, #{uri := Own}} = chappe_sip_hdr:name_addr(
        chappe_sip_dialog:local_contact(D)
    ),
    ?assertEqual(Own, contact_uri(Refer)),
    send(S, Src, resp(Refer, 200, <<"OK">>, <<"unused">>, [])),
    {ok, Id, #{subscription := true}} = sent_result(Sender),
    ok = send_notify(S, 10, <<"refer">>, <<"active">>, 100),
    _ = recv_status(maps:get(sock, S), 200),
    ?assertEqual({refer_progress, Id, 100}, recv_msg()),
    ok = send_notify(
        S, 11, <<"refer">>, <<"terminated;reason=noresource">>, 200
    ),
    _ = recv_status(maps:get(sock, S), 200),
    ?assertEqual({refer_done, Id, 200}, recv_msg()),
    hangup(S, D).

%% ---- app side ----

start_engine() ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => ctc_engine(EP)}),
    EP.

%% an INVITE dialog with the peer; every in-dialog event comes to the test
call() ->
    EP = start_engine(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{
            handled_events => [refer]
        }),
        Test ! {dialog, Dlg},
        relay(Test)
    end),
    S = peer(EP, <<"a">>),
    R200 = send_invite(S),
    D =
        receive
            {dialog, Dlg} -> Dlg
        after 4000 -> ct:fail(no_dialog)
        end,
    {S#{tt => to_tag(R200), target => contact_uri(R200)}, D}.

relay(Test) ->
    receive
        {chappe_sip_dialog, _, destroy, _} ->
            ok;
        {chappe_sip_dialog, _, Ev, Req, Res} ->
            Test ! {app_event, Ev, Req, Res},
            relay(Test);
        {chappe_sip_dialog, _, _Ev, _Req} ->
            relay(Test)
    after 30000 ->
        ok
    end.

app_event(Ev) ->
    receive
        {app_event, Ev, Req, Res} -> {Req, Res}
    after 4000 -> ct:fail({no_app_event, Ev})
    end.

%% the REFER handler: accept/3 with the case's options, and report what
%% Target-Dialog named
ood_handler() ->
    Test = self(),
    fun(Req, Res) ->
        Opts = persistent_term:get({?MODULE, opts}, #{}),
        TD =
            case chappe_sip_refer:target_dialog(Req) of
                {ok, Dlg} -> {ok, chappe_sip_dialog:id(Dlg)};
                Other -> Other
            end,
        {ok, Refer} = chappe_sip_refer:accept(Req, Res, Opts#{owner => Test}),
        Test ! {ood_accepted, TD, Refer}
    end.

ood_accepted() ->
    receive
        {ood_accepted, TD, Refer} -> {TD, Refer}
    after 4000 -> ct:fail(no_ood_accept)
    end.

%% send/3 blocks until the REFER is answered: run it aside, owned by the
%% test process
send_async(To, Target, Opts) ->
    Test = self(),
    spawn(fun() ->
        Test !
            {sent, self(),
                chappe_sip_refer:send(
                    To,
                    Target,
                    Opts#{owner => Test}
                )}
    end).

sent_result(Pid) ->
    receive
        {sent, Pid, R} -> R
    after 8000 -> ct:fail(no_send_result)
    end.

recv_msg() ->
    receive
        {refer_progress, _, _} = M -> M;
        {refer_done, _, _} = M -> M
    after 4000 -> ct:fail(no_refer_message)
    end.

no_msg(Ms) ->
    receive
        {refer_progress, _, _} = M -> ct:fail({unexpected, M});
        {refer_done, _, _} = M -> ct:fail({unexpected, M})
    after Ms -> ok
    end.

hangup(S, D) ->
    _ = spawn(fun() -> chappe_sip_dialog:destroy(D) end),
    {Bye, Src} = recv_req(S, <<"BYE">>),
    send(S, Src, resp(Bye, 200, <<"OK">>, <<"unused">>, [])),
    ok.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

%% ---- the far end (raw SIP over UDP) ----

peer(EP, Name) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    #{
        sock => Sock,
        ep => EP,
        name => Name,
        ft => <<Name/binary, (rand_hex(3))/binary>>,
        call => <<"refer-", (rand_hex(4))/binary, "@ct">>
    }.

peer_uri(#{sock := Sock, name := Name}) ->
    <<"sip:", Name/binary, "@127.0.0.1:",
        (integer_to_binary(lport(Sock)))/binary>>.

send_invite(#{sock := Sock, ft := FT, call := Call, ep := EP} = S) ->
    Req = request(
        <<"INVITE">>,
        <<"sip:app@127.0.0.1">>,
        S#{tt => undefined},
        1,
        []
    ),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req),
    R200 = recv_status(Sock, 200),
    TT = to_tag(R200),
    P = integer_to_binary(lport(Sock)),
    Ack =
        <<
            "ACK sip:app@127.0.0.1 SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 127.0.0.1:",
            P/binary,
            ";branch=",
            (branch())/binary,
            "\r\n"
            "Max-Forwards: 70\r\n"
            "From: <",
            (peer_uri(S))/binary,
            ">;tag=",
            FT/binary,
            "\r\n"
            "To: <sip:app@127.0.0.1>;tag=",
            TT/binary,
            "\r\n"
            "Call-ID: ",
            Call/binary,
            "\r\nCSeq: 1 ACK\r\n"
            "Content-Length: 0\r\n\r\n"
        >>,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Ack),
    R200.

%% an in-dialog REFER from the peer, accepted by the app with Opts;
%% returns the final response the peer got and accept/4's result
refer_in(S, D, CSeq, Hs) ->
    refer_in(S, D, CSeq, Hs, #{}).

refer_in(#{sock := Sock} = S, D, CSeq, Hs, Opts) ->
    ok = send_refer(S, CSeq, Hs),
    {Req, Res} = app_event(refer),
    Result = chappe_sip_refer:accept(
        D,
        Req,
        Res,
        maps:merge(
            #{owner => self()}, Opts
        )
    ),
    {recv_final(Sock), Result}.

send_refer(#{target := Target, ep := EP, sock := Sock} = S, CSeq, Hs) ->
    Req = request(<<"REFER">>, Target, S, CSeq, Hs),
    gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req).

%% an out-of-dialog REFER (no To tag, its own Call-ID); returns the answer
refer_out(#{ep := EP, sock := Sock} = S, Call, Hs) ->
    Req = request(
        <<"REFER">>,
        <<"sip:app@127.0.0.1">>,
        S#{call => Call, tt => undefined},
        1,
        Hs
    ),
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req),
    recv_status(Sock, 200).

send_subscribe(
    #{target := Target, ep := EP, sock := Sock} = S,
    CSeq,
    Event,
    Expires
) ->
    Req = request(
        <<"SUBSCRIBE">>,
        Target,
        S,
        CSeq,
        [
            {<<"Event">>, Event},
            {<<"Expires">>, integer_to_binary(Expires)}
        ]
    ),
    gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req).

send_notify(
    #{target := Target, ep := EP, sock := Sock} = S,
    CSeq,
    Event,
    State,
    Code
) ->
    Body = chappe_sip_sipfrag:build(Code),
    Req = request(
        <<"NOTIFY">>,
        Target,
        S,
        CSeq,
        [
            {<<"Event">>, Event},
            {<<"Subscription-State">>, State},
            {<<"Content-Type">>, ?FRAG_CT}
        ],
        Body
    ),
    gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req).

request(Method, RUri, S, CSeq, Hs) ->
    request(Method, RUri, S, CSeq, Hs, <<>>).

request(
    Method,
    RUri,
    #{sock := Sock, ft := FT, call := Call} = S,
    CSeq,
    Hs,
    Body
) ->
    P = integer_to_binary(lport(Sock)),
    ToTag =
        case maps:get(tt, S, undefined) of
            undefined -> <<>>;
            TT -> <<";tag=", TT/binary>>
        end,
    iolist_to_binary([
        Method,
        <<" ">>,
        RUri,
        <<" SIP/2.0\r\n">>,
        <<"Via: SIP/2.0/UDP 127.0.0.1:">>,
        P,
        <<";rport;branch=">>,
        branch(),
        <<"\r\n">>,
        <<"Max-Forwards: 70\r\n">>,
        <<"From: <">>,
        peer_uri(S),
        <<">;tag=">>,
        FT,
        <<"\r\n">>,
        <<"To: <sip:app@127.0.0.1>">>,
        ToTag,
        <<"\r\n">>,
        <<"Call-ID: ">>,
        Call,
        <<"\r\n">>,
        <<"CSeq: ">>,
        integer_to_binary(CSeq),
        <<" ">>,
        Method,
        <<"\r\n">>,
        <<"Contact: <">>,
        peer_uri(S),
        <<">\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hs],
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>,
        Body
    ]).

%% receive a NOTIFY, answer it 200, and note when it came
notify_ok(S) ->
    {N, Src} = recv_req(S, <<"NOTIFY">>),
    T = erlang:monotonic_time(millisecond),
    send(S, Src, resp(N, 200, <<"OK">>, <<"unused">>, [])),
    {N, T}.

no_request(#{sock := Sock}, Method, Ms) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, _, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            ct:fail({unexpected, Bin})
    after Ms -> ok
    end.

send(#{sock := Sock}, Dst, Bin) -> gen_udp:send(Sock, {127, 0, 0, 1}, Dst, Bin).

recv_req(#{sock := Sock}, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            {Bin, Src}
    after 8000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    Bin = recv_final(Sock),
    case status(Bin) of
        Code -> Bin;
        _ -> ct:fail({unexpected_status, Code, Bin})
    end.

recv_final(Sock) ->
    receive
        {udp, Sock, _, _, <<"SIP/2.0 1", _/binary>>} ->
            recv_final(Sock);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = Bin} ->
            Bin
    after 6000 -> ct:fail(no_final_response)
    end.

resp(ReqBin, Status, Reason, ToTag, Extra) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined -> <<To0/binary, ";tag=", ToTag/binary>>;
            _ -> To0
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>,
        integer_to_binary(Status),
        <<" ">>,
        Reason,
        <<"\r\n">>,
        [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
        <<"From: ">>,
        chappe_sip_msg:get(<<"from">>, Msg),
        <<"\r\n">>,
        <<"To: ">>,
        To,
        <<"\r\n">>,
        <<"Call-ID: ">>,
        chappe_sip_msg:call_id(Msg),
        <<"\r\n">>,
        <<"CSeq: ">>,
        chappe_sip_msg:get(<<"cseq">>, Msg),
        <<"\r\n">>,
        [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Extra],
        <<"Content-Length: 0\r\n\r\n">>
    ]).

%% ---- message helpers ----

parse(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    M.

status(Bin) -> chappe_sip_msg:status(parse(Bin)).
hdr(Bin, Name) -> chappe_sip_msg:get(Name, parse(Bin)).
body(Bin) -> chappe_sip_msg:body(parse(Bin)).
call_id(Bin) -> chappe_sip_msg:call_id(parse(Bin)).
to_tag(Bin) -> chappe_sip_msg:to_tag(parse(Bin)).
from_tag(Bin) -> chappe_sip_msg:from_tag(parse(Bin)).

contact_uri(Bin) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(Bin, <<"contact">>)),
    U.

%% "active;expires=57" -> {<<"active">>, 57}
sub_state(Bin) ->
    [State, Params] = binary:split(hdr(Bin, <<"subscription-state">>), <<";">>),
    <<"expires=", N/binary>> = Params,
    {State, binary_to_integer(N)}.

pick() -> chappe_sip_test_port:pick().
ctc_engine(EP) -> <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>.
lport(Sock) ->
    {ok, P} = inet:port(Sock),
    P.
rand_hex(N) -> binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
branch() -> <<"z9hG4bK", (rand_hex(6))/binary>>.
