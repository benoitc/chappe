%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The compute of one tick. Every talking leg's frame is decoded
%% straight into one sum, an atomics array of one signed slot per sample
%% of a 20 ms frame (160 at 8 kHz, 320 at 16 kHz). Once every talker is
%% in, mixed/1 reads the sum out into a tuple, and each leg's output is
%% encoded from it less its own frame, decoded again from the payload it
%% came in. On the common path no decoded frame is ever kept as a list,
%% and every per-sample lookup is element/2 (test/audit/ATTEMPTS.md has
%% the comparison). A listener whose signal would clip has it scaled by a
%% gain control kept per listener (see encode/4).
%%
%% A frame is G.711 code words (an 8 kHz room: one octet a sample,
%% decoded and encoded through the chappe_mix_g711 tables) or L16 (a
%% 16 kHz room: 16-bit signed samples in network byte order, RFC 3551
%% 4.5.11, the mix linear end to end). A room has one rate, so one sum
%% never holds both.
%%
%% The array is mutable and lives only for the tick of the process that
%% made it: a sum is never shared, sent or kept across ticks.
%%
%% A frame shorter than the sum counts as silence past its end: the
%% same as padding the decoded samples. chappe_mix_jbuf never hands out a
%% longer one.
-module(chappe_mix_dsp).

-export([new/0, new/1, add/3, add_level/3, mixed/1, silence/0]).
-export([encode/4, pcm/1, pcm/2]).

-export_type([sum/0, mixed/0, frame/0]).

%% the frame of an 8 kHz room, what new/0 and pcm/1 take
-define(FRAME8, 160).
-define(FULL, 32767).
%% the gain control's release: 0.2 dB a frame, 10 dB a second
-define(RELEASE, 1.0232929922807541).

-opaque sum() :: {atomics:atomics_ref(), non_neg_integer(), pos_integer()}.
%% The sum of one tick, read out: none when nobody talks.
-opaque mixed() :: tuple() | none.
%% A leg's frame as it arrived: its format and payload.
-type frame() :: {chappe_mix_fmt:codec(), binary()}.

%% An empty sum for one tick of an 8 kHz room.
-spec new() -> sum().
new() ->
    new(?FRAME8).

%% An empty sum for one tick of Frame samples (chappe_mix_fmt:frame/1).
-spec new(pos_integer()) -> sum().
new(Frame) ->
    {atomics:new(Frame, [{signed, true}]), 0, Frame}.

%% Add one talker's frame to the sum.
-spec add(sum(), chappe_mix_fmt:codec(), binary()) -> sum().
add({A, N, F}, l16, Pcm) ->
    add_l16(A, Pcm, 1),
    {A, N + 1, F};
add({A, N, F}, Law, Codes) ->
    {Dec, _Enc} = chappe_mix_g711:tables(Law),
    add_codes(A, Dec, Codes, 1),
    {A, N + 1, F}.

%% add/3, and the frame's energy (the sum of its squared samples) for
%% telling a talker from a silent leg. Only called when someone listens
%% for talker events: add/3 costs nothing more.
-spec add_level(sum(), chappe_mix_fmt:codec(), binary()) ->
    {sum(), non_neg_integer()}.
add_level({A, N, F}, l16, Pcm) ->
    {{A, N + 1, F}, add_l16_level(A, Pcm, 1, 0)};
add_level({A, N, F}, Law, Codes) ->
    {Dec, _Enc} = chappe_mix_g711:tables(Law),
    {{A, N + 1, F}, add_codes_level(A, Dec, Codes, 1, 0)}.

%% The sum of a tick nobody talks in.
-spec silence() -> mixed().
silence() ->
    none.

%% The sum read out once every talker is in, for encode/4.
-spec mixed(sum()) -> mixed().
mixed({_A, 0, _F}) ->
    none;
mixed({A, _, F}) ->
    list_to_tuple([atomics:get(A, I) || I <- lists:seq(1, F)]).

