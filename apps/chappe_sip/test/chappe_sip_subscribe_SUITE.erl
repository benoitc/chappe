%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% SUBSCRIBE/NOTIFY subscription dialogs (RFC 6665) on the notifier side.
%%
%% The test process is the subscriber: it owns a gen_udp socket and speaks
%% raw SIP. The app handler answers the SUBSCRIBE with create_uas/3, relays
%% the dialog events it receives to the test process, and runs the
%% notify/destroy calls the test asks for.
-module(chappe_sip_subscribe_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([
    subscribe_initial_notify/1,
    expires_capped/1,
    min_expires_423/1,
    refresh_extends/1,
    unsubscribe/1,
    expiry_terminates/1,
    destroy_sends_terminated/1,
    notify_481_terminates/1,
    notify_failure_removes/1,
    notify_500_keeps/1,
    unknown_package_489/1,
    missing_event_489/1,
    refer_package_403/1,
    owner_down_terminates/1,
    notify_in_invite_dialog/1,
    ws_subscription/1
]).

all() ->
    [
        subscribe_initial_notify,
        expires_capped,
        min_expires_423,
        refresh_extends,
        unsubscribe,
        expiry_terminates,
        destroy_sends_terminated,
        notify_481_terminates,
        notify_failure_removes,
        notify_500_keeps,
        unknown_package_489,
        missing_event_489,
        refer_package_403,
        owner_down_terminates,
        notify_in_invite_dialog,
        ws_subscription
    ].

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
    flush(),
    ok.

-define(CT, <<"application/conference-info+xml">>).

%% SUBSCRIBE is answered 200 with the granted Expires; the owner's first
%% NOTIFY carries Event, Subscription-State active;expires and the body.
subscribe_initial_notify(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t1">>),
    R200 = send_subscribe(S, 1, 300, undefined),
    ?assertEqual(<<"300">>, hdr(R200, <<"expires">>)),
    ?assertNotEqual(undefined, hdr(R200, <<"contact">>)),
    {_Dlg, H} = dialog(),
    run_async(H, fun(D) ->
        chappe_sip_dialog:notify(D, #{
            state => active, body => <<"<conference-info/>">>,
            content_type => ?CT
        })
    end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(<<"conference">>, hdr(Notify, <<"event">>)),
    ?assertEqual(?CT, hdr(Notify, <<"content-type">>)),
    ?assertEqual(<<"<conference-info/>">>, body(Notify)),
    ?assertEqual(to_tag(R200), from_tag(Notify)),
    ?assertEqual(maps:get(ft, S), to_tag(Notify)),
    {<<"active">>, Exp} = sub_state(Notify),
    ?assert(Exp =< 300 andalso Exp >= 290),
    reply(S, Notify, NSrc, 200),
    {ok, Msg} = ran(),
    ?assertEqual(200, chappe_sip_msg:status(Msg)).

%% the granted Expires is the app's cap when the subscriber asks for more
expires_capped(_Config) ->
    EP = setup(#{expires => 120}),
    S = sub(EP, <<"t2">>),
    R200 = send_subscribe(S, 1, 7200, undefined),
    ?assertEqual(<<"120">>, hdr(R200, <<"expires">>)),
    {_Dlg, H} = dialog(),
    run_async(H, fun(D) -> chappe_sip_dialog:notify(D, #{state => pending}) end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    {<<"pending">>, Exp} = sub_state(Notify),
    ?assert(Exp =< 120 andalso Exp >= 110),
    reply(S, Notify, NSrc, 200),
    {ok, _} = ran().

%% an Expires under min_expires is refused 423 with Min-Expires, no dialog
min_expires_423(_Config) ->
    EP = setup(#{expires => 600, min_expires => 60}),
    S = sub(EP, <<"t3">>),
    R423 = send_subscribe(S, 1, 10, undefined, 423),
    ?assertEqual(<<"60">>, hdr(R423, <<"min-expires">>)),
    receive
        {create_uas, Err} -> ?assertEqual({error, {interval_too_brief, 60}}, Err)
    after 4000 -> ct:fail(no_create_uas_result)
    end.

%% an in-dialog SUBSCRIBE refreshes the expiry: 200 with the new Expires,
%% the owner is told, and the subscription outlives the first grant
refresh_extends(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t4">>),
    R200 = send_subscribe(S, 1, 2, undefined),
    ?assertEqual(<<"2">>, hdr(R200, <<"expires">>)),
    TT = to_tag(R200),
    {_Dlg, H} = dialog(),
    R2 = send_subscribe(S#{target => contact_uri(R200)}, 2, 60, TT),
    ?assertEqual(<<"60">>, hdr(R2, <<"expires">>)),
    ok = expect({owner, {refreshed, 60}}),
    timer:sleep(3000),
    %% still alive past the first 2 s grant: no terminated NOTIFY, no destroy
    receive
        {owner, destroy, Why} -> ct:fail({destroyed, Why})
    after 0 -> ok
    end,
    run_async(H, fun(D) -> chappe_sip_dialog:notify(D, #{state => active}) end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    {<<"active">>, Exp} = sub_state(Notify),
    ?assert(Exp > 2 andalso Exp =< 60),
    reply(S, Notify, NSrc, 200),
    {ok, _} = ran().

%% SUBSCRIBE Expires: 0 unsubscribes: 200 Expires: 0, the owner is told and
%% sends the final NOTIFY, after which the dialog is gone
unsubscribe(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t5">>),
    R200 = send_subscribe(S, 1, 600, undefined),
    TT = to_tag(R200),
    {Dlg, H} = dialog(),
    R2 = send_subscribe(S#{target => contact_uri(R200)}, 2, 0, TT),
    ?assertEqual(<<"0">>, hdr(R2, <<"expires">>)),
    ok = expect({owner, unsubscribed}),
    run_async(H, fun(D) ->
        chappe_sip_dialog:notify(D, #{
            state => {terminated, timeout}, body => <<"<x/>">>,
            content_type => ?CT
        })
    end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(
        <<"terminated;reason=timeout">>, hdr(Notify, <<"subscription-state">>)
    ),
    reply(S, Notify, NSrc, 200),
    {ok, _} = ran(),
    ok = expect({owner, destroy, terminated}),
    ok = wait_down(Dlg).

%% no refresh before the grant runs out: the fsm sends terminated;
%% reason=timeout, tells the owner, and stops
expiry_terminates(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t6">>),
    _R200 = send_subscribe(S, 1, 1, undefined),
    {Dlg, _H} = dialog(),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(
        <<"terminated;reason=timeout">>, hdr(Notify, <<"subscription-state">>)
    ),
    ?assertEqual(<<"conference">>, hdr(Notify, <<"event">>)),
    reply(S, Notify, NSrc, 200),
    ok = expect({owner, destroy, expired}),
    ok = wait_down(Dlg).

%% destroy/1 ends a subscription with a terminated NOTIFY, never a BYE
destroy_sends_terminated(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t7">>),
    _R200 = send_subscribe(S, 1, 600, undefined),
    {Dlg, H} = dialog(),
    run_async(H, fun(D) -> chappe_sip_dialog:destroy(D) end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(Notify, <<"subscription-state">>)
    ),
    reply(S, Notify, NSrc, 200),
    ok = ran(),
    ok = wait_down(Dlg),
    Sock = maps:get(sock, S),
    receive
        {udp, Sock, _, _, <<"BYE ", _/binary>>} -> ct:fail(bye_sent)
    after 1000 -> ok
    end.

%% a 481 to a NOTIFY ends the subscription (RFC 6665 4.2.2)
notify_481_terminates(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t8">>),
    _R200 = send_subscribe(S, 1, 600, undefined),
    {Dlg, H} = dialog(),
    run_async(H, fun(D) -> chappe_sip_dialog:notify(D, #{state => active}) end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    reply(S, Notify, NSrc, 481),
    {ok, Msg} = ran(),
    ?assertEqual(481, chappe_sip_msg:status(Msg)),
    ok = expect({owner, destroy, {notify_failed, 481}}),
    ok = wait_down(Dlg).

%% Every NOTIFY failure code of RFC 6665 4.2.2 removes the subscription,
%% and so does a 408.
%% req: R6665-14
notify_failure_removes(_Config) ->
    EP = setup(#{expires => 600}),
    Codes = [404, 405, 408, 410, 416, 480, 481, 482, 483, 484, 485, 489, 501,
             604],
    lists:foreach(
        fun(Code) ->
            S = sub(EP, <<"tf">>),
            _R200 = send_subscribe(S, 1, 600, undefined),
            {Dlg, H} = dialog(),
            run_async(H, fun(D) ->
                chappe_sip_dialog:notify(D, #{state => active})
            end),
            {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
            reply(S, Notify, NSrc, Code),
            {ok, Msg} = ran(),
            ?assertEqual(Code, chappe_sip_msg:status(Msg)),
            ok = expect({owner, destroy, {notify_failed, Code}}),
            ok = wait_down(Dlg)
        end,
        Codes
    ).

%% A failure outside that list leaves the subscription in place.
%% req: R6665-14
notify_500_keeps(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"tk">>),
    _R200 = send_subscribe(S, 1, 600, undefined),
    {Dlg, H} = dialog(),
    run_async(H, fun(D) -> chappe_sip_dialog:notify(D, #{state => active}) end),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    reply(S, Notify, NSrc, 500),
    {ok, Msg} = ran(),
    ?assertEqual(500, chappe_sip_msg:status(Msg)),
    MRef = chappe_sip_dialog:monitor(Dlg),
    receive
        {'DOWN', MRef, process, _, _} -> ct:fail(subscription_removed)
    after 1000 -> ok
    end.

%% A notifier registered for some packages answers any other with 489 and
%% the packages it serves in Allow-Events (RFC 6665 4.2.1.1, 8.3.2).
%% req: R6665-07 R6665-27
unknown_package_489(_Config) ->
    EP = setup_events([<<"conference">>, <<"dialog">>]),
    S = sub(EP, <<"tu">>),
    R489 = send_subscribe(S, 1, 600, undefined, 489, <<"presence">>),
    ?assertEqual(<<"conference, dialog">>, hdr(R489, <<"allow-events">>)),
    receive
        {dialog, _, _} -> ct:fail(handler_ran)
    after 300 -> ok
    end,
    S2 = sub(EP, <<"tu2">>),
    _ = send_subscribe(S2, 1, 600, undefined, 200, <<"conference;id=7">>),
    {_, _} = dialog().

%% A SUBSCRIBE with no Event is the old PINT default (RFC 6665 7.2.1):
%% 489 when that package is not served.
%% req: R6665-29
missing_event_489(_Config) ->
    EP = setup_events([<<"conference">>]),
    S = sub(EP, <<"tm">>),
    R489 = send_subscribe(S, 1, 600, undefined, 489, none),
    ?assertEqual(<<"conference">>, hdr(R489, <<"allow-events">>)).

%% A refer subscription only exists inside the REFER's dialog, so an
%% out-of-dialog SUBSCRIBE for it matches none and gets 403, whatever the
%% handler serves (RFC 3515 2.4.4).
%% req: R3515-17
refer_package_403(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"tr">>),
    _ = send_subscribe(S, 1, 600, undefined, 403, <<"refer">>),
    receive
        {dialog, _, _} -> ct:fail(handler_ran)
    after 300 -> ok
    end,
    ok = chappe_sip:stop(),
    EP2 = setup_events([<<"conference">>, <<"refer">>]),
    S2 = sub(EP2, <<"tr2">>),
    _ = send_subscribe(S2, 1, 600, undefined, 403, <<"refer;id=3">>).

%% the owner dying tears a subscription down with a terminated NOTIFY
owner_down_terminates(_Config) ->
    EP = setup(#{expires => 600}),
    S = sub(EP, <<"t9">>),
    _R200 = send_subscribe(S, 1, 600, undefined),
    {Dlg, H} = dialog(),
    exit(H, kill),
    {Notify, NSrc} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(Notify, <<"subscription-state">>)
    ),
    reply(S, Notify, NSrc, 200),
    ok = wait_down(Dlg).

%% notify/2 in an INVITE dialog (the REFER implicit subscription): the app
%% names the event, a terminated NOTIFY leaves the call up
notify_in_invite_dialog(_Config) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => ctc_engine(EP)}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{}),
        Test ! {dialog, Dlg, self()},
        relay(Test, Dlg)
    end),
    S = sub(EP, <<"t10">>),
    R200 = send_invite(S),
    TT = to_tag(R200),
    {Dlg, H} = dialog(),
    run_async(H, fun(D) ->
        chappe_sip_dialog:notify(D, #{
            event => <<"refer">>, state => active,
            body => <<"SIP/2.0 100 Trying\r\n">>,
            content_type => <<"message/sipfrag">>
        })
    end),
    {N1, Src1} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(<<"refer">>, hdr(N1, <<"event">>)),
    ?assertEqual(<<"active">>, hdr(N1, <<"subscription-state">>)),
    reply(S, N1, Src1, 200),
    {ok, _} = ran(),
    run_async(H, fun(D) ->
        chappe_sip_dialog:notify(D, #{
            event => <<"refer">>, state => {terminated, noresource},
            body => <<"SIP/2.0 200 OK\r\n">>,
            content_type => <<"message/sipfrag">>
        })
    end),
    {N2, Src2} = recv_req(S, <<"NOTIFY">>),
    ?assertEqual(
        <<"terminated;reason=noresource">>, hdr(N2, <<"subscription-state">>)
    ),
    reply(S, N2, Src2, 200),
    {ok, _} = ran(),
    %% the call is still up: destroy sends a BYE
    run_async(H, fun(D) -> chappe_sip_dialog:destroy(D) end),
    {Bye, BSrc} = recv_req(S, <<"BYE">>),
    send(S, BSrc, resp(Bye, 200, <<"OK">>, TT)),
    ok = ran(),
    ok = wait_down(Dlg).

%% over WebSocket: the 2xx, a refresh and the final NOTIFY all ride the flow
ws_subscription(_Config) ->
    EP = pick(),
    WP = pick(),
    ok = chappe_sip:start(#{contact => ctc_engine(EP), ws => #{port => WP}}),
    Test = self(),
    ok = chappe_sip:subscribe(fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{expires => 600}),
        Test ! {dialog, Dlg, self()},
        relay(Test, Dlg)
    end),
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{
        handler => chappe_sip_ws_test_client,
        handler_opts => #{notify => self()},
        subprotocols => [<<"sip">>]
    }),
    Call = <<"ws-sub-", (rand_hex(4))/binary, "@ct">>,
    ws:send(C, {text, ws_subscribe(Call, 1, 300, undefined)}),
    R200 = recv_ws_status(200),
    ?assertEqual(<<"300">>, hdr(R200, <<"expires">>)),
    TT = to_tag(R200),
    {Dlg, H} = dialog(),
    ws:send(C, {text, ws_subscribe(Call, 2, 120, TT)}),
    R2 = recv_ws_status(200),
    ?assertEqual(<<"120">>, hdr(R2, <<"expires">>)),
    ok = expect({owner, {refreshed, 120}}),
    run_async(H, fun(D) -> chappe_sip_dialog:destroy(D) end),
    Notify = recv_ws_req(<<"NOTIFY">>),
    ?assertEqual(
        <<"terminated;reason=noresource">>,
        hdr(Notify, <<"subscription-state">>)
    ),
    ws:send(C, {text, resp(Notify, 200, <<"OK">>, <<"unused">>)}),
    ok = ran(),
    ok = wait_down(Dlg),
    ws:close(C, 1000).

ws_subscribe(Call, CSeq, Expires, TT) ->
    ToTag =
        case TT of
            undefined -> <<>>;
            _ -> <<";tag=", TT/binary>>
        end,
    <<"SUBSCRIBE sip:conf@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:sub@127.0.0.1>;tag=wssub\r\n"
      "To: <sip:conf@127.0.0.1>", ToTag/binary, "\r\n"
      "Contact: <sip:sub@df7jal23ls0d.invalid;transport=ws>\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: ", (integer_to_binary(CSeq))/binary, " SUBSCRIBE\r\n"
      "Event: conference\r\n"
      "Expires: ", (integer_to_binary(Expires))/binary, "\r\n"
      "Content-Length: 0\r\n\r\n">>.

recv_ws_status(Code) ->
    CB = integer_to_binary(Code),
    receive
        {ws_in, <<"SIP/2.0 ", CB:3/binary, _/binary>> = Bin} -> Bin;
        {ws_in, <<"SIP/2.0 1", _/binary>>} -> recv_ws_status(Code);
        {ws_in, Other} -> ct:fail({unexpected_ws, Other})
    after 6000 -> ct:fail({no_ws_status, Code})
    end.

recv_ws_req(Method) ->
    L = byte_size(Method),
    receive
        {ws_in, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method -> Bin
    after 8000 -> ct:fail({no_ws_req, Method})
    end.

%% ---- app side ----

setup(Opts) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => ctc_engine(EP)}),
    Test = self(),
    ok = chappe_sip:subscribe(fun(Req, Res) ->
        case chappe_sip:create_uas(Req, Res, Opts) of
            {ok, Dlg} ->
                Test ! {dialog, Dlg, self()},
                relay(Test, Dlg);
            Err ->
                Test ! {create_uas, Err}
        end
    end),
    EP.

setup_events(Events) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => ctc_engine(EP)}),
    Test = self(),
    ok = chappe_sip:subscribe(Events, fun(Req, Res) ->
        {ok, Dlg} = chappe_sip:create_uas(Req, Res, #{expires => 600}),
        Test ! {dialog, Dlg, self()},
        relay(Test, Dlg)
    end),
    EP.

relay(Test, Dlg) ->
    receive
        {run, From, F} ->
            From ! {ran, F(Dlg)},
            relay(Test, Dlg);
        {chappe_sip_dialog, _, destroy, Why} ->
            Test ! {owner, destroy, Why},
            %% keep serving run requests for a destroy caller still waiting
            relay(Test, Dlg);
        {chappe_sip_dialog, _, Ev, _Req} ->
            Test ! {owner, Ev},
            relay(Test, Dlg);
        {chappe_sip_dialog, _, Ev, _Req, _Res} ->
            Test ! {owner, Ev},
            relay(Test, Dlg)
    after 30000 ->
        ok
    end.

dialog() ->
    receive
        {dialog, D, H} -> {D, H}
    after 4000 -> ct:fail(no_dialog)
    end.

run_async(H, F) -> H ! {run, self(), F}.

ran() ->
    receive
        {ran, R} -> R
    after 8000 -> ct:fail(no_run_result)
    end.

wait_down(Dlg) ->
    MRef = chappe_sip_dialog:monitor(Dlg),
    receive
        {'DOWN', MRef, process, _, _} -> ok
    after 5000 -> ct:fail(dialog_still_up)
    end.

expect(Msg) ->
    receive
        Msg -> ok
    after 6000 -> ct:fail({expected, Msg})
    end.

flush() ->
    receive
        _ -> flush()
    after 0 -> ok
    end.

%% ---- subscriber side (raw SIP over UDP) ----

sub(EP, FT) ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    #{
        sock => Sock, ep => EP, ft => <<FT/binary, (rand_hex(3))/binary>>,
        call => <<"sub-", (rand_hex(4))/binary, "@ct">>,
        target => <<"sip:conf@127.0.0.1">>
    }.

send_subscribe(S, CSeq, Expires, TT) ->
    send_subscribe(S, CSeq, Expires, TT, 200).

send_subscribe(S, CSeq, Expires, TT, Want) ->
    send_subscribe(S, CSeq, Expires, TT, Want, <<"conference">>).

send_subscribe(#{ep := EP} = S, CSeq, Expires, TT, Want, Event) ->
    #{sock := Sock, ft := FT, call := Call, target := Target} = S,
    P = integer_to_binary(lport(Sock)),
    ToTag =
        case TT of
            undefined -> <<>>;
            _ -> <<";tag=", TT/binary>>
        end,
    Req =
        <<"SUBSCRIBE ", Target/binary, " SIP/2.0\r\n"
          "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
          (branch())/binary, "\r\n"
          "Max-Forwards: 70\r\n"
          "From: <sip:sub@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
          "To: <sip:conf@127.0.0.1>", ToTag/binary, "\r\n"
          "Contact: <sip:sub@127.0.0.1:", P/binary, ">\r\n"
          "Call-ID: ", Call/binary, "\r\n"
          "CSeq: ", (integer_to_binary(CSeq))/binary, " SUBSCRIBE\r\n",
          (case Event of
               none -> <<>>;
               _ -> <<"Event: ", Event/binary, "\r\n">>
           end)/binary,
          "Accept: application/conference-info+xml\r\n"
          "Expires: ", (integer_to_binary(Expires))/binary, "\r\n"
          "Content-Length: 0\r\n\r\n">>,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req),
    recv_status(Sock, Want).

send_invite(#{sock := Sock, ft := FT, call := Call, ep := EP}) ->
    P = integer_to_binary(lport(Sock)),
    Req =
        <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
          "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=",
          (branch())/binary, "\r\n"
          "Max-Forwards: 70\r\n"
          "From: <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
          "To: <sip:app@127.0.0.1>\r\n"
          "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
          "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
          "Content-Length: 0\r\n\r\n">>,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Req),
    R200 = recv_status(Sock, 200),
    TT = to_tag(R200),
    Ack =
        <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
          "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=",
          (branch())/binary, "\r\n"
          "Max-Forwards: 70\r\n"
          "From: <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
          "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
          "Call-ID: ", Call/binary, "\r\nCSeq: 1 ACK\r\n"
          "Content-Length: 0\r\n\r\n">>,
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, EP, Ack),
    R200.

reply(S, ReqBin, Src, Status) ->
    send(S, Src, resp(ReqBin, Status, reason(Status), <<"unused">>)).

reason(200) -> <<"OK">>;
reason(481) -> <<"Call/Transaction Does Not Exist">>;
reason(_) -> <<"Failed">>.

send(#{sock := Sock}, Dst, Bin) -> gen_udp:send(Sock, {127, 0, 0, 1}, Dst, Bin).

recv_req(#{sock := Sock}, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when
            M =:= Method
        ->
            {Bin, Src};
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>>} ->
            recv_req(#{sock => Sock}, Method)
    after 8000 -> ct:fail({no_req, Method})
    end.

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                <<"1", _/binary>> -> recv_status(Sock, Code);
                _ -> ct:fail({unexpected_status, Bin})
            end
    after 6000 -> ct:fail({no_status, Code})
    end.

resp(ReqBin, Status, Reason, ToTag) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To =
        case chappe_sip_msg:to_tag(Msg) of
            undefined -> <<To0/binary, ";tag=", ToTag/binary>>;
            _ -> To0
        end,
    iolist_to_binary([
        <<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
        [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
        <<"From: ">>, chappe_sip_msg:get(<<"from">>, Msg), <<"\r\n">>,
        <<"To: ">>, To, <<"\r\n">>,
        <<"Call-ID: ">>, chappe_sip_msg:call_id(Msg), <<"\r\n">>,
        <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, Msg), <<"\r\n">>,
        <<"Content-Length: 0\r\n\r\n">>
    ]).

%% ---- message helpers ----

parse(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    M.

hdr(Bin, Name) -> chappe_sip_msg:get(Name, parse(Bin)).
body(Bin) -> chappe_sip_msg:body(parse(Bin)).
to_tag(Bin) -> chappe_sip_msg:to_tag(parse(Bin)).
from_tag(Bin) -> chappe_sip_msg:from_tag(parse(Bin)).

contact_uri(Bin) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(hdr(Bin, <<"contact">>)),
    U.

%% "active;expires=297" -> {<<"active">>, 297}
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
