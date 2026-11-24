%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

-module(chappe_sip_uri_tests).
-include_lib("eunit/include/eunit.hrl").

basic_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"sip:alice@atlanta.com">>),
    ?assertMatch(
        #{
            scheme := sip,
            user := <<"alice">>,
            host := <<"atlanta.com">>
        },
        U
    ),
    ?assertEqual(<<"sip:alice@atlanta.com">>, chappe_sip_uri:format(U)).

full_test() ->
    In = <<"sips:bob:pw@biloxi.com:5061;transport=tls;lr?Subject=Hi">>,
    {ok, U} = chappe_sip_uri:parse(In),
    ?assertMatch(
        #{
            scheme := sips,
            user := <<"bob">>,
            password := <<"pw">>,
            host := <<"biloxi.com">>,
            port := 5061,
            headers := <<"Subject=Hi">>
        },
        U
    ),
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
    ?assertMatch(
        #{scheme := sips, host := <<"[2001:db8::1]">>, port := 5061}, U
    ),
    ?assertEqual(error, maps:find(user, U)),
    ?assertEqual(In, chappe_sip_uri:format(U)).

tel_test() ->
    {ok, U} = chappe_sip_uri:parse(
        <<"tel:+15551234;phone-context=example.com">>
    ),
    ?assertMatch(#{scheme := tel, user := <<"+15551234">>}, U),
    ?assertEqual(
        <<"tel:+15551234;phone-context=example.com">>,
        chappe_sip_uri:format(U)
    ).

angle_tolerance_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"<sip:a@b>">>),
    ?assertMatch(#{user := <<"a">>, host := <<"b">>}, U).

errors_test() ->
    ?assertEqual({error, bad_scheme}, chappe_sip_uri:parse(<<"http://x">>)),
    ?assertMatch({error, _}, chappe_sip_uri:parse(<<"sip:a@b:70000">>)),
    ?assertMatch({error, _}, chappe_sip_uri:parse(<<"sip:a@b:notaport">>)).

%% credentials follow a redirect only within one scheme, host and port
same_authority_test() ->
    S = fun chappe_sip_uri:same_authority/2,
    ?assert(
        S(<<"sip:a@Host.example:5060">>, <<"sip:b@host.example:5060;x=1">>)
    ),
    ?assertNot(S(<<"sip:a@host.example">>, <<"sips:a@host.example">>)),
    ?assertNot(S(<<"sip:a@host.example">>, <<"sip:a@other.example">>)),
    ?assertNot(S(<<"sip:a@host.example">>, <<"sip:a@host.example:5070">>)),
    ?assertNot(S(<<"sip:a@host.example">>, <<"http://host.example">>)),
    ?assertNot(S(<<"garbage">>, <<"garbage">>)).
%% a user part may carry ';' (RFC 3261 19.1.1): the params start after the
%% host (U3)
semicolon_user_test() ->
    {ok, U} = chappe_sip_uri:parse(<<"sip:alice;day=tuesday@example.com">>),
    ?assertMatch(
        #{user := <<"alice;day=tuesday">>, host := <<"example.com">>}, U
    ),
    ?assertEqual(#{}, maps:get(params, U)),
    ?assertEqual(
        <<"sip:alice;day=tuesday@example.com">>, chappe_sip_uri:format(U)
    ),
    %% RFC 4475 3.1.1.10 (semiuri)
    {ok, S} = chappe_sip_uri:parse(
        <<"sip:user;par=u%40example.net@example.com">>
    ),
    ?assertMatch(
        #{
            user := <<"user;par=u%40example.net">>,
            host := <<"example.com">>
        },
        S
    ),
    %% params after the host still are params
    {ok, P} = chappe_sip_uri:parse(
        <<"sip:alice;x=1@example.com:5070;transport=tcp">>
    ),
    ?assertMatch(
        #{
            user := <<"alice;x=1">>,
            port := 5070,
            params := #{<<"transport">> := <<"tcp">>}
        },
        P
    ).

