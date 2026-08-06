%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_rtpengine_ng_tests).

-include_lib("eunit/include/eunit.hrl").

command_key_mapping_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{
        call_id => <<"abc">>,
        from_tag => <<"ft">>,
        sdp => <<"v=0">>,
        ice => remove,
        transport_protocol => <<"RTP/AVP">>,
        flags => [trust_address, 'SIP-source-address'],
        delete_delay => 30
    }),
    ?assertEqual(<<"offer">>, maps:get(<<"command">>, Dict)),
    ?assertEqual(<<"abc">>, maps:get(<<"call-id">>, Dict)),
    ?assertEqual(<<"ft">>, maps:get(<<"from-tag">>, Dict)),
    ?assertEqual(<<"v=0">>, maps:get(<<"sdp">>, Dict)),
    ?assertEqual(<<"remove">>, maps:get(<<"ICE">>, Dict)),
    ?assertEqual(<<"RTP/AVP">>, maps:get(<<"transport-protocol">>, Dict)),
    ?assertEqual(
        [<<"trust-address">>, <<"SIP-source-address">>],
        maps:get(<<"flags">>, Dict)
    ),
    ?assertEqual(30, maps:get(<<"delete-delay">>, Dict)).

irregular_casing_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{
        dtls => off,
        sdes => [no_srtp],
        osrtp => accept,
        record_call => yes
    }),
    ?assertEqual(<<"off">>, maps:get(<<"DTLS">>, Dict)),
    ?assertEqual([<<"no-srtp">>], maps:get(<<"SDES">>, Dict)),
    ?assertEqual(<<"accept">>, maps:get(<<"OSRTP">>, Dict)),
    ?assertEqual(<<"yes">>, maps:get(<<"record call">>, Dict)).

binary_key_passthrough_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{<<"generic key">> => <<"value">>}),
    ?assertEqual(<<"value">>, maps:get(<<"generic key">>, Dict)).

