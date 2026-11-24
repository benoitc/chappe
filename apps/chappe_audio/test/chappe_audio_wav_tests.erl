%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_audio_wav_tests).

-include_lib("eunit/include/eunit.hrl").

header_test() ->
    H = chappe_audio_wav:header(16000, 2, 6400),
    ?assertEqual(44, byte_size(H)),
    ?assertEqual(
        {ok, #{
            encoding => pcm,
            rate => 16000,
            channels => 2,
            bits => 16,
            data_bytes => 6400,
            data_offset => 44
        }},
        chappe_audio_wav:info(H)
    ).

patch_test() ->
    H0 = chappe_audio_wav:header(8000, 1, 0),
    H = lists:foldl(
        fun({Off, B}, Acc) ->
            <<Pre:Off/binary, _:(byte_size(B))/binary, Post/binary>> = Acc,
            <<Pre/binary, B/binary, Post/binary>>
        end,
        H0,
        chappe_audio_wav:size_patches(320)
    ),
    ?assertEqual(chappe_audio_wav:header(8000, 1, 320), H).

%% other chunks before the data, an odd-sized one padded to a word
chunks_test() ->
    <<Riff:12/binary, Fmt:24/binary, Data:8/binary>> = chappe_audio_wav:header(
        8000, 1, 10
    ),
    Odd = <<"junk", 3:32/little, "abc", 0>>,
    List = <<"LIST", 4:32/little, "INFO">>,
    {ok, #{data_offset := Off, data_bytes := 10}} =
        chappe_audio_wav:info(
            <<Riff/binary, Odd/binary, Fmt/binary, List/binary, Data/binary>>
        ),
    ?assertEqual(12 + 12 + 24 + 12 + 8, Off).

not_wave_test() ->
    [
        ?assertEqual(error, chappe_audio_wav:info(B))
     || B <- [
            <<>>,
            <<"ID3 tags">>,
            <<"RIFF", 0:32, "AVI ">>,
            %% truncated before the data chunk
            binary:part(chappe_audio_wav:header(8000, 1, 0), 0, 30),
            %% data before any fmt
            <<"RIFF", 0:32, "WAVE", "data", 0:32>>,
            %% a chunk claiming more than there is
            <<"RIFF", 0:32, "WAVE", "fmt ", 9999:32/little, 0:64>>
        ]
    ].

ref_dir_test() ->
    ?assertEqual(
        <<"call-1.a_b">>, chappe_audio_store_file:ref_dir(<<"call-1.a_b">>)
    ),
    [
        ?assertMatch(<<"x-", _:64/binary>>, chappe_audio_store_file:ref_dir(R))
     || R <- [
            <<"..">>,
            <<".">>,
            <<"a/b">>,
            <<"a\\b">>,
            <<>>,
            <<0>>,
            binary:copy(<<"a">>, 129)
        ]
    ].
