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
    ?assertEqual(ok, chappe_sip_route:check_secret(undefined)),
    ?assertEqual(ok, chappe_sip_route:check_secret(<<"0123456789abcdef">>)),
    ?assertEqual(ok, chappe_sip_route:check_secret("0123456789abcdef")),
    ?assertEqual({error, {flow_token_secret, too_short}},
                 chappe_sip_route:check_secret(<<"short">>)),
    ?assertEqual({error, {flow_token_secret, too_short}},
                 chappe_sip_route:check_secret("short")),
    ?assertEqual({error, {flow_token_secret, too_short}},
                 chappe_sip_route:check_secret(42)).

short_secret_stops_boot_test() ->
    application:set_env(chappe_sip, flow_token_secret, <<"tooshort">>),
    try
        ?assertEqual({error, {flow_token_secret, too_short}},
                     chappe_sip_route:ensure_secret())
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
