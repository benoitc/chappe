%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% G.711 mu-law and A-law, between code words and 16-bit linear samples.
%%
%% The arithmetic follows the Sun reference implementation that every
%% softswitch shares, so a frame decoded here sums the same as one decoded
%% by FreeSWITCH or rtpengine. The per-sample functions compute; the frame
%% functions, which the mixer calls 50 times a second per leg, go through
%% tables built once and kept in persistent_term: a 256-entry tuple per law
%% for decoding and a 64 KiB binary per law, indexed by sample + 32768, for
%% encoding.
%%
%% Build them with init/0 before any call starts (chappe_mix_app does). A
%% persistent_term:put stalls every process on the node while it runs, so
%% building lazily from inside a running conference costs a mix tick.
-module(chappe_mix_g711).

-export([init/0, decode/2, encode/2, decode_frame/2, encode_frame/2]).

-export_type([law/0]).

-type law() :: ulaw | alaw.

-define(BIAS, 16#84).
-define(CLIP, 32635).

%% Build the frame tables. Idempotent; call it before the first call.
-spec init() -> ok.
init() ->
    _ = tables(ulaw),
    _ = tables(alaw),
    ok.

%% Decode one code word to a linear sample.
-spec decode(law(), byte()) -> -32768..32767.
decode(ulaw, U0) ->
    U = bnot U0 band 16#FF,
    Exp = (U bsr 4) band 7,
    T = ((((U band 16#0F) bsl 3) + ?BIAS) bsl Exp) - ?BIAS,
    case U band 16#80 of
        0 -> T;
        _ -> -T
    end;
decode(alaw, A0) ->
    A = A0 bxor 16#55,
    T0 = (A band 16#0F) bsl 4,
    T =
        case (A band 16#70) bsr 4 of
            0 -> T0 + 8;
            1 -> T0 + 16#108;
            Seg -> (T0 + 16#108) bsl (Seg - 1)
        end,
    case A band 16#80 of
        0 -> -T;
        _ -> T
    end.

%% Encode one linear sample to a code word. Out-of-range input is clipped.
-spec encode(law(), integer()) -> byte().
encode(Law, X) when X > 32767 -> encode(Law, 32767);
encode(Law, X) when X < -32768 -> encode(Law, -32768);
encode(ulaw, X) ->
    {Sign, Mag0} =
        case X < 0 of
            true -> {16#80, -X};
            false -> {0, X}
        end,
    Mag = min(Mag0, ?CLIP) + ?BIAS,
    Exp = min(bit_length(Mag bsr 7) - 1, 7),
    Mant = (Mag bsr (Exp + 3)) band 16#0F,
    bnot (Sign bor (Exp bsl 4) bor Mant) band 16#FF;
encode(alaw, X) ->
    V0 = X bsr 3,
    {Mask, V} =
        case V0 >= 0 of
            true -> {16#D5, V0};
            false -> {16#55, -V0 - 1}
        end,
    case alaw_segment(V) of
        8 ->
            16#7F bxor Mask;
        Seg when Seg < 2 ->
            ((Seg bsl 4) bor ((V bsr 1) band 16#0F)) bxor Mask;
        Seg ->
            ((Seg bsl 4) bor ((V bsr Seg) band 16#0F)) bxor Mask
    end.

%% Decode a frame of code words to a list of linear samples.
-spec decode_frame(law(), binary()) -> [-32768..32767].
decode_frame(Law, Frame) ->
    {Dec, _Enc} = tables(Law),
    [element(B + 1, Dec) || <<B>> <= Frame].

%% Encode a list of linear samples to a frame, clipping each sample.
-spec encode_frame(law(), [integer()]) -> binary().
encode_frame(Law, Samples) ->
    {_Dec, Enc} = tables(Law),
    <<<<(binary:at(Enc, clip(S) + 32768))>> || S <- Samples>>.

%% ---- internal ----

clip(S) when S > 32767 -> 32767;
clip(S) when S < -32768 -> -32768;
clip(S) -> S.

bit_length(0) -> 0;
bit_length(N) -> 1 + bit_length(N bsr 1).

alaw_segment(V) -> alaw_segment(V, 16#1F, 0).

alaw_segment(_V, _End, 8) -> 8;
alaw_segment(V, End, Seg) when V =< End -> Seg;
alaw_segment(V, End, Seg) -> alaw_segment(V, (End bsl 1) bor 1, Seg + 1).

tables(Law) ->
    Key = {?MODULE, Law},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Tabs = build_tables(Law),
            persistent_term:put(Key, Tabs),
            Tabs;
        Tabs ->
            Tabs
    end.

build_tables(Law) ->
    Dec = list_to_tuple([decode(Law, B) || B <- lists:seq(0, 255)]),
    Enc = <<<<(encode(Law, S))>> || S <- lists:seq(-32768, 32767)>>,
    {Dec, Enc}.
