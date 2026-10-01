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

%% ---- RFC 3891 Replaces ----

replaces_basic_test() ->
    ?assertEqual(
       {ok, #{call_id => <<"98732@sip.example.com">>, to_tag => <<"r33th4x0r">>,
              from_tag => <<"ff87ff">>, early_only => false}},
       chappe_sip_hdr:replaces(
         <<"98732@sip.example.com;to-tag=r33th4x0r;from-tag=ff87ff">>)),
    %% param order does not matter
    ?assertEqual(
       {ok, #{call_id => <<"c">>, to_tag => <<"t">>, from_tag => <<"f">>,
              early_only => false}},
       chappe_sip_hdr:replaces(<<"c;from-tag=f;to-tag=t">>)).

%% param names are case-insensitive, whitespace around ; and = is LWS, the
%% early-only flag is reported, unknown generic params are ignored, and the
%% call-id and tags keep their case (they compare case-sensitively)
replaces_lenient_test() ->
    ?assertEqual(
       {ok, #{call_id => <<"AbC@Host">>, to_tag => <<"TT">>,
              from_tag => <<"Ff">>, early_only => true}},
       chappe_sip_hdr:replaces(
         <<"  AbC@Host ; To-Tag = TT ;FROM-TAG=Ff; early-only ;x=y ">>)),
    ?assertMatch({ok, #{early_only := false}},
                 chappe_sip_hdr:replaces(<<"a;to-tag=1;from-tag=2;foo">>)).

replaces_missing_params_test() ->
    M = {error, malformed},
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"abc@h">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"abc@h;to-tag=1">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"abc@h;from-tag=1">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"abc@h;to-tag=;from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"abc@h;to-tag;from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<";to-tag=1;from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<>>)).

replaces_garbage_test() ->
    M = {error, malformed},
    %% whitespace inside the call-id, two @, a duplicated tag, a valued flag,
    %% bytes outside token, and non-binary input
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"a b;to-tag=1;from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"a@b@c;to-tag=1;from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(
                      <<"a;to-tag=1;to-tag=3;from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(
                      <<"a;to-tag=1;from-tag=2;early-only=yes">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"a;to-tag=\"1\";from-tag=2">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<"a;to-tag=1;from-tag=2\r\nX: y">>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(<<0, 1, 2, 255>>)),
    ?assertEqual(M, chappe_sip_hdr:replaces(undefined)),
    ?assertEqual(M, chappe_sip_hdr:replaces("a;to-tag=1;from-tag=2")).

%% oversized input is refused, not scanned forever and never a crash
replaces_huge_test() ->
    Big = binary:copy(<<"a">>, 1 bsl 20),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:replaces(<<Big/binary, ";to-tag=1;from-tag=2">>)),
    Semis = binary:copy(<<";">>, 1 bsl 20),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:replaces(<<"a", Semis/binary>>)).

%% random bytes never throw
replaces_total_test() ->
    rand:seed(exsss, {1, 2, 3}),
    lists:foreach(
      fun(_) ->
              B = rand:bytes(rand:uniform(64)),
              R = chappe_sip_hdr:replaces(B),
              ?assert(R =:= {error, malformed} orelse element(1, R) =:= ok)
      end, lists:seq(1, 2000)).

