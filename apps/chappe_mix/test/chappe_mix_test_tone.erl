%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Test endpoints for the mixer: a sender that streams a pure tone as
%% PCMU RTP on a 20 ms clock, a receiver that collects what comes back,
%% and a Goertzel detector that says how loud each tone is in it. The
%% band check (band_probe/1, band_check/2,3, band_shape/2 through a
%% codec) tells a 16 kHz path from one that went through 8 kHz on the
%% way; band_energy/3 does the same for speech.
-module(chappe_mix_test_tone).

-export([
    endpoint/1,
    stop/1,
    samples/1,
    rate/1,
    frames/1,
    gaps/2,
    weak_frames/3,
    clear/1,
    levels/2,
    tone/3,
    hears/3,
    windows/2
]).
-export([levels/3, tone/4, weak_frames/4, hears/4]).
-export([law_pt/1, encode/2, decode/2]).
-export([band_probe/1, band_calibrate/1, band_check/2, band_check/3]).
-export([band_shape/2, band_energy/3]).
-export([power/3]).

%% the default sample rate of every helper; the rate option or argument
%% changes it
-define(RATE, 8000).

%% the band check: Goertzel at 16 kHz over 200 ms windows
-define(BAND_RATE, 16000).
-define(BAND_WINDOW, 3200).
-define(BAND_TONES, [1000, 2500, 5000, 6000]).
%% where 6000 and 5000 Hz fold when a path drops to 8 kHz
-define(BAND_ALIASES, [2000, 3000]).
-define(BAND_AMP, 5000).

%% Start an endpoint: a process owning one UDP socket that sends Freq
%% (or nothing, with freq => none) to Dst every ptime ms and records what
%% it receives. Opts: #{freq, dst, amp, loss (0.0..1.0), ssrc_switch_after
%% (packets), ip (bind address, default loopback), law (ulaw | alaw |
%% l16, both ways, default ulaw; l16 is RFC 3551 L16, 16-bit big-endian),
%% pt (payload type, default 0, 8 or 96 by law), rate (sample rate and
%% RTP clock, default 8000), ptime (ms per packet sent, default 20),
%% signal (a tuple of samples played in a loop in place of the tone; Pid !
%% {signal, Sig} changes it, a tuple of zeros for silence)}. Only
%% packets carrying the payload type are recorded, so comfort noise or
%% telephone-event from a real peer is not decoded as audio. Returns
%% {Pid, LocalPort}.
endpoint(Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Opts) end),
    receive
        {Pid, port, Port} -> {Pid, Port}
    after 2000 -> error(endpoint_start)
    end.

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

%% The endpoint's sample rate (its rate option).
rate(Pid) ->
    Pid ! {rate, self()},
    receive
        {Pid, rate, R} -> R
    after 2000 -> error(endpoint_rate)
    end.

%% Decoded samples received so far, in arrival order.
samples(Pid) ->
    Pid ! {samples, self()},
    receive
        {Pid, samples, S} -> S
    after 2000 -> error(endpoint_samples)
    end.

%% Decoded samples received so far, one list per packet.
frames(Pid) ->
    Pid ! {frames, self()},
    receive
        {Pid, frames, F} -> F
    after 2000 -> error(endpoint_frames)
    end.

%% How many of Frames hold a run of at least Run samples of silence (0):
%% a gap the mixer played inside a frame.
gaps(Frames, Run) ->
    length([F || F <- Frames, longest_zero_run(F, 0, 0) >= Run]).

longest_zero_run([], Cur, Max) -> max(Cur, Max);
longest_zero_run([0 | T], Cur, Max) -> longest_zero_run(T, Cur + 1, Max);
longest_zero_run([_ | T], Cur, Max) -> longest_zero_run(T, 0, max(Cur, Max)).

%% How many of Frames carry Freq below Db dBFS: a 20 ms frame where a
%% steady tone was cut or half missing.
weak_frames(Frames, Freq, Db) ->
    weak_frames(Frames, Freq, Db, ?RATE).

weak_frames(Frames, Freq, Db, Rate) ->
    length([F || F <- Frames, level(F, length(F), Freq, Rate) < Db]).

clear(Pid) ->
    Pid ! clear,
    ok.

%% Level of each frequency in Samples, in dB relative to full scale.
levels(Samples, Freqs) ->
    levels(Samples, Freqs, ?RATE).

levels(Samples, Freqs, Rate) ->
    N = length(Samples),
    [{F, level(Samples, N, F, Rate)} || F <- Freqs].

