%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_dispatch: the engine's dispatch policy as pure functions.
-module(chappe_sip_dispatch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(D, chappe_sip_dispatch).

req(Method, Extra) ->
    iolist_to_binary([
        Method, " sip:bob@example.com SIP/2.0\r\n",
        "Via: SIP/2.0/UDP 192.0.2.1:5060;branch=z9hG4bK-1\r\n",
        "From: <sip:alice@example.com>;tag=ft\r\n",
        "To: <sip:bob@example.com>", Extra, "\r\n",
        "Call-ID: c1\r\n",
        "CSeq: 1 ", Method, "\r\n",
        "Content-Length: 0\r\n\r\n"
    ]).

sub(Event) ->
    iolist_to_binary([
        "SUBSCRIBE sip:bob@example.com SIP/2.0\r\n",
        "Via: SIP/2.0/UDP 192.0.2.1:5060;branch=z9hG4bK-2\r\n",
        "From: <sip:alice@example.com>;tag=ft\r\n",
        "To: <sip:bob@example.com>\r\n",
        "Call-ID: c2\r\n",
        "CSeq: 1 SUBSCRIBE\r\n",
        [["Event: ", Event, "\r\n"] || Event =/= none],
        "Content-Length: 0\r\n\r\n"
    ]).

h() -> fun(_Req, _Res) -> ok end.

stray_in_dialog_test() ->
    ?assert(?D:stray_in_dialog(<<"BYE">>, req("BYE", ""))),
    ?assert(?D:stray_in_dialog(<<"INFO">>, req("INFO", ";tag=tt"))),
    ?assertNot(?D:stray_in_dialog(<<"INFO">>, req("INFO", ""))),
    ?assertNot(?D:stray_in_dialog(<<"NOTIFY">>, req("NOTIFY", ";tag=tt"))),
    ?assertNot(?D:stray_in_dialog(<<"ACK">>, req("ACK", ";tag=tt"))),
    ?assertNot(?D:stray_in_dialog(<<"INFO">>, <<"garbage">>)).

route_for_method_test() ->
    H = h(),
    Routes = #{<<"INVITE">> => H},
    ?assertEqual(
        {H, <<"INVITE">>},
        ?D:route_for(<<"INVITE">>, req("INVITE", ""), Routes, {#{}, undefined})
    ),
    ?assertEqual(
        none,
        ?D:route_for(<<"INFO">>, req("INFO", ""), Routes, {#{}, undefined})
    ).

route_for_package_test() ->
    P = h(),
    S = h(),
    Pkgs = #{<<"presence">> => P},
    Events = {Pkgs, undefined},
    ?assertEqual(
        {P, {package, <<"presence">>}},
        ?D:route_for(<<"SUBSCRIBE">>, sub("Presence;id=1"), #{}, Events)
    ),
    %% another package: the SUBSCRIBE handler, else 489
    ?assertEqual(
        {S, <<"SUBSCRIBE">>},
        ?D:route_for(
            <<"SUBSCRIBE">>, sub("dialog"), #{<<"SUBSCRIBE">> => S}, Events
        )
    ),
    ?assertEqual(
        {bad_event, [<<"presence">>]},
        ?D:route_for(<<"SUBSCRIBE">>, sub("dialog"), #{}, Events)
    ),
    %% refer is never a package handler's
    ?assertEqual(
        {bad_event, [<<"refer">>]},
        ?D:route_for(
            <<"SUBSCRIBE">>, sub("refer"), #{}, {#{<<"refer">> => P}, []}
        )
    ),
    ?assertEqual(
        none, ?D:route_for(<<"SUBSCRIBE">>, sub("dialog"), #{}, {#{}, undefined})
    ).

bad_event_test() ->
    Events = {#{<<"presence">> => h()}, undefined},
    ?assertEqual(refer, ?D:bad_event(<<"SUBSCRIBE">>, sub("refer"), Events)),
    ?assertEqual(false, ?D:bad_event(<<"SUBSCRIBE">>, sub("presence"), Events)),
    ?assertEqual(
        {true, [<<"presence">>]},
        ?D:bad_event(<<"SUBSCRIBE">>, sub(none), Events)
    ),
    ?assertEqual(false, ?D:bad_event(<<"SUBSCRIBE">>, sub("x"), {#{}, any})),
    ?assertEqual(false, ?D:bad_event(<<"INVITE">>, req("INVITE", ""), Events)).

unrouted_test() ->
    Routes = #{<<"INVITE">> => h()},
    E = {#{}, undefined},
    ?assertEqual(noreply, ?D:unrouted(<<"ACK">>, Routes, E)),
    ?assertMatch({481, _, []}, ?D:unrouted(<<"CANCEL">>, Routes, E)),
    {405, _, [{<<"Allow">>, Allow}]} = ?D:unrouted(<<"INFO">>, Routes, E),
    ?assertEqual(<<"ACK, BYE, CANCEL, INVITE, NOTIFY, OPTIONS">>, Allow),
    ?assertMatch({501, _, [{<<"Allow">>, _}]}, ?D:unrouted(<<"FOO">>, Routes, E)),
    {200, _, Hdrs} = ?D:unrouted(<<"OPTIONS">>, Routes, E),
    ?assertMatch({_, _}, lists:keyfind(<<"Accept">>, 1, Hdrs)),
    ?assertEqual(false, lists:keyfind(<<"Allow-Events">>, 1, Hdrs)),
    {200, _, Hdrs2} =
        ?D:unrouted(<<"OPTIONS">>, Routes, {#{<<"presence">> => h()}, [<<"dialog">>]}),
    ?assertEqual(
        {<<"Allow-Events">>, <<"dialog, presence">>},
        lists:keyfind(<<"Allow-Events">>, 1, Hdrs2)
    ),
    {<<"Allow">>, Allow2} = lists:keyfind(<<"Allow">>, 1, Hdrs2),
    ?assertNotEqual(nomatch, binary:match(Allow2, <<"SUBSCRIBE">>)).

allow_events_test() ->
    ?assertEqual(any, ?D:allow_events(#{}, undefined)),
    ?assertEqual(any, ?D:allow_events(#{<<"a">> => h()}, any)),
    ?assertEqual([<<"a">>], ?D:allow_events(#{<<"a">> => h()}, undefined)),
    ?assertEqual([<<"a">>, <<"b">>], ?D:allow_events(#{<<"a">> => h()}, [<<"b">>, <<"a">>])).

event_package_test() ->
    ?assertEqual(<<"presence">>, ?D:event_package(sub(" Presence ;id=2"))),
    ?assertEqual(undefined, ?D:event_package(sub(none))),
    ?assertEqual(undefined, ?D:event_package(<<"junk">>)).

merge_test() ->
    Raw = req("INVITE", ""),
    {Key, <<"z9hG4bK-1">>} = ?D:merge_key(Raw),
    ?assertEqual({<<"ft">>, <<"c1">>, 1, <<"INVITE">>}, Key),
    ?assertEqual(none, ?D:merge_key(req("INVITE", ";tag=tt"))),
    ?assertEqual(none, ?D:merge_check(<<"ACK">>, Raw, #{}, #{})),
    ?assertEqual({Key, <<"z9hG4bK-1">>}, ?D:merge_check(<<"INVITE">>, Raw, #{}, #{})),
    Pid = self(),
    %% the same key on another branch: merged, unless that one is proxied
    Idx = #{Key => {<<"z9hG4bK-other">>, 7, Pid}},
    ?assertEqual(merged, ?D:merge_check(<<"INVITE">>, Raw, Idx, #{})),
    ?assertEqual(
        {Key, <<"z9hG4bK-1">>},
        ?D:merge_check(<<"INVITE">>, Raw, Idx, #{7 => Pid})
    ),
    %% the same branch is a retransmission, not a merge
    Same = #{Key => {<<"z9hG4bK-1">>, 7, Pid}},
    ?assertEqual({Key, <<"z9hG4bK-1">>}, ?D:merge_check(<<"INVITE">>, Raw, Same, #{})).

own_route_test() ->
    ?assertNot(?D:is_own_route(req("BYE", ";tag=tt"), <<"sip:127.0.0.1:5060">>)),
    ?assertNot(?D:is_own_route(<<"espx= junk">>, <<"sip:127.0.0.1:5060">>)).
