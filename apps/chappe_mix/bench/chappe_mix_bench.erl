%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mix bench arms. One arm per VM launch:
%%
%%   erl -noshell +S 1 -pa <ebins> -run chappe_mix_bench main <arm> [args]
%%
%% Arms: null, latency, loss, jitter, capacity, mix_cost, ref_latency,
%% ref_capacity. See
%% README.md next to this file for what each measures and how to compare
%% two commits. Every result line starts with the arm name and ends with
%% the load average; a line ending in VOID was taken above the load limit
%% and says nothing about the mixer.
-module(chappe_mix_bench).

-export([main/1]).

-define(FRAME, 160).
-define(BUCKETS, [500, 1000, 2000, 5000, 10000, 20000, infinity]).

main([Arm | Args]) ->
    Load = load_check(),
    {ok, _} = application:ensure_all_started(chappe_mix),
    try
        arm(Arm, Args, Load),
        halt(0)
    catch
        C:R:St ->
            io:format("~s error ~p:~p~n~p~n", [Arm, C, R, St]),
            halt(1)
    end;
main([]) ->
    io:format(
        "usage: -run chappe_mix_bench main "
        "null|latency|loss|jitter|capacity|mix_cost|ref_latency|"
        "ref_capacity [args]~n"
    ),
    halt(2).

%% ---- arms ----

%% An empty fun, and bare 20 ms timers: what the box does to you before
%% the mixer is involved at all.
arm("null", _Args, Load) ->
    F = fun() -> ok end,
    Rounds = [
        begin
            {Us, ok} = timer:tc(fun() -> spin(F, 1000000) end),
            Us * 1000 / 1000000
        end
     || _ <- lists:seq(1, 5)
    ],
    report(null, Load, [
        {fun_ns_min, lists:min(Rounds)}, {fun_ns_max, lists:max(Rounds)}
    ]),
    Late = timer_lateness(250),
    report(null, Load, [
        {timer_late_p50_us, pct(Late, 50)},
        {timer_late_p99_us, pct(Late, 99)},
        {timer_late_max_us, lists:max(Late)}
    ]);
%% Burst latency A to B through one conference, the probe in a peer node.
%% Args: [Bursts] [ExtraSilentLegs].
arm("latency", Args, Load) ->
    latency(latency, int_arg(Args, 1, 100), int_arg(Args, 2, 2), silence, Load);
%% The latency probe while the other legs carry a tone with 5% random
%% loss (the PERF.md loss row): the probe's latency, the conference's
%% overruns and each leg's counted losses. Args: [Bursts] [LossyLegs].
arm("loss", Args, Load) ->
    latency(
        loss, int_arg(Args, 1, 100), int_arg(Args, 2, 2), {lossy, 0.05}, Load
    );
%% Tick lateness idle (one 4-party conference) or at capacity (N of
%% them). Args: idle [Secs] | capacity [Confs] [Secs].
arm("jitter", ["capacity" | Args], Load) ->
    jitter(capacity, int_arg(Args, 1, 100), int_arg(Args, 2, 30), Load);
arm("jitter", ["idle" | Args], Load) ->
    jitter(idle, 1, int_arg(Args, 1, 30), Load);
arm("jitter", [], Load) ->
    jitter(idle, 1, 30, Load);
%% Ramp 4-party conferences until a tick misses its budget.
%% Args: [Step] [StepSecs] [MaxConfs].
arm("capacity", Args, Load) ->
    capacity(
        int_arg(Args, 1, 10), int_arg(Args, 2, 5), int_arg(Args, 3, 1000), Load
    );
%% Compute of one mix tick for N legs, no sockets, each listener kept
%% from hearing K other legs besides itself (chappe_mix:relate/4).
%% Args: nohear K [N...].
arm("mix_cost", ["nohear", K | Args], Load) ->
    Ns =
        case Args of
            [] -> [4, 64];
            _ -> [list_to_integer(A) || A <- Args]
        end,
    [mix_cost(N, list_to_integer(K), Load) || N <- Ns],
    ok;
%% Compute of one mix tick for N legs, no sockets. Args: [N...].
arm("mix_cost", Args, Load) ->
    Ns =
        case Args of
            [] -> [2, 4, 8, 16, 32, 64];
            _ -> [list_to_integer(A) || A <- Args]
        end,
    [mix_cost(N, Load) || N <- Ns],
    ok;
%% chappe_mix against FreeSWITCH mod_conference: tones, then interleaved
%% latency rounds. Args: [Rounds] [BurstsPerRound].
arm("ref_latency", Args, Load) ->
    ref_latency(int_arg(Args, 1, 5), int_arg(Args, 2, 50), Load);
%% Ramp 4-party rooms on fs or chappe, judged from outside the mixer by a
%% probe room at each step. Args: fs|chappe [Step] [Bursts] [MaxRooms].
arm("ref_capacity", [Mixer | Args], Load) when
    Mixer =:= "fs"; Mixer =:= "chappe"
->
    ref_capacity(
        list_to_atom(Mixer),
        int_arg(Args, 1, 10),
        int_arg(Args, 2, 25),
        int_arg(Args, 3, 1000),
        Load
    );
arm(Other, _Args, _Load) ->
    io:format("unknown arm ~s~n", [Other]),
    halt(2).

%% ---- latency ----