tone(Freq, Amp, N) ->
    tone(Freq, Amp, N, ?RATE).

tone(Freq, Amp, N, Rate) ->
    [
        round(Amp * math:sin(2 * math:pi() * Freq * I / Rate))
     || I <- lists:seq(0, N - 1)
    ].

%% ---- endpoint process ----

init(Parent, Opts) ->
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    {ok, Sock} = gen_udp:open(0, [binary, {ip, Ip}, {active, true}]),
    {ok, Port} = inet:port(Sock),
    Parent ! {self(), port, Port},
    Law = maps:get(law, Opts, ulaw),
    S = #{
        sock => Sock,
        dst => maps:get(dst, Opts, undefined),
        freq => maps:get(freq, Opts, none),
        amp => maps:get(amp, Opts, 6000),
        loss => maps:get(loss, Opts, 0.0),
        law => Law,
        pt => maps:get(pt, Opts, law_pt(Law)),
        rate => maps:get(rate, Opts, ?RATE),
        ptime => maps:get(ptime, Opts, 20),
        switch => maps:get(ssrc_switch_after, Opts, infinity),
        ssrc => rand:uniform(16#FFFFFFF),
        seq => rand:uniform(60000),
        n => 0,
        next => erlang:monotonic_time(millisecond),
        rx => []
    },
    self() ! tick,
    loop(S).

