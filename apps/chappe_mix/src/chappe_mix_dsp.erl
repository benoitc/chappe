%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The compute of one tick. Every talking leg's G.711 frame is decoded
%% straight into one sum, an atomics array of 160 signed slots. Once every
%% talker is in, mixed/1 reads the sum out into a tuple, and each leg's
%% output is encoded from it less its own frame, decoded again from the
%% code words it came in. On the common path no decoded frame is ever
%% kept as a list, and every per-sample lookup is element/2
%% (test/audit/ATTEMPTS.md has the comparison). A listener whose signal
%% would clip has it scaled by a gain control kept per listener (see
%% encode/4).
%%
%% The array is mutable and lives only for the tick of the process that
%% made it: a sum is never shared, sent or kept across ticks.
%%
%% A frame shorter than 160 bytes counts as silence past its end: the
%% same as padding the decoded samples. chappe_mix_jbuf never hands out a
%% longer one.
-module(chappe_mix_dsp).

-export([new/0, add/3, add_level/3, mixed/1, silence/0, encode/4, pcm/1]).

-export_type([sum/0, mixed/0, frame/0]).

-define(FRAME, 160).
-define(FULL, 32767).
%% the gain control's release: 0.2 dB a frame, 10 dB a second
-define(RELEASE, 1.0232929922807541).

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

%% add/3, and the frame's energy (the sum of its squared samples) for
%% telling a talker from a silent leg. Only called when someone listens
%% for talker events: add/3 costs nothing more.
-spec add_level(sum(), chappe_mix_g711:law(), binary()) ->
    {sum(), non_neg_integer()}.
add_level({A, N}, Law, Codes) ->
    {Dec, _Enc} = chappe_mix_g711:tables(Law),
    {{A, N + 1}, add_codes_level(A, Dec, Codes, 1, 0)}.

%% The sum of a tick nobody talks in.
-spec silence() -> mixed().
silence() ->
    none.

%% The sum read out once every talker is in, for encode/4.
-spec mixed(sum()) -> mixed().
mixed({_A, 0}) ->
    none;
mixed({A, _}) ->
    list_to_tuple([atomics:get(A, I) || I <- lists:seq(1, ?FRAME)]).

