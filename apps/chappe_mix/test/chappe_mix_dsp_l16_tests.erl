%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The 16 kHz mix (L16) against a reference written with lists: decode
%% each leg's big-endian payload (RFC 3551 4.5.11), pad it to the 320
%% samples of 20 ms, sum the talkers, take out each listener's own frame,
%% scale a signal that would clip to full scale, and encode it big-endian
%% again. chappe_mix_dsp gives the same bytes for every leg, over rooms of
%% 1 to 64 legs.
-module(chappe_mix_dsp_l16_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FRAME, 320).

%% Legs are {Pcm | none, Muted}; per leg, its payload or none.
reference(Legs) ->
    [
        case X of
            none -> none;
            _ -> <<<<S:16/big-signed>> || S <- scaled(X)>>
        end
     || X <- signals(Legs)
    ].

signals(Legs) ->
    Pcms = [{pcm(P), Muted} || {P, Muted} <- Legs],
    case [P || {P, false} <- Pcms, P =/= none] of
        [] ->
            [none || _ <- Legs];
        [T | Ts] ->
            Sum = lists:foldl(fun add/2, T, Ts),
            [
                case {P, Muted} of
                    {none, _} -> Sum;
                    {_, true} -> Sum;
                    _ -> lists:zipwith(fun(X, Y) -> X - Y end, Sum, P)
                end
             || {P, Muted} <- Pcms
            ]
    end.

add(A, B) -> lists:zipwith(fun(X, Y) -> X + Y end, A, B).

pcm(none) ->
    none;
pcm(Bin) ->
    S = [X || <<X:16/big-signed>> <= Bin],
    S ++ lists:duplicate(?FRAME - length(S), 0).

scaled(X) ->
    case lists:max([abs(S) || S <- X]) of
        Peak when Peak =< 32767 -> X;
        Peak -> [max(-32768, min(32767, round(S * (32767 / Peak)))) || S <- X]
    end.

