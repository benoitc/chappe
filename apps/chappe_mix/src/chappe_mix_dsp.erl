%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The compute of one tick. Every talking leg's G.711 frame is decoded
%% straight into one sum, an atomics array of 160 signed slots; each leg's
%% output is then encoded from the sum less its own frame, decoded again
%% from the code words it came in. No decoded frame is ever kept as a
%% term, which is where the list version spent its time (test/audit/
%% ATTEMPTS.md has the comparison).
%%
%% The array is mutable and lives only for the tick of the process that
%% made it: a sum is never shared, sent or kept across ticks.
%%
%% A frame shorter than 160 bytes counts as silence past its end, and a
%% longer one is cut by chappe_mix_leg:pop/1: the same as padding or
%% cutting the decoded samples.
-module(chappe_mix_dsp).

-export([new/0, add/3, encode/3]).

-export_type([sum/0, frame/0]).

-define(FRAME, 160).

-opaque sum() :: {atomics:atomics_ref(), non_neg_integer()}.
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

%% What a leg of law OutLaw hears: the sum less Own, its own frame if it
%% is in the sum (none if it is not: muted, or nothing to play), encoded.
%% none when nobody talks: the leg sends its law's silence.
-spec encode(sum(), chappe_mix_g711:law(), frame() | none) -> binary() | none.
encode({_A, 0}, _OutLaw, _Own) ->
    none;
encode({A, _}, OutLaw, none) ->
    {_Dec, Enc} = chappe_mix_g711:tables(OutLaw),
    enc_sum(A, Enc, 1, []);
encode({A, _}, OutLaw, {Law, Codes}) ->
    {Dec, _} = chappe_mix_g711:tables(Law),
    {_, Enc} = chappe_mix_g711:tables(OutLaw),
    enc_own(A, Dec, Enc, Codes, 1, []).

%% ---- internal ----

add_codes(_A, _Dec, <<>>, _I) ->
    ok;
add_codes(A, Dec, <<B, Rest/binary>>, I) ->
    atomics:add(A, I, element(B + 1, Dec)),
    add_codes(A, Dec, Rest, I + 1).

enc_own(A, _Dec, Enc, <<>>, I, Acc) ->
    enc_sum(A, Enc, I, Acc);
enc_own(A, Dec, Enc, <<B, Rest/binary>>, I, Acc) ->
    S = atomics:get(A, I) - element(B + 1, Dec),
    enc_own(A, Dec, Enc, Rest, I + 1, [code(Enc, S) | Acc]).

enc_sum(_A, _Enc, I, Acc) when I > ?FRAME ->
    list_to_binary(lists:reverse(Acc));
enc_sum(A, Enc, I, Acc) ->
    enc_sum(A, Enc, I + 1, [code(Enc, atomics:get(A, I)) | Acc]).

code(Enc, S) when S > 32767 -> binary:at(Enc, 65535);
code(Enc, S) when S < -32768 -> binary:at(Enc, 0);
code(Enc, S) -> binary:at(Enc, S + 32768).
