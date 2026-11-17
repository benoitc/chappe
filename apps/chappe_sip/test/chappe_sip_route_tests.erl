%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Unit tests for the boot checks, the Record-Route helpers and the proxy
%% best-response choice.
-module(chappe_sip_route_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---- boot checks ----

cookie_refused_test() ->
    ?assert(chappe_sip_app:insecure_cookie('CHANGE_ME_SET_NODE_COOKIE')),
    ?assert(chappe_sip_app:insecure_cookie(chappe_sip)),
    ?assertNot(chappe_sip_app:insecure_cookie(nocookie)),
    ?assertNot(chappe_sip_app:insecure_cookie('a-real-secret-cookie')).

flow_secret_check_test() ->
    ?assertEqual(ok, chappe_sip_flow:check_secret(undefined)),
    ?assertEqual(ok, chappe_sip_flow:check_secret(<<"0123456789abcdef">>)),
    ?assertEqual(ok, chappe_sip_flow:check_secret("0123456789abcdef")),
    ?assertEqual({error, {flow_token_secret, too_short}},
                 chappe_sip_flow:check_secret(<<"short">>)),
    ?assertEqual({error, {flow_token_secret, too_short}},
                 chappe_sip_flow:check_secret("short")),
    ?assertEqual({error, {flow_token_secret, too_short}},
                 chappe_sip_flow:check_secret(42)).

short_secret_stops_boot_test() ->
    application:set_env(chappe_sip, flow_token_secret, <<"tooshort">>),
    try
        ?assertEqual({error, {flow_token_secret, too_short}},
                     chappe_sip_flow:ensure_secret())
    after
        application:unset_env(chappe_sip, flow_token_secret)
    end.

%% ---- Record-Route ----

marker_round_trip_test() ->
    RR = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>, {7, 9},
                                       <<"c1">>),
    ?assert(chappe_sip_route:is_self(RR, undefined, <<"c1">>)),
    ?assertNot(chappe_sip_route:is_self(RR, undefined, <<"other">>)),
    %% the flows are under the MAC
    Forged = binary:replace(RR, <<"ftokd=9">>, <<"ftokd=8">>),
    ?assertNot(chappe_sip_route:is_self(Forged, undefined, <<"c1">>)).

sips_contact_gives_sips_route_test() ->
    RR = chappe_sip_route:record_route(<<"sips:10.0.0.1:5061">>, undefined,
                                       <<"c2">>),
    ?assertMatch(<<"<sips:10.0.0.1:5061;lr;", _/binary>>, RR).

comma_joined_route_popped_test() ->
    RR = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>, undefined,
                                       <<"c3">>),
    Raw = <<"BYE sip:b@10.0.0.3 SIP/2.0\r\n"
            "Via: SIP/2.0/UDP 10.0.0.9;branch=z9hG4bKx\r\n"
            "Route: ", RR/binary, ", <sip:10.0.0.2;lr>\r\n"
            "From: <sip:a@x>;tag=1\r\nTo: <sip:b@x>;tag=2\r\n"
            "Call-ID: c3\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>,
    {ok, M} = chappe_sip_msg:parse(Raw),
    {Next, _Flows, M1} = chappe_sip_route:pop_self(M),
    ?assertEqual(<<"sip:10.0.0.2;lr">>, Next),
    ?assertEqual([<<"<sip:10.0.0.2;lr>">>], chappe_sip_route:routes(M1)).

next_flow_test() ->
    ?assertEqual({ws, 9}, chappe_sip_route:next_flow(7, {7, 9})),
    ?assertEqual({ws, 7}, chappe_sip_route:next_flow(9, {7, 9})),
    ?assertEqual(next_hop, chappe_sip_route:next_flow(7, {7, undefined})),
    ?assertEqual({ws, 7}, chappe_sip_route:next_flow(undefined, {7, undefined})),
    ?assertEqual({ws, 9}, chappe_sip_route:next_flow(undefined, {undefined, 9})),
    ?assertEqual(next_hop,
                 chappe_sip_route:next_flow(undefined, {undefined, undefined})).

%% A connection or a UDP address rides in a Record-Route as a token, under
%% the MAC, and comes back as the flow it names.
conn_and_udp_tokens_round_trip_test() ->
    Flows = [{conn, 12}, {udp, <<"192.0.2.7">>, 5070},
             {udp, <<"2001:db8::1">>, 5060, <<"10.0.0.1">>}],
    lists:foreach(
      fun(F) ->
          RR = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>,
                                             {undefined, F}, <<"c9">>),
          ?assert(chappe_sip_route:is_self(RR, undefined, <<"c9">>)),
          {ok, M} = chappe_sip_msg:parse(bye(RR, <<"c9">>)),
          ?assertMatch({_, {undefined, F}, _}, chappe_sip_route:pop_self(M))
      end, Flows).

%% A connection or WS id names something only within one boot: after a
%% restart the same id may be another device's connection, so a
%% Record-Route naming one stops being ours. A UDP address stays valid.
conn_token_bound_to_boot_test() ->
    Boot = chappe_sip_flow:boot(),
    Conn = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>,
                                         {undefined, {conn, 5}}, <<"c10">>),
    Ws = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>, {7, 9},
                                       <<"c10">>),
    Udp = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>,
                                        {undefined, {udp, <<"192.0.2.7">>, 5070}},
                                        <<"c10">>),
    ?assert(chappe_sip_route:is_self(Conn, undefined, <<"c10">>)),
    persistent_term:put({chappe_sip_flow, boot_id}, <<"another-boot">>),
    try
        ?assertNot(chappe_sip_route:is_self(Conn, undefined, <<"c10">>)),
        ?assertNot(chappe_sip_route:is_self(Ws, undefined, <<"c10">>)),
        ?assert(chappe_sip_route:is_self(Udp, undefined, <<"c10">>))
    after
        persistent_term:put({chappe_sip_flow, boot_id}, Boot)
    end.

