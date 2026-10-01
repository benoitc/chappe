%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_rtpengine_sdp_tests).

-include_lib("eunit/include/eunit.hrl").

%% A subscription offer as rtpengine writes it for a three-stream
%% recording call: one m-line per recorded party, each labelled.
offer() ->
    <<
        "v=0\r\n"
        "o=- 1 1 IN IP4 198.51.100.1\r\n"
        "s=siprec\r\n"
        "c=IN IP4 203.0.113.9\r\n"
        "t=0 0\r\n"
        "m=audio 30010 RTP/AVP 0\r\n"
        "a=label:1\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=sendonly\r\n"
        "a=rtcp:30011\r\n"
        "m=audio 30018 RTP/AVP 0\r\n"
        "a=label:2\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=sendonly\r\n"
        "a=rtcp:30019\r\n"
        "m=audio 30000 RTP/AVP 0\r\n"
        "a=label:3\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=sendonly\r\n"
        "a=rtcp:30001\r\n"
    >>.

streams_test() ->
    ?assertEqual(
        [
            #{
                index => 0,
                type => <<"audio">>,
                port => 30010,
                label => <<"1">>,
                labels => [<<"1">>]
            },
            #{
                index => 1,
                type => <<"audio">>,
                port => 30018,
                label => <<"2">>,
                labels => [<<"2">>]
            },
            #{
                index => 2,
                type => <<"audio">>,
                port => 30000,
                label => <<"3">>,
                labels => [<<"3">>]
            }
        ],
        chappe_rtpengine_sdp:streams(offer())
    ).

%% The siprec flag adds a second, zero-based label; either matches.
siprec_double_label_test() ->
    Sdp = <<
        "v=0\r\n"
        "m=audio 30054 RTP/AVP 0\r\n"
        "a=label:1\r\n"
        "a=label:0\r\n"
    >>,
    [#{label := Label, labels := Labels}] = chappe_rtpengine_sdp:streams(Sdp),
    ?assertEqual(<<"1">>, Label),
    ?assertEqual([<<"1">>, <<"0">>], Labels),
    {ok, ByFirst} = chappe_rtpengine_sdp:fork_answer(
        Sdp, {label, <<"1">>}, dest(5000)
    ),
    {ok, BySecond} = chappe_rtpengine_sdp:fork_answer(
        Sdp, {label, <<"0">>}, dest(5000)
    ),
    ?assertEqual(ByFirst, BySecond).

no_media_test() ->
    ?assertEqual([], chappe_rtpengine_sdp:streams(<<"v=0\r\nt=0 0\r\n">>)).

%% The answer keeps every m-line of the offer, in order: the selected
%% one at the receiver's port, the others rejected with port 0.
fork_answer_selects_one_stream_test() ->
    {ok, Answer} = chappe_rtpengine_sdp:fork_answer(
        offer(), {label, <<"2">>}, dest(40002)
    ),
    ?assertEqual(
        [
            #{
                index => 0,
                type => <<"audio">>,
                port => 0,
                label => undefined,
                labels => []
            },
            #{
                index => 1,
                type => <<"audio">>,
                port => 40002,
                label => undefined,
                labels => []
            },
            #{
                index => 2,
                type => <<"audio">>,
                port => 0,
                label => undefined,
                labels => []
            }
        ],
        chappe_rtpengine_sdp:streams(Answer)
    ),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"c=IN IP4 192.0.2.7\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"a=rtpmap:0 PCMU/8000">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"a=ptime:20">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"a=recvonly">>)),
    %% the offerer's direction, labels and rtcp stay with the offerer
    ?assertEqual(nomatch, binary:match(Answer, <<"a=sendonly">>)),
    ?assertEqual(nomatch, binary:match(Answer, <<"a=label:">>)),
    ?assertEqual(nomatch, binary:match(Answer, <<"a=rtcp:">>)).

fork_answer_by_index_test() ->
    {ok, ByIndex} = chappe_rtpengine_sdp:fork_answer(
        offer(), {index, 1}, dest(40002)
    ),
    {ok, ByLabel} = chappe_rtpengine_sdp:fork_answer(
        offer(), {label, <<"2">>}, dest(40002)
    ),
    ?assertEqual(ByLabel, ByIndex).

