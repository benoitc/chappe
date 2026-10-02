%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_dsp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FRAME, 160).
%% where the limiter starts to bend (chappe_mix_g711:limit/1), -6 dBFS
-define(KNEE, 16384).

%% The mix as it was before chappe_mix_dsp (1244d99), kept here as the
%% reference: decode each frame to a list, pad or cut it to 160 samples,
%% sum the talkers, take out each leg's own frame, clip and encode. Since
%% the soft limiter, chappe_mix_dsp gives the same bytes for every sample
%% under the knee, and a softer one above it (see check/1).
%% Legs are {Law, Codes | none, Muted}; the result is, per leg, its
%% payload or none (the leg sends its law's silence).
reference(Legs) ->
    Pcms = [
        {Law, pcm(Law, Codes), Muted}
     || {Law, Codes, Muted} <- Legs
    ],
    Talking = [P || {_, P, false} <- Pcms, P =/= none],
    Sum =
        case Talking of
            [] ->
                none;
            [T | Ts] ->
                lists:foldl(
                    fun(A, B) -> lists:zipwith(fun(X, Y) -> X + Y end, A, B) end,
                    T,
                    Ts
                )
        end,
    [
        case {Sum, P, Muted} of
            {none, _, _} -> none;
            {_, none, _} -> chappe_mix_g711:encode_frame(Law, Sum);
            {_, _, true} -> chappe_mix_g711:encode_frame(Law, Sum);
            _ -> chappe_mix_g711:encode_frame(Law, sub(Sum, P))
        end
     || {Law, P, Muted} <- Pcms
    ].

%% What each leg hears before it is encoded: the sum less its own frame,
%% as a list of samples, or none.
signals(Legs) ->
    Pcms = [{pcm(Law, Codes), Muted} || {Law, Codes, Muted} <- Legs],
    Talking = [P || {P, false} <- Pcms, P =/= none],
    case Talking of
        [] ->
            [none || _ <- Legs];
        [T | Ts] ->
            Sum = lists:foldl(
                fun(A, B) -> lists:zipwith(fun(X, Y) -> X + Y end, A, B) end,
                T,
                Ts
            ),
            [
                case {P, Muted} of
                    {none, _} -> Sum;
                    {_, true} -> Sum;
                    _ -> sub(Sum, P)
                end
             || {P, Muted} <- Pcms
            ]
    end.

pcm(_Law, none) ->
    none;
pcm(Law, Codes) ->
    fit(chappe_mix_g711:decode_frame(Law, Codes)).

fit(P) when length(P) =:= ?FRAME -> P;
fit(P) when length(P) > ?FRAME -> lists:sublist(P, ?FRAME);
fit(P) -> P ++ lists:duplicate(?FRAME - length(P), 0).

sub(A, B) -> lists:zipwith(fun(X, Y) -> X - Y end, A, B).

%% The same legs through chappe_mix_dsp, as chappe_mix_conf:mix/2 drives
%% it, after chappe_mix_leg:pop/1 has cut a long frame.
dsp(Legs) ->
    Cut = [{Law, cut(Codes), Muted} || {Law, Codes, Muted} <- Legs],
    Sum = lists:foldl(
        fun
            ({Law, Codes, false}, Acc) when Codes =/= none ->
                chappe_mix_dsp:add(Acc, Law, Codes);
            (_, Acc) ->
                Acc
        end,
        chappe_mix_dsp:new(),
        Cut
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    [
        chappe_mix_dsp:encode(Mixed, Law, own(Law, Codes, Muted))
     || {Law, Codes, Muted} <- Cut
    ].

cut(none) -> none;
cut(C) when byte_size(C) > ?FRAME -> binary:part(C, 0, ?FRAME);
cut(C) -> C.

own(_Law, _Codes, true) -> none;
own(_Law, none, _) -> none;
own(Law, Codes, _) -> {Law, Codes}.

%% ---- cases ----

setup() ->
    chappe_mix_g711:init().

%% Seeded random rooms of 1 to 64 legs: mixed laws, muted legs, legs with
%% nothing to play, frames of 80, 160 and 240 bytes, and code words drawn
%% from the whole range so that sums clip both ways.
same_as_reference_test_() ->
    {setup, fun setup/0, fun(_) ->
        [
            ?_test(begin
                rand:seed(exsss, {Seed, 7, 11}),
                [check(room()) || _ <- lists:seq(1, 50)]
            end)
         || Seed <- lists:seq(1, 10)
        ]
    end}.

%% Rooms where every leg sends the loudest code word of its law: the sum
%% is far past 16 bits and every output is limited.
clips_like_reference_test() ->
    setup(),
    Loud = [
        {Law, binary:copy(<<C>>, ?FRAME), false}
     || {Law, C} <- lists:flatten(lists:duplicate(8, [{ulaw, 16#80}, {alaw, 16#AA}, {ulaw, 16#00}]))
    ],
    check(Loud),
    check([{ulaw, binary:copy(<<16#80>>, ?FRAME), false} || _ <- lists:seq(1, 64)]).

%% Nobody talks: every leg gets none (its law's silence).
nobody_talks_test() ->
    setup(),
    Legs = [{ulaw, none, false}, {alaw, binary:copy(<<1>>, ?FRAME), true}],
    ?assertEqual([none, none], dsp(Legs)),
    check(Legs).

%% A single talker hears nothing of itself: the sum less its own frame is
%% zero, which encodes to the law's zero code word.
alone_hears_zero_test() ->
    setup(),
    [Out] = dsp([{ulaw, binary:copy(<<16#23>>, ?FRAME), false}]),
    ?assertEqual(binary:copy(<<16#FF>>, ?FRAME), Out).

%% Under the knee of the limiter (where chappe_mix_g711:limit/1 leaves a
%% sample as it is) every code word is the reference's, the hard clip
%% included; above it the output keeps the sign, is no louder than the
%% hard clip and no quieter than the knee less a quantization step.
%% And the whole output is, byte for byte, the reference's sum less own
%% frame put through the limiter before it is encoded.
check(Legs) ->
    Ref = reference(Legs),
    Out = dsp(Legs),
    ?assertEqual(limited(Legs), Out, Legs),
    [
        check_leg(Law, X, R, O)
     || {{Law, _, _}, X, {R, O}} <- lists:zip3(
            Legs, signals(Legs), lists:zip(Ref, Out)
        )
    ],
    ok.

check_leg(_Law, _X, none, O) ->
    ?assertEqual(none, O);
check_leg(Law, X, R, O) ->
    ?assertEqual(?FRAME, byte_size(O)),
    [
        check_sample(Law, S, RC, OC)
     || {S, RC, OC} <- lists:zip3(X, binary_to_list(R), binary_to_list(O))
    ].

check_sample(Law, S, RC, OC) ->
    case chappe_mix_g711:limit(S) =:= S of
        true ->
            ?assertEqual(RC, OC, {sample, S});
        false ->
            Out = chappe_mix_g711:decode(Law, OC),
            Hard = chappe_mix_g711:decode(Law, RC),
            ?assert(Out * S > 0, {sign, S, Out}),
            ?assert(abs(Out) =< abs(Hard), {louder_than_clip, S, Out, Hard}),
            ?assert(abs(Out) >= ?KNEE - 1024, {under_knee, S, Out})
    end.

%% The reference's signals through chappe_mix_g711:limit/1, encoded.
limited(Legs) ->
    [
        case X of
            none ->
                none;
            _ ->
                chappe_mix_g711:encode_frame(
                    Law, [chappe_mix_g711:limit(S) || S <- X]
                )
        end
     || {{Law, _, _}, X} <- lists:zip(Legs, signals(Legs))
    ].

%% Eight talkers on distinct tones at -6 dBFS each, heard by a ninth leg
%% that says nothing: their sum is at full scale RMS and peaks near 2.7
%% times full scale. Over 1 s, the distortion and noise at the listener
%% (what is left once the eight tones are taken out, over the tones) is
%% lower through the limiter than through the hard clip.
limiter_distortion_test() ->
    setup(),
    Freqs = [300, 450, 650, 850, 1100, 1350, 1700, 2300],
    Frames = [
        [
            {ulaw,
                chappe_mix_g711:encode_frame(
                    ulaw,
                    [
                        round(16384 * math:sin(2 * math:pi() * F * I / 8000 + F))
                     || I <- lists:seq(K * ?FRAME, K * ?FRAME + ?FRAME - 1)
                    ]
                ),
                false}
         || F <- Freqs
        ] ++ [{ulaw, none, false}]
     || K <- lists:seq(0, 49)
    ],
    Heard = fun(Mix) ->
        lists:append([
            chappe_mix_g711:decode_frame(ulaw, lists:last(Mix(Legs)))
         || Legs <- Frames
        ])
    end,
    Hard = thdn(Heard(fun reference/1), Freqs),
    Soft = thdn(Heard(fun dsp/1), Freqs),
    ?debugFmt("THD+N at the listener: hard clip ~.2f dB, limiter ~.2f dB", [
        Hard, Soft
    ]),
    ?assert(Soft < Hard - 0.3, {Soft, Hard}).

%% Power outside the tone bins over the power in them, dB. Every tone
%% makes whole cycles in the window, so its Goertzel bin holds it all.
thdn(Samples, Freqs) ->
    N = length(Samples),
    Total = lists:sum([X * X || X <- Samples]),
    Tones = lists:sum([2 * goertzel(Samples, F) / N || F <- Freqs]),
    10 * math:log10(max(Total - Tones, 1.0e-9) / Tones).

goertzel(Samples, F) ->
    C = 2 * math:cos(2 * math:pi() * F / 8000),
    {S1, S2} = lists:foldl(
        fun(X, {P1, P2}) -> {X + C * P1 - P2, P1} end, {0.0, 0.0}, Samples
    ),
    S1 * S1 + S2 * S2 - C * S1 * S2.

room() ->
    N = rand:uniform(64),
    [leg() || _ <- lists:seq(1, N)].

leg() ->
    Law = lists:nth(rand:uniform(2), [ulaw, alaw]),
    Codes =
        case rand:uniform(5) of
            1 -> none;
            _ -> rand:bytes(lists:nth(rand:uniform(3), [80, 160, 240]))
        end,
    {Law, Codes, rand:uniform(5) =:= 1}.
