%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The RIFF WAVE container for 16-bit PCM, as pure functions: the 44-byte
%% header a recording starts with, the two sizes patched in when it
%% ends, and the format and length of a finished file (FreeSWITCH and
%% rtpengine write other chunks, LIST among them, before the data).
-module(chappe_audio_wav).

-export([header/3, size_patches/1, info/1]).

-define(HEADER, 44).

%% A header for Rate and Channels with DataBytes of audio (0 while the
%% recording runs).
-spec header(pos_integer(), pos_integer(), non_neg_integer()) -> binary().
header(Rate, Channels, DataBytes) ->
    Align = Channels * 2,
    <<"RIFF", (36 + DataBytes):32/little, "WAVE", "fmt ", 16:32/little,
        1:16/little, Channels:16/little, Rate:32/little,
        (Rate * Align):32/little, Align:16/little, 16:16/little, "data",
        DataBytes:32/little>>.

%% The writes that finish a header made by header/3: {Offset, Bytes}.
-spec size_patches(non_neg_integer()) -> [{non_neg_integer(), binary()}].
size_patches(DataBytes) ->
    [{4, <<(36 + DataBytes):32/little>>}, {40, <<DataBytes:32/little>>}].

%% The format and the audio length of a WAVE file's first bytes (its
%% chunks up to the data chunk header), or error when it is not one.
-spec info(binary()) ->
    {ok, #{
        encoding := pcm | non_neg_integer(),
        rate := pos_integer(),
        channels := pos_integer(),
        bits := non_neg_integer(),
        data_bytes := non_neg_integer(),
        data_offset := pos_integer()
    }}
    | error.
info(<<"RIFF", _:32, "WAVE", Chunks/binary>> = Bin) ->
    case chunks(Chunks, undefined) of
        {ok, Info, AtData} ->
            {ok, Info#{data_offset => byte_size(Bin) - byte_size(AtData) + 8}};
        error ->
            error
    end;
info(_) ->
    error.

chunks(<<"fmt ", Size:32/little, Body:Size/binary, Rest/binary>>, _) ->
    case Body of
        <<Enc:16/little, Ch:16/little, Rate:32/little, _:32, _:16,
            Bits:16/little,
            _/binary>> when Ch > 0, Rate > 0 ->
            chunks(pad(Size, Rest), {encoding(Enc), Ch, Rate, Bits});
        _ ->
            error
    end;
chunks(<<"data", Size:32/little, _/binary>> = AtData, {Enc, Ch, Rate, Bits}) ->
    {ok,
        #{
            encoding => Enc,
            rate => Rate,
            channels => Ch,
            bits => Bits,
            data_bytes => Size
        },
        AtData};
chunks(<<_:4/binary, Size:32/little, Rest/binary>>, Fmt) when
    byte_size(Rest) >= Size
->
    <<_:Size/binary, Rest1/binary>> = Rest,
    chunks(pad(Size, Rest1), Fmt);
chunks(_, _) ->
    error.

%% chunks are word aligned
pad(Size, <<_, Rest/binary>>) when Size rem 2 =:= 1 -> Rest;
pad(_Size, Rest) -> Rest.

encoding(1) -> pcm;
encoding(N) -> N.