%% A marker from before expiries carries no node or boot: one naming a WS
%% flow is refused (the id may be another node's, or from before a
%% restart), one naming no flow is still ours within the window.
legacy_marker_with_a_flow_refused_test() ->
    WithFlow = chappe_sip_route:legacy_marker(<<"10.0.0.1">>, 5060, 7, <<"c11">>),
    NoFlow = chappe_sip_route:legacy_marker(<<"10.0.0.1">>, 5060, undefined, <<"c11">>),
    ?assertNot(chappe_sip_route:is_self(WithFlow, undefined, <<"c11">>)),
    ?assert(chappe_sip_route:is_self(NoFlow, undefined, <<"c11">>)).

%% A request from the registered UA over its own flow goes on by its next
%% hop; one from anywhere else goes to that flow.
next_flow_by_connection_test() ->
    Udp = {udp, <<"192.0.2.7">>, 5070},
    ?assertEqual(next_hop, chappe_sip_route:next_flow(
                             {udp, <<"192.0.2.7">>, 5070, <<"10.0.0.1">>},
                             {undefined, Udp})),
    ?assertEqual(Udp, chappe_sip_route:next_flow({udp, <<"10.0.0.9">>, 5060},
                                                 {undefined, Udp})),
    ?assertEqual({conn, 3}, chappe_sip_route:next_flow({conn, 4},
                                                       {undefined, {conn, 3}})),
    ?assertEqual(next_hop, chappe_sip_route:next_flow({conn, 3},
                                                      {undefined, {conn, 3}})).

%% An edge route is ours for any Call-ID, names its flow, and stops being
%% ours once forged or expired.
%% req: R5626-R-13
edge_route_test() ->
    Exp = erlang:system_time(second) + 60,
    R = chappe_sip_flow:edge_route(<<"sip:10.0.0.1:5060">>, {conn, 5},
                                    <<"tcp">>, Exp),
    ?assert(chappe_sip_route:is_self(R, undefined, <<"any">>)),
    {ok, M} = chappe_sip_msg:parse(bye(R, <<"x">>)),
    ?assertEqual({ok, {conn, 5}, <<"tcp">>}, chappe_sip_flow:edge_flow(M)),
    Forged = binary:replace(R, <<"ftokd=c5">>, <<"ftokd=c6">>),
    ?assertNot(chappe_sip_route:is_self(Forged, undefined, <<"any">>)),
    Old = chappe_sip_flow:edge_route(<<"sip:10.0.0.1:5060">>, {conn, 5},
                                      <<"tcp">>, Exp - 120),
    ?assertNot(chappe_sip_route:is_self(Old, undefined, <<"any">>)),
    %% no Record-Route stands for an edge route
    RR = chappe_sip_route:record_route(<<"sip:10.0.0.1:5060">>,
                                       {undefined, {conn, 5}}, <<"x">>),
    {ok, M2} = chappe_sip_msg:parse(bye(RR, <<"x">>)),
    ?assertEqual(none, chappe_sip_flow:edge_flow(M2)).

bye(Route, CallId) ->
    <<"BYE sip:b@10.0.0.3 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 10.0.0.9;branch=z9hG4bKx\r\n"
      "Route: ", Route/binary, "\r\n"
      "From: <sip:a@x>;tag=1\r\nTo: <sip:b@x>;tag=2\r\n"
      "Call-ID: ", CallId/binary, "\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% ---- best response (RFC 3261 16.7 step 6) ----

best_6xx_wins_test() ->
    ?assertMatch({603, _},
                 chappe_sip_proxy_rules:best_response([{486, resp(486)},
                                                 {603, resp(603)},
                                                 {302, resp(302)}])).

best_lowest_class_test() ->
    ?assertMatch({404, _},
                 chappe_sip_proxy_rules:best_response([{500, resp(500)},
                                                 {404, resp(404)}])).

best_retry_4xx_preferred_test() ->
    ?assertMatch({401, _},
                 chappe_sip_proxy_rules:best_response([{404, resp(404)},
                                                 {401, resp(401)}])).

best_503_is_500_test() ->
    ?assertEqual({500, undefined},
                 chappe_sip_proxy_rules:best_response([{503, resp(503)}])).

best_timeout_is_408_test() ->
    ?assertEqual({408, undefined},
                 chappe_sip_proxy_rules:best_response([{408, undefined},
                                                 {500, resp(500)}])).

resp(Status) ->
    S = integer_to_binary(Status),
    <<"SIP/2.0 ", S/binary, " X\r\n"
      "Via: SIP/2.0/UDP 10.0.0.1;branch=z9hG4bKa\r\n"
      "From: <sip:a@x>;tag=1\r\nTo: <sip:b@x>;tag=2\r\n"
      "Call-ID: c\r\nCSeq: 1 INVITE\r\nContent-Length: 0\r\n\r\n">>.