%% 19.1 vectors: the scheme is case-insensitive, a telephone-subscriber
%% user, headers with an encoded @
rfc3261_19_1_vectors_test() ->
    {ok, A} = chappe_sip_uri:parse(<<"SIP:ALICE@AtLanTa.CoM;Transport=udp">>),
    ?assertMatch(#{scheme := sip, user := <<"ALICE">>}, A),
    {ok, B} = chappe_sip_uri:parse(
        <<"sip:+1-212-555-1212:1234@gateway.com;user=phone">>
    ),
    ?assertMatch(
        #{
            user := <<"+1-212-555-1212">>,
            password := <<"1234">>,
            host := <<"gateway.com">>,
            params := #{<<"user">> := <<"phone">>}
        },
        B
    ),
    {ok, C} = chappe_sip_uri:parse(
        <<"sip:atlanta.com;method=REGISTER?to=alice%40atlanta.com">>
    ),
    ?assertMatch(
        #{host := <<"atlanta.com">>, headers := <<"to=alice%40atlanta.com">>}, C
    ),
    ?assertEqual(error, maps:find(user, C)),
    {ok, D} = chappe_sip_uri:parse(<<"sips:1212@gateway.com">>),
    ?assertMatch(#{scheme := sips, user := <<"1212">>}, D),
    {ok, E} = chappe_sip_uri:parse(<<"sip:alice@192.0.2.4">>),
    ?assertMatch(#{host := <<"192.0.2.4">>}, E).

%% RFC 3261 19.1.4: the equivalent and the different sets of the section
uri_equal_test() ->
    Same = [
        {<<"sip:%61lice@atlanta.com;transport=TCP">>,
            <<"sip:alice@AtLanTa.CoM;Transport=tcp">>},
        {<<"sip:carol@chicago.com">>, <<"sip:carol@chicago.com;newparam=5">>},
        {<<"sip:carol@chicago.com">>, <<"sip:carol@chicago.com;security=on">>},
        {<<"sip:carol@chicago.com;newparam=5">>,
            <<"sip:carol@chicago.com;security=on">>},
        {<<"sip:biloxi.com;transport=tcp;method=REGISTER?to=sip:bob%40biloxi.com">>,
            <<"sip:biloxi.com;method=REGISTER;transport=tcp?to=sip:bob%40biloxi.com">>},
        {<<"sip:alice@atlanta.com?subject=project%20x&priority=urgent">>,
            <<"sip:alice@atlanta.com?priority=urgent&subject=project%20x">>}
    ],
    Different = [
        {<<"SIP:ALICE@AtLanTa.CoM;Transport=udp">>,
            <<"sip:alice@AtLanTa.CoM;Transport=UDP">>},
        {<<"sip:bob@biloxi.com">>, <<"sip:bob@biloxi.com:5060">>},
        {<<"sip:bob@biloxi.com">>, <<"sip:bob@biloxi.com;transport=udp">>},
        {<<"sip:bob@biloxi.com">>, <<"sip:bob@biloxi.com:6000;transport=tcp">>},
        {<<"sip:carol@chicago.com">>,
            <<"sip:carol@chicago.com?Subject=next%20meeting">>},
        {<<"sip:bob@phone21.boxesbybob.com">>, <<"sip:bob@192.0.2.4">>},
        {<<"sip:carol@chicago.com;security=on">>,
            <<"sip:carol@chicago.com;security=off">>},
        {<<"sip:alice@atlanta.com">>, <<"sips:alice@atlanta.com">>},
        {<<"sip:alice@atlanta.com">>,
            <<"sip:alice@atlanta.com;maddr=1.2.3.4">>},
        {<<"sip:alice@atlanta.com">>, <<"sip:alice@atlanta.com;user=ip">>}
    ],
    [?assert(chappe_sip_uri:equal(A, B)) || {A, B} <- Same],
    [?assert(chappe_sip_uri:equal(B, A)) || {A, B} <- Same],
    [?assertNot(chappe_sip_uri:equal(A, B)) || {A, B} <- Different],
    [?assertNot(chappe_sip_uri:equal(B, A)) || {A, B} <- Different],
    %% the strict form also refuses a parameter only one side carries
    [?assertNot(chappe_sip_uri:equal_strict(A, B)) || {A, B} <- Different],
    ?assert(
        chappe_sip_uri:equal_strict(
            <<"sip:%61lice@atlanta.com;transport=TCP">>,
            <<"sip:alice@AtLanTa.CoM;Transport=tcp">>
        )
    ),
    ?assert(
        chappe_sip_uri:equal_strict(
            <<"sip:biloxi.com;transport=tcp;method=REGISTER?to=sip:bob%40biloxi.com">>,
            <<"sip:biloxi.com;method=REGISTER;transport=tcp?to=sip:bob%40biloxi.com">>
        )
    ),
    ?assertNot(
        chappe_sip_uri:equal_strict(
            <<"sip:carol@chicago.com">>,
            <<"sip:carol@chicago.com;newparam=5">>
        )
    ),
    ?assertNot(
        chappe_sip_uri:equal_strict(
            <<"sip:carol@chicago.com;lr">>, <<"sip:carol@chicago.com">>
        )
    ).

%% the registrar's canonical AOR (RFC 3261 10.3 step 5)
aor_test() ->
    ?assertEqual(
        {ok, <<"sip:alice@example.com">>},
        chappe_sip_uri:aor(<<"sip:%61lice@EXAMPLE.com;user=phone?x=y">>)
    ),
    ?assertEqual(
        {ok, <<"sip:alice@example.com:5070">>},
        chappe_sip_uri:aor(<<"SIP:alice@Example.COM:5070;transport=tcp">>)
    ),
    ?assertEqual(
        {ok, <<"sips:example.com">>}, chappe_sip_uri:aor(<<"sips:EXAMPLE.com">>)
    ),
    ?assertEqual(error, chappe_sip_uri:aor(<<"mailto:a@b">>)).

%% the scheme is case-insensitive (RFC 3261 19.1.4)
is_sips_test() ->
    ?assert(chappe_sip_uri:is_sips(<<"sips:alice@example.com">>)),
    ?assert(chappe_sip_uri:is_sips(<<"SIPS:alice@example.com">>)),
    ?assert(chappe_sip_uri:is_sips(<<"SiPs:alice@example.com">>)),
    ?assertNot(chappe_sip_uri:is_sips(<<"sip:alice@example.com">>)),
    ?assertNot(chappe_sip_uri:is_sips(<<"<sips:alice@example.com>">>)),
    ?assertNot(chappe_sip_uri:is_sips(<<"sips">>)),
    ?assertNot(chappe_sip_uri:is_sips(<<>>)).