replaces_build_test() ->
    V = #{call_id => <<"c@h">>, to_tag => <<"t">>, from_tag => <<"f">>},
    ?assertEqual(<<"c@h;to-tag=t;from-tag=f">>,
                 chappe_sip_hdr:replaces_value(V)),
    ?assertEqual(<<"c@h;to-tag=t;from-tag=f;early-only">>,
                 chappe_sip_hdr:replaces_value(V#{early_only => true})),
    ?assertEqual(<<"c@h;to-tag=t;from-tag=f">>,
                 chappe_sip_hdr:replaces_value(V#{early_only => false})),
    %% round trip
    ?assertEqual({ok, V#{early_only => true}},
                 chappe_sip_hdr:replaces(
                   chappe_sip_hdr:replaces_value(V#{early_only => true}))).

unescape_test() ->
    ?assertEqual({ok, <<"a;b@c">>}, chappe_sip_hdr:unescape(<<"a%3Bb%40c">>)),
    ?assertEqual({ok, <<"a;b">>}, chappe_sip_hdr:unescape(<<"a%3bb">>)),
    ?assertEqual({ok, <<"plain">>}, chappe_sip_hdr:unescape(<<"plain">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:unescape(<<"a%3">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:unescape(<<"a%zz">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:unescape(<<"%">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:unescape(42)).

escape_test() ->
    ?assertEqual(<<"c%40h%3Bto-tag%3Dt%3Bfrom-tag%3Df">>,
                 chappe_sip_hdr:escape(<<"c@h;to-tag=t;from-tag=f">>)),
    Raw = <<"x y&z%?:/[]+$-_.!~*'()">>,
    ?assertEqual({ok, Raw}, chappe_sip_hdr:unescape(chappe_sip_hdr:escape(Raw))).

%% RFC 3891 section 6.1 / RFC 5589: a REFER target carries Replaces as an
%% escaped URI header
refer_to_replaces_test() ->
    RT = <<"<sip:dave@denver.example.org?Replaces=12345%40192.168.118.3%3B"
           "to-tag%3D12345%3Bfrom-tag%3D5FFE-3994>">>,
    ?assertEqual(
       {ok, #{call_id => <<"12345@192.168.118.3">>, to_tag => <<"12345">>,
              from_tag => <<"5FFE-3994">>, early_only => false}},
       chappe_sip_hdr:refer_to_replaces(RT)),
    %% header name is case-insensitive, other URI headers are skipped
    ?assertMatch(
       {ok, #{call_id := <<"a">>, early_only := true}},
       chappe_sip_hdr:refer_to_replaces(
         <<"\"D\" <sip:d@h;transport=udp?Subject=x&replaces=a%3Bto-tag%3D1"
           "%3Bfrom-tag%3D2%3Bearly-only>;method=INVITE">>)),
    ?assertEqual({error, no_replaces},
                 chappe_sip_hdr:refer_to_replaces(<<"<sip:d@h>">>)),
    ?assertEqual({error, no_replaces},
                 chappe_sip_hdr:refer_to_replaces(<<"<sip:d@h?Subject=x>">>)),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:refer_to_replaces(<<"<sip:d@h?Replaces=a%3>">>)),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:refer_to_replaces(
                   <<"<sip:d@h?Replaces=a%3Bto-tag%3D1>">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:refer_to_replaces(<<"<">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:refer_to_replaces(nope)).

%% building a Refer-To target and reading it back agrees
refer_to_round_trip_test() ->
    V = #{call_id => <<"c@h">>, to_tag => <<"t">>, from_tag => <<"f">>,
          early_only => false},
    RT = <<"<sip:x@h?Replaces=",
           (chappe_sip_hdr:escape(chappe_sip_hdr:replaces_value(V)))/binary, ">">>,
    ?assertEqual({ok, V}, chappe_sip_hdr:refer_to_replaces(RT)).

%% ---- REFER headers ----

%% RFC 3892 2: Referred-By is a name-addr or addr-spec with an optional
%% cid param (a quoted msg-id naming the signed token body)
referred_by_test() ->
    ?assertEqual(
       {ok, #{uri => <<"sip:referrer@atlanta.example.com">>,
              display => <<"Alice">>,
              cid => <<"20398823.2UWQFN309shb3@referrer.atlanta.example.com">>,
              params => #{}}},
       chappe_sip_hdr:referred_by(
         <<"Alice <sip:referrer@atlanta.example.com>;cid=\"20398823.2UWQFN309"
           "shb3@referrer.atlanta.example.com\"">>)),
    ?assertEqual(
       {ok, #{uri => <<"sip:a@h">>, params => #{<<"x">> => <<"1">>}}},
       chappe_sip_hdr:referred_by(<<"sip:a@h;x=1">>)),
    %% cid must be a quoted id-left "@" id-right
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:referred_by(<<"<sip:a@h>;cid=\"nope\"">>)),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:referred_by(<<"<sip:a@h>;cid=a@b">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:referred_by(<<"<">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:referred_by(42)).

referred_by_value_test() ->
    V = chappe_sip_hdr:referred_by_value(
          #{uri => <<"sip:a@h">>, display => <<"Alice">>, cid => <<"1@h">>}),
    ?assertEqual(<<"\"Alice\" <sip:a@h>;cid=\"1@h\"">>, V),
    ?assertMatch({ok, #{uri := <<"sip:a@h">>, cid := <<"1@h">>}},
                 chappe_sip_hdr:referred_by(V)),
    ?assertEqual(<<"<sip:a@h>">>,
                 chappe_sip_hdr:referred_by_value(#{uri => <<"sip:a@h">>})).

%% RFC 4538 7: callid with local-tag and remote-tag, both required (4: a
%% value missing either is ignored)
target_dialog_test() ->
    ?assertEqual(
       {ok, #{call_id => <<"fa77as7dad8-sd98ajzz@host.example.com">>,
              local_tag => <<"kkaz-">>, remote_tag => <<"6544">>}},
       chappe_sip_hdr:target_dialog(
         <<"fa77as7dad8-sd98ajzz@host.example.com ;local-tag=kkaz- "
           ";remote-tag=6544">>)),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:target_dialog(<<"c@h;local-tag=a">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:target_dialog(<<";x">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:target_dialog(nope)),
    TD = #{call_id => <<"c@h">>, local_tag => <<"l">>, remote_tag => <<"r">>},
    ?assertEqual(<<"c@h;local-tag=l;remote-tag=r">>,
                 chappe_sip_hdr:target_dialog_value(TD)),
    ?assertEqual({ok, TD},
                 chappe_sip_hdr:target_dialog(
                   chappe_sip_hdr:target_dialog_value(TD))).

%% RFC 6665 8.2.1: the event type and its id param identify a subscription
event_test() ->
    ?assertEqual({ok, #{type => <<"refer">>, id => undefined}},
                 chappe_sip_hdr:event(<<"refer">>)),
    ?assertEqual({ok, #{type => <<"refer">>, id => <<"93809824">>}},
                 chappe_sip_hdr:event(<<"refer ; ID=93809824;x=y">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:event(<<>>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:event(undefined)).

%% Refer-To (RFC 3515 2.1): the target URI, its method param (RFC 3261
%% 19.1.1) and its escaped headers, among them a Replaces (RFC 3891 6.1)
%% or a nested Refer-To (RFC 4579 5.7)
refer_to_test() ->
    {ok, RT} = chappe_sip_hdr:refer_to(
                 <<"<sip:dave@denver.example.org?Replaces=12345%40192.168.118.3"
                   "%3Bto-tag%3D12345%3Bfrom-tag%3D5FFE-3994>">>),
    ?assertMatch(
       #{scheme := <<"sip">>, method := <<"INVITE">>,
         target := <<"sip:dave@denver.example.org">>,
         replaces := #{call_id := <<"12345@192.168.118.3">>,
                       to_tag := <<"12345">>, from_tag := <<"5FFE-3994">>}},
       RT),
    ?assertEqual([{<<"Replaces">>,
                   <<"12345@192.168.118.3;to-tag=12345;from-tag=5FFE-3994">>}],
                 maps:get(headers, RT)),
    {ok, Bye} = chappe_sip_hdr:refer_to(
                  <<"<sip:carol@chicago.example.com;method=BYE>">>),
    ?assertMatch(#{method := <<"BYE">>, replaces := undefined,
                   target := <<"sip:carol@chicago.example.com">>,
                   headers := []}, Bye),
    {ok, Ref} = chappe_sip_hdr:refer_to(
                  <<"<sip:bob@biloxi.example.com;method=REFER"
                    "?Refer-To=sip:3402934234%40example.com>">>),
    ?assertMatch(#{method := <<"REFER">>,
                   target := <<"sip:bob@biloxi.example.com">>,
                   headers := [{<<"Refer-To">>,
                                <<"sip:3402934234@example.com">>}]}, Ref),
    ?assertMatch({ok, #{scheme := <<"tel">>, target := <<"tel:+15551234">>}},
                 chappe_sip_hdr:refer_to(<<"<tel:+15551234>">>)),
    ?assertMatch({ok, #{scheme := <<"http">>}},
                 chappe_sip_hdr:refer_to(<<"<http://example.com/x>">>)),
    ?assertMatch({ok, #{display := <<"Carol">>, uri := <<"sip:c@h">>}},
                 chappe_sip_hdr:refer_to(<<"\"Carol\" <sip:c@h>">>)),
    ?assertEqual({error, malformed},
                 chappe_sip_hdr:refer_to(<<"<sip:d@h?Replaces=a%3>">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:refer_to(<<"<">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:refer_to(<<"nouri">>)),
    ?assertEqual({error, malformed}, chappe_sip_hdr:refer_to(1)).

refer_to_value_test() ->
    R = #{call_id => <<"c@h">>, to_tag => <<"t">>, from_tag => <<"f">>,
          early_only => false},
    V = chappe_sip_hdr:refer_to_value(#{uri => <<"sip:x@h">>, replaces => R}),
    ?assertEqual(<<"<sip:x@h?Replaces=c%40h%3Bto-tag%3Dt%3Bfrom-tag%3Df>">>, V),
    ?assertMatch({ok, #{replaces := R}}, chappe_sip_hdr:refer_to(V)),
    V2 = chappe_sip_hdr:refer_to_value(
           #{uri => <<"sip:bob@h">>, method => <<"REFER">>,
             headers => [{<<"Refer-To">>, <<"sip:conf@h">>}]}),
    ?assertEqual(<<"<sip:bob@h;method=REFER?Refer-To=sip:conf%40h>">>, V2),
    ?assertMatch({ok, #{method := <<"REFER">>,
                        headers := [{<<"Refer-To">>, <<"sip:conf@h">>}]}},
                 chappe_sip_hdr:refer_to(V2)),
    ?assertEqual(<<"\"C\" <sip:c@h;method=BYE>">>,
                 chappe_sip_hdr:refer_to_value(
                   #{uri => <<"sip:c@h">>, method => <<"BYE">>,
                     display => <<"C">>})).
