%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% SIPREC metadata (RFC 7865) and the multipart body that carries it (RFC
%% 7866 9.1), on the RFC's own examples.
-module(chappe_sip_siprec_meta_tests).

-include_lib("eunit/include/eunit.hrl").
-include("chappe_sip_siprec_examples.hrl").

-define(M, chappe_sip_siprec_meta).

%% the complete snapshot of RFC 7865 8.1, extensions skipped
rfc_complete_example_test() ->
    {ok, Doc} = ?M:parse(?EX81),
    ?assertEqual(complete, maps:get(datamode, Doc)),
    ?assertMatch(
        [#{id := <<"7+OTCyoxTmqmqyA/1weDAg==">>,
           associate_time := <<"2010-12-16T23:41:07Z">>}],
        maps:get(groups, Doc)
    ),
    [S] = maps:get(sessions, Doc),
    ?assertMatch(
        #{id := <<"hVpd7YQgRW2nD22h7q60JQ==">>,
          group_ref := <<"7+OTCyoxTmqmqyA/1weDAg==">>,
          sip_session_ids := [<<"ab30317f1a784dc48ff824d0d3715d86;", _/binary>>]},
        S
    ),
    ?assertNot(maps:is_key(call_ref, S)),
    ?assertMatch(
        [#{id := <<"srfBElmCRp2QB23b7Mpk0w==">>,
           names := [#{aor := <<"sip:bob@biloxi.com">>, name := <<"Bob">>,
                       lang := <<"it">>}]},
         #{id := <<"zSfPoSvdSDCmU3A3TRDxAw==">>,
           names := [#{aor := <<"sip:Paul@biloxi.com">>, name := <<"Paul">>}]}],
        maps:get(participants, Doc)
    ),
    ?assertEqual(
        [<<"96">>, <<"97">>, <<"98">>, <<"99">>],
        [L || #{label := L} <- maps:get(streams, Doc)]
    ),
    ?assertMatch([#{session_id := <<"hVpd7YQgRW2nD22h7q60JQ==">>}],
                 maps:get(session_assocs, Doc)),
    ?assertEqual(2, length(maps:get(participant_session_assocs, Doc))),
    [Bob, _Paul] = maps:get(participant_stream_assocs, Doc),
    ?assertEqual(
        [<<"i1Pz3to5hGk8fuXl+PbwCw==">>, <<"UAAMm5GRQKSCMVvLyl4rFw==">>],
        maps:get(send, Bob)
    ),
    ?assertEqual(2, length(maps:get(recv, Bob))).

%% who sends each stream, as a recording server maps a label to a party
senders_test() ->
    {ok, Doc} = ?M:parse(?EX81),
    BySender = [
        {L, [A || #{names := [#{aor := A}]} <- Ps]}
     || #{label := L, participants := Ps} <- ?M:senders(Doc)
    ],
    ?assertEqual(
        [{<<"96">>, [<<"sip:bob@biloxi.com">>]},
         {<<"97">>, [<<"sip:bob@biloxi.com">>]},
         {<<"98">>, [<<"sip:Paul@biloxi.com">>]},
         {<<"99">>, [<<"sip:Paul@biloxi.com">>]}],
        BySender
    ).

%% the partial update of RFC 7865 8.2
rfc_partial_example_test() ->
    {ok, Doc} = ?M:parse(?EX82),
    ?assertEqual(partial, maps:get(datamode, Doc)),
    ?assertMatch(
        [#{participant_id := <<"srfBElmCRp2QB23b7Mpk0w==">>,
           disassociate_time := <<"2010-12-16T23:41:07Z">>}],
        maps:get(participant_session_assocs, Doc)
    ).

%% the snapshot request of RFC 7865 7 and RFC 7866 9.2
rfc_snapshot_request_test() ->
    ?assertEqual({ok, {snapshot_request, <<"SRS internal error">>}},
                 ?M:parse(?EX7)),
    ?assertEqual({ok, {snapshot_request, <<"lost state">>}},
                 ?M:parse(?M:snapshot_request(<<"lost state">>))),
    ?assertEqual({ok, {snapshot_request, undefined}},
                 ?M:parse(?M:snapshot_request(undefined))).

%% what build/1 writes, parse/1 reads back, the call_ref extension too
round_trip_test() ->
    T = <<"2026-11-14T10:00:00Z">>,
    Doc = #{
        datamode => complete,
        groups => [],
        sessions => [#{id => <<"s1">>, call_ref => <<"abc123">>,
                       sip_session_ids => [], reasons => [],
                       start_time => T}],
        participants => [
            #{id => <<"p1">>,
              names => [#{aor => <<"sip:alice@example.com">>,
                          name => <<"Al & \"Co\" <x>">>}]},
            #{id => <<"p2">>, names => [#{aor => <<"sip:bob@example.com">>}]}
        ],
        streams => [#{id => <<"st1">>, session_id => <<"s1">>, label => <<"1">>},
                    #{id => <<"st2">>, session_id => <<"s1">>, label => <<"2">>}],
        session_assocs => [#{session_id => <<"s1">>, associate_time => T}],
        participant_session_assocs => [
            #{participant_id => <<"p1">>, session_id => <<"s1">>, params => [],
              associate_time => T},
            #{participant_id => <<"p2">>, session_id => <<"s1">>,
              params => [{<<"role">>, <<"callee">>}], associate_time => T}
        ],
        participant_stream_assocs => [
            #{participant_id => <<"p1">>, send => [<<"st1">>], recv => [<<"st2">>]},
            #{participant_id => <<"p2">>, send => [<<"st2">>], recv => [<<"st1">>],
              disassociate_time => <<"2026-11-14T10:05:00Z">>}
        ]
    },
    Xml = ?M:build(Doc),
    ?assertMatch(<<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>", _/binary>>, Xml),
    ?assertEqual({ok, Doc}, ?M:parse(Xml)),
    %% a stream whose sender left is no longer anybody's
    ?assertMatch([#{label := <<"1">>, participants := [#{id := <<"p1">>}]},
                  #{label := <<"2">>, participants := []}],
                 ?M:senders(Doc)).

%% RFC 7865 6.10: base64 of a version 4 UUID, fresh each time
new_id_test() ->
    Id = ?M:new_id(),
    <<_:48, V:4, _:12, Var:2, _:62>> = base64:decode(Id),
    ?assertEqual(4, V),
    ?assertEqual(2, Var),
    ?assertNotEqual(Id, ?M:new_id()).

%% RFC 7865 6.9: RFC 3339, capital T and Z
now_test() ->
    ?assertMatch({match, _},
                 re:run(?M:now(), "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$")).

%% RFC 9806 2: the media type gained +xml; the older name is still read
content_type_test() ->
    ?assertEqual(<<"application/rs-metadata+xml">>, ?M:content_type()),
    ?assert(?M:is_content_type(<<"application/rs-metadata+xml">>)),
    ?assert(?M:is_content_type(<<"Application/RS-Metadata">>)),
    ?assertNot(?M:is_content_type(<<"application/sdp">>)).

%% a hostile document: a DTD, another namespace, a missing id, too big,
%% element names that would become atoms
refused_test() ->
    ?assertEqual({error, doctype}, ?M:parse(
        <<"<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY a \"aaaa\">]><r/>">>)),
    ?assertEqual({error, not_recording_metadata},
                 ?M:parse(<<"<recording xmlns='urn:other'/>">>)),
    ?assertEqual({error, {missing, <<"participant_id">>}},
                 ?M:parse(<<"<recording xmlns='urn:ietf:params:xml:ns:recording:1'>"
                            "<participant/></recording>">>)),
    ?assertEqual({error, too_large}, ?M:parse(binary:copy(<<" ">>, 70000))),
    ?assertMatch({error, _}, ?M:parse(<<"<recording">>)),
    Before = erlang:system_info(atom_count),
    Odd = iolist_to_binary([
        <<"<recording xmlns='urn:ietf:params:xml:ns:recording:1'>">>,
        [[<<"<e_siprec_meta_">>, integer_to_binary(I), <<"/>">>]
         || I <- lists:seq(1, 200)],
        <<"</recording>">>
    ]),
    {ok, _} = ?M:parse(Odd),
    ?assert(erlang:system_info(atom_count) - Before < 50).

%% ---- multipart/mixed (RFC 2046 5.1), the SDP and metadata of RFC 7866 9.1 ----

multipart_round_trip_test() ->
    Sdp = <<"v=0\r\no=- 1 1 IN IP4 192.0.2.1\r\ns=-\r\nt=0 0\r\n"
            "m=audio 4000 RTP/AVP 0\r\na=sendonly\r\na=label:1\r\n">>,
    Xml = ?M:build(#{participants => [#{id => <<"p">>, names => []}]}),
    {CT, Body} = chappe_sip_multipart:build([
        #{content_type => <<"application/sdp">>, body => Sdp},
        #{content_type => ?M:content_type(), disposition => ?M:disposition(),
          body => Xml}
    ]),
    ?assertMatch(<<"multipart/mixed;boundary=", _/binary>>, CT),
    {ok, [P1, P2]} = chappe_sip_multipart:parse(CT, Body),
    ?assertEqual(#{content_type => <<"application/sdp">>, body => Sdp}, P1),
    ?assertEqual(<<"recording-session">>, maps:get(disposition, P2)),
    ?assertEqual(Xml, maps:get(body, P2)),
    ?assertEqual({ok, P1},
                 chappe_sip_multipart:find(<<"application/sdp">>, [P1, P2])),
    ?assertEqual(error, chappe_sip_multipart:find(<<"text/plain">>, [P1, P2])).

%% Figure 12 of RFC 7866: the body as the RFC writes it, then with a
%% quoted boundary and a preamble
multipart_rfc7866_figure_test() ->
    Body = <<"--foobar\r\nContent-Type: application/sdp\r\n\r\nv=0\r\n\r\n"
             "--foobar\r\nContent-Type: application/rs-metadata\r\n"
             "Content-Disposition: recording-session\r\n\r\n"
             "[metadata content]\r\n--foobar--\r\n">>,
    {ok, [S, M]} = chappe_sip_multipart:parse(
                     <<"multipart/mixed;boundary=foobar">>, Body),
    ?assertEqual(<<"v=0\r\n">>, maps:get(body, S)),
    ?assert(?M:is_content_type(maps:get(content_type, M))),
    ?assertEqual(<<"[metadata content]">>, maps:get(body, M)),
    {ok, [_, _]} = chappe_sip_multipart:parse(
        <<"multipart/mixed; boundary=\"foobar\"">>,
        <<"preamble\r\n", Body/binary>>).

multipart_refused_test() ->
    ?assertEqual({error, no_boundary},
                 chappe_sip_multipart:parse(<<"multipart/mixed">>, <<"x">>)),
    ?assertEqual({error, no_close_delimiter},
                 chappe_sip_multipart:parse(<<"multipart/mixed;boundary=b">>,
                                            <<"--b\r\nContent-Type: a/b\r\n\r\nx">>)),
    Many = iolist_to_binary([[<<"--b\r\n\r\nx\r\n">>] || _ <- lists:seq(1, 40)]
                            ++ [<<"--b--">>]),
    ?assertEqual({error, too_many_parts},
                 chappe_sip_multipart:parse(<<"multipart/mixed;boundary=b">>, Many)),
    ?assertEqual({ok, [#{content_type => <<"application/sdp">>, body => <<"v=0">>}]},
                 chappe_sip_multipart:parse(<<"Application/SDP">>, <<"v=0">>)).
