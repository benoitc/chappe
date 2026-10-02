%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_dsp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FRAME, 160).

%% The mix as it was before chappe_mix_dsp (1244d99), kept here as the
%% reference: decode each frame to a list, pad or cut it to 160 samples,
%% sum the talkers, take out each leg's own frame, clip and encode.
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
%% is far past 16 bits and every output clips.
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

check(Legs) ->
    ?assertEqual(reference(Legs), dsp(Legs), Legs).

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
