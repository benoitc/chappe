%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_sip_flow: flow tokens, received flows, NAT detection and the MAC
%% fields. Edge routes and the secret are covered by chappe_sip_route_tests.
-module(chappe_sip_flow_tests).

-include_lib("eunit/include/eunit.hrl").

-define(F, chappe_sip_flow).

token_round_trip_test() ->
    Flows = [
        42,
        {conn, 7},
        {udp, <<"192.0.2.1">>, 5060},
        {udp, <<"192.0.2.1">>, 5060, <<"10.0.0.1">>}
    ],
    [?assertEqual(F, ?F:untoken(?F:token(F))) || F <- Flows],
    ?assertEqual(<<"c7">>, ?F:token({conn, 7})),
    ?assertEqual(<<"42">>, ?F:token(42)),
    ?assertEqual(undefined, ?F:untoken(<<"c0">>)),
    ?assertEqual(undefined, ?F:untoken(<<"u3132-70000">>)),
    ?assertEqual(undefined, ?F:untoken(<<"x">>)).

tokens_test() ->
    ?assertEqual(
        {42, {conn, 3}},
        ?F:tokens(#{<<"ftok">> => <<"42">>, <<"ftokd">> => <<"c3">>})
    ),
    ?assertEqual({undefined, undefined}, ?F:tokens(#{})).

same_test() ->
    U = {udp, <<"192.0.2.1">>, 5060},
    ?assert(?F:same(U, {udp, <<"192.0.2.1">>, 5060, <<"l">>})),
    ?assert(?F:same({udp, <<"192.0.2.1">>, 5060, <<"l">>}, U)),
    ?assertNot(?F:same(undefined, U)),
    ?assertNot(?F:same(U, undefined)),
    ?assert(?F:same(5, 5)).

received_flow_test() ->
    ?assertEqual({conn, 9}, ?F:received_flow(#{conn => 9})),
    ?assertEqual(
        {udp, <<"192.0.2.1">>, 5062},
        ?F:received_flow(#{
            transport => <<"udp">>,
            source_ip => <<"192.0.2.1">>,
            source_port => 5062
        })
    ),
    ?assertEqual(undefined, ?F:received_flow(#{transport => <<"tcp">>})),
    ?assertEqual(12, ?F:arrival_flow(#{flow => 12, conn => 9})),
    ?assertEqual({conn, 9}, ?F:arrival_flow(#{conn => 9})).

nated_test() ->
    From = {udp, <<"192.0.2.1">>, 5062},
    ?assert(?F:nated(<<"<sip:a@10.0.0.2:5060>">>, From)),
    ?assertNot(?F:nated(<<"<sip:a@192.0.2.1:5062>">>, From)),
    ?assertNot(?F:nated(<<"<sip:a@10.0.0.2;transport=tcp>">>, From)),
    ?assertNot(?F:nated(<<"<sip:a@10.0.0.2>">>, {conn, 1})),
    ?assert(?F:nated(<<"sip:a@10.0.0.2">>, {udp, <<"192.0.2.1">>, 5062, <<"l">>})).

flow_route_test() ->
    ?assertEqual({ws, 3}, ?F:flow_route(3)),
    ?assertEqual({conn, 3}, ?F:flow_route({conn, 3})).

fields_test() ->
    ?assertEqual(
        <<"h||c1|42|">>, ?F:fields([<<"h">>, undefined, {conn, 1}, 42, undefined])
    ),
    ?assert(?F:mac_equal(<<"ab">>, <<"ab">>)),
    ?assertNot(?F:mac_equal(<<"a">>, <<"ab">>)),
    ?assertEqual({ok, 5}, ?F:expiry(#{<<"exp">> => <<"5">>})),
    ?assertEqual(legacy, ?F:expiry(#{})),
    ?assertEqual(error, ?F:expiry(#{<<"exp">> => <<"x">>})).
