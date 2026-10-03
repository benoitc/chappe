%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mix against the reference, FreeSWITCH mod_conference, fed the
%% same tones and judged by the same Goertzel code. Skipped unless
%% FREESWITCH_HOST is set; see chappe_mix_ref for the environment.
%% `make interop-ref' (apps/chappe_mix/test/ref.sh suite) brings
%% FreeSWITCH up from apps/chappe_mix/interop/freeswitch, runs this suite
%% and tears it down.
%%
%% Timing is logged, never asserted here: a loaded box voids any latency.
%% The bench arm ref_latency is where latency is compared.
-module(chappe_mix_ref_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    reference_n_minus_one/1,
    same_detection_as_reference/1,
    thirty_ms_same_detection/1,
    burst_latency_logged/1
]).

%% Clear of mod_conference's stock enter tone (500, 600 and 700 Hz), in
%% case a FreeSWITCH other than the harness's plays it: a 500 Hz burst
%% reads about -50 dBFS in a 440 Hz Goertzel bin, a leak by this judge.
-define(F, [1100, 1700, 2300]).
-define(PRESENT, -18.0).
-define(ABSENT, -54.7).

all() ->
    [
        reference_n_minus_one,
        same_detection_as_reference,
        thirty_ms_same_detection,
        burst_latency_logged
    ].

init_per_suite(Config) ->
    case chappe_mix_ref:env() of
        {skip, _} = Skip ->
            Skip;
        {ok, Env} ->
            {ok, _} = application:ensure_all_started(chappe_mix),
            [{env, Env} | Config]
    end.

end_per_suite(_Config) ->
    _ = application:stop(chappe_mix),
    ok.

%% The reference itself passes the N-1 contract as this suite judges it;
%% otherwise nothing it says about chappe_mix means anything.
reference_n_minus_one(Config) ->
    Matrix = detect(fs, ?config(env, Config)),
    ct:log("mod_conference: ~p", [Matrix]),
    ?assertEqual(expected(), verdicts(Matrix)).

%% Each receiver detects the same tones through chappe_mix as through
%% mod_conference, and each own tone is gone in both.
same_detection_as_reference(Config) ->
    Env = ?config(env, Config),
    Mix = detect(chappe, Env),
    Ref = detect(fs, Env),
    ct:log("chappe_mix: ~p~nmod_conference: ~p", [Mix, Ref]),
    ct:log("own tone, loudest window (dBFS): chappe_mix ~p, reference ~p", [
        own_max(Mix), own_max(Ref)
    ]),
    ?assertEqual(verdicts(Ref), verdicts(Mix)),
    ?assertEqual(expected(), verdicts(Mix)).

%% The 1100 Hz party sends 30 ms packets to both mixers. Each receiver
%% detects the same tones through chappe_mix as through mod_conference,
%% and the 30 ms party's tone is in its 20 ms frames as often as the
%% reference keeps it there (or misses it in at most one frame in fifty).
thirty_ms_same_detection(Config) ->
    Env = ?config(env, Config),
    Spec = [{1100, 30}, 1700, 2300],
    {Mix, MixWeak} = detect(chappe, Env, Spec),
    {Ref, RefWeak} = detect(fs, Env, Spec),
    ct:log("chappe_mix: ~p~nmod_conference: ~p", [Mix, Ref]),
    ct:log("frames short of 1100 Hz: chappe_mix ~p, reference ~p", [
        MixWeak, RefWeak
    ]),
    ?assertEqual(verdicts(Ref), verdicts(Mix)),
    ?assertEqual(expected(), verdicts(Mix)),
    [
        ?assert(W =< max(RW, N div 50), {weak, F, W, RW, N})
     || {{F, W, N}, {F, RW, _}} <- lists:zip(MixWeak, RefWeak)
    ].

%% Tone bursts from A reach B through both mixers. The numbers go to the
%% log for the record; only that most bursts arrive is asserted.
burst_latency_logged(Config) ->
    Env = ?config(env, Config),
    Opts = #{bursts => 20},
    Mix = chappe_mix_ref:latency(chappe, Env, Opts),
    Ref = chappe_mix_ref:latency(fs, Env, Opts),
    [
        ct:log(
            "~s: p50 ~p us, p99 ~p us, missed ~p, all ~p",
            [
                Name,
                chappe_mix_probe:percentile(L, 50),
                chappe_mix_probe:percentile(L, 99),
                M,
                L
            ]
        )
     || {Name, #{latencies_us := L, missed := M}} <- [
            {"chappe_mix", Mix}, {"mod_conference", Ref}
        ]
    ],
    [
        ?assert(length(L) >= 10, {bursts_lost, Name, R})
     || {Name, #{latencies_us := L} = R} <- [{chappe, Mix}, {fs, Ref}]
    ],
    ok.

%% ---- helpers ----

%% For each receiver: its frequency, the judge's verdict, and the levels.
detect(Mixer, Env) ->
    {Res, _} = detect(Mixer, Env, ?F),
    Res.

%% The same with some parties sending another packet time, given as
%% {Freq, Ptime}; also, for every other receiver, how many of its frames
%% are short of the first such party's tone.
detect(Mixer, Env, Spec) ->
    H = chappe_mix_ref:parties(Mixer, Env, Spec),
    Eps = eps(H),
    %% a stock mod_conference plays enter tones, and a loaded one can
    %% take seconds to start mixing. Wait
    %% for the steady state, two polls in a row where every receiver's
    %% last 200 ms shows the contract, before recording. A mixer that
    %% leaks for good never gets there and is judged after 15 s anyway.
    Waited = steady(Eps, erlang:monotonic_time(millisecond) + 15000),
    ct:log("~p steady after ~p ms", [Mixer, Waited]),
    [chappe_mix_test_tone:clear(P) || {P, _, _} <- Eps],
    timer:sleep(2000),
    Res = [
        {F,
            chappe_mix_test_tone:hears(
                P, {?PRESENT, ?ABSENT}, {?F -- [F], [F]}
            )}
     || {P, _, F} <- Eps
    ],
    Weak = [
        {F, chappe_mix_test_tone:weak_frames(Fs, Odd, ?PRESENT), length(Fs)}
     || {Odd, _} <- lists:sublist([S || {_, _} = S <- Spec], 1),
        {P, _, F} <- Eps,
        F =/= Odd,
        Fs <- [chappe_mix_test_tone:frames(P)]
    ],
    case H of
        {chappe, Conf, _} ->
            ct:log("chappe_mix legs: ~p", [chappe_mix:legs(Conf)]);
        _ ->
            ok
    end,
    chappe_mix_ref:close(H),
    {Res, Weak}.

steady(Eps, Deadline) ->
    Start = erlang:monotonic_time(millisecond),
    steady(Eps, Start, Deadline, 0).

steady(Eps, Start, Deadline, Good) ->
    timer:sleep(200),
    Now = erlang:monotonic_time(millisecond),
    Good1 =
        case lists:all(fun(E) -> last_window_ok(E) end, Eps) of
            true -> Good + 1;
            false -> 0
        end,
    case Good1 >= 2 orelse Now > Deadline of
        true -> Now - Start;
        false -> steady(Eps, Start, Deadline, Good1)
    end.

last_window_ok({P, _, F}) ->
    S = chappe_mix_test_tone:samples(P),
    N = length(S),
    case N >= 1600 of
        false ->
            false;
        true ->
            W = lists:nthtail(N - 1600, S),
            [{F, Own} | Others] = chappe_mix_test_tone:levels(W, [F | ?F -- [F]]),
            Own < ?ABSENT andalso
                lists:all(fun({_, L}) -> L > ?PRESENT end, Others)
    end.

eps({fs, Eps}) -> Eps;
eps({chappe, _Conf, Eps}) -> Eps.

verdicts(Matrix) ->
    [{F, verdict(R)} || {F, R} <- Matrix].

verdict({ok, _}) -> ok;
verdict({error, {Kind, Freq, _}, _}) -> {Kind, Freq};
verdict({error, {Kind, Freq, _, _}, _}) -> {Kind, Freq};
verdict({error, Other, _}) -> Other.

expected() ->
    [{F, ok} || F <- ?F].

own_max(Matrix) ->
    [
        {F, lists:max([-200.0 | [L || Ls <- Ws, {G, L} <- Ls, G =:= F]])}
     || {F, R} <- Matrix, Ws <- [windows(R)]
    ].

windows({ok, W}) -> W;
windows({error, _, W}) -> W.
