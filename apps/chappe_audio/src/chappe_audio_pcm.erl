%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% 16-bit signed little-endian PCM, the format both fork modules send
%% (FreeSWITCH L16 in host order, little-endian on the platforms it
%% runs on).
-module(chappe_audio_pcm).

-export([levels/2]).

%% The RMS level of each channel over the frame, in dBFS (0 is a full
%% scale square wave); '-inf' for digital silence or an empty frame.
-spec levels(binary(), 1 | 2) -> [float() | '-inf'].
levels(Pcm, 1) ->
    [db(sum_sq(Pcm, 0, 0))];
levels(Pcm, 2) ->
    {L, R} = sum_sq2(Pcm, {0, 0}, 0),
    [db(L), db(R)].

sum_sq(<<S:16/little-signed, Rest/binary>>, Acc, N) ->
    sum_sq(Rest, Acc + S * S, N + 1);
sum_sq(_, Acc, N) ->
    {Acc, N}.

sum_sq2(<<L:16/little-signed, R:16/little-signed, Rest/binary>>, {A, B}, N) ->
    sum_sq2(Rest, {A + L * L, B + R * R}, N + 1);
sum_sq2(_, {A, B}, N) ->
    {{A, N}, {B, N}}.

db({0, _}) -> '-inf';
db({_, 0}) -> '-inf';
db({Sq, N}) -> 20 * math:log10(math:sqrt(Sq / N) / 32768).
