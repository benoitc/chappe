%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_rtp_tests).

-include_lib("eunit/include/eunit.hrl").

pkt() ->
    #{
        pt => 0,
        seq => 65535,
        ts => 16#FFFFFF60,
        ssrc => 16#DEADBEEF,
        marker => true,
        csrcs => [],
        payload => <<1, 2, 3, 4>>
    }.

roundtrip_test() ->
    P = pkt(),
    {ok, Q} = chappe_mix_rtp:parse(chappe_mix_rtp:build(P)),
    ?assertEqual(P, Q).

%% The fixed header as RFC 3550 lays it out: V=2, M set, PT 0.
wire_test() ->
    ?assertMatch(
        <<2:2, 0:1, 0:1, 0:4, 1:1, 0:7, 65535:16, 16#FFFFFF60:32,
            16#DEADBEEF:32, 1, 2, 3, 4>>,
        chappe_mix_rtp:build(pkt())
    ).

%% CSRCs, a header extension and padding are all skipped to reach the
%% payload, and the padding is not part of it.
skip_test() ->
    Hdr = <<2:2, 1:1, 1:1, 2:4, 0:1, 8:7, 7:16, 160:32, 42:32>>,
    Csrc = <<1:32, 2:32>>,
    Ext = <<16#BEDE:16, 1:16, 0:32>>,
    Pad = <<0, 0, 3>>,
    {ok, P} = chappe_mix_rtp:parse(
        <<Hdr/binary, Csrc/binary, Ext/binary, "abc", Pad/binary>>
    ),
    ?assertMatch(#{pt := 8, seq := 7, ts := 160, ssrc := 42}, P),
    ?assertEqual(<<"abc">>, maps:get(payload, P)).

malformed_test_() ->
    [
        ?_assertEqual({error, malformed}, chappe_mix_rtp:parse(<<>>)),
        ?_assertEqual({error, malformed}, chappe_mix_rtp:parse(<<1, 2, 3>>)),
        %% version 1
        ?_assertEqual(
            {error, malformed},
            chappe_mix_rtp:parse(<<1:2, 0:6, 0, 0:16, 0:32, 0:32>>)
        ),
        %% 3 CSRCs announced, none present
        ?_assertEqual(
            {error, malformed},
            chappe_mix_rtp:parse(<<2:2, 0:2, 3:4, 0, 0:16, 0:32, 0:32>>)
        ),
        %% padding longer than the payload
        ?_assertEqual(
            {error, malformed},
            chappe_mix_rtp:parse(<<2:2, 1:1, 0:5, 0, 0:16, 0:32, 0:32, 9>>)
        ),
        %% RTCP (PT 200..204 with the marker bit) is not RTP
        ?_assertEqual(
            {error, rtcp},
            chappe_mix_rtp:parse(<<2:2, 0:6, 200, 0:16, 0:32, 0:32>>)
        )
    ].

%% R3550-05: a mixer's CSRC list goes on the wire after the SSRC with
%% CC set to its length, and parses back.
csrc_test() ->
    P = (pkt())#{csrcs => [1, 2, 3]},
    Bin = chappe_mix_rtp:build(P),
    ?assertMatch(
        <<2:2, 0:1, 0:1, 3:4, 1:1, 0:7, _:16, _:32, 16#DEADBEEF:32, 1:32, 2:32,
            3:32, 1, 2, 3, 4>>,
        Bin
    ),
    ?assertEqual({ok, P}, chappe_mix_rtp:parse(Bin)).

%% R5761-003 R5761-011: with RTP and RTCP on one port, a second octet of
%% 192..223 (PT 64..95 after the marker bit) is RTCP, not only SR..APP; RTP PT 0
%% and 8 with or without the marker, and PT 96..127, stay RTP.
demux_test_() ->
    Rtcp = fun(B) ->
        chappe_mix_rtp:parse(<<2:2, 0:6, B, 0:16, 0:32, 0:32>>)
    end,
    [?_assertEqual({error, rtcp}, Rtcp(B)) || B <- lists:seq(192, 223)] ++
        [
            ?_assertMatch({ok, _}, Rtcp(B))
         || B <- [0, 8, 13, 63, 96, 101, 127, 128, 136, 191, 224, 255]
        ].

%% Extended sequence numbers carry across the 16-bit wrap, and a packet
%% just before the wrap arriving late maps to the previous cycle.
extend_test_() ->
    [
        ?_assertEqual(5, chappe_mix_rtp:extend_seq(5, undefined)),
        ?_assertEqual(65536, chappe_mix_rtp:extend_seq(0, 65535)),
        ?_assertEqual(65537, chappe_mix_rtp:extend_seq(1, 65535)),
        ?_assertEqual(65535, chappe_mix_rtp:extend_seq(65535, 65537)),
        ?_assertEqual(131072 + 3, chappe_mix_rtp:extend_seq(3, 131070))
    ].
