%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_dsp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FRAME, 160).
%% the gain control's release, per 20 ms frame (chappe_mix_dsp)
-define(RELEASE_DB, 0.2).

%% The mix as it was before chappe_mix_dsp (1244d99), kept here as the
%% reference: decode each frame to a list, pad or cut it to 160 samples,
%% sum the talkers, take out each leg's own frame, clip and encode. Since
%% the gain control, chappe_mix_dsp gives the same bytes for every leg
%% whose signal fits in 16 bits, and a scaled one for a leg that would
%% clip (see check/1).
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
                    fun(A, B) ->
                        lists:zipwith(fun(X, Y) -> X + Y end, A, B)
                    end,
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

%% The same legs through chappe_mix_dsp, as chappe_mix_room:mix/3 drives
%% it, every leg's gain at unity (a fresh leg).
dsp(Legs) ->
    {Outs, _} = dsp(Legs, [1.0 || _ <- Legs]),
    Outs.

%% One frame of Legs with each leg's gain going in; the payloads and the
%% gains coming out.
dsp(Legs, Gains) ->
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
    lists:unzip([
        chappe_mix_dsp:encode(Mixed, Law, own(Law, Codes, Muted), G)
     || {{Law, Codes, Muted}, G} <- lists:zip(Cut, Gains)
    ]).

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
%% is far past 16 bits and every output is scaled down.
clips_like_reference_test() ->
    setup(),
    Loud = [
        {Law, binary:copy(<<C>>, ?FRAME), false}
     || {Law, C} <- lists:flatten(
            lists:duplicate(8, [{ulaw, 16#80}, {alaw, 16#AA}, {ulaw, 16#00}])
        )
    ],
    check(Loud),
    check([
        {ulaw, binary:copy(<<16#80>>, ?FRAME), false}
     || _ <- lists:seq(1, 64)
    ]).

%% A listener can be kept from hearing more than itself: encode/4 takes a
%% list of frames to take out of the sum, which is the reference mix with
%% each of them left out.
several_left_out_test() ->
    setup(),
    rand:seed(exsss, {3, 5, 7}),
    [
        begin
            Legs = [{Law, rand:bytes(?FRAME), false} || Law <- Laws],
            Sum = lists:foldl(
                fun({Law, Codes, _}, Acc) ->
                    chappe_mix_dsp:add(Acc, Law, Codes)
                end,
                chappe_mix_dsp:new(),
                Legs
            ),
            Mixed = chappe_mix_dsp:mixed(Sum),
            Out = [{Law, Codes} || {Law, Codes, _} <- lists:sublist(Legs, K)],
            Kept = lists:nthtail(K, Legs),
            ?assertEqual(
                hd(expected([{ulaw, none, false} | Kept])),
                element(1, chappe_mix_dsp:encode(Mixed, ulaw, Out, 1.0))
            )
        end
     || Laws <- [[ulaw, alaw, ulaw, alaw, ulaw], [alaw, alaw, ulaw]],
        K <- lists:seq(0, length(Laws) - 1)
    ],
    ok.

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

%% A leg whose signal (the sum less what it does not hear) fits in 16
%% bits gets the reference's bytes, byte for byte: the gain stays at
%% unity. A leg whose signal would clip gets it scaled by the gain that
%% puts its peak at full scale (attack is immediate), then encoded:
%% never clipped, never louder than the reference.
check(Legs) ->
    Ref = reference(Legs),
    Out = dsp(Legs),
    ?assertEqual(expected(Legs), Out, Legs),
    [
        ?assertEqual(R, O)
     || {X, R, O} <- lists:zip3(signals(Legs), Ref, Out), fits(X)
    ],
    ok.

fits(none) -> true;
fits(X) -> lists:max([abs(S) || S <- X]) =< 32767.

%% The reference's signals, each scaled to fit when it would clip.
expected(Legs) ->
    [
        case X of
            none -> none;
            _ -> chappe_mix_g711:encode_frame(Law, scaled(X))
        end
     || {{Law, _, _}, X} <- lists:zip(Legs, signals(Legs))
    ].

scaled(X) ->
    case lists:max([abs(S) || S <- X]) of
        Peak when Peak =< 32767 -> X;
        Peak -> [round(S * (32767 / Peak)) || S <- X]
    end.

%% Eight talkers on distinct tones at -6 dBFS each, heard by a ninth leg
%% that says nothing: their sum is at full scale RMS and peaks near 2.7
%% times full scale. Over 1 s (50 frames, the gain carried from frame to
%% frame) the distortion and noise at the listener (what is left once
%% the eight tones are taken out, over the tones) is at most -26 dB; the
%% hard clip of the reference is the baseline.
gain_distortion_test() ->
    setup(),
    {Hard, Agc, _} = loud_room(50),
    ?debugFmt(
        "THD+N at the listener: hard clip ~.2f dB, gain control ~.2f dB", [
            Hard, Agc
        ]
    ),
    ?assert(Agc =< -26.0, {Agc, Hard}).

%% In that steady loud room the gain settles and does not pump: after the
%% first frame it moves by at most the release step up or 1.5 dB down
%% from one frame to the next, and stays in a 3 dB band.
gain_stable_test() ->
    setup(),
    {_, _, Gains} = loud_room(100),
    Db = [20 * math:log10(G) || G <- tl(Gains)],
    Steps = [B - A || {A, B} <- lists:zip(lists:droplast(Db), tl(Db))],
    ?debugFmt("gain ~.2f to ~.2f dB, steps ~.2f to ~.2f dB", [
        lists:min(Db), lists:max(Db), lists:min(Steps), lists:max(Steps)
    ]),
    ?assert(lists:max(Steps) =< ?RELEASE_DB + 1.0e-6, Steps),
    ?assert(lists:min(Steps) >= -1.5, Steps),
    ?assert(lists:max(Db) - lists:min(Db) =< 3.0, Db),
    ?assert(lists:max(Gains) < 1.0).

%% After a loud burst the gain comes back by the release step, 0.2 dB a
%% frame (10 dB a second), to unity exactly, and from then on the
%% listener gets the reference's bytes again. Never above unity.
gain_recovers_test() ->
    setup(),
    {_, _, Gains} = loud_room(10),
    G0 = lists:last(Gains),
    Quiet = fun(K) ->
        [{ulaw, tone_frame(1100, 3000, K), false}, {ulaw, none, false}]
    end,
    Frames = ceil(-20 * math:log10(G0) / ?RELEASE_DB),
    {Outs, Back} = lists:foldl(
        fun(K, {Acc, G}) ->
            {[_, O2], [_, G2]} = dsp(Quiet(K), [1.0, G]),
            {[{O2, G2} | Acc], G2}
        end,
        {[], G0},
        lists:seq(1, Frames + 5)
    ),
    Seen = lists:reverse(Outs),
    ?debugFmt("gain ~.3f back to ~p in ~p frames", [G0, Back, Frames]),
    ?assertEqual(1.0, Back),
    ?assertEqual(1.0, element(2, lists:nth(Frames, Seen))),
    ?assert(lists:all(fun({_, G}) -> G =< 1.0 end, Seen)),
    ?assertEqual(
        lists:last(reference(Quiet(Frames + 5))), element(1, lists:last(Seen))
    ),
    %% each step up is the release step, the last one capped at unity
    Ups = [
        20 * math:log10(B / A)
     || {A, B} <- lists:zip([G0 | [G || {_, G} <- lists:droplast(Seen)]], [
            G
         || {_, G} <- Seen
        ]),
        B > A
    ],
    ?assert(lists:all(fun(U) -> U =< ?RELEASE_DB + 1.0e-6 end, Ups), Ups),
    %% and within a frame the rising gain is spread from the last frame's
    %% to this one's, sample by sample, not stepped at the frame's start
    Prev = [G0 | [G || {_, G} <- lists:droplast(Seen)]],
    [
        ?assertEqual(
            chappe_mix_g711:encode_frame(ulaw, [
                round(X * (From + (To - From) * I / ?FRAME))
             || {I, X} <- lists:enumerate(
                    chappe_mix_g711:decode_frame(
                        ulaw, tone_frame(1100, 3000, K)
                    )
                )
            ]),
            O,
            {frame, K}
        )
     || {K, From, {O, To}} <- lists:zip3(lists:seq(1, length(Seen)), Prev, Seen)
    ].

%% The loud room: N frames of 8 tones at -6 dBFS and a ninth, silent
%% listener, through the reference and through the dsp with the
%% listener's gain carried. THD+N of each, and the gains frame by frame.
loud_room(N) ->
    %% whole cycles in 1 s for the judge, but not in 20 ms, so the frames
    %% differ and their peaks move from frame to frame
    Freqs = [310, 470, 660, 830, 1090, 1370, 1710, 2290],
    Frames = [
        [{ulaw, tone_frame(F, 16384, K), false} || F <- Freqs] ++
            [{ulaw, none, false}]
     || K <- lists:seq(0, N - 1)
    ],
    Ref = lists:append([
        chappe_mix_g711:decode_frame(ulaw, lists:last(reference(Legs)))
     || Legs <- Frames
    ]),
    {Outs, Gains, _} = lists:foldl(
        fun(Legs, {Os, Gs, G}) ->
            Gains0 = [1.0 || _ <- Freqs] ++ [G],
            {Out, GainsOut} = dsp(Legs, Gains0),
            G1 = lists:last(GainsOut),
            {[lists:last(Out) | Os], [G1 | Gs], G1}
        end,
        {[], [], 1.0},
        Frames
    ),
    Agc = lists:append([
        chappe_mix_g711:decode_frame(ulaw, O)
     || O <- lists:reverse(Outs)
    ]),
    {
        thdn(lists:sublist(Ref, 8000), Freqs),
        thdn(lists:sublist(Agc, 8000), Freqs),
        lists:reverse(Gains)
    }.

tone_frame(F, Amp, K) ->
    chappe_mix_g711:encode_frame(ulaw, [
        round(Amp * math:sin(2 * math:pi() * F * I / 8000 + F))
     || I <- lists:seq(K * ?FRAME, K * ?FRAME + ?FRAME - 1)
    ]).

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
