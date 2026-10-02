%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The compute of one tick. Every talking leg's G.711 frame is decoded
%% straight into one sum, an atomics array of 160 signed slots. Once every
%% talker is in, mixed/1 reads the sum out into a tuple, and each leg's
%% output is encoded from it less its own frame, decoded again from the
%% code words it came in. No decoded frame is ever kept as a list, and
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

%% What a leg of law OutLaw hears: the sum less Own, its own frame if it
%% is in the sum (none if it is not: muted, or nothing to play), encoded.
%% none when nobody talks: the leg sends its law's silence.
-spec encode(mixed(), chappe_mix_g711:law(), frame() | none) ->
    binary() | none.
encode(none, _OutLaw, _Own) ->
    none;
encode(Sum, OutLaw, none) ->
    enc_sum(Sum, chappe_mix_g711:encoder(OutLaw), 1, <<>>);
encode(Sum, OutLaw, {Law, Codes}) ->
    {Dec, _} = chappe_mix_g711:tables(Law),
    enc_own(Sum, Dec, chappe_mix_g711:encoder(OutLaw), Codes, 1, <<>>).

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

enc_sum(_Sum, _Enc, I, Acc) when I > ?FRAME ->
    Acc;
enc_sum(Sum, Enc, I, Acc) ->
    enc_sum(Sum, Enc, I + 1, <<Acc/binary, (code(Enc, element(I, Sum)))>>).

-compile({inline, [code/2]}).
code(Enc, S) when S > 32767 -> element(65536, Enc);
code(Enc, S) when S < -32768 -> element(1, Enc);
code(Enc, S) -> element(S + 32769, Enc).