loop(S) ->
    receive
        tick ->
            S1 = send_frame(S),
            Next = maps:get(next, S1) + maps:get(ptime, S1),
            erlang:send_after(Next, self(), tick, [{abs, true}]),
            loop(S1#{next => Next});
        {udp, _Sock, _Ip, _Port, Pkt} ->
            PT = maps:get(pt, S),
            case chappe_mix_rtp:parse(Pkt) of
                {ok, #{pt := PT, payload := P}} ->
                    loop(S#{rx => [P | maps:get(rx, S)]});
                _ ->
                    loop(S)
            end;
        {samples, From} ->
            Frames = lists:reverse(maps:get(rx, S)),
            From !
                {
                    self(),
                    samples,
                    lists:append([decode(maps:get(law, S), F) || F <- Frames])
                },
            loop(S);
        {frames, From} ->
            Law = maps:get(law, S),
            From !
                {self(), frames, [
                    decode(Law, F)
                 || F <- lists:reverse(maps:get(rx, S))
                ]},
            loop(S);
        {rate, From} ->
            From ! {self(), rate, maps:get(rate, S)},
            loop(S);
        clear ->
            loop(S#{rx => []});
        {dst, Dst} ->
            loop(S#{dst => Dst});
        {signal, Sig} ->
            loop(S#{signal => Sig})
    end.

send_frame(#{dst := undefined} = S) ->
    S;
send_frame(#{freq := none} = S) ->
    S;
send_frame(#{n := N, switch := Switch} = S0) ->
    S =
        case N =:= Switch of
            true -> S0#{ssrc => rand:uniform(16#FFFFFFF), seq => 1};
            false -> S0
        end,
    #{sock := Sock, dst := {Ip, Port}, freq := F, amp := A, seq := Seq} = S,
    Rate = maps:get(rate, S),
    Frame = maps:get(ptime, S) * Rate div 1000,
    Samples =
        case maps:get(signal, S, undefined) of
            undefined ->
                [
                    round(A * math:sin(2 * math:pi() * F * I / Rate))
                 || I <- lists:seq(N * Frame, N * Frame + Frame - 1)
                ];
            Sig ->
                [
                    element(I rem tuple_size(Sig) + 1, Sig)
                 || I <- lists:seq(N * Frame, N * Frame + Frame - 1)
                ]
        end,
    Law = maps:get(law, S),
    Pkt = chappe_mix_rtp:build(#{
        pt => maps:get(pt, S),
        seq => Seq band 16#FFFF,
        ts => (N * Frame) band 16#FFFFFFFF,
        ssrc => maps:get(ssrc, S),
        marker => N =:= 0,
        payload => encode(Law, Samples)
    }),
    case rand:uniform() < maps:get(loss, S) of
        true -> ok;
        false -> gen_udp:send(Sock, Ip, Port, Pkt)
    end,
    S#{n => N + 1, seq => Seq + 1}.

%% The payload type, encoder and decoder of each law the endpoints and
%% chappe_mix_probe speak: G.711 through chappe_mix_g711, l16 as RFC 3551
%% L16 (16-bit big-endian) on a dynamic type.
law_pt(ulaw) -> 0;
law_pt(alaw) -> 8;
law_pt(l16) -> 96.

encode(l16, Samples) -> <<<<X:16/big-signed>> || X <- Samples>>;
encode(Law, Samples) -> chappe_mix_g711:encode_frame(Law, Samples).

decode(l16, P) -> [X || <<X:16/big-signed>> <= P];
decode(Law, P) -> chappe_mix_g711:decode_frame(Law, P).

%% ---- judging what an endpoint heard ----

%% Judge what Pid heard, per 200 ms window. A tone that must be absent is
%% absent in every window: that is the N-1 contract, and no load excuses a
%% leak. A tone that must be present is present in at least 70% of the
%% windows: a loaded host stalls the test senders (bare 20 ms timers woke
%% 164 ms late at a load average of 34), and a stalled sender is a gap,
%% not a wrong mix. Present means within 3 dB of a 6000-amplitude tone
%% (Present dBFS), absent means 40 dB below it (Absent dBFS). Returns
%% {ok, Windows} or {error, Reason, Windows}, at the endpoint's own rate
%% (its rate option); hears/4 takes the rate to judge at.
hears(Pid, Dbs, Tones) ->
    hears(Pid, Dbs, Tones, rate(Pid)).

hears(Pid, {PresentDb, AbsentDb}, {Present, Absent}, Rate) ->
    Samples = samples(Pid),
    Windows = [
        levels(W, Present ++ Absent, Rate)
     || W <- windows(Samples, Rate div 5)
    ],
    Leaks = [
        {leaked, F, L}
     || Levels <- Windows,
        {F, L} <- Levels,
        lists:member(F, Absent),
        L >= AbsentDb
    ],
    Missing = [
        {missing, F, heard(F, PresentDb, Windows), length(Windows)}
     || F <- Present, heard(F, PresentDb, Windows) < 0.7 * length(Windows)
    ],
    case {length(Samples) >= Rate div 2, Leaks, Missing} of
        {false, _, _} -> {error, {too_few_samples, length(Samples)}, Windows};
        {true, [], []} -> {ok, Windows};
        {true, [L | _], _} -> {error, L, Windows};
        {true, [], [M | _]} -> {error, M, Windows}
    end.

heard(F, PresentDb, Windows) ->
    length([ok || Levels <- Windows, {G, L} <- Levels, G =:= F, L > PresentDb]).

windows(Samples, N) when length(Samples) >= N ->
    {W, Rest} = lists:split(N, Samples),
    [W | windows(Rest, N)];
windows(_, _) ->
    [].

%% ---- band check ----

%% Ms of the 16 kHz probe: 1000 and 2500 Hz (the narrow band), 5000 and
%% 6000 Hz (above it), 5000 of amplitude each. Every tone is a whole
%% number of cycles in a 3200-sample window, so the bins do not leak into
%% each other.
band_probe(Ms) ->
    [
        round(
            lists:sum([
                ?BAND_AMP * math:sin(2 * math:pi() * F * I / ?BAND_RATE)
             || F <- ?BAND_TONES
            ])
        )
     || I <- lists:seq(0, Ms * ?BAND_RATE div 1000 - 1)
    ].

%% The level of each probe tone in Samples (16 kHz): what band_check/2
%% compares against. Calibrate on what the path is fed, or on the same
%% path at a known-good setting. A tone more than 10 dB below what the
%% probe sends raises {bad_calibration, Freq, Level}: a calibration taken
%% on a narrowband path would make every level check pass.
band_calibrate(Samples) ->
    Nominal = 20 * math:log10(?BAND_AMP / 32768),
    Levels = band_levels(Samples, ?BAND_TONES),
    case [{F, L} || {F, L} <- Levels, L < Nominal - 10.0] of
        [] -> maps:from_list(Levels);
        [{F, L} | _] -> erlang:error({bad_calibration, F, L})
    end.

band_check(Samples, Cal) ->
    band_check(Samples, Cal, #{}).

%% Whether Samples (16 kHz) carry the probe across the whole band: each
%% tone within tolerance dB of Cal (default 3.0; take 6.0 through a
%% codec), and the alias bins (2000, 3000 Hz) alias_db below the quietest
%% calibrated tone (default 40.0). Levels are the median over 200 ms
%% windows, so a glitch in one window does not decide. Returns ok or
%% {error, Faults}: {level, Freq, Got, Want}, {alias, Freq, Got, Limit},
%% {too_short, Samples}.
band_check(Samples, Cal, Opts) ->
    Tol = maps:get(tolerance, Opts, 3.0),
    Down = maps:get(alias_db, Opts, 40.0),
    case length(Samples) < ?BAND_WINDOW of
        true ->
            {error, [{too_short, length(Samples)}]};
        false ->
            Got = maps:from_list(
                band_levels(Samples, ?BAND_TONES ++ ?BAND_ALIASES)
            ),
            Limit = lists:min(maps:values(Cal)) - Down,
            Faults =
                [
                    {level, F, G, W}
                 || {F, W} <- lists:sort(maps:to_list(Cal)),
                    G <- [maps:get(F, Got)],
                    abs(G - W) > Tol
                ] ++
                    [
                        {alias, F, G, Limit}
                     || F <- ?BAND_ALIASES,
                        G <- [maps:get(F, Got)],
                        G > Limit
                    ],
            case Faults of
                [] -> ok;
                _ -> {error, Faults}
            end
    end.

%% The band check on the shape of the band, not on the path's gain, for
%% a probe that went through a caller's codec: the codec may move the
%% whole probe a few dB (pjsua's G.722 path comes 6 dB down), so Cal
%% moves by what 1000 Hz, which any 8 kHz path keeps, lost on the way;
%% then every tone within 3 dB of it, and the alias bins 30 dB below the
%% quietest tone. 30 dB, not 40, because G.722's QMF bank folds 5000 and
%% 6000 Hz onto them at about 60 dB down; a careless drop to 8 kHz folds
%% them within a few dB of full level. Returns ok or {error, Faults}:
%% band_check/3's, or {missing, Freq, Level} for a tone 10 dB down or
%% more (the path lost the band).
band_shape(Samples, Cal) ->
    case length(Samples) >= ?BAND_WINDOW of
        false ->
            {error, [{too_short, length(Samples)}]};
        true ->
            try band_calibrate(Samples) of
                #{1000 := Got} ->
                    Gain = Got - maps:get(1000, Cal),
                    ct:log("path gain at 1000 Hz: ~.1f dB", [Gain]),
                    Shifted = maps:map(fun(_, L) -> L + Gain end, Cal),
                    band_check(Samples, Shifted, #{
                        tolerance => 3.0, alias_db => 30.0
                    })
            catch
                error:{bad_calibration, F, L} -> {error, [{missing, F, L}]}
            end
    end.

%% The energy of Samples (at Rate) from Lo to Hi Hz, in dB: the DFT bins
%% of the band, one every 50 Hz over 20 ms frames, summed over every
%% frame. It measures a band of speech, whose harmonics fall anywhere,
%% where levels/3 measures a tone. Compare two bands of one capture; the
%% absolute value depends on the frame length.
band_energy(Samples, {Lo, Hi}, Rate) ->
    Bins = lists:seq(Lo, Hi, 50),
    P = lists:sum([
        power(W, F, Rate)
     || W <- windows(Samples, Rate div 50), F <- Bins
    ]),
    10 * math:log10(max(P, 1.0e-12)).

band_levels(Samples, Freqs) ->
    Windows = [
        levels(W, Freqs, ?BAND_RATE)
     || W <- windows(Samples, ?BAND_WINDOW)
    ],
    [{F, median([L || Ls <- Windows, {G, L} <- Ls, G =:= F])} || F <- Freqs].

median(L) ->
    lists:nth((length(L) + 1) div 2, lists:sort(L)).

%% ---- Goertzel ----

%% The Goertzel power of Samples (at Rate) in the bin of F: the one
%% detector the chappe_mix test helpers share.
power(Samples, F, Rate) ->
    Coeff = 2 * math:cos(2 * math:pi() * F / Rate),
    {S1, S2} = lists:foldl(
        fun(X, {P1, P2}) -> {X + Coeff * P1 - P2, P1} end, {0.0, 0.0}, Samples
    ),
    S1 * S1 + S2 * S2 - Coeff * S1 * S2.

level(_Samples, 0, _F, _Rate) ->
    -200.0;
level(Samples, N, F, Rate) ->
    Power = power(Samples, F, Rate),
    %% amplitude of the component, relative to 16-bit full scale
    Amp = 2 * math:sqrt(max(Power, 0.0)) / N,
    20 * math:log10(max(Amp, 1.0e-9) / 32768).
