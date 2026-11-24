%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The wav helpers of chappe_mrf_live_ua: a prompt written at 8 or
%% 16 kHz reads back at the level it was written with, at the rate its
%% header names.
-module(chappe_mrf_live_ua_tests).

-include_lib("eunit/include/eunit.hrl").

-define(UA, chappe_mrf_live_ua).

wav_rates_test_() ->
    {setup, fun tmp/0, fun(Dir) -> file:del_dir_r(Dir) end, fun(Dir) ->
        [
            ?_test(round_trip(Dir, 8000, 1000)),
            ?_test(round_trip(Dir, 16000, 1000)),
            %% above the 8 kHz Nyquist frequency: only a 16 kHz read sees it
            ?_test(round_trip(Dir, 16000, 6000))
        ]
    end}.

round_trip(Dir, Rate, Freq) ->
    Path = filename:join(Dir, io_lib:format("t~b_~b.wav", [Rate, Freq])),
    ok = ?UA:write_wav(Path, Freq, 600, 8000, Rate),
    {ok, Bin} = file:read_file(Path),
    ?assertEqual(44 + 2 * Rate * 600 div 1000, byte_size(Bin)),
    Want = 20 * math:log10(8000 / 32768),
    ?assert(abs(?UA:wav_level(Path, Freq) - Want) < 0.2),
    %% a tone that is not there stays 40 dB down
    ?assert(?UA:wav_level(Path, Freq + 500) < Want - 40).

%% the 8 kHz default of write_wav/4 is unchanged
default_rate_test() ->
    Dir = tmp(),
    Path = filename:join(Dir, "d.wav"),
    ok = ?UA:write_wav(Path, 600, 400, 8000),
    {ok, <<_:24/binary, Rate:32/little, _/binary>>} = file:read_file(Path),
    ?assertEqual(8000, Rate),
    file:del_dir_r(Dir).

tmp() ->
    Dir = filename:join(
        filename:basedir(user_cache, "chappe_mrf_live_ua_tests"),
        integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.