%% One subscription can also feed several receivers at once: each
%% selected stream gets its own media-level address.
fork_answer_many_destinations_test() ->
    {ok, Answer} = chappe_rtpengine_sdp:fork_answer(offer(), [
        {{label, <<"1">>}, #{address => <<"192.0.2.1">>, port => 41000}},
        {{label, <<"3">>}, #{address => <<"192.0.2.3">>, port => 41002}}
    ]),
    ?assertEqual(
        [41000, 0, 41002],
        [P || #{port := P} <- chappe_rtpengine_sdp:streams(Answer)]
    ),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"c=IN IP4 192.0.2.1\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"c=IN IP4 192.0.2.3\r\n">>)).

fork_answer_unknown_stream_test() ->
    ?assertEqual(
        {error, {no_such_stream, {label, <<"9">>}}},
        chappe_rtpengine_sdp:fork_answer(offer(), {label, <<"9">>}, dest(1))
    ),
    ?assertEqual(
        {error, {no_such_stream, {index, 3}}},
        chappe_rtpengine_sdp:fork_answer(offer(), {index, 3}, dest(1))
    ).

fork_answer_rejects_empty_and_duplicate_test() ->
    ?assertEqual(
        {error, no_streams_selected},
        chappe_rtpengine_sdp:fork_answer(offer(), [])
    ),
    ?assertEqual(
        {error, {duplicate_stream, {index, 0}}},
        chappe_rtpengine_sdp:fork_answer(offer(), [
            {{label, <<"1">>}, dest(41000)},
            {{index, 0}, dest(41002)}
        ])
    ).

%% Bare newlines and a port count on the m-line are both legal SDP.
lenient_parsing_test() ->
    Sdp = <<"v=0\nm=audio 30010/2 RTP/AVP 0 8\na=label:x\n">>,
    ?assertEqual(
        [
            #{
                index => 0,
                type => <<"audio">>,
                port => 30010,
                label => <<"x">>,
                labels => [<<"x">>]
            }
        ],
        chappe_rtpengine_sdp:streams(Sdp)
    ).

dest(Port) ->
    #{address => <<"192.0.2.7">>, port => Port, ptime => 20}.

%% An IPv6 receiver gets IN IP6 in o= and c=, per stream as well.
fork_answer_ipv6_test() ->
    {ok, Answer} = chappe_rtpengine_sdp:fork_answer(offer(), [
        {{label, <<"1">>}, #{address => <<"2001:db8::7">>, port => 41000}},
        {{label, <<"3">>}, #{address => <<"192.0.2.3">>, port => 41002}}
    ]),
    ?assertNotEqual(
        nomatch, binary:match(Answer, <<"o=- 1 1 IN IP6 2001:db8::7\r\n">>)
    ),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"c=IN IP6 2001:db8::7\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Answer, <<"c=IN IP4 192.0.2.3\r\n">>)),
    ?assertEqual(nomatch, binary:match(Answer, <<"IN IP4 2001">>)).

%% An m-line the offerer already rejected (port 0) cannot carry a fork.
fork_answer_rejected_stream_test() ->
    Offer = <<
        "v=0\r\n"
        "c=IN IP4 203.0.113.9\r\n"
        "m=audio 30010 RTP/AVP 0\r\n"
        "a=label:1\r\n"
        "m=audio 0 RTP/AVP 0\r\n"
        "a=label:2\r\n"
    >>,
    ?assertEqual(
        {error, {rejected_stream, {label, <<"2">>}}},
        chappe_rtpengine_sdp:fork_answer(Offer, {label, <<"2">>}, dest(1))
    ),
    ?assertMatch(
        {ok, _}, chappe_rtpengine_sdp:fork_answer(Offer, {index, 0}, dest(1))
    ).

fork_answer_bad_selector_test() ->
    ?assertEqual(
        {error, {bad_selector, {port, 30010}}},
        chappe_rtpengine_sdp:fork_answer(offer(), {port, 30010}, dest(1))
    ),
    ?assertEqual(
        {error, {bad_selector, nope}},
        chappe_rtpengine_sdp:fork_answer(offer(), [{nope, dest(1)}])
    ).