%% The legs through chappe_mix_dsp at 16 kHz, as chappe_mix_room drives
%% it, every gain at unity.
dsp(Legs) ->
    Sum = lists:foldl(
        fun
            ({P, false}, Acc) when P =/= none ->
                chappe_mix_dsp:add(Acc, l16, P);
            (_, Acc) ->
                Acc
        end,
        chappe_mix_dsp:new(?FRAME),
        Legs
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    [
        element(1, chappe_mix_dsp:encode(Mixed, l16, own(P, Muted), 1.0))
     || {P, Muted} <- Legs
    ].

own(_P, true) -> none;
own(none, _) -> none;
own(P, false) -> {l16, P}.

%% Seeded rooms of 1 to 64 legs: muted legs, legs with nothing to play,
%% frames of 10, 20 and 30 ms cut to 20 (as the jitter buffer hands
%% them), quiet rooms that stay at unity and loud ones that clip.
same_as_reference_test_() ->
    [
        ?_test(begin
            rand:seed(exsss, {Seed, 16, 0}),
            [check(room()) || _ <- lists:seq(1, 30)]
        end)
     || Seed <- lists:seq(1, 8)
    ].

check(Legs) ->
    ?assertEqual(reference(Legs), dsp(Legs)).

room() ->
    N = rand:uniform(64),
    Amp =
        case rand:uniform(3) of
            1 -> 32767;
            _ -> 32767 div N
        end,
    [leg(Amp) || _ <- lists:seq(1, N)].

leg(Amp) ->
    P =
        case rand:uniform(6) of
            1 ->
                none;
            _ ->
                Len = lists:nth(rand:uniform(2), [160, 320]),
                <<
                    <<(rand:uniform(2 * Amp + 1) - Amp - 1):16/big-signed>>
                 || _ <- lists:seq(1, Len)
                >>
        end,
    {P, rand:uniform(5) =:= 1}.

%% Two talkers, one listener: what each hears is the other, sample for
%% sample, big-endian; the listener hears both.
two_talkers_test() ->
    A = [1, -2, 300, -32768, 32767 | lists:duplicate(315, 7)],
    B = [256, 1, -1, 0, 0 | lists:duplicate(315, -3)],
    Enc = fun(Xs) -> <<<<X:16/big-signed>> || X <- Xs>> end,
    [OutA, OutB, OutL] = dsp([{Enc(A), false}, {Enc(B), false}, {none, false}]),
    ?assertEqual(Enc(B), OutA),
    ?assertEqual(Enc(A), OutB),
    ?assertEqual(Enc(lists:zipwith(fun(X, Y) -> X + Y end, A, B)), OutL).

%% A listener kept from hearing a second talker: encode/4 takes the list
%% of frames to leave out, at 16 kHz too.
several_left_out_test() ->
    rand:seed(exsss, {16, 3, 1}),
    Legs = [
        <<
            <<(rand:uniform(4001) - 2001):16/big-signed>>
         || _ <- lists:seq(1, 320)
        >>
     || _ <- lists:seq(1, 5)
    ],
    Sum = chappe_mix_dsp:mixed(
        lists:foldl(
            fun(P, Acc) -> chappe_mix_dsp:add(Acc, l16, P) end,
            chappe_mix_dsp:new(?FRAME),
            Legs
        )
    ),
    [
        ?assertEqual(
            hd(
                reference([
                    {none, false} | lists:nthtail(K, [{P, false} || P <- Legs])
                ])
            ),
            element(
                1,
                chappe_mix_dsp:encode(
                    Sum, l16, [{l16, P} || P <- lists:sublist(Legs, K)], 1.0
                )
            )
        )
     || K <- lists:seq(0, 4)
    ].

%% Nobody talks: none, and the room's PCM is 640 bytes of zeros.
silence_test() ->
    Mixed = chappe_mix_dsp:mixed(chappe_mix_dsp:new(?FRAME)),
    ?assertEqual({none, 1.0}, chappe_mix_dsp:encode(Mixed, l16, none, 1.0)),
    ?assertEqual(<<0:(640 * 8)>>, chappe_mix_dsp:pcm(Mixed, ?FRAME)).

%% The room's PCM is little-endian, the sum of the talkers, clipped.
pcm_test() ->
    A = <<<<I:16/big-signed>> || I <- lists:seq(1, 320)>>,
    B = <<<<(-2 * I):16/big-signed>> || I <- lists:seq(1, 320)>>,
    Mixed = chappe_mix_dsp:mixed(
        chappe_mix_dsp:add(
            chappe_mix_dsp:add(chappe_mix_dsp:new(?FRAME), l16, A), l16, B
        )
    ),
    Pcm = chappe_mix_dsp:pcm(Mixed, ?FRAME),
    ?assertEqual(640, byte_size(Pcm)),
    ?assertEqual([-I || I <- lists:seq(1, 320)], [
        S
     || <<S:16/little-signed>> <= Pcm
    ]).

%% The energy add_level/3 returns is the sum of the squared samples.
level_test() ->
    P = <<<<(I - 160):16/big-signed>> || I <- lists:seq(1, 320)>>,
    {_, E} = chappe_mix_dsp:add_level(chappe_mix_dsp:new(?FRAME), l16, P),
    ?assertEqual(
        lists:sum([(I - 160) * (I - 160) || I <- lists:seq(1, 320)]), E
    ).

%% The gain control at 16 kHz: a loud room is scaled, never clipped, and
%% the gain comes back to unity by the release step once it is quiet.
gain_test() ->
    Loud = <<
        <<
            (case I rem 2 of
                0 -> 30000;
                1 -> -30000
            end):16/big-signed
        >>
     || I <- lists:seq(1, 320)
    >>,
    Legs = [{Loud, false} || _ <- lists:seq(1, 4)] ++ [{none, false}],
    Sum = lists:foldl(
        fun
            ({P, _}, Acc) when P =/= none -> chappe_mix_dsp:add(Acc, l16, P);
            (_, Acc) -> Acc
        end,
        chappe_mix_dsp:new(?FRAME),
        Legs
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    {Out, G} = chappe_mix_dsp:encode(Mixed, l16, none, 1.0),
    ?assert(G < 0.3, G),
    Xs = [X || <<X:16/big-signed>> <= Out],
    ?assertEqual(320, length(Xs)),
    ?assert(lists:max([abs(X) || X <- Xs]) =< 32767),
    ?assert(lists:max([abs(X) || X <- Xs]) > 32000),
    Quiet = chappe_mix_dsp:mixed(
        chappe_mix_dsp:add(
            chappe_mix_dsp:new(?FRAME), l16, <<1000:16, 0:(319 * 16)>>
        )
    ),
    Back = lists:foldl(
        fun(_, Gain) ->
            element(2, chappe_mix_dsp:encode(Quiet, l16, none, Gain))
        end,
        G,
        lists:seq(1, 300)
    ),
    ?assertEqual(1.0, Back).
