%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The band check of chappe_mix_test_tone: a 16 kHz probe (1000 and
%% 2500 Hz in the narrow band, 5000 and 6000 Hz above it) must come back
%% with each tone near its calibrated level and nothing in the bins the
%% high tones fold onto when a path drops to 8 kHz (2000 and 3000 Hz).
%% The identity path passes; two narrowband round trips must fail it, or
%% the check could not tell a wideband path from a narrowband one.
-module(chappe_mix_band_tests).

-include_lib("eunit/include/eunit.hrl").

-define(RATE, 16000).

probe() ->
    chappe_mix_test_tone:band_probe(600).

identity_passes_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    ?assertEqual(ok, chappe_mix_test_tone:band_check(P, Cal)),
    ?assertEqual(
        ok, chappe_mix_test_tone:band_check(P, Cal, #{tolerance => 6.0})
    ).

calibration_reads_the_four_tones_test() ->
    Cal = chappe_mix_test_tone:band_calibrate(probe()),
    ?assertEqual([1000, 2500, 5000, 6000], lists:sort(maps:keys(Cal))),
    %% each tone has amplitude 5000: 20 log10(5000 / 32768)
    [
        ?assert(abs(L - 20 * math:log10(5000 / 32768)) < 0.1)
     || L <- maps:values(Cal)
    ].

%% A path 4 dB quieter in every band: inside the codec tolerance, outside
%% the plain one.
tolerance_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    Quiet = [round(X * 0.63) || X <- P],
    ?assertEqual(
        ok, chappe_mix_test_tone:band_check(Quiet, Cal, #{tolerance => 6.0})
    ),
    {error, Faults} = chappe_mix_test_tone:band_check(Quiet, Cal),
    ?assertEqual(
        [1000, 2500, 5000, 6000], lists:sort([F || {level, F, _, _} <- Faults])
    ).

%% (a) A correct narrowband path: low-pass at 3.4 kHz, decimate to 8 kHz,
%% upsample and low-pass again. The low band survives, the high band is
%% gone, nothing folds.
filtered_round_trip_fails_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    Out = filtered_round_trip(P),
    [
        begin
            {error, Faults} =
                chappe_mix_test_tone:band_check(Out, Cal, #{tolerance => Tol}),
            ?assertEqual([5000, 6000], lists:sort(levels(Faults))),
            ?assertEqual([], aliases(Faults))
        end
     || Tol <- [3.0, 6.0]
    ].

%% Calibrating on a narrowband capture would make every level check pass
%% vacuously: band_calibrate/1 refuses a tone far below what the probe
%% sends.
calibration_refuses_narrowband_test() ->
    Out = filtered_round_trip(probe()),
    ?assertError(
        {bad_calibration, 5000, _},
        chappe_mix_test_tone:band_calibrate(Out)
    ).

%% (b) A careless one: drop every other sample, hold each one twice. The
%% high tones fold to 3000 and 2000 Hz; even with the codec tolerance the
%% alias bins give it away.
naive_decimation_fails_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    Out = naive_round_trip(P),
    [
        begin
            {error, Faults} =
                chappe_mix_test_tone:band_check(Out, Cal, #{tolerance => Tol}),
            ?assertEqual([2000, 3000], lists:sort(aliases(Faults)))
        end
     || Tol <- [3.0, 6.0]
    ].

%% The live G.722 paths take a 30 dB alias limit (G.722's QMF bank folds
%% 5000 and 6000 Hz onto 3000 and 2000 Hz, about 60 dB down): careless
%% decimation folds the tones within a few dB of full level, so it still
%% fails there.
naive_decimation_fails_at_codec_alias_limit_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    {error, Faults} = chappe_mix_test_tone:band_check(
        naive_round_trip(P), Cal, #{tolerance => 6.0, alias_db => 30.0}
    ),
    ?assertEqual([2000, 3000], lists:sort(aliases(Faults))).

%% band_shape/2, for a probe through a caller's codec: a path 6 dB down
%% keeps the shape of the band and passes, where band_check/2 fails it;
%% the narrowband round trip is missing its high tones, and the careless
%% one folds them onto the alias bins.
band_shape_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    Down = [round(X * 0.5) || X <- P],
    ?assertEqual(ok, chappe_mix_test_tone:band_shape(Down, Cal)),
    ?assertMatch({error, _}, chappe_mix_test_tone:band_check(Down, Cal)),
    ?assertMatch(
        {error, [{missing, 5000, _}]},
        chappe_mix_test_tone:band_shape(filtered_round_trip(P), Cal)
    ),
    {error, Faults} = chappe_mix_test_tone:band_shape(naive_round_trip(P), Cal),
    ?assertEqual([2000, 3000], lists:sort(aliases(Faults))),
    ?assertEqual(
        {error, [{too_short, 100}]},
        chappe_mix_test_tone:band_shape(lists:sublist(P, 100), Cal)
    ).

%% band_energy/3 of two tones of one level: the band of each holds the
%% same energy, and a band with neither holds none.
band_energy_test() ->
    [T1, T2] = [
        chappe_mix_test_tone:tone(F, 5000, 8000, ?RATE)
     || F <- [2000, 5000]
    ],
    S = lists:zipwith(fun erlang:'+'/2, T1, T2),
    Low = chappe_mix_test_tone:band_energy(S, {1000, 3000}, ?RATE),
    High = chappe_mix_test_tone:band_energy(S, {4000, 7000}, ?RATE),
    ?assert(abs(High - Low) < 0.5),
    None = chappe_mix_test_tone:band_energy(T1, {4000, 7000}, ?RATE),
    ?assert(Low - None > 60.0).

too_short_test() ->
    P = probe(),
    Cal = chappe_mix_test_tone:band_calibrate(P),
    ?assertMatch(
        {error, [{too_short, 100}]},
        chappe_mix_test_tone:band_check(lists:sublist(P, 100), Cal)
    ).

%% The Goertzel helpers take the sample rate; 8000 stays the default.
rate_option_test() ->
    Want = 20 * math:log10(6000 / 32768),
    T16 = chappe_mix_test_tone:tone(5000, 6000, 3200, ?RATE),
    [{5000, L16}] = chappe_mix_test_tone:levels(T16, [5000], ?RATE),
    ?assert(abs(L16 - Want) < 0.1),
    T8 = chappe_mix_test_tone:tone(1000, 6000, 1600),
    ?assertEqual(T8, chappe_mix_test_tone:tone(1000, 6000, 1600, 8000)),
    ?assertEqual(
        chappe_mix_test_tone:levels(T8, [1000, 3000]),
        chappe_mix_test_tone:levels(T8, [1000, 3000], 8000)
    ).

%% Two endpoints on loopback speaking L16 at 16 kHz: a tone above the
%% narrow band comes through at its level, judged at the endpoints' rate.
l16_endpoints_test() ->
    {Rx, RxPort} = chappe_mix_test_tone:endpoint(#{law => l16, rate => ?RATE}),
    {Tx, _} = chappe_mix_test_tone:endpoint(#{
        freq => 6000, dst => {{127, 0, 0, 1}, RxPort}, law => l16, rate => ?RATE
    }),
    timer:sleep(700),
    chappe_mix_test_tone:stop(Tx),
    Want = 20 * math:log10(6000 / 32768),
    try
        ?assertMatch(
            {ok, _},
            chappe_mix_test_tone:hears(
                Rx, {Want - 3, Want - 40}, {[6000], [2000]}, ?RATE
            )
        ),
        [F | _] = chappe_mix_test_tone:frames(Rx),
        %% 20 ms at 16 kHz
        ?assertEqual(320, length(F))
    after
        chappe_mix_test_tone:stop(Rx)
    end.

levels(Faults) -> [F || {level, F, _, _} <- Faults].
aliases(Faults) -> [F || {alias, F, _, _} <- Faults].

%% ---- the two narrowband paths ----

filtered_round_trip(Xs) ->
    H = lowpass(3400, ?RATE, 127),
    Narrow = every_other(fir(H, Xs)),
    Stuffed = lists:append([[X, 0.0] || X <- Narrow]),
    [clip(2 * Y) || Y <- fir(H, Stuffed)].

naive_round_trip(Xs) ->
    lists:append([[X, X] || X <- every_other(Xs)]).

every_other([A, _ | T]) -> [A | every_other(T)];
every_other(T) -> T.

clip(Y) -> max(-32768, min(32767, round(Y))).

%% Windowed sinc, Blackman window (about 74 dB of stopband), unit gain at
%% DC.
lowpass(Cutoff, Rate, Taps) ->
    M = Taps - 1,
    Fc = Cutoff / Rate,
    H = [tap(I, M, Fc) || I <- lists:seq(0, M)],
    Sum = lists:sum(H),
    [X / Sum || X <- H].

tap(I, M, Fc) ->
    K = I - M / 2,
    Sinc =
        case K == 0 of
            true -> 2 * Fc;
            false -> math:sin(2 * math:pi() * Fc * K) / (math:pi() * K)
        end,
    W =
        0.42 - 0.5 * math:cos(2 * math:pi() * I / M) +
            0.08 * math:cos(4 * math:pi() * I / M),
    Sinc * W.

fir(H, Xs) ->
    T = list_to_tuple(Xs),
    Ht = list_to_tuple(H),
    [
        conv(T, Ht, N, 1, min(tuple_size(Ht), N), 0.0)
     || N <- lists:seq(1, tuple_size(T))
    ].

conv(_T, _Ht, _N, K, Max, Acc) when K > Max ->
    Acc;
conv(T, Ht, N, K, Max, Acc) ->
    conv(T, Ht, N, K + 1, Max, Acc + element(K, Ht) * element(N - K + 1, T)).
