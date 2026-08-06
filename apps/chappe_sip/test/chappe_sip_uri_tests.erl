%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

-module(chappe_sip_uri_tests).
-include_lib("eunit/include/eunit.hrl").

basic_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"sip:alice@atlanta.com">>),
    ?assertMatch(#{scheme := sip, user := <<"alice">>,
                   host := <<"atlanta.com">>}, U),
    ?assertEqual(<<"sip:alice@atlanta.com">>, chappe_sip_uri:format(U)).

full_test() ->
    In = <<"sips:bob:pw@biloxi.com:5061;transport=tls;lr?Subject=Hi">>,
    {ok, U} = chappe_sip_uri:parse(In),
    ?assertMatch(#{scheme := sips, user := <<"bob">>, password := <<"pw">>,
                   host := <<"biloxi.com">>, port := 5061,
                   headers := <<"Subject=Hi">>}, U),
    #{params := P} = U,
    ?assertEqual(<<"tls">>, maps:get(<<"transport">>, P)),
    ?assertEqual(true, maps:get(<<"lr">>, P)),
    ?assertEqual(In, chappe_sip_uri:format(U)).

no_user_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"sip:192.0.2.4:5060">>),
    ?assertMatch(#{host := <<"192.0.2.4">>, port := 5060}, U),
    ?assertEqual(error, maps:find(user, U)),
    ?assertEqual(<<"sip:192.0.2.4:5060">>, chappe_sip_uri:format(U)).

ipv6_test() ->
    In = <<"sip:carol@[2001:db8::10]:5070;transport=tcp">>,
    {ok, U} = chappe_sip_uri:parse(In),
    ?assertMatch(#{host := <<"[2001:db8::10]">>, port := 5070}, U),
    ?assertEqual(In, chappe_sip_uri:format(U)).

%% a bracketed IPv6 host with no userpart (a distinct parse path from the
%% user@[v6] form above): the ':' inside the brackets is not the port sep
ipv6_no_user_test() ->
    In = <<"sips:[2001:db8::1]:5061;transport=tls">>,
    {ok, U} = chappe_sip_uri:parse(In),
    ?assertMatch(#{scheme := sips, host := <<"[2001:db8::1]">>, port := 5061}, U),
    ?assertEqual(error, maps:find(user, U)),
    ?assertEqual(In, chappe_sip_uri:format(U)).

tel_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"tel:+15551234;phone-context=example.com">>),
    ?assertMatch(#{scheme := tel, user := <<"+15551234">>}, U),
    ?assertEqual(<<"tel:+15551234;phone-context=example.com">>,
                 chappe_sip_uri:format(U)).

angle_tolerance_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"<sip:a@b>">>),
    ?assertMatch(#{user := <<"a">>, host := <<"b">>}, U).

errors_test() ->
    ?assertEqual({error, bad_scheme}, chappe_sip_uri:parse(<<"http://x">>)),
    ?assertMatch({error, _}, chappe_sip_uri:parse(<<"sip:a@b:70000">>)),
    ?assertMatch({error, _}, chappe_sip_uri:parse(<<"sip:a@b:notaport">>)).
