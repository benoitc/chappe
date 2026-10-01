%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% message/sipfrag (RFC 3420) as the refer event package uses it (RFC 3515
%% 2.4.5).
-module(chappe_sip_sipfrag_tests).
-include_lib("eunit/include/eunit.hrl").

build_test() ->
    ?assertEqual(<<"SIP/2.0 100 Trying\r\n">>, chappe_sip_sipfrag:build(100)),
    ?assertEqual(<<"SIP/2.0 503 Service Unavailable\r\n">>,
                 chappe_sip_sipfrag:build(503)),
    ?assertEqual(<<"SIP/2.0 486 Busy Here\r\n">>,
                 chappe_sip_sipfrag:build(486, <<"Busy Here">>)),
    ?assertEqual(<<"SIP/2.0 299 Unknown\r\n">>, chappe_sip_sipfrag:build(299)),
    ?assertEqual(
       <<"SIP/2.0 603 Declined\r\nWarning: 399 h \"x\"\r\n">>,
       chappe_sip_sipfrag:build(603, <<"Declined">>,
                                [{<<"Warning">>, <<"399 h \"x\"">>}])).

parse_status_test() ->
    ?assertEqual({ok, #{status => 200, reason => <<"OK">>, headers => [],
                        body => <<>>}},
                 chappe_sip_sipfrag:parse(<<"SIP/2.0 200 OK\r\n">>)),
    %% no trailing CRLF, a multi-word reason
    ?assertMatch({ok, #{status := 503, reason := <<"Service Unavailable">>}},
                 chappe_sip_sipfrag:parse(<<"SIP/2.0 503 Service Unavailable">>)),
    %% headers and a body after the blank line (RFC 3420 2)
    ?assertEqual(
       {ok, #{status => 180, reason => <<"Ringing">>,
              headers => [{<<"Warning">>, <<"x">>}, {<<"To">>, <<"<sip:a@h>">>}],
              body => <<"v=0\r\n">>}},
       chappe_sip_sipfrag:parse(
         <<"SIP/2.0 180 Ringing\r\nWarning: x\r\nTo: <sip:a@h>\r\n\r\n"
           "v=0\r\n">>)),
    %% an empty reason phrase is legal
    ?assertMatch({ok, #{status := 200, reason := <<>>}},
                 chappe_sip_sipfrag:parse(<<"SIP/2.0 200 \r\n">>)).

parse_other_frags_test() ->
    %% a request-line fragment, and a headers-only fragment (RFC 3420 2)
    ?assertMatch({ok, #{method := <<"INVITE">>, uri := <<"sip:a@h">>}},
                 chappe_sip_sipfrag:parse(<<"INVITE sip:a@h SIP/2.0\r\n">>)),
    ?assertEqual({ok, #{headers => [{<<"From">>, <<"<sip:a@h>">>}],
                        body => <<>>}},
                 chappe_sip_sipfrag:parse(<<"From: <sip:a@h>\r\n">>)).

parse_bad_test() ->
    ?assertEqual({error, malformed},
                 chappe_sip_sipfrag:parse(<<"SIP/2.0 2x OK">>)),
    ?assertEqual({error, malformed},
                 chappe_sip_sipfrag:parse(<<"SIP/2.0 99 X">>)),
    ?assertEqual({error, malformed}, chappe_sip_sipfrag:parse(<<"garbage">>)),
    ?assertEqual({error, malformed}, chappe_sip_sipfrag:parse(<<>>)),
    ?assertEqual({error, malformed}, chappe_sip_sipfrag:parse(nope)).

round_trip_test() ->
    F = chappe_sip_sipfrag:build(487, <<"Request Terminated">>),
    ?assertMatch({ok, #{status := 487, reason := <<"Request Terminated">>}},
                 chappe_sip_sipfrag:parse(F)).

content_type_test() ->
    ?assertEqual(<<"message/sipfrag;version=2.0">>,
                 chappe_sip_sipfrag:content_type()).
