%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_fmt_tests).

-include_lib("eunit/include/eunit.hrl").

rates_test() ->
    ?assertEqual([8000, 16000], chappe_mix_fmt:rates()),
    ?assertEqual(8000, chappe_mix_fmt:rate(ulaw)),
    ?assertEqual(8000, chappe_mix_fmt:rate(alaw)),
    ?assertEqual(16000, chappe_mix_fmt:rate(l16)).

%% 20 ms at each rate, which is also the timestamp step of a frame
frame_test() ->
    ?assertEqual(160, chappe_mix_fmt:frame(8000)),
    ?assertEqual(320, chappe_mix_fmt:frame(16000)).

width_test() ->
    ?assertEqual(1, chappe_mix_fmt:width(ulaw)),
    ?assertEqual(1, chappe_mix_fmt:width(alaw)),
    ?assertEqual(2, chappe_mix_fmt:width(l16)).

%% silence is the code word closest to zero in each law (A-law has no
%% zero: its smallest step is 8), and two zero octets in L16
fill_test() ->
    ?assertEqual(
        [0], chappe_mix_g711:decode_frame(ulaw, <<(chappe_mix_fmt:fill(ulaw))>>)
    ),
    ?assertEqual(
        [8], chappe_mix_g711:decode_frame(alaw, <<(chappe_mix_fmt:fill(alaw))>>)
    ),
    ?assertEqual(0, chappe_mix_fmt:fill(l16)).

pt_test() ->
    ?assertEqual({0, 8, 96}, {
        chappe_mix_fmt:pt(ulaw), chappe_mix_fmt:pt(alaw), chappe_mix_fmt:pt(l16)
    }).

%% L16 is big-endian on the wire (RFC 3551 4.5.11) and the PCM of a tap
%% little-endian; a short frame is padded, an odd octet dropped
pcm_l16_test() ->
    Samples = [0, 1, -1, 32767, -32768, 256, -256],
    Wire = <<<<S:16/big-signed>> || S <- Samples>>,
    Pcm = chappe_mix_fmt:pcm(l16, 320, Wire),
    ?assertEqual(640, byte_size(Pcm)),
    ?assertEqual(
        Samples ++ lists:duplicate(320 - 7, 0),
        [S || <<S:16/little-signed>> <= Pcm]
    ),
    ?assertEqual(Pcm, chappe_mix_fmt:pcm(l16, 320, <<Wire/binary, 16#7F>>)),
    Full = <<<<(I - 160):16/big-signed>> || I <- lists:seq(1, 320)>>,
    ?assertEqual(
        [I - 160 || I <- lists:seq(1, 320)],
        [S || <<S:16/little-signed>> <= chappe_mix_fmt:pcm(l16, 320, Full)]
    ).

%% G.711 decodes as chappe_mix_g711 does, 160 samples
pcm_g711_test() ->
    chappe_mix_g711:init(),
    Codes = list_to_binary(lists:seq(0, 159)),
    [
        ?assertEqual(
            chappe_mix_g711:pcm(L, Codes), chappe_mix_fmt:pcm(L, 160, Codes)
        )
     || L <- [ulaw, alaw]
    ],
    ?assertEqual(320, byte_size(chappe_mix_fmt:pcm(ulaw, 160, <<1, 2>>))).
