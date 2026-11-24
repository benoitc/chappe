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
        sdes => [unencrypted_srtp],
        osrtp => accept,
        record_call => yes
    }),
    ?assertEqual(<<"off">>, maps:get(<<"DTLS">>, Dict)),
    ?assertEqual([<<"unencrypted_srtp">>], maps:get(<<"SDES">>, Dict)),
    ?assertEqual(<<"accept">>, maps:get(<<"OSRTP">>, Dict)),
    ?assertEqual(<<"yes">>, maps:get(<<"record call">>, Dict)).

%% Keys whose NG names are not the hyphenated atom.
%% req: RNG-10
documented_key_names_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{
        media_address => <<"203.0.113.1">>,
        address_family => 'IP6',
        received_from => [<<"IP4">>, <<"198.51.100.1">>],
        ice_lite => forward,
        tos => 184,
        dtls_fingerprint => 'SHA-256',
        dtls_reverse => passive,
        t38 => [decode]
    }),
    ?assertEqual(<<"203.0.113.1">>, maps:get(<<"media address">>, Dict)),
    ?assertEqual(<<"IP6">>, maps:get(<<"address family">>, Dict)),
    ?assertEqual(
        [<<"IP4">>, <<"198.51.100.1">>], maps:get(<<"received from">>, Dict)
    ),
    ?assertEqual(<<"forward">>, maps:get(<<"ICE-lite">>, Dict)),
    ?assertEqual(184, maps:get(<<"TOS">>, Dict)),
    ?assertEqual(<<"SHA-256">>, maps:get(<<"DTLS-fingerprint">>, Dict)),
    ?assertEqual(<<"passive">>, maps:get(<<"DTLS-reverse">>, Dict)),
    ?assertEqual([<<"decode">>], maps:get(<<"T.38">>, Dict)).

%% Option words (flags, replace, ICE, ...) are hyphenated; every other
%% atom value goes out verbatim, so SDES suite names and codec names
%% keep their underscores.
%% req: RNG-10
atom_value_rule_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{
        flags => [trust_address, strict_source],
        replace => [session_connection, origin],
        ice => force_relay,
        sdes => [no_AES_CM_128_HMAC_SHA1_32, 'only-AES_CM_128_HMAC_SHA1_80'],
        codec => #{transcode => [opus], mask => ['G722_1']},
        direction => [pub_net, priv_net]
    }),
    ?assertEqual(
        [<<"trust-address">>, <<"strict-source">>], maps:get(<<"flags">>, Dict)
    ),
    ?assertEqual(
        [<<"session-connection">>, <<"origin">>], maps:get(<<"replace">>, Dict)
    ),
    ?assertEqual(<<"force-relay">>, maps:get(<<"ICE">>, Dict)),
    ?assertEqual(
        [<<"no_AES_CM_128_HMAC_SHA1_32">>, <<"only-AES_CM_128_HMAC_SHA1_80">>],
        maps:get(<<"SDES">>, Dict)
    ),
    ?assertEqual(
        #{<<"transcode">> => [<<"opus">>], <<"mask">> => [<<"G722_1">>]},
        maps:get(<<"codec">>, Dict)
    ),
    ?assertEqual(
        [<<"pub_net">>, <<"priv_net">>], maps:get(<<"direction">>, Dict)
    ).

%% Bencode has no floats or tuples: a clear error, not a function_clause.
bad_value_rejected_test() ->
    ?assertError(
        {bad_param, ptime, 20.0},
        chappe_rtpengine_ng:command(offer, #{ptime => 20.0})
    ),
    ?assertError(
        {bad_param, address, {1, 2, 3, 4}},
        chappe_rtpengine_ng:command(offer, #{address => {1, 2, 3, 4}})
    ),
    ?assertError(
        {bad_param, codec, 1.5},
        chappe_rtpengine_ng:command(offer, #{codec => #{mask => [1.5]}})
    ).

%% rtpengine sheds load with result "load limit".
%% req: RNG-07
decode_reply_load_limit_test() ->
    Reply = #{<<"result">> => <<"load limit">>, <<"message">> => <<"busy">>},
    ?assertEqual(
        {error, load_limit, Reply}, chappe_rtpengine_ng:decode_reply(Reply)
    ).

%% A warning rides on a successful reply and stays in the map.
%% req: RNG-07
decode_reply_keeps_warning_test() ->
    Reply = #{<<"result">> => <<"ok">>, <<"warning">> => <<"codec dropped">>},
    ?assertEqual({ok, Reply}, chappe_rtpengine_ng:decode_reply(Reply)).

binary_key_passthrough_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{
        <<"generic key">> => <<"value">>
    }),
    ?assertEqual(<<"value">>, maps:get(<<"generic key">>, Dict)).

nested_map_test() ->
    Dict = chappe_rtpengine_ng:command(offer, #{codec => #{mask => [all]}}),
    ?assertEqual(#{<<"mask">> => [<<"all">>]}, maps:get(<<"codec">>, Dict)).

command_name_test() ->
    Name = fun(Cmd) ->
        maps:get(<<"command">>, chappe_rtpengine_ng:command(Cmd, #{}))
    end,
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
        maps:get(
            <<"command">>, chappe_rtpengine_ng:command(unsilence_media, #{})
        )
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
    ?assertEqual(
        {error, <<"unknown">>, Reply}, chappe_rtpengine_ng:decode_reply(Reply)
    ).

decode_reply_missing_result_test() ->
    ?assertMatch(
        {error, {unexpected_result, undefined}, _},
        chappe_rtpengine_ng:decode_reply(#{<<"sdp">> => <<"v=0">>})
    ).