%% Burst latency A to B through one conference, the probe in a peer node,
%% with Extra more legs fed by a sender group of Kind.
latency(Arm, Bursts, Extra, Kind, Load) ->
    Peer = start_peer(),
    Collector = collector(),
    {ok, Conf} = chappe_mix:start(#{trace => Collector}),
    {ok, _, #{port := PA}} = chappe_mix:add_leg(Conf, #{}),
    {ok, _, #{port := PB}} = chappe_mix:add_leg(Conf, #{}),
    ExtraDsts = [
        {{127, 0, 0, 1}, P}
     || _ <- lists:seq(1, Extra),
        {ok, _, #{port := P}} <- [chappe_mix:add_leg(Conf, #{})]
    ],
    _ = [
        peer_call(Peer, chappe_mix_bench_load, start_group, [ExtraDsts, Kind])
     || Extra > 0
    ],
    R = peer_call(Peer, chappe_mix_bench_load, latency, [
        #{
            a_dst => {{127, 0, 0, 1}, PA},
            b_dst => {{127, 0, 0, 1}, PB},
            bursts => Bursts
        }
    ]),
    Ticks = ticks(Collector),
    #{latencies_us := L, missed := Missed} = R,
    report(Arm, Load, [
        {legs, 2 + Extra},
        {bursts, Bursts},
        {heard, length(L)},
        {missed, Missed},
        {p50_us, pct(L, 50)},
        {p99_us, pct(L, 99)},
        {max_us, max_or_undef(L)}
    ]),
    report_ticks(Arm, Load, Ticks),
    report_legs(Arm, Load, Conf),
    peer:stop(Peer).

%% ---- jitter ----

jitter(Mode, Confs, Secs, Load) ->
    Peer = start_peer(),
    Collector = collector(),
    Pairs = [
        new_conf(Peer, I =:= 1 andalso Collector)
     || I <- lists:seq(1, Confs)
    ],
    {All, Groups} = lists:unzip(Pairs),
    timer:sleep(1000),
    flush_collector(Collector),
    Sent0 = peer_call(Peer, chappe_mix_bench_load, sent, [Groups]),
    Before = snapshot(All),
    timer:sleep(Secs * 1000),
    After = snapshot(All),
    Sent1 = peer_call(Peer, chappe_mix_bench_load, sent, [Groups]),
    Ticks = ticks(Collector),
    D = delta(Before, After),
    report(jitter, Load, [
        {mode, Mode},
        {confs, Confs},
        {secs, Secs},
        {ticks, maps:get(ticks, D)},
        {overruns, maps:get(overruns, D)},
        {p99_bucket_us, hist_pct(maps:get(hist, D), 99)},
        {late_max_since_start_us, maps:get(late_max, D)},
        {rx_per_sent, ratio(maps:get(rx, D), Sent1 - Sent0)},
        {hist, hist_list(maps:get(hist, D))}
    ]),
    report_ticks(jitter, Load, Ticks),
    peer:stop(Peer).

%% ---- capacity ----

capacity(Step, Secs, Max, Load) ->
    Peer = start_peer(),
    report(capacity, Load, [
        {schedulers_online, erlang:system_info(schedulers_online)},
        {step, Step},
        {step_secs, Secs}
    ]),
    Mem0 = erlang:memory(total),
    Last = ramp(Peer, Step, Secs, Max, {[], []}, undefined, Load),
    case Last of
        undefined ->
            report(capacity, Load, [{result, none_in_budget}]);
        {N, Util, Mem} ->
            report(capacity, Load, [
                {result, in_budget},
                {confs, N},
                {legs, 4 * N},
                {sched_util, Util},
                {erl_bytes_per_conf, maps:get(erl, Mem)},
                {kernel_buf_ceiling_per_conf, maps:get(kernel, Mem)},
                {vm_total_growth_per_conf,
                    (erlang:memory(total) - Mem0) div max(1, N)}
            ])
    end,
    peer:stop(Peer).

ramp(_Peer, _Step, _Secs, Max, {Confs, _}, Last, _Load) when
    length(Confs) >= Max
->
    Last;
ramp(Peer, Step, Secs, Max, {Confs0, Groups0}, Last, Load) ->
    {NewConfs, NewGroups} = lists:unzip([
        new_conf(Peer, false)
     || _ <- lists:seq(1, Step)
    ]),
    Confs = NewConfs ++ Confs0,
    Groups = NewGroups ++ Groups0,
    timer:sleep(1000),
    Sent0 = peer_call(Peer, chappe_mix_bench_load, sent, [Groups]),
    Before = snapshot(Confs),
    Util = sched_util(Secs),
    After = snapshot(Confs),
    Sent1 = peer_call(Peer, chappe_mix_bench_load, sent, [Groups]),
    D = delta(Before, After),
    N = length(Confs),
    P99 = hist_pct(maps:get(hist, D), 99),
    Expected = 4 * N * 50 * Secs,
    Mem = conf_memory(Confs),
    report(capacity, Load, [
        {confs, N},
        {legs, 4 * N},
        {sched_util, Util},
        {ticks, maps:get(ticks, D)},
        {overruns, maps:get(overruns, D)},
        {p99_bucket_us, P99},
        {late_max_since_start_us, maps:get(late_max, D)},
        {sent_per_expected, ratio(Sent1 - Sent0, Expected)},
        {rx_per_sent, ratio(maps:get(rx, D), Sent1 - Sent0)},
        {erl_bytes_per_conf, maps:get(erl, Mem)}
    ]),
    case maps:get(overruns, D) > 0 orelse bucket_gt(P99, 5000) of
        true ->
            Last;
        false ->
            ramp(Peer, Step, Secs, Max, {Confs, Groups}, {N, Util, Mem}, Load)
    end.

bucket_gt(infinity, _) -> true;
bucket_gt(B, Limit) -> B > Limit.

%% A 4-party conference fed by its own sender group in the peer. Trace is
%% a collector pid or false.
new_conf(Peer, Trace) ->
    Opts =
        case Trace of
            false -> #{};
            Pid -> #{trace => Pid}
        end,
    {ok, Conf} = chappe_mix:start(Opts),
    Dsts = [
        {{127, 0, 0, 1}, P}
     || _ <- lists:seq(1, 4),
        {ok, _, #{port := P}} <- [chappe_mix:add_leg(Conf, #{})]
    ],
    G = peer_call(Peer, chappe_mix_bench_load, start_group, [Dsts, tone]),
    {Conf, G}.

snapshot(Confs) ->
    [
        {
            chappe_mix:stats(C),
            lists:sum([R || #{received := R} <- chappe_mix:legs(C)])
        }
     || C <- Confs
    ].

delta(Before, After) ->
    lists:foldl(
        fun({{B, RxB}, {A, RxA}}, Acc) ->
            #{
                ticks => maps:get(ticks, Acc) + maps:get(ticks, A) -
                    maps:get(ticks, B),
                overruns => maps:get(overruns, Acc) + maps:get(overruns, A) -
                    maps:get(overruns, B),
                late_max => max(
                    maps:get(late_max, Acc), maps:get(late_max_us, A)
                ),
                rx => maps:get(rx, Acc) + RxA - RxB,
                hist => hist_add(
                    maps:get(hist, Acc),
                    hist_sub(
                        maps:get(late_histogram_us, A),
                        maps:get(late_histogram_us, B)
                    )
                )
            }
        end,
        #{ticks => 0, overruns => 0, late_max => 0, rx => 0, hist => #{}},
        lists:zip(Before, After)
    ).

hist_sub(A, B) ->
    maps:map(fun(K, V) -> V - maps:get(K, B, 0) end, A).

hist_add(A, B) ->
    maps:fold(
        fun(K, V, Acc) -> maps:update_with(K, fun(X) -> X + V end, V, Acc) end,
        A,
        B
    ).

%% The upper bound of the bucket holding the P-th percentile tick.
hist_pct(H, P) ->
    Total = lists:sum(maps:values(H)),
    hist_pct(H, P, Total, 0, ?BUCKETS).

hist_pct(_H, _P, 0, _Acc, _) ->
    undefined;
hist_pct(_H, _P, _Total, _Acc, []) ->
    infinity;
hist_pct(H, P, Total, Acc, [B | Bs]) ->
    Acc1 = Acc + maps:get(B, H, 0),
    case Acc1 * 100 >= P * Total of
        true -> B;
        false -> hist_pct(H, P, Total, Acc1, Bs)
    end.

hist_list(H) ->
    [{B, maps:get(B, H, 0)} || B <- ?BUCKETS].

%% Per conference: the process heap plus its sockets' port memory (what
%% the VM holds), and the kernel buffer sizes the sockets are allowed (a
%% ceiling on kernel memory, not what is in use).
conf_memory(Confs) ->
    Per = [one_conf_memory(C) || C <- Confs],
    N = max(1, length(Per)),
    #{
        erl => lists:sum([E || {E, _} <- Per]) div N,
        kernel => lists:sum([K || {_, K} <- Per]) div N
    }.

one_conf_memory(Conf) ->
    {memory, M} = process_info(Conf, memory),
    {links, Links} = process_info(Conf, links),
    Ports = [P || P <- Links, is_port(P)],
    PortMem = lists:sum([
        case erlang:port_info(P, memory) of
            {memory, B} -> B;
            undefined -> 0
        end
     || P <- Ports
    ]),
    Kernel = lists:sum([
        case inet:getopts(P, [recbuf, sndbuf]) of
            {ok, [{_, R}, {_, S}]} -> R + S;
            _ -> 0
        end
     || P <- Ports
    ]),
    {M + PortMem, Kernel}.

%% The average over the normal schedulers. Not `total': that also averages
%% in the dirty CPU schedulers, one per normal scheduler by default and
%% idle here, so with +S 1 a saturated scheduler reads 0.5 in it.
sched_util(Secs) ->
    Normal = [U || {normal, _Id, U, _} <- scheduler:utilization(Secs)],
    case Normal of
        [] -> undefined;
        _ -> round2(lists:sum(Normal) / length(Normal))
    end.

%% ---- mix cost ----

%% The compute in chappe_mix_conf:mix/2: decode every leg into the sum,
%% and for each leg encode the sum less its own frame and build the RTP
%% packet with the CSRC list of the others (at most 15). It calls
%% chappe_mix_dsp, the mixer's own code, when that module exists; on an
%% older commit it runs the list version the mixer had then, so the arm
%% still compares two commits.
mix_cost(N, Load) ->
    mix_cost(N, 0, Load).

mix_cost(N, K, Load) ->
    chappe_mix_g711:init(),
    Frames = [
        chappe_mix_g711:encode_frame(ulaw, [
            round(6000 * math:sin(2 * math:pi() * (300 + 100 * T) * I / 8000))
         || I <- lists:seq(0, ?FRAME - 1)
        ])
     || T <- lists:seq(1, N)
    ],
    Iter = max(50, 20000 div N),
    _ = code:ensure_loaded(chappe_mix_dsp),
    Tick =
        case
            {
                erlang:function_exported(chappe_mix_dsp, mixed, 1),
                erlang:function_exported(chappe_mix_dsp, new, 0)
            }
        of
            {true, _} when K > 0 -> fun(Fs) -> mix_tick_nohear(Fs, K) end;
            {true, _} -> fun mix_tick/1;
            {false, true} -> fun mix_tick_dsp0/1;
            {false, false} -> fun mix_tick_lists/1
        end,
    Rounds = [
        begin
            {Us, ok} = timer:tc(fun() -> mix_loop(Tick, Frames, Iter) end),
            Us / Iter
        end
     || _ <- lists:seq(1, 5)
    ],
    Min = lists:min(Rounds),
    report(mix_cost, Load, [
        {legs, N},
        {nohear, K},
        {tick_us_min, round2(Min)},
        {tick_us_max, round2(lists:max(Rounds))},
        {per_leg_us, round2(Min / N)},
        {budget_pct_one_sched, round2(Min / 200)}
    ]).

mix_loop(_Tick, _Frames, 0) ->
    ok;
mix_loop(Tick, Frames, K) ->
    _ = Tick(Frames),
    mix_loop(Tick, Frames, K - 1).

mix_tick(Frames) ->
    Sum = lists:foldl(
        fun(F, Acc) -> chappe_mix_dsp:add(Acc, ulaw, F) end,
        chappe_mix_dsp:new(),
        Frames
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    Ids = lists:seq(1, length(Frames)),
    [
        chappe_mix_rtp:build(#{
            pt => 0,
            seq => 1,
            ts => 160,
            ssrc => 42,
            marker => false,
            csrcs => lists:sublist(Ids -- [K], 15),
            payload => chappe_mix_dsp:encode(Mixed, ulaw, {ulaw, F})
        })
     || {K, F} <- lists:zip(Ids, Frames)
    ].

%% As mix_tick/1, each listener also kept from hearing the K legs after
%% it: their frames are taken out of its sum, and out of its CSRC list.
mix_tick_nohear(Frames, K) ->
    Sum = lists:foldl(
        fun(F, Acc) -> chappe_mix_dsp:add(Acc, ulaw, F) end,
        chappe_mix_dsp:new(),
        Frames
    ),
    Mixed = chappe_mix_dsp:mixed(Sum),
    N = length(Frames),
    Ids = lists:seq(1, N),
    Tuple = list_to_tuple(Frames),
    [
        begin
            Skip = [((I - 1 + J) rem N) + 1 || J <- lists:seq(0, K)],
            chappe_mix_rtp:build(#{
                pt => 0,
                seq => 1,
                ts => 160,
                ssrc => 42,
                marker => false,
                csrcs => lists:sublist(Ids -- Skip, 15),
                payload => chappe_mix_dsp:encode(
                    Mixed, ulaw, [{ulaw, element(J, Tuple)} || J <- Skip]
                )
            })
        end
     || I <- Ids
    ].

%% chappe_mix_dsp before mixed/1 (0ea59d9 to 0cd3bb2): encode read the
%% atomics sum directly.
mix_tick_dsp0(Frames) ->
    Sum = lists:foldl(
        fun(F, Acc) -> chappe_mix_dsp:add(Acc, ulaw, F) end,
        chappe_mix_dsp:new(),
        Frames
    ),
    Ids = lists:seq(1, length(Frames)),
    [
        chappe_mix_rtp:build(#{
            pt => 0,
            seq => 1,
            ts => 160,
            ssrc => 42,
            marker => false,
            csrcs => lists:sublist(Ids -- [K], 15),
            payload => chappe_mix_dsp:encode(Sum, ulaw, {ulaw, F})
        })
     || {K, F} <- lists:zip(Ids, Frames)
    ].

%% The mix before chappe_mix_dsp: decoded frames as lists.
mix_tick_lists(Frames) ->
    Pcms = [chappe_mix_g711:decode_frame(ulaw, F) || F <- Frames],
    Sum = lists:foldl(
        fun(A, B) -> lists:zipwith(fun(X, Y) -> X + Y end, A, B) end,
        hd(Pcms),
        tl(Pcms)
    ),
    Ids = lists:seq(1, length(Pcms)),
    [
        chappe_mix_rtp:build(#{
            pt => 0,
            seq => 1,
            ts => 160,
            ssrc => 42,
            marker => false,
            csrcs => lists:sublist(Ids -- [K], 15),
            payload => chappe_mix_g711:encode_frame(
                ulaw, lists:zipwith(fun(X, Y) -> X - Y end, Sum, P)
            )
        })
     || {K, P} <- lists:zip(Ids, Pcms)
    ].

%% ---- reference ----

ref_latency(Rounds, Bursts, Load) ->
    Env = ref_env(ref_latency),
    [ref_tones(Mixer, Env, Load) || Mixer <- [chappe, fs]],
    Res = [
        [
            begin
                R = chappe_mix_ref:latency(Mixer, Env, #{bursts => Bursts}),
                #{latencies_us := L, missed := M} = R,
                report(ref_latency, Load, [
                    {round, I},
                    {mixer, Mixer},
                    {heard, length(L)},
                    {missed, M},
                    {p50_us, pct(L, 50)},
                    {p99_us, pct(L, 99)}
                ]),
                {Mixer, pct(L, 50), pct(L, 99)}
            end
         || Mixer <- [chappe, fs]
        ]
     || I <- lists:seq(1, Rounds)
    ],
    Flat = lists:append(Res),
    [
        report(ref_latency, Load, [
            {mixer, Mixer},
            {rounds, Rounds},
            {p50_us_min, min_defined([P || {M, P, _} <- Flat, M =:= Mixer])},
            {p99_us_min, min_defined([P || {M, _, P} <- Flat, M =:= Mixer])}
        ])
     || Mixer <- [chappe, fs]
    ],
    ok.

%% Three parties, three tones: what each one hears, in dBFS per tone.
ref_tones(Mixer, Env, Load) ->
    %% clear of mod_conference's 500/600/700 Hz enter tone
    Freqs = [1100, 1700, 2300],
    H = chappe_mix_ref:parties(Mixer, Env, Freqs),
    Eps =
        case H of
            {fs, E} -> E;
            {chappe, _, E} -> E
        end,
    timer:sleep(3000),
    [chappe_mix_test_tone:clear(P) || {P, _, _} <- Eps],
    timer:sleep(2000),
    [
        begin
            S = chappe_mix_test_tone:samples(P),
            Levels = chappe_mix_test_tone:levels(S, Freqs),
            report(ref_tones, Load, [
                {mixer, Mixer},
                {receiver, F},
                {samples, length(S)}
                | [
                    {list_to_atom("dbfs_" ++ integer_to_list(G)), round2(L)}
                 || {G, L} <- Levels
                ]
            ])
        end
     || {P, _, F} <- Eps
    ],
    chappe_mix_ref:close(H).

ref_env(Arm) ->
    case chappe_mix_ref:env() of
        {ok, E} ->
            E;
        {skip, Why} ->
            io:format("~s skipped: ~s~n", [Arm, Why]),
            halt(3)
    end.

%% ---- reference capacity ----

%% Rooms of four legs, each fed a tone by a sender group in the peer node,
%% added Step at a time. At each step a fresh probe room (probe legs A and
%% B plus two silent legs, the latency arm's shape) is judged from outside
%% the mixer, which is all FreeSWITCH allows: burst latency, the gaps
%% between packets arriving on B, the packets B got per frame sent, and
%% the mixer's CPU over the window. The same judge runs on chappe_mix
%% (in this node, +S 1) so the two ramps compare.
ref_capacity(Mixer, Step, Bursts, Max, Load) ->
    Env =
        case Mixer of
            fs -> ref_env(ref_capacity);
            chappe -> #{}
        end,
    Peer = start_peer(),
    Bind =
        case Mixer of
            fs -> {0, 0, 0, 0};
            chappe -> {127, 0, 0, 1}
        end,
    Ctx = #{mixer => Mixer, env => Env, peer => Peer, bind => Bind},
    Mem0 = mixer_mem(Mixer),
    report(ref_capacity, Load, [
        {mixer, Mixer},
        {step, Step},
        {bursts, Bursts},
        {schedulers_online, erlang:system_info(schedulers_online)},
        {fs_cpus, fs_cpus(Mixer)},
        {mem0_bytes, Mem0}
    ]),
    {Rooms, Last} = ref_ramp(Ctx, Step, Bursts, Max, Mem0, [], undefined, Load),
    case Last of
        undefined ->
            report(ref_capacity, Load, [
                {mixer, Mixer}, {result, none_in_budget}
            ]);
        Fields ->
            report(ref_capacity, Load, [
                {mixer, Mixer}, {result, in_budget} | Fields
            ])
    end,
    [close_room(Ctx, R) || R <- Rooms],
    peer:stop(Peer).

ref_ramp(_Ctx, _Step, _Bursts, Max, _Mem0, Rooms, Last, _Load) when
    length(Rooms) >= Max
->
    {Rooms, Last};
ref_ramp(Ctx, Step, Bursts, Max, Mem0, Rooms0, Last, Load) ->
    #{mixer := Mixer} = Ctx,
    case add_rooms(Ctx, Step, Rooms0) of
        {error, Reason, Rooms} ->
            report(ref_capacity, Load, [
                {mixer, Mixer}, {rooms, length(Rooms)}, {stop, Reason}
            ]),
            {Rooms, Last};
        {ok, Rooms} ->
            Fields = ref_step(Ctx, Rooms, Bursts, Mem0),
            report(ref_capacity, Load, [{mixer, Mixer} | Fields]),
            case in_budget(Fields) of
                true ->
                    ref_ramp(Ctx, Step, Bursts, Max, Mem0, Rooms, Fields, Load);
                false ->
                    {Rooms, Last}
            end
    end.

%% A step is in budget when every probe burst is heard with a p99 no more
%% than 20 ms (one frame) above the p50 of the same room, B gets at least
%% 98% of a packet per frame with no gap over 60 ms (three frames,
%% audible), and the mixer uses under 95% of one core. Latency is judged
%% within the room because each step's probe room is new, and
%% mod_conference's latency moves by whole frames from room to room with
%% the phase of its timers. The gaps' spread is reported, not judged:
%% mod_conference paces its output with a p99 spread near 5 ms even with
%% a few rooms.
in_budget(Fields) ->
    #{
        missed := Missed,
        p50_us := P50,
        p99_us := P99,
        b_gap_max_us := GapMax,
        b_rx_per_frame := Rx,
        cpu_pct_one_core := Cpu
    } = maps:from_list(Fields),
    Missed =:= 0 andalso is_integer(P50) andalso is_integer(P99) andalso
        P99 - P50 =< 20000 andalso
        is_integer(GapMax) andalso GapMax =< 60000 andalso
        is_float(Rx) andalso Rx >= 0.98 andalso
        (Cpu =:= undefined orelse Cpu < 95.0).

ref_step(#{mixer := Mixer, peer := Peer} = Ctx, Rooms, Bursts, Mem0) ->
    timer:sleep(1000),
    Groups = [G || {_, _, G} <- Rooms],
    N = length(Rooms),
    {Sent0, S0} = {sent(Peer, Groups), erlang:monotonic_time()},
    Cpu0 = mixer_cpu(Mixer),
    R = probe_room(Ctx, Bursts),
    Cpu1 = mixer_cpu(Mixer),
    {Sent1, S1} = {sent(Peer, Groups), erlang:monotonic_time()},
    Mem = mixer_mem(Mixer),
    SentSecs = erlang:convert_time_unit(S1 - S0, native, microsecond) / 1.0e6,
    #{
        latencies_us := L,
        missed := Missed,
        frames := Frames,
        b_gaps_us := Gaps
    } = R,
    [
        {rooms, N},
        {legs, 4 * N},
        {cpu_pct_one_core, cpu_pct(Cpu0, Cpu1)},
        {heard, length(L)},
        {missed, Missed},
        {p50_us, pct(L, 50)},
        {p99_us, pct(L, 99)},
        {b_gap_dev_p50_us, pct([abs(G - 20000) || G <- Gaps], 50)},
        {b_gap_dev_p99_us, pct([abs(G - 20000) || G <- Gaps], 99)},
        {b_gap_hist, gap_hist(Gaps)},
        {b_gap_max_us, max_or_undef(Gaps)},
        {b_rx_per_frame, ratio(length(Gaps) + 1, Frames)},
        {sent_per_expected, ratio(Sent1 - Sent0, round(4 * N * 50 * SentSecs))},
        {mem_per_room_bytes, mem_per_room(Mem0, Mem, N)}
    ].

add_rooms(_Ctx, 0, Rooms) ->
    {ok, Rooms};
add_rooms(Ctx, K, Rooms) ->
    try new_room(Ctx, tone, 4) of
        Room -> add_rooms(Ctx, K - 1, [Room | Rooms])
    catch
        error:Reason -> {error, Reason, Rooms}
    end.

%% A room of Legs legs fed by one sender group of Kind in the peer.
%% Returns {Mixer, Handle, Group}.
new_room(#{mixer := chappe, peer := Peer}, Kind, Legs) ->
    {ok, Conf} = chappe_mix:start(#{}),
    Dsts = [
        {{127, 0, 0, 1}, P}
     || _ <- lists:seq(1, Legs),
        {ok, _, #{port := P}} <- [chappe_mix:add_leg(Conf, #{})]
    ],
    G = peer_call(Peer, chappe_mix_bench_load, start_group, [Dsts, Kind]),
    {chappe, Conf, G};
new_room(#{mixer := fs, peer := Peer, bind := Bind, env := Env}, Kind, Legs) ->
    {G, GPort} = peer_call(Peer, chappe_mix_bench_load, open_group, [
        Kind, Bind
    ]),
    User = fs_room_user(),
    Calls = [fs_leg(Env, User, GPort) || _ <- lists:seq(1, Legs)],
    #{host := Host} = Env,
    ok = peer_call(Peer, chappe_mix_bench_load, feed, [
        G, [{Host, P} || {_, P} <- Calls]
    ]),
    {fs, [C || {C, _} <- Calls], G}.

fs_leg(Env, User, RtpPort) ->
    #{host := Host, sip_port := SipPort, advertise := Adv} = Env,
    case
        chappe_mix_sip_ua:call(#{
            host => Host,
            port => SipPort,
            user => User,
            advertise => Adv,
            rtp_port => RtpPort,
            timeout => 10000
        })
    of
        {ok, Call, #{port := P}} when is_integer(P) -> {Call, P};
        {ok, _, Media} -> error({no_media_in_answer, Media});
        {error, Reason} -> error({freeswitch_call_failed, Reason})
    end.

fs_room_user() ->
    N = binary:encode_hex(crypto:strong_rand_bytes(4), lowercase),
    <<"conf-refcap", N/binary>>.

close_room(#{peer := Peer}, {chappe, Conf, G}) ->
    ok = peer_call(Peer, chappe_mix_bench_load, stop_group, [G]),
    chappe_mix:stop(Conf);
close_room(#{peer := Peer}, {fs, Calls, G}) ->
    ok = peer_call(Peer, chappe_mix_bench_load, stop_group, [G]),
    Pids = [spawn(fun() -> chappe_mix_sip_ua:hangup(C) end) || C <- Calls],
    Refs = [monitor(process, P) || P <- Pids],
    [
        receive
            {'DOWN', Ref, process, _, _} -> ok
        after 15000 -> ok
        end
     || Ref <- Refs
    ],
    ok.

%% The probe room for one step: probe legs A and B, two silent legs.
probe_room(#{peer := Peer, bind := Bind} = Ctx, Bursts) ->
    {Probe, PA, PB} = peer_call(Peer, chappe_mix_probe, start, [
        #{ip => Bind}
    ]),
    {Room, ADst, BDst} = probe_legs(Ctx, PA, PB),
    R = peer_call(Peer, chappe_mix_probe, run, [
        Probe, #{a_dst => ADst, b_dst => BDst, bursts => Bursts, settle => 50}
    ]),
    peer_call(Peer, chappe_mix_probe, stop, [Probe]),
    close_room(Ctx, Room),
    R.

probe_legs(#{mixer := chappe, peer := Peer}, _PA, _PB) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {ok, _, #{port := MA}} = chappe_mix:add_leg(Conf, #{}),
    {ok, _, #{port := MB}} = chappe_mix:add_leg(Conf, #{}),
    Sil = [
        {{127, 0, 0, 1}, P}
     || _ <- [1, 2],
        {ok, _, #{port := P}} <- [chappe_mix:add_leg(Conf, #{})]
    ],
    G = peer_call(Peer, chappe_mix_bench_load, start_group, [Sil, silence]),
    {{chappe, Conf, G}, {{127, 0, 0, 1}, MA}, {{127, 0, 0, 1}, MB}};
probe_legs(#{mixer := fs, peer := Peer, bind := Bind, env := Env}, PA, PB) ->
    #{host := Host} = Env,
    User = fs_room_user(),
    {CA, FA} = fs_leg(Env, User, PA),
    {CB, FB} = fs_leg(Env, User, PB),
    {G, GPort} = peer_call(Peer, chappe_mix_bench_load, open_group, [
        silence, Bind
    ]),
    Sil = [fs_leg(Env, User, GPort) || _ <- [1, 2]],
    ok = peer_call(Peer, chappe_mix_bench_load, feed, [
        G, [{Host, P} || {_, P} <- Sil]
    ]),
    {{fs, [CA, CB | [C || {C, _} <- Sil]], G}, {Host, FA}, {Host, FB}}.

%% {CpuNs, WallNs} of the mixer: the FreeSWITCH container's cgroup CPU
%% time at the instant docker read it, or this VM's own threads
%% (statistics(runtime) covers every thread).
mixer_cpu(fs) ->
    case docker_get("/stats?stream=false&one-shot=true") of
        {ok, #{
            <<"read">> := Read,
            <<"cpu_stats">> := #{<<"cpu_usage">> := #{<<"total_usage">> := U}}
        }} ->
            {U,
                calendar:rfc3339_to_system_time(binary_to_list(Read), [
                    {unit, nanosecond}
                ])};
        _ ->
            undefined
    end;
mixer_cpu(chappe) ->
    {Ms, _} = statistics(runtime),
    {Ms * 1000000, erlang:monotonic_time(nanosecond)}.

cpu_pct({C0, W0}, {C1, W1}) when W1 > W0 ->
    round2((C1 - C0) / (W1 - W0) * 100);
cpu_pct(_, _) ->
    undefined.

sent(Peer, Groups) ->
    peer_call(Peer, chappe_mix_bench_load, sent, [Groups]).

%% Gaps between packets on B in 5 ms buckets: [{UpperMs, Count}].
gap_hist(Gaps) ->
    H = lists:foldl(
        fun(G, Acc) ->
            maps:update_with(
                min(60, (G div 5000 + 1) * 5), fun(X) -> X + 1 end, 1, Acc
            )
        end,
        #{},
        Gaps
    ),
    lists:sort(maps:to_list(H)).

%% Memory of the mixer: the container's usage less its inactive page
%% cache, as `docker stats' shows it, or this VM's total.
mixer_mem(fs) ->
    case docker_get("/stats?stream=false&one-shot=true") of
        {ok, #{<<"memory_stats">> := #{<<"usage">> := U} = M}} ->
            Stats = maps:get(<<"stats">>, M, #{}),
            U - maps:get(<<"inactive_file">>, Stats, 0);
        _ ->
            undefined
    end;
mixer_mem(chappe) ->
    erlang:memory(total).

mem_per_room(M0, M1, N) when is_integer(M0), is_integer(M1) ->
    (M1 - M0) div max(1, N);
mem_per_room(_, _, _) ->
    undefined.

fs_cpus(chappe) ->
    undefined;
fs_cpus(fs) ->
    case docker_get("/json") of
        {ok, #{<<"HostConfig">> := #{<<"NanoCpus">> := C}}} -> C / 1.0e9;
        _ -> undefined
    end.

%% GET /containers/<FREESWITCH_CONTAINER><Path> from the docker API over
%% its unix socket (DOCKER_SOCK). error when either is unreachable.
docker_get(Path) ->
    Name = env_or("FREESWITCH_CONTAINER", "chappe-mix-fs"),
    Sock = env_or("DOCKER_SOCK", "/var/run/docker.sock"),
    Opts = [binary, {active, false}, {packet, raw}],
    case gen_tcp:connect({local, Sock}, 0, Opts, 2000) of
        {ok, S} ->
            Req = [
                "GET /containers/",
                Name,
                Path,
                " HTTP/1.0\r\nHost: docker\r\n\r\n"
            ],
            ok = gen_tcp:send(S, Req),
            Resp = recv_all(S, []),
            gen_tcp:close(S),
            case binary:split(Resp, <<"\r\n\r\n">>) of
                [<<"HTTP/1.", _:1/binary, " 200", _/binary>> = Head, Body] ->
                    case binary:match(Head, <<"chunked">>) of
                        nomatch -> {ok, json:decode(Body)};
                        _ -> {ok, json:decode(dechunk(Body, []))}
                    end;
                _ ->
                    error
            end;
        {error, _} ->
            error
    end.

%% The docker API answers HTTP/1.0 with a chunked body all the same.
dechunk(Bin, Acc) ->
    [SizeLine, Rest] = binary:split(Bin, <<"\r\n">>),
    case binary_to_integer(SizeLine, 16) of
        0 ->
            iolist_to_binary(lists:reverse(Acc));
        Size ->
            <<Chunk:Size/binary, "\r\n", Next/binary>> = Rest,
            dechunk(Next, [Chunk | Acc])
    end.

recv_all(S, Acc) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, B} -> recv_all(S, [B | Acc]);
        {error, _} -> iolist_to_binary(lists:reverse(Acc))
    end.

env_or(Name, Default) ->
    case os:getenv(Name) of
        V when is_list(V), V =/= "" -> V;
        _ -> Default
    end.

%% ---- tick trace collection ----

collector() ->
    spawn_link(fun() -> collect([]) end).

collect(Acc) ->
    receive
        {chappe_mix_tick, _Conf, T} ->
            collect([T | Acc]);
        flush ->
            collect([]);
        {get, From} ->
            From ! {ticks, lists:reverse(Acc)}
    end.

flush_collector(Pid) ->
    Pid ! flush.

ticks(Pid) ->
    Pid ! {get, self()},
    receive
        {ticks, T} -> T
    after 10000 -> []
    end.

report_ticks(_Arm, _Load, []) ->
    ok;
report_ticks(Arm, Load, Ticks) ->
    Late = [us(St - D) || #{due := D, start := St} <- Ticks],
    Work = [us(Dn - St) || #{start := St, done := Dn} <- Ticks],
    report(Arm, Load, [
        {traced_ticks, length(Ticks)},
        {late_p50_us, pct(Late, 50)},
        {late_p99_us, pct(Late, 99)},
        {late_max_us, lists:max(Late)},
        {early_ticks, length([X || X <- Late, X < 0])},
        {tick_to_send_p50_us, pct(Work, 50)},
        {tick_to_send_p99_us, pct(Work, 99)},
        {tick_to_send_max_us, lists:max(Work)}
    ]).

report_legs(Arm, Load, Conf) ->
    Legs = chappe_mix:legs(Conf),
    Sum = fun(K) -> lists:sum([maps:get(K, L) || L <- Legs]) end,
    report(Arm, Load, [
        {rx, Sum(received)},
        {lost, Sum(lost)},
        {late, Sum(late)},
        {dropped, Sum(dropped)},
        {underruns, Sum(underruns)},
        {prefill_shrunk,
            lists:sum([maps:get(prefill_shrunk, L, 0) || L <- Legs])},
        {max_prefill, lists:max([maps:get(prefill, L) || L <- Legs])}
    ]).

%% ---- peer node ----

%% The traffic runs in a second VM so the mixer's numbers are its own.
start_peer() ->
    Root = code:root_dir(),
    Paths = [
        P
     || P <- code:get_path(), not lists:prefix(Root, P), filelib:is_dir(P)
    ],
    Args = lists:append([["-pa", P] || P <- Paths]),
    Peer =
        case peer:start_link(#{connection => standard_io, args => Args}) of
            {ok, P} -> P;
            {ok, P, _Node} -> P
        end,
    ok = peer_call(Peer, chappe_mix_bench_load, init, []),
    Peer.

peer_call(Peer, M, F, A) ->
    peer:call(Peer, M, F, A, 600000).

%% ---- load check and output ----

%% Refuse to run above the limit unless CHAPPE_MIX_BENCH_FORCE=1, in
%% which case every line is marked VOID.
load_check() ->
    Up = string:trim(os:cmd("uptime")),
    Load1 = parse_load(Up),
    Cpus =
        case erlang:system_info(logical_processors_available) of
            unknown -> erlang:system_info(logical_processors);
            C -> C
        end,
    Limit =
        case os:getenv("CHAPPE_MIX_BENCH_MAX_LOAD") of
            false -> max(1.0, Cpus / 4);
            V -> list_to_float(V)
        end,
    Void = Load1 =:= undefined orelse Load1 > Limit,
    io:format("uptime: ~s~n", [Up]),
    io:format("load_1m=~p limit=~p cpus=~p~n", [Load1, Limit, Cpus]),
    case {Void, os:getenv("CHAPPE_MIX_BENCH_FORCE")} of
        {false, _} ->
            #{load => Load1, void => false};
        {true, "1"} ->
            io:format("load above limit: every result below is VOID~n"),
            #{load => Load1, void => true};
        {true, _} ->
            io:format(
                "load above limit, refusing (CHAPPE_MIX_BENCH_FORCE=1 runs anyway, marked VOID)~n"
            ),
            halt(2)
    end.

parse_load(Up) ->
    case
        re:run(Up, "load averages?: *([0-9.]+)", [
            {capture, all_but_first, list}
        ])
    of
        {match, [L]} -> list_to_float(fix_float(L));
        nomatch -> undefined
    end.

fix_float(L) ->
    case lists:member($., L) of
        true -> L;
        false -> L ++ ".0"
    end.

report(Arm, #{load := Load, void := Void}, Fields) ->
    Kv = [[" ", atom_to_list(K), "=", fmt(V)] || {K, V} <- Fields],
    Tail =
        case Void of
            true -> " VOID";
            false -> ""
        end,
    io:format("~s~s load=~p~s~n", [Arm, Kv, Load, Tail]).

fmt(V) when is_float(V) -> float_to_list(V, [{decimals, 2}, compact]);
fmt(V) when is_list(V) -> io_lib:format("~0p", [V]);
fmt(V) -> io_lib:format("~0p", [V]).

%% ---- small things ----

spin(_F, 0) ->
    ok;
spin(F, N) ->
    F(),
    spin(F, N - 1).

timer_lateness(N) ->
    T0 = erlang:monotonic_time(microsecond),
    timer_lateness(N, T0 div 1000 + 20, []).

timer_lateness(0, _Next, Acc) ->
    Acc;
timer_lateness(N, Next, Acc) ->
    erlang:send_after(Next, self(), t, [{abs, true}]),
    receive
        t -> ok
    end,
    Late = erlang:monotonic_time(microsecond) - Next * 1000,
    timer_lateness(N - 1, Next + 20, [Late | Acc]).

us(Native) ->
    erlang:convert_time_unit(Native, native, microsecond).

pct([], _) -> undefined;
pct(L, P) -> chappe_mix_probe:percentile(L, P).

max_or_undef([]) -> undefined;
max_or_undef(L) -> lists:max(L).

min_defined(L) ->
    case [X || X <- L, X =/= undefined] of
        [] -> undefined;
        D -> lists:min(D)
    end.

ratio(_, 0) -> undefined;
ratio(A, B) -> round2(A / B).

round2(F) when is_float(F) -> round(F * 100) / 100;
round2(X) -> X.

int_arg(Args, N, _Default) when length(Args) >= N ->
    list_to_integer(lists:nth(N, Args));
int_arg(_Args, _N, Default) ->
    Default.
