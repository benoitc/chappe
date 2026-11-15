%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_esl_cidr_tests).

-include_lib("eunit/include/eunit.hrl").

parse_test() ->
    ?assertEqual({ok, {{10, 0, 0, 0}, 8}}, chappe_esl_cidr:parse(<<"10.0.0.0/8">>)),
    ?assertEqual({ok, {{10, 0, 0, 1}, 32}}, chappe_esl_cidr:parse("10.0.0.1")),
    ?assertEqual(
        {ok, {{16#2001, 16#db8, 0, 0, 0, 0, 0, 0}, 32}},
        chappe_esl_cidr:parse(<<"2001:db8::/32">>)
    ),
    ?assertEqual(error, chappe_esl_cidr:parse(<<"10.0.0.0/33">>)),
    ?assertEqual(error, chappe_esl_cidr:parse(<<"10.0.0.0/-1">>)),
    ?assertEqual(error, chappe_esl_cidr:parse(<<"10.0.0.0/8x">>)),
    ?assertEqual(error, chappe_esl_cidr:parse(<<"host/8">>)),
    ?assertEqual(error, chappe_esl_cidr:parse({10, 0, 0, 0})),
    ?assertEqual(error, chappe_esl_cidr:parse([1000])).

parse_list_test() ->
    ?assertMatch({ok, [_, _]}, chappe_esl_cidr:parse_list(["10.0.0.0/8", <<"::1">>])),
    ?assertEqual({ok, []}, chappe_esl_cidr:parse_list([])),
    ?assertEqual(error, chappe_esl_cidr:parse_list([<<"10.0.0.0/8">>, bad])),
    ?assertEqual(error, chappe_esl_cidr:parse_list(<<"10.0.0.0/8">>)).

member_test() ->
    {ok, Nets} = chappe_esl_cidr:parse_list([<<"172.16.0.0/12">>, <<"fd00::/8">>]),
    ?assert(chappe_esl_cidr:member({172, 20, 1, 2}, Nets)),
    ?assertNot(chappe_esl_cidr:member({172, 32, 0, 1}, Nets)),
    ?assert(chappe_esl_cidr:member({16#fd12, 0, 0, 0, 0, 0, 0, 1}, Nets)),
    ?assertNot(chappe_esl_cidr:member({0, 0, 0, 0, 0, 0, 0, 1}, Nets)),
    %% an IPv4 peer on an IPv6 socket
    ?assert(chappe_esl_cidr:member({0, 0, 0, 0, 0, 16#ffff, 16#ac14, 16#0102}, Nets)),
    ?assertNot(chappe_esl_cidr:member({10, 0, 0, 1}, [])),
    {ok, Any} = chappe_esl_cidr:parse_list([<<"0.0.0.0/0">>]),
    ?assert(chappe_esl_cidr:member({8, 8, 8, 8}, Any)).