%% What a leg of law OutLaw hears: the sum less Out, the frames in the sum
%% it must not hear (its own, and those of the legs it is kept from
%% hearing): none, one frame or a list. Gain is the leg's gain control
%% coming in (1.0 for a new leg); returns the payload (none when nobody
%% talks: the leg sends its law's silence) and the gain going out, to
%% hand back on the next tick.
%%
%% The gain control. At unity, a signal that fits in 16 bits is encoded
%% as it is, so a room that does not clip is the plain N-1 mix, byte for
%% byte. When a frame would clip, the gain drops at once to what puts its
%% peak at full scale (the whole frame is known before it is encoded, so
%% the attack needs no look-ahead and nothing clips). It then comes back
%% by 0.2 dB a frame, 10 dB a second, spread across each frame, never
%% above unity: slow enough not to pump on the peaks of a loud room
%% (0.4 dB a frame measured 0.8 dB worse), fast enough that a room loud
%% for a moment (a 9 dB cut) is back at unity within a second. Scaling a
%% frame, unlike bending each sample, keeps the waveform: 8 tones at
%% -6 dBFS (full scale RMS) measure -29 dB THD+N against -10 dB clipped
%% (test/audit/PERF.md). A hard clip stays as the last safety net.
-spec encode(
    mixed(), chappe_mix_g711:law(), frame() | none | [frame()], float()
) -> {binary() | none, float()}.
encode(none, _OutLaw, _Out, Gain) ->
    {none, release(Gain)};
encode(Sum, OutLaw, Out, 1.0) ->
    Enc = chappe_mix_g711:encoder(OutLaw),
    try
        {enc_unity(Sum, Enc, less(Out)), 1.0}
    catch
        error:clip -> enc_gain(signal(Sum, less(Out)), Enc, 1.0)
    end;
encode(Sum, OutLaw, Out, Gain) ->
    enc_gain(signal(Sum, less(Out)), chappe_mix_g711:encoder(OutLaw), Gain).

%% The whole sum as 16-bit signed little-endian PCM (what a tap of the
%% room hears: every talker), clipped; silence when nobody talks.
-spec pcm(mixed()) -> binary().
pcm(none) ->
    <<0:(?FRAME * 16)>>;
pcm(Sum) ->
    <<
        <<(max(-32768, min(?FULL, S))):16/little-signed>>
     || S <- tuple_to_list(Sum)
    >>.

%% ---- internal ----

add_codes(_A, _Dec, <<>>, _I) ->
    ok;
add_codes(A, Dec, <<B, Rest/binary>>, I) ->
    atomics:add(A, I, element(B + 1, Dec)),
    add_codes(A, Dec, Rest, I + 1).

add_codes_level(_A, _Dec, <<>>, _I, E) ->
    E;
add_codes_level(A, Dec, <<B, Rest/binary>>, I, E) ->
    X = element(B + 1, Dec),
    atomics:add(A, I, X),
    add_codes_level(A, Dec, Rest, I + 1, E + X * X).

%% What to take out of the sum: nothing, one frame's code words, or the
%% sum of several read out.
less(none) ->
    none;
less([]) ->
    none;
less([Frame]) ->
    less(Frame);
less({Law, Codes}) ->
    {codes, element(1, chappe_mix_g711:tables(Law)), Codes};
less(Frames) ->
    {sum,
        mixed(
            lists:foldl(
                fun({Law, Codes}, Acc) -> add(Acc, Law, Codes) end,
                new(),
                Frames
            )
        )}.

%% At unity: encode as it comes, fail with clip at the first sample that
%% does not fit (the caller scales the frame instead).
enc_unity(Sum, Enc, none) ->
    enc_sum(Sum, Enc, 1, <<>>);
enc_unity(Sum, Enc, {codes, Dec, Codes}) ->
    enc_own(Sum, Dec, Enc, Codes, 1, <<>>);
enc_unity(Sum, Enc, {sum, Less}) ->
    enc_less(Sum, Less, Enc, 1, <<>>).

%% The listener's signal as a list of samples.
signal(Sum, none) ->
    tuple_to_list(Sum);
signal(Sum, {codes, Dec, Codes}) ->
    Own = [element(B + 1, Dec) || <<B>> <= Codes],
    Pad = Own ++ lists:duplicate(?FRAME - length(Own), 0),
    lists:zipwith(fun(S, O) -> S - O end, tuple_to_list(Sum), Pad);
signal(Sum, {sum, Less}) ->
    lists:zipwith(
        fun(S, O) -> S - O end, tuple_to_list(Sum), tuple_to_list(Less)
    ).

%% Release the gain toward unity, then take it down at once if the frame
%% still would not fit; scale and encode.
enc_gain(Xs, Enc, Gain0) ->
    Peak = lists:max([abs(X) || X <- Xs]),
    Gain =
        case Peak * release(Gain0) > ?FULL of
            true -> ?FULL / Peak;
            false -> release(Gain0)
        end,
    {ramp(Xs, Enc, min(Gain0, Gain), Gain, 0, <<>>), Gain}.

%% Scale by a gain that moves from From to To across the frame: a rising
%% gain (release) is spread over the frame rather than stepped at its
%% start, and every sample's gain is at most To, so nothing clips.
ramp([], _Enc, _From, _To, _I, Acc) ->
    Acc;
ramp([X | Xs], Enc, From, To, I, Acc) ->
    G = From + (To - From) * (I + 1) / ?FRAME,
    ramp(Xs, Enc, From, To, I + 1, <<Acc/binary, (clip(Enc, round(X * G)))>>).

release(G) when G * ?RELEASE >= 1.0 -> 1.0;
release(G) -> G * ?RELEASE.

%% The safety net: a hard clip.
clip(Enc, S) when S > ?FULL -> element(65536, Enc);
clip(Enc, S) when S < -32768 -> element(1, Enc);
clip(Enc, S) -> element(S + 32769, Enc).

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

%% A sample past 16 bits at unity: the frame is scaled instead.
-compile({inline, [code/2]}).
code(_Enc, S) when S > ?FULL; S < -32768 ->
    error(clip);
code(Enc, S) ->
    element(S + 32769, Enc).
