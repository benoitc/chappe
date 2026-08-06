%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

-module(chappe_sip_hdr_tests).
-include_lib("eunit/include/eunit.hrl").

via_test() ->
    {ok, V} = chappe_sip_hdr:via(<<"SIP/2.0/UDP pc33.atlanta.com:5066;branch=z9hG4bK776;rport">>),
    ?assertMatch(#{proto := <<"UDP">>, host := <<"pc33.atlanta.com">>,
                   port := 5066}, V),
    #{params := P} = V,
    ?assertEqual(<<"z9hG4bK776">>, maps:get(<<"branch">>, P)),
    ?assertEqual(true, maps:get(<<"rport">>, P)).

via_no_port_test() ->
    {ok, V} = chappe_sip_hdr:via(<<"SIP/2.0/TCP 192.0.2.1;branch=z9hG4bK1">>),
    ?assertMatch(#{proto := <<"TCP">>, host := <<"192.0.2.1">>}, V),
    ?assertEqual(error, maps:find(port, V)).

cseq_test() ->
    ?assertEqual({ok, #{seq => 314159, method => <<"INVITE">>}},
                 chappe_sip_hdr:cseq(<<"314159 INVITE">>)),
    ?assertMatch({error, _}, chappe_sip_hdr:cseq(<<"nonsense">>)).

%% RFC 3261 8.1.1.5: 0 =< CSeq < 2^31 (the RFC 4475 scalar torture cases)
cseq_range_test() ->
    ?assertMatch({ok, #{seq := 9}}, chappe_sip_hdr:cseq(<<"9 INVITE">>)),
    ?assertEqual({error, bad_cseq}, chappe_sip_hdr:cseq(<<"-1 INVITE">>)),
    ?assertEqual({error, bad_cseq}, chappe_sip_hdr:cseq(<<"4294967301 INVITE">>)).

%% a Via port must be a valid 1..65535 port
via_port_range_test() ->
    ?assertMatch({ok, #{port := 5060}},
                 chappe_sip_hdr:via(<<"SIP/2.0/UDP h:5060;branch=z9hG4bK1">>)),
    ?assertMatch({error, _}, chappe_sip_hdr:via(<<"SIP/2.0/UDP h:0;branch=z9hG4bK1">>)),
    ?assertMatch({error, _},
                 chappe_sip_hdr:via(<<"SIP/2.0/UDP h:70000;branch=z9hG4bK1">>)).

%% a quoted display name closes at the first UNescaped quote (RFC 4475 wsinv
%% From), and an unterminated quoted string is rejected
name_addr_escaped_quote_test() ->
    {ok, N} = chappe_sip_hdr:name_addr(
                <<"\"J Rosenberg \\\"\" <sip:jdrosen@example.com>;tag=x">>),
    ?assertEqual(<<"J Rosenberg \\\"">>, maps:get(display, N)),
    ?assertEqual(<<"sip:jdrosen@example.com">>, maps:get(uri, N)),
    ?assertEqual(<<"x">>, maps:get(<<"tag">>, maps:get(params, N))),
    ?assertMatch({error, _},
                 chappe_sip_hdr:name_addr(<<"\"unterminated <sip:a@b>">>)).

name_addr_display_test() ->
    {ok, N} = chappe_sip_hdr:name_addr(<<"Bob <sip:bob@biloxi.com>;tag=a6c85cf">>),
    ?assertMatch(#{display := <<"Bob">>, uri := <<"sip:bob@biloxi.com">>}, N),
    #{params := P} = N,
    ?assertEqual(<<"a6c85cf">>, maps:get(<<"tag">>, P)).

name_addr_quoted_test() ->
    {ok, N} = chappe_sip_hdr:name_addr(<<"\"Alice Smith\" <sips:a@b>;tag=t">>),
    ?assertMatch(#{display := <<"Alice Smith">>, uri := <<"sips:a@b">>}, N).

name_addr_bare_test() ->
    %% bare addr-spec: ; params belong to the header, not the uri
    {ok, N} = chappe_sip_hdr:name_addr(<<"sip:carol@chicago.com;tag=abc">>),
    ?assertMatch(#{uri := <<"sip:carol@chicago.com">>}, N),
    #{params := P} = N,
    ?assertEqual(<<"abc">>, maps:get(<<"tag">>, P)).

name_addr_list_test() ->
    {ok, L} = chappe_sip_hdr:name_addr_list(
                <<"<sip:p1.com;lr>, \"B, C\" <sip:p2.com;lr>;q=0.5">>),
    ?assertEqual(2, length(L)),
    [N1, N2] = L,
    ?assertEqual(<<"sip:p1.com;lr">>, maps:get(uri, N1)),
    ?assertEqual(<<"B, C">>, maps:get(display, N2)),
    ?assertEqual(<<"0.5">>, maps:get(<<"q">>, maps:get(params, N2))).

auth_challenge_test() ->
    {ok, A} = chappe_sip_hdr:auth(
                <<"Digest realm=\"atlanta.example.com\", qop=\"auth\", "
                  "nonce=\"f84f1cec41e6cbe5aea9c8e88d359\", "
                  "opaque=\"\", stale=FALSE, algorithm=MD5">>),
    ?assertMatch(#{scheme := <<"Digest">>}, A),
    #{params := P} = A,
    ?assertEqual(<<"atlanta.example.com">>, maps:get(<<"realm">>, P)),
    ?assertEqual(<<"auth">>, maps:get(<<"qop">>, P)),
    ?assertEqual(<<"MD5">>, maps:get(<<"algorithm">>, P)),
    ?assertEqual(<<"FALSE">>, maps:get(<<"stale">>, P)).