nested_map_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{codec => #{mask => [all]}}),
    ?assertEqual(#{<<"mask">> => [<<"all">>]}, maps:get(<<"codec">>, Dict)).

command_name_test() ->
    Name = fun(Cmd) -> maps:get(<<"command">>, chappe_rtpengine_ng:command(Cmd, #{})) end,
    ?assertEqual(<<"ping">>, Name(ping)),
    ?assertEqual(<<"query">>, Name(query)),
    ?assertEqual(<<"start recording">>, Name(start_recording)),
    ?assertEqual(<<"block DTMF">>, Name(block_dtmf)),
    ?assertEqual(<<"subscribe request">>, Name(subscribe_request)),
    ?assertEqual(<<"play media">>, Name(play_media)).

media_control_wire_test() ->
    Dict = chappe_rtpengine_ng:command(silence_media, #{
        call_id => <<"c">>,
        from_tag => <<"ft">>,
        flags => [directional]
    }),
    ?assertEqual(<<"silence media">>, maps:get(<<"command">>, Dict)),
    ?assertEqual(<<"ft">>, maps:get(<<"from-tag">>, Dict)),
    ?assertEqual([<<"directional">>], maps:get(<<"flags">>, Dict)),
    BlockAll = chappe_rtpengine_ng:command(block_media, #{
        call_id => <<"c">>, flags => [all]
    }),
    ?assertEqual(<<"block media">>, maps:get(<<"command">>, BlockAll)),
    ?assertEqual([<<"all">>], maps:get(<<"flags">>, BlockAll)),
    ?assertEqual(
        <<"unblock media">>,
        maps:get(<<"command">>, chappe_rtpengine_ng:command(unblock_media, #{}))
    ),
    ?assertEqual(
        <<"unsilence media">>,
        maps:get(<<"command">>, chappe_rtpengine_ng:command(unsilence_media, #{}))
    ).

play_media_wire_test() ->
    Blob = <<1, 2, 3, 255, 0, 32>>,
    Dict = chappe_rtpengine_ng:command(play_media, #{
        call_id => <<"c">>,
        from_tag => <<"ft">>,
        blob => Blob,
        repeat_times => 2
    }),
    ?assertEqual(<<"play media">>, maps:get(<<"command">>, Dict)),
    ?assertEqual(Blob, maps:get(<<"blob">>, Dict)),
    ?assertEqual(2, maps:get(<<"repeat-times">>, Dict)),
    Dict2 = chappe_rtpengine_ng:command(play_media, #{
        blob64 => base64:encode(Blob),
        db_id => 7
    }),
    ?assertEqual(base64:encode(Blob), maps:get(<<"blob64">>, Dict2)),
    ?assertEqual(7, maps:get(<<"db-id">>, Dict2)),
    %% raw binary blobs survive the full bencode roundtrip
    Encoded = chappe_rtpengine_bencode:encode_to_binary(Dict),
    {ok, Decoded} = chappe_rtpengine_bencode:decode(Encoded),
    ?assertEqual(Blob, maps:get(<<"blob">>, Decoded)).

subscribe_request_wire_test() ->
    Dict = chappe_rtpengine_ng:command(subscribe_request, #{
        call_id => <<"c">>,
        from_tags => [<<"ft">>],
        codec => #{mask => [all], transcode => ['PCMU']},
        ptime => 20
    }),
    ?assertEqual(<<"subscribe request">>, maps:get(<<"command">>, Dict)),
    ?assertEqual([<<"ft">>], maps:get(<<"from-tags">>, Dict)),
    ?assertEqual(
        #{<<"mask">> => [<<"all">>], <<"transcode">> => [<<"PCMU">>]},
        maps:get(<<"codec">>, Dict)
    ),
    ?assertEqual(20, maps:get(<<"ptime">>, Dict)).

decode_play_media_reply_test() ->
    Reply = #{<<"result">> => <<"ok">>, <<"duration">> => 1520},
    {ok, Decoded} = chappe_rtpengine_ng:decode_reply(Reply),
    ?assertEqual(1520, maps:get(<<"duration">>, Decoded)).

decode_subscribe_reply_test() ->
    Reply = #{
        <<"result">> => <<"ok">>,
        <<"sdp">> => <<"v=0\r\n">>,
        <<"to-tag">> => <<"sub-1">>,
        <<"from-tags">> => [<<"ft">>]
    },
    {ok, Decoded} = chappe_rtpengine_ng:decode_reply(Reply),
    ?assertEqual(<<"sub-1">>, maps:get(<<"to-tag">>, Decoded)),
    ?assertEqual(<<"v=0\r\n">>, chappe_rtpengine_ng:sdp(Decoded)).

decode_reply_ok_test() ->
    Reply = #{<<"result">> => <<"ok">>, <<"sdp">> => <<"v=0">>},
    ?assertEqual({ok, Reply}, chappe_rtpengine_ng:decode_reply(Reply)),
    ?assertEqual(<<"v=0">>, chappe_rtpengine_ng:sdp(Reply)).

decode_reply_pong_test() ->
    Reply = #{<<"result">> => <<"pong">>},
    ?assertEqual({ok, Reply}, chappe_rtpengine_ng:decode_reply(Reply)),
    ?assertEqual(undefined, chappe_rtpengine_ng:sdp(Reply)).

decode_reply_error_test() ->
    Reply = #{
        <<"result">> => <<"error">>,
        <<"error-reason">> => <<"Unknown call-id">>
    },
    ?assertEqual(
        {error, <<"Unknown call-id">>, Reply},
        chappe_rtpengine_ng:decode_reply(Reply)
    ).

decode_reply_error_without_reason_test() ->
    Reply = #{<<"result">> => <<"error">>},
    ?assertEqual({error, <<"unknown">>, Reply}, chappe_rtpengine_ng:decode_reply(Reply)).

decode_reply_missing_result_test() ->
    ?assertMatch(
        {error, {unexpected_result, undefined}, _},
        chappe_rtpengine_ng:decode_reply(#{<<"sdp">> => <<"v=0">>})
    ).
