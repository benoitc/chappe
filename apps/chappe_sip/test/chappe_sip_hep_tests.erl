%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% HEPv3 encoding and decoding, and the hep option.
-module(chappe_sip_hep_tests).

-include_lib("eunit/include/eunit.hrl").

pkt() ->
    #{
        proto => tcp,
        src => {{10, 0, 0, 1}, 5060},
        dst => {{10, 0, 0, 2}, 40000},
        time => {1700000000, 123456},
        capture_id => 2001,
        payload => <<"OPTIONS sip:a@b SIP/2.0\r\n\r\n">>,
        correlation_id => <<"abc@host">>
    }.

%% The bytes of a HEPv3 packet, written out chunk by chunk from the HEP
%% specification (vendor 0, type, length including the 6 header bytes).
by_hand() ->
    Payload = <<"OPTIONS sip:a@b SIP/2.0\r\n\r\n">>,
    Chunks = <<
        0:16, 1:16, 7:16, 2:8,
        0:16, 2:16, 7:16, 6:8,
        0:16, 3:16, 10:16, 10, 0, 0, 1,
        0:16, 4:16, 10:16, 10, 0, 0, 2,
        0:16, 7:16, 8:16, 5060:16,
        0:16, 8:16, 8:16, 40000:16,
        0:16, 9:16, 10:16, 1700000000:32,
        0:16, 10:16, 10:16, 123456:32,
        0:16, 11:16, 7:16, 1:8,
        0:16, 12:16, 10:16, 2001:32,
        0:16, 15:16, (6 + byte_size(Payload)):16, Payload/binary,
        0:16, 17:16, 14:16, "abc@host"
    >>,
    <<"HEP3", (6 + byte_size(Chunks)):16, Chunks/binary>>.

encode_matches_spec_test() ->
    ?assertEqual(by_hand(), chappe_sip_hep:encode(pkt())).

decode_test() ->
    {ok, P} = chappe_sip_hep:decode(by_hand()),
    ?assertEqual(maps:merge(pkt(), #{family => inet, proto_type => 1}), P).

ipv6_round_trip_test() ->
    P = (pkt())#{
        src => {{16#2001, 16#db8, 0, 0, 0, 0, 0, 1}, 5060},
        dst => {{0, 0, 0, 0, 0, 0, 0, 1}, 5061},
        proto => udp
    },
    P1 = maps:remove(correlation_id, P),
    {ok, D} = chappe_sip_hep:decode(chappe_sip_hep:encode(P1)),
    ?assertEqual(P1#{family => inet6, proto_type => 1}, D).

decode_rejects_test() ->
    ?assertEqual({error, not_hep3}, chappe_sip_hep:decode(<<"HEP2", 0:16>>)),
    %% the length must cover the packet exactly
    Bin = by_hand(),
    ?assertEqual({error, not_hep3},
                 chappe_sip_hep:decode(<<Bin/binary, 0>>)),
    %% a chunk running past the end
    <<"HEP3", _:16, Rest/binary>> = Bin,
    Bad = <<0:16, 15:16, 60000:16>>,
    Len = 6 + byte_size(Rest) + byte_size(Bad),
    ?assertEqual({error, bad_chunk},
                 chappe_sip_hep:decode(<<"HEP3", Len:16, Rest/binary, Bad/binary>>)).

validate_test_() ->
    [
        ?_assertEqual(
            {ok, #{host => {127, 0, 0, 1}, port => 9060, version => 3,
                   capture_id => 200}},
            chappe_sip_hep:validate(#{host => "127.0.0.1", port => 9060})
        ),
        ?_assertEqual(
            {ok, #{host => {0, 0, 0, 0, 0, 0, 0, 1}, port => 9060,
                   version => 3, capture_id => 7}},
            chappe_sip_hep:validate(#{host => <<"::1">>, port => 9060,
                                      capture_id => 7})
        ),
        ?_assertMatch({error, {hep, {bad_port, 1023}}},
                      chappe_sip_hep:validate(#{host => "127.0.0.1",
                                                port => 1023})),
        ?_assertMatch({error, {hep, {bad_capture_id, 0}}},
                      chappe_sip_hep:validate(#{host => "127.0.0.1",
                                                port => 9060,
                                                capture_id => 0})),
        ?_assertMatch({error, {hep, {bad_options, _}}},
                      chappe_sip_hep:validate(#{port => 9060}))
    ].

native_url_test_() ->
    [
        ?_assertEqual(
            <<"udp:127.0.0.1:9060;hep=3;capture_id=200">>,
            chappe_sip_hep:native_url(#{host => {127, 0, 0, 1}, port => 9060,
                                        version => 3, capture_id => 200})
        ),
        ?_assertEqual(
            <<"udp:[::1]:9060;hep=3;capture_id=5">>,
            chappe_sip_hep:native_url(#{host => {0, 0, 0, 0, 0, 0, 0, 1},
                                        port => 9060, version => 3,
                                        capture_id => 5})
        )
    ].

%% keepalives are not captured, and capture is a no-op while off
capture_off_test() ->
    ?assertEqual(ok, chappe_sip_hep:capture(out, ws, undefined, <<"\r\n">>)),
    ?assertEqual(ok, chappe_sip_hep:capture(in, ws, undefined, <<"x">>)).
