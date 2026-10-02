%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Test endpoints for the mixer: a sender that streams a pure tone as
%% PCMU RTP on a 20 ms clock, a receiver that collects what comes back,
%% and a Goertzel detector that says how loud each tone is in it.
-module(chappe_mix_test_tone).

-export([
    endpoint/1,
    stop/1,
    samples/1,
    frames/1,
    gaps/2,
    weak_frames/3,
    clear/1,
    levels/2,
    tone/3,
    hears/3,
    windows/2
]).

-define(RATE, 8000).

%% Start an endpoint: a process owning one UDP socket that sends Freq
%% (or nothing, with freq => none) to Dst every ptime ms and records what
%% it receives. Opts: #{freq, dst, amp, loss (0.0..1.0), ssrc_switch_after
%% (packets), ip (bind address, default loopback), law (ulaw | alaw, both
%% ways, default ulaw), ptime (ms per packet sent, default 20)}. Only packets carrying the law's payload type are
%% recorded, so comfort noise or telephone-event from a real peer is not
%% decoded as audio. Returns {Pid, LocalPort}.
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
    length([F || F <- Frames, level(F, length(F), Freq) < Db]).

clear(Pid) ->
    Pid ! clear,
    ok.

%% Level of each frequency in Samples, in dB relative to full scale.
levels(Samples, Freqs) ->
    N = length(Samples),
    [{F, level(Samples, N, F)} || F <- Freqs].

tone(Freq, Amp, N) ->
    [
        round(Amp * math:sin(2 * math:pi() * Freq * I / ?RATE))
     || I <- lists:seq(0, N - 1)
    ].

%% ---- endpoint process ----

init(Parent, Opts) ->
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    {ok, Sock} = gen_udp:open(0, [binary, {ip, Ip}, {active, true}]),
    {ok, Port} = inet:port(Sock),
    Parent ! {self(), port, Port},
    S = #{
        sock => Sock,
        dst => maps:get(dst, Opts, undefined),
        freq => maps:get(freq, Opts, none),
        amp => maps:get(amp, Opts, 6000),
        loss => maps:get(loss, Opts, 0.0),
        law => maps:get(law, Opts, ulaw),
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
            PT = law_pt(maps:get(law, S)),
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
                    lists:append([
                        chappe_mix_g711:decode_frame(maps:get(law, S), F)
                     || F <- Frames
                    ])
                },
            loop(S);
        {frames, From} ->
            Law = maps:get(law, S),
            From !
                {self(), frames, [
                    chappe_mix_g711:decode_frame(Law, F)
                 || F <- lists:reverse(maps:get(rx, S))
                ]},
            loop(S);
        clear ->
            loop(S#{rx => []});
        {dst, Dst} ->
            loop(S#{dst => Dst})
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
    Frame = maps:get(ptime, S) * ?RATE div 1000,
    Samples = [
        round(A * math:sin(2 * math:pi() * F * I / ?RATE))
     || I <- lists:seq(N * Frame, N * Frame + Frame - 1)
    ],
    Law = maps:get(law, S),
    Pkt = chappe_mix_rtp:build(#{
        pt => law_pt(Law),
        seq => Seq band 16#FFFF,
        ts => (N * Frame) band 16#FFFFFFFF,
        ssrc => maps:get(ssrc, S),
        marker => N =:= 0,
        payload => chappe_mix_g711:encode_frame(Law, Samples)
    }),
    case rand:uniform() < maps:get(loss, S) of
        true -> ok;
        false -> gen_udp:send(Sock, Ip, Port, Pkt)
    end,
    S#{n => N + 1, seq => Seq + 1}.

law_pt(ulaw) -> 0;
law_pt(alaw) -> 8.

%% ---- judging what an endpoint heard ----

%% Judge what Pid heard, per 200 ms window. A tone that must be absent is
%% absent in every window: that is the N-1 contract, and no load excuses a
%% leak. A tone that must be present is present in at least 70% of the
%% windows: a loaded host stalls the test senders (bare 20 ms timers woke
%% 164 ms late at a load average of 34), and a stalled sender is a gap,
%% not a wrong mix. Present means within 3 dB of a 6000-amplitude tone
%% (Present dBFS), absent means 40 dB below it (Absent dBFS). Returns
%% {ok, Windows} or {error, Reason, Windows}.
hears(Pid, {PresentDb, AbsentDb}, {Present, Absent}) ->
    Samples = samples(Pid),
    Windows = [levels(W, Present ++ Absent) || W <- windows(Samples, 1600)],
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
    case {length(Samples) >= 4000, Leaks, Missing} of
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

%% ---- Goertzel ----

level(_Samples, 0, _F) ->
    -200.0;
level(Samples, N, F) ->
    W = 2 * math:pi() * F / ?RATE,
    Coeff = 2 * math:cos(W),
    {S1, S2} = lists:foldl(
        fun(X, {P1, P2}) -> {X + Coeff * P1 - P2, P1} end, {0.0, 0.0}, Samples
    ),
    Power = S1 * S1 + S2 * S2 - Coeff * S1 * S2,
    %% amplitude of the component, relative to 16-bit full scale
    Amp = 2 * math:sqrt(max(Power, 0.0)) / N,
    20 * math:log10(max(Amp, 1.0e-9) / 32768).
