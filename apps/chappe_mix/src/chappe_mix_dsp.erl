%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The compute of one tick. Every talking leg's G.711 frame is decoded
%% straight into one sum, an atomics array of 160 signed slots. Once every
%% talker is in, mixed/1 reads the sum out into a tuple, and each leg's
%% output is encoded from it less its own frame, decoded again from the
%% code words it came in. The encode goes through the soft limiter
%% (chappe_mix_g711:limit/1), folded into the encode table: under -6 dBFS
%% a sample encodes as it always did, above it the room is compressed
%% toward full scale instead of clipped. No decoded frame is ever kept as a list, and
%% every per-sample lookup is element/2 (test/audit/ATTEMPTS.md has the
%% comparison).
%%
%% The array is mutable and lives only for the tick of the process that
%% made it: a sum is never shared, sent or kept across ticks.
%%
%% A frame shorter than 160 bytes counts as silence past its end: the
%% same as padding the decoded samples. chappe_mix_jbuf never hands out a
%% longer one.
-module(chappe_mix_dsp).

-export([new/0, add/3, mixed/1, encode/3]).

-export_type([sum/0, mixed/0, frame/0]).

-define(FRAME, 160).

-opaque sum() :: {atomics:atomics_ref(), non_neg_integer()}.
%% The sum of one tick, read out: none when nobody talks.
-opaque mixed() :: tuple() | none.
%% A leg's frame as it arrived: its law and code words.
-type frame() :: {chappe_mix_g711:law(), binary()}.

%% An empty sum for one tick.
-spec new() -> sum().
new() ->
    {atomics:new(?FRAME, [{signed, true}]), 0}.

%% Add one talker's frame to the sum.
-spec add(sum(), chappe_mix_g711:law(), binary()) -> sum().
add({A, N}, Law, Codes) ->
    {Dec, _Enc} = chappe_mix_g711:tables(Law),
    add_codes(A, Dec, Codes, 1),
    {A, N + 1}.

%% The sum read out once every talker is in, for encode/3.
-spec mixed(sum()) -> mixed().
mixed({_A, 0}) ->
    none;
mixed({A, _}) ->
    list_to_tuple([atomics:get(A, I) || I <- lists:seq(1, ?FRAME)]).

%% What a leg of law OutLaw hears: the sum less Out, the frames in the sum
%% it must not hear (its own, and those of the legs it is kept from
%% hearing), encoded: none, one frame or a list. none when nobody talks:
%% the leg sends its law's silence.
-spec encode(mixed(), chappe_mix_g711:law(), frame() | none | [frame()]) ->
    binary() | none.
encode(none, _OutLaw, _Out) ->
    none;
encode(Sum, OutLaw, Out) when Out =:= none; Out =:= [] ->
    enc_sum(Sum, chappe_mix_g711:encoder(OutLaw), 1, <<>>);
encode(Sum, OutLaw, [Frame]) ->
    encode(Sum, OutLaw, Frame);
encode(Sum, OutLaw, {Law, Codes}) ->
    {Dec, _} = chappe_mix_g711:tables(Law),
    enc_own(Sum, Dec, chappe_mix_g711:encoder(OutLaw), Codes, 1, <<>>);
encode(Sum, OutLaw, Frames) ->
    %% several left out: their own sum, taken out sample by sample
    Less = mixed(
        lists:foldl(
            fun({Law, Codes}, Acc) -> add(Acc, Law, Codes) end, new(), Frames
        )
    ),
    enc_less(Sum, Less, chappe_mix_g711:encoder(OutLaw), 1, <<>>).

%% ---- internal ----

add_codes(_A, _Dec, <<>>, _I) ->
    ok;
add_codes(A, Dec, <<B, Rest/binary>>, I) ->
    atomics:add(A, I, element(B + 1, Dec)),
    add_codes(A, Dec, Rest, I + 1).

enc_own(Sum, _Dec, Enc, <<>>, I, Acc) ->
    enc_sum(Sum, Enc, I, Acc);
enc_own(Sum, Dec, Enc, <<B, Rest/binary>>, I, Acc) ->
    S = element(I, Sum) - element(B + 1, Dec),
    enc_own(Sum, Dec, Enc, Rest, I + 1, <<Acc/binary, (code(Enc, S))>>).

enc_less(_Sum, _Less, _Enc, I, Acc) when I > ?FRAME ->
    Acc;
enc_less(Sum, Less, Enc, I, Acc) ->
    S = element(I, Sum) - element(I, Less),
    enc_less(Sum, Less, Enc, I + 1, <<Acc/binary, (code(Enc, S))>>).

enc_sum(_Sum, _Enc, I, Acc) when I > ?FRAME ->
    Acc;
enc_sum(Sum, Enc, I, Acc) ->
    enc_sum(Sum, Enc, I + 1, <<Acc/binary, (code(Enc, element(I, Sum)))>>).

%% A sum past 16 bits is rare (a room clipping): limit it, then encode
%% it with the law the table carries last.
-compile({inline, [code/2]}).
code(Enc, S) when S > 32767; S < -32768 ->
    chappe_mix_g711:encode(element(65537, Enc), chappe_mix_g711:limit(S));
code(Enc, S) ->
    element(S + 32769, Enc).
