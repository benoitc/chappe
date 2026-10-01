%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% chappe_mix bench arms. One arm per VM launch:
%%
%%   erl -noshell +S 1 -pa <ebins> -run chappe_mix_bench main <arm> [args]
%%
%% Arms: null, latency, loss, jitter, capacity, mix_cost, ref_latency. See
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
        "null|latency|loss|jitter|capacity|mix_cost|ref_latency [args]~n"
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

sched_util(Secs) ->
    case lists:keyfind(total, 1, scheduler:utilization(Secs)) of
        {total, F, _} -> round2(F);
        false -> undefined
    end.

%% ---- mix cost ----

%% Mirrors the compute in chappe_mix_conf:mix/2 as of this commit:
%% decode every leg, sum once, and for each leg subtract its own frame,
%% encode and build the RTP packet with the CSRC list of the others (at
%% most 15). Keep it in step with the mixer.
mix_cost(N, Load) ->
    chappe_mix_g711:init(),
    Frames = [
        chappe_mix_g711:encode_frame(ulaw, [
            round(6000 * math:sin(2 * math:pi() * (300 + 100 * K) * I / 8000))
         || I <- lists:seq(0, ?FRAME - 1)
        ])
     || K <- lists:seq(1, N)
    ],
    Iter = max(50, 20000 div N),
    Rounds = [
        begin
            {Us, ok} = timer:tc(fun() -> mix_loop(Frames, Iter) end),
            Us / Iter
        end
     || _ <- lists:seq(1, 5)
    ],
    Min = lists:min(Rounds),
    report(mix_cost, Load, [
        {legs, N},
        {tick_us_min, round2(Min)},
        {tick_us_max, round2(lists:max(Rounds))},
        {per_leg_us, round2(Min / N)},
        {budget_pct_one_sched, round2(Min / 200)}
    ]).

mix_loop(_Frames, 0) ->
    ok;
mix_loop(Frames, K) ->
    _ = mix_tick(Frames),
    mix_loop(Frames, K - 1).

mix_tick(Frames) ->
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
    Env =
        case chappe_mix_ref:env() of
            {ok, E} ->
                E;
            {skip, Why} ->
                io:format("ref_latency skipped: ~s~n", [Why]),
                halt(3)
        end,
    report(ref_latency, Load, [
        {caveat,
            "FreeSWITCH image is amd64 only; emulated on arm64 its timing is not a fair reference"}
    ]),
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
