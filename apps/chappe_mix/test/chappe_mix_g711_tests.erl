%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_g711_tests).

-include_lib("eunit/include/eunit.hrl").

%% Reference points from ITU-T G.711 tables 2a/2b (decoder output, scaled to
%% 16-bit linear as the Sun reference implementation and every softswitch
%% do). A wrong segment, bias or sign convention moves at least one of them.
ulaw_reference_test_() ->
    [
        ?_assertEqual(0, chappe_mix_g711:decode(ulaw, 16#FF)),
        ?_assertEqual(0, chappe_mix_g711:decode(ulaw, 16#7F)),
        ?_assertEqual(-32124, chappe_mix_g711:decode(ulaw, 16#00)),
        ?_assertEqual(32124, chappe_mix_g711:decode(ulaw, 16#80)),
        ?_assertEqual(-8, chappe_mix_g711:decode(ulaw, 16#7E)),
        ?_assertEqual(8, chappe_mix_g711:decode(ulaw, 16#FE)),
        ?_assertEqual(16#FF, chappe_mix_g711:encode(ulaw, 0)),
        ?_assertEqual(16#80, chappe_mix_g711:encode(ulaw, 32767)),
        ?_assertEqual(16#00, chappe_mix_g711:encode(ulaw, -32768))
    ].

alaw_reference_test_() ->
    [
        ?_assertEqual(8, chappe_mix_g711:decode(alaw, 16#D5)),
        ?_assertEqual(-8, chappe_mix_g711:decode(alaw, 16#55)),
        ?_assertEqual(32256, chappe_mix_g711:decode(alaw, 16#AA)),
        ?_assertEqual(-32256, chappe_mix_g711:decode(alaw, 16#2A)),
        ?_assertEqual(16#D5, chappe_mix_g711:encode(alaw, 0)),
        ?_assertEqual(16#AA, chappe_mix_g711:encode(alaw, 32767)),
        ?_assertEqual(16#2A, chappe_mix_g711:encode(alaw, -32768))
    ].

%% Every code word survives decode then encode. A-law has no duplicate
%% values; mu-law has two zeros (0x7F and 0xFF) and encodes 0 as 0xFF.
roundtrip_test_() ->
    [
        ?_assertEqual(
            [C || C <- lists:seq(0, 255), C =/= 16#7F],
            [
                chappe_mix_g711:encode(ulaw, chappe_mix_g711:decode(ulaw, C))
             || C <- lists:seq(0, 255), C =/= 16#7F
            ]
        ),
        ?_assertEqual(
            lists:seq(0, 255),
            [
                chappe_mix_g711:encode(alaw, chappe_mix_g711:decode(alaw, C))
             || C <- lists:seq(0, 255)
            ]
        )
    ].

%% Encoding is monotone over the whole 16-bit range and the quantisation
%% error stays inside the segment step, which bounds it to 1/16 of the
%% magnitude plus the smallest step.
quantisation_test_() ->
    [{atom_to_list(Law), fun() -> quantisation(Law) end} || Law <- [ulaw, alaw]].

quantisation(Law) ->
    Xs = lists:seq(-32768, 32767),
    Ys = [chappe_mix_g711:decode(Law, chappe_mix_g711:encode(Law, X)) || X <- Xs],
    ?assert(monotone(Ys)),
    Bad = [
        {X, Y}
     || {X, Y} <- lists:zip(Xs, Ys), abs(X - Y) > abs(X) div 16 + 132
    ],
    ?assertEqual([], Bad).

monotone([A, B | T]) when A =< B -> monotone([B | T]);
monotone([_]) -> true;
monotone(_) -> false.

%% The frame functions agree with the per-sample ones, clip out-of-range
%% sums instead of wrapping them, and keep the byte length.
frame_test_() ->
    Frame = list_to_binary(lists:seq(0, 159)),
    [
        ?_assertEqual(
            [chappe_mix_g711:decode(ulaw, B) || B <- binary_to_list(Frame)],
            chappe_mix_g711:decode_frame(ulaw, Frame)
        ),
        ?_assertEqual(
            Frame,
            chappe_mix_g711:encode_frame(
                alaw, chappe_mix_g711:decode_frame(alaw, Frame)
            )
        ),
        ?_assertEqual(
            <<16#80, 16#00>>,
            chappe_mix_g711:encode_frame(ulaw, [70000, -70000])
        ),
        ?_assertEqual(<<>>, chappe_mix_g711:encode_frame(ulaw, []))
    ].

%% A tap's PCM: each code word decoded to 16-bit little-endian, a short
%% frame padded with silence to 160 samples.
pcm_test_() ->
    Frame = list_to_binary(lists:seq(0, 159)),
    Want = <<
        <<(chappe_mix_g711:decode(alaw, B)):16/little-signed>>
     || <<B>> <= Frame
    >>,
    Short = chappe_mix_g711:pcm(ulaw, <<255, 255>>),
    [
        ?_assertEqual(Want, chappe_mix_g711:pcm(alaw, Frame)),
        ?_assertEqual(320, byte_size(Short)),
        ?_assertEqual(<<0:2560>>, chappe_mix_g711:pcm(ulaw, <<>>))
    ].

%% The room's PCM: the sum clipped to 16 bits, silence when nobody talks.
dsp_pcm_test_() ->
    Loud = chappe_mix_dsp:mixed(
        lists:foldl(
            fun(_, Acc) -> chappe_mix_dsp:add(Acc, ulaw, binary:copy(<<16#80>>, 160)) end,
            chappe_mix_dsp:new(),
            [1, 2]
        )
    ),
    [
        ?_assertEqual(<<0:2560>>, chappe_mix_dsp:pcm(chappe_mix_dsp:mixed(chappe_mix_dsp:new()))),
        ?_assertEqual(binary:copy(<<32767:16/little>>, 160), chappe_mix_dsp:pcm(Loud))
    ].
