%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_audio_pcm: the G.711 decode of an RTP receiver.
-module(chappe_audio_pcm_tests).

-include_lib("eunit/include/eunit.hrl").

%% G.711 as an RTP receiver decodes it (chappe_audio_rtp): the reference
%% values of ITU-T G.711, 16-bit little-endian
g711_decode_test() ->
    D = fun(Law, B) ->
        <<S:16/little-signed>> = chappe_audio_pcm:decode(Law, <<B>>),
        S
    end,
    ?assertEqual(0, D(ulaw, 16#FF)),
    ?assertEqual(-32124, D(ulaw, 16#00)),
    ?assertEqual(32124, D(ulaw, 16#80)),
    ?assertEqual(8, D(alaw, 16#D5)),
    ?assertEqual(-8, D(alaw, 16#55)),
    ?assertEqual(32256, D(alaw, 16#AA)),
    ?assertEqual(
        320, byte_size(chappe_audio_pcm:decode(ulaw, binary:copy(<<0>>, 160)))
    ).