%% What a leg of format Out hears: the sum less Less, the frames in the
%% sum it must not hear (its own, and those of the legs it is kept from
%% hearing): none, one frame or a list. Gain is the leg's gain control
%% coming in (1.0 for a new leg); returns the payload (none when nobody
%% talks: the leg sends its format's silence) and the gain going out, to
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
%% (test/audit/PERF.md). A hard clip stays as the last safety net. The
%% control steps once a frame whatever its length, so it runs the same
%% at 16 kHz.
-spec encode(
    mixed(), chappe_mix_fmt:codec(), frame() | none | [frame()], float()
) -> {binary() | none, float()}.
encode(none, _Out, _Less, Gain) ->
    {none, release(Gain)};
encode(Sum, l16, Less, 1.0) ->
    L = less(Less, tuple_size(Sum)),
    try
        {l16_unity(Sum, L), 1.0}
    catch
        error:clip -> l16_gain(signal(Sum, L), tuple_size(Sum), 1.0)
    end;
encode(Sum, l16, Less, Gain) ->
    l16_gain(signal(Sum, less(Less, tuple_size(Sum))), tuple_size(Sum), Gain);
encode(Sum, OutLaw, Less, 1.0) ->
    Enc = chappe_mix_g711:encoder(OutLaw),
    L = less(Less, tuple_size(Sum)),
    try
        {enc_unity(Sum, Enc, L), 1.0}
    catch
        error:clip -> enc_gain(signal(Sum, L), Enc, tuple_size(Sum), 1.0)
    end;
encode(Sum, OutLaw, Less, Gain) ->
    enc_gain(
        signal(Sum, less(Less, tuple_size(Sum))),
        chappe_mix_g711:encoder(OutLaw),
        tuple_size(Sum),
        Gain
    ).

%% The whole sum of an 8 kHz room as PCM: see pcm/2.
-spec pcm(mixed()) -> binary().
pcm(Mixed) ->
    pcm(Mixed, ?FRAME8).

%% The whole sum as 16-bit signed little-endian PCM (what a tap of the
%% room hears: every talker), clipped; Frame samples of silence when
%% nobody talks.
-spec pcm(mixed(), pos_integer()) -> binary().
pcm(none, Frame) ->
    <<0:(Frame * 16)>>;
pcm(Sum, _Frame) ->
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

%% L16 samples are big-endian on the wire (RFC 3551 4.5.11); an odd
%% octet at the end is not a sample
add_l16(A, <<X:16/signed-big, Rest/binary>>, I) ->
    atomics:add(A, I, X),
    add_l16(A, Rest, I + 1);
add_l16(_A, _Rest, _I) ->
    ok.

add_l16_level(A, <<X:16/signed-big, Rest/binary>>, I, E) ->
    atomics:add(A, I, X),
    add_l16_level(A, Rest, I + 1, E + X * X);
add_l16_level(_A, _Rest, _I, E) ->
    E.

%% What to take out of the sum: nothing, one frame (G.711 code words with
%% their law's decode table, or L16 samples), or the sum of several read
%% out.
less(none, _Frame) ->
    none;
less([], _Frame) ->
    none;
less([One], Frame) ->
    less(One, Frame);
less({l16, Pcm}, _Frame) ->
    {l16, Pcm};
less({Law, Codes}, _Frame) when is_atom(Law) ->
    {codes, element(1, chappe_mix_g711:tables(Law)), Codes};
less(Frames, Frame) ->
    {sum,
        mixed(
            lists:foldl(
                fun({Codec, P}, Acc) -> add(Acc, Codec, P) end,
                new(Frame),
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
    less_own(Sum, [element(B + 1, Dec) || <<B>> <= Codes]);
signal(Sum, {l16, Pcm}) ->
    less_own(Sum, [X || <<X:16/signed-big>> <= Pcm]);
signal(Sum, {sum, Less}) ->
    lists:zipwith(
        fun(S, O) -> S - O end, tuple_to_list(Sum), tuple_to_list(Less)
    ).

less_own(Sum, Own) ->
    Pad = Own ++ lists:duplicate(tuple_size(Sum) - length(Own), 0),
    lists:zipwith(fun(S, O) -> S - O end, tuple_to_list(Sum), Pad).

%% Release the gain toward unity, then take it down at once if the frame
%% still would not fit; scale and encode.
enc_gain(Xs, Enc, Frame, Gain0) ->
    Gain = gain(Xs, Gain0),
    From = min(Gain0, Gain),
    {ramp(Xs, Enc, From, Gain - From, float(Frame), 1, <<>>), Gain}.

l16_gain(Xs, Frame, Gain0) ->
    Gain = gain(Xs, Gain0),
    From = min(Gain0, Gain),
    {ramp_l16(Xs, From, Gain - From, float(Frame), 1, <<>>), Gain}.

gain(Xs, Gain0) ->
    Peak = lists:max([abs(X) || X <- Xs]),
    case Peak * release(Gain0) > ?FULL of
        true -> ?FULL / Peak;
        false -> release(Gain0)
    end.

%% Scale by a gain that moves from From to From + D across the frame of
%% F samples (a float): a rising gain (release) is spread over the frame
%% rather than stepped at its start, and every sample's gain is at most
%% the last, so nothing clips. Sample I (from 1) takes From + D * I / F,
%% the float operations of the 8 kHz mix of before in their order, so the
%% bytes are the same. Nothing is called per sample (clip/2 and scale/5
%% are inlined; test/audit/ATTEMPTS.md, the gain path at 8 kHz).
ramp([], _Enc, _From, _D, _F, _I, Acc) ->
    Acc;
ramp([X | Xs], Enc, From, D, F, I, Acc) ->
    S = clip(Enc, scale(X, From, D, F, I)),
    ramp(Xs, Enc, From, D, F, I + 1, <<Acc/binary, S>>).

ramp_l16([], _From, _D, _F, _I, Acc) ->
    Acc;
ramp_l16([X | Xs], From, D, F, I, Acc) ->
    S = max(-32768, min(?FULL, scale(X, From, D, F, I))),
    ramp_l16(Xs, From, D, F, I + 1, <<Acc/binary, S:16/signed-big>>).

%% Sample I at its point of the ramp (inlined into both loops)
scale(X, From, D, F, I) ->
    round(X * (From + D * I / F)).

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

enc_less(Sum, _Less, _Enc, I, Acc) when I > tuple_size(Sum) ->
    Acc;
enc_less(Sum, Less, Enc, I, Acc) ->
    S = element(I, Sum) - element(I, Less),
    enc_less(Sum, Less, Enc, I + 1, <<Acc/binary, (code(Enc, S))>>).

enc_sum(Sum, _Enc, I, Acc) when I > tuple_size(Sum) ->
    Acc;
enc_sum(Sum, Enc, I, Acc) ->
    enc_sum(Sum, Enc, I + 1, <<Acc/binary, (code(Enc, element(I, Sum)))>>).

%% A sample past 16 bits at unity: the frame is scaled instead.
-compile({inline, [code/2, fits/1, clip/2, scale/5]}).
code(_Enc, S) when S > ?FULL; S < -32768 ->
    error(clip);
code(Enc, S) ->
    element(S + 32769, Enc).

%% The L16 loops at unity, the same three as G.711's: the whole sum, the
%% sum less one frame, the sum less a sum; each sample goes out
%% big-endian.
l16_unity(Sum, none) ->
    l16_sum(Sum, 1, <<>>);
l16_unity(Sum, {l16, Pcm}) ->
    l16_own(Sum, Pcm, 1, <<>>);
l16_unity(Sum, {sum, Less}) ->
    l16_less(Sum, Less, 1, <<>>).

l16_own(Sum, <<O:16/signed-big, Rest/binary>>, I, Acc) ->
    S = fits(element(I, Sum) - O),
    l16_own(Sum, Rest, I + 1, <<Acc/binary, S:16/signed-big>>);
l16_own(Sum, _Rest, I, Acc) ->
    l16_sum(Sum, I, Acc).

l16_less(Sum, _Less, I, Acc) when I > tuple_size(Sum) ->
    Acc;
l16_less(Sum, Less, I, Acc) ->
    S = fits(element(I, Sum) - element(I, Less)),
    l16_less(Sum, Less, I + 1, <<Acc/binary, S:16/signed-big>>).

l16_sum(Sum, I, Acc) when I > tuple_size(Sum) ->
    Acc;
l16_sum(Sum, I, Acc) ->
    S = fits(element(I, Sum)),
    l16_sum(Sum, I + 1, <<Acc/binary, S:16/signed-big>>).

fits(S) when S > ?FULL; S < -32768 -> error(clip);
fits(S) -> S.
