%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Mouth-to-ear latency through a mixer, for the bench arms and the
%% reference suite. One process owns two RTP sockets, A and B, both
%% joined to the same conference. Every 20 ms both send a frame: silence,
%% except that every `gap' frames A sends a short loud tone burst. The
%% latency of a burst is the time from handing its first frame to A's
%% socket to the first packet arriving on B whose decoded samples are
%% loud and carry that burst's tone. Bursts cycle through three tones so a
%% late copy of the previous burst is not taken for this one (the
%% calibration case caught exactly that on a loaded box). Send and receive are timed by the same process on the same
%% clock, so the number needs no clock sync, and the mixer can run in
%% another node or another host.
-module(chappe_mix_probe).

-export([start/1, run/2, stop/1, percentile/2]).

-define(FRAME, 160).
-define(LOUD, 4000).
%% whole numbers of cycles in a 20 ms frame, so the three are orthogonal
-define(TONES, [700, 1100, 1500]).

%% Opts: ip (bind address, default loopback), law (default ulaw).
%% Returns {Pid, PortA, PortB}.
start(Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Opts) end),
    receive
        {Pid, ports, A, B} -> {Pid, A, B}
    after 5000 -> error(probe_start)
    end.

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

%% Opts: a_dst, b_dst ({Ip, Port} each side sends to), bursts (count),
%% gap (frames between bursts, default 20 = 400 ms), settle (frames of
%% silence before the first burst, default 25), burst_frames (default 1).
%% Returns #{latencies_us := [integer()], missed := integer(),
%% frames := integer(), b_gaps_us := [integer()]}: besides the bursts, the
%% frames each side sent and the gap between consecutive packets arriving
%% on B, every packet of the run, so a caller can judge the mixer's
%% output timing as a receiver sees it.
run(Pid, Opts) ->
    Pid ! {run, self(), Opts},
    Bursts = maps:get(bursts, Opts),
    Gap = maps:get(gap, Opts, 20),
    Settle = maps:get(settle, Opts, 25),
    Ms = (Settle + (Bursts + 1) * Gap) * 20,
    receive
        {Pid, result, R} -> R
    after Ms + 30000 -> error(probe_timeout)
    end.

%% Nearest-rank percentile of a list of numbers, P in 0..100.
percentile([], _P) ->
    undefined;
percentile(L, P) ->
    S = lists:sort(L),
    N = length(S),
    lists:nth(max(1, min(N, ceil(P / 100 * N))), S).

%% ---- process ----

init(Parent, Opts) ->
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    SockOpts = [binary, {ip, Ip}, {active, true}],
    {ok, A} = gen_udp:open(0, SockOpts),
    {ok, B} = gen_udp:open(0, SockOpts),
    {ok, PA} = inet:port(A),
    {ok, PB} = inet:port(B),
    Parent ! {self(), ports, PA, PB},
    Law = maps:get(law, Opts, ulaw),
    idle(#{a => A, b => B, law => Law}).

idle(S) ->
    receive
        {run, From, Opts} ->
            Law = maps:get(law, S),
            Bursts = list_to_tuple([
                chappe_mix_g711:encode_frame(Law, tone(F, 16000))
             || F <- ?TONES
            ]),
            S1 = S#{
                from => From,
                a_dst => maps:get(a_dst, Opts),
                b_dst => maps:get(b_dst, Opts),
                left => maps:get(bursts, Opts),
                gap => maps:get(gap, Opts, 20),
                settle => maps:get(settle, Opts, 25),
                bframes => maps:get(burst_frames, Opts, 1),
                silence => chappe_mix_g711:encode_frame(
                    Law, lists:duplicate(?FRAME, 0)
                ),
                bursts => Bursts,
                k => 0,
                n => 0,
                seq_a => rand:uniform(30000),
                seq_b => rand:uniform(30000),
                ssrc_a => rand:uniform(16#FFFFFFF),
                ssrc_b => rand:uniform(16#FFFFFFF),
                pending => undefined,
                lat => [],
                missed => 0,
                b_last => undefined,
                b_gaps => [],
                next => erlang:monotonic_time(millisecond)
            },
            self() ! tick,
            loop(S1);
        {udp, _, _, _, _} ->
            idle(S)
    end.

loop(S) ->
    receive
        tick ->
            tick(S);
        {udp, Sock, _, _, Pkt} ->
            Now = erlang:monotonic_time(microsecond),
            loop(received(Sock, Pkt, Now, arrival(Sock, Now, S)))
    end.

arrival(Sock, Now, #{b := Sock, b_last := Last, b_gaps := Gaps} = S) ->
    case Last of
        undefined -> S#{b_last => Now};
        _ -> S#{b_last => Now, b_gaps => [Now - Last | Gaps]}
    end;
arrival(_Sock, _Now, S) ->
    S.

tick(#{left := 0, pending := undefined} = S) ->
    finish(S);
tick(#{n := N, settle := Settle, gap := Gap, bframes := BF} = S0) ->
    Phase = N - Settle,
    BurstStart = Phase >= 0 andalso Phase rem Gap =:= 0,
    InBurst = Phase >= 0 andalso Phase rem Gap < BF,
    S1 =
        case BurstStart of
            true -> start_burst(S0);
            false -> S0
        end,
    case maps:get(left, S1) < 0 of
        true ->
            finish(S1#{left => 0});
        false ->
            Payload =
                case InBurst andalso maps:get(pending, S1) =/= undefined of
                    true -> element(burst_idx(S1) + 1, maps:get(bursts, S1));
                    false -> maps:get(silence, S1)
                end,
            S2 = send(a, Payload, S1),
            S3 = send(b, maps:get(silence, S1), S2),
            Next = maps:get(next, S3) + 20,
            erlang:send_after(Next, self(), tick, [{abs, true}]),
            loop(S3#{n => N + 1, next => Next})
    end.

%% A burst still pending when the next one is due was never heard.
start_burst(#{left := 0, pending := undefined} = S) ->
    S#{left => -1};
start_burst(#{left := 0} = S) ->
    S#{left => -1, missed => maps:get(missed, S) + 1, pending => undefined};
start_burst(#{left := Left, pending := P, missed := M} = S) ->
    Missed =
        case P of
            undefined -> M;
            _ -> M + 1
        end,
    %% timestamp taken just before the burst frame is handed to the socket
    K = maps:get(k, S),
    S#{
        left => Left - 1,
        missed => Missed,
        k => K + 1,
        pending => {erlang:monotonic_time(microsecond), K rem length(?TONES)}
    }.

burst_idx(#{pending := {_, Idx}}) -> Idx.

send(Side, Payload, S) ->
    {Sock, Dst, SeqK, SsrcK} =
        case Side of
            a -> {maps:get(a, S), maps:get(a_dst, S), seq_a, ssrc_a};
            b -> {maps:get(b, S), maps:get(b_dst, S), seq_b, ssrc_b}
        end,
    Seq = maps:get(SeqK, S),
    Pkt = chappe_mix_rtp:build(#{
        pt => law_pt(maps:get(law, S)),
        seq => Seq band 16#FFFF,
        ts => (Seq * ?FRAME) band 16#FFFFFFFF,
        ssrc => maps:get(SsrcK, S),
        marker => false,
        payload => Payload
    }),
    {Ip, Port} = Dst,
    _ = gen_udp:send(Sock, Ip, Port, Pkt),
    S#{SeqK => Seq + 1}.

%% Only the law's payload type counts: comfort noise from a real peer
%% decoded as G.711 could read as loud.
received(Sock, Pkt, Now, #{b := Sock, pending := {T0, Idx}} = S) ->
    PT = law_pt(maps:get(law, S)),
    case chappe_mix_rtp:parse(Pkt) of
        {ok, #{pt := PT, payload := P}} ->
            Samples = chappe_mix_g711:decode_frame(maps:get(law, S), P),
            case loud(Samples) andalso dominant(Samples, Idx) of
                true ->
                    S#{
                        pending => undefined,
                        lat => [Now - T0 | maps:get(lat, S)]
                    };
                false ->
                    S
            end;
        _ ->
            S
    end;
received(_Sock, _Pkt, _Now, S) ->
    S.

%% Report and go back to idle, ready for another run on the same ports.
finish(#{from := From, lat := Lat, missed := Missed} = S) ->
    From !
        {self(), result, #{
            latencies_us => lists:reverse(Lat),
            missed => Missed,
            frames => maps:get(n, S),
            b_gaps_us => lists:reverse(maps:get(b_gaps, S))
        }},
    idle(maps:with([a, b, law], S)).

loud(Samples) ->
    lists:any(fun(X) -> abs(X) > ?LOUD end, Samples).

%% The burst's own tone carries at least four times the power of each of
%% the other two.
dominant(Samples, Idx) ->
    Powers = [power(Samples, F) || F <- ?TONES],
    Own = lists:nth(Idx + 1, Powers),
    Others = lists:sublist(Powers, Idx) ++ lists:nthtail(Idx + 1, Powers),
    lists:all(fun(O) -> Own > 4 * O end, Others).

power(Samples, F) ->
    Coeff = 2 * math:cos(2 * math:pi() * F / 8000),
    {S1, S2} = lists:foldl(
        fun(X, {P1, P2}) -> {X + Coeff * P1 - P2, P1} end, {0.0, 0.0}, Samples
    ),
    S1 * S1 + S2 * S2 - Coeff * S1 * S2.

law_pt(ulaw) -> 0;
law_pt(alaw) -> 8.

tone(Freq, Amp) ->
    [
        round(Amp * math:sin(2 * math:pi() * Freq * I / 8000))
     || I <- lists:seq(0, ?FRAME - 1)
    ].
