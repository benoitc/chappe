%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The mixer over real UDP on loopback. Every endpoint streams its own
%% tone; what each one receives is checked with a Goertzel detector: the
%% other parties' tones present, its own absent. That is the whole contract
%% of an N-1 conference mix, measured on the wire rather than assumed.
-module(chappe_mix_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    three_party/1,
    four_party/1,
    join_and_leave/1,
    mute/1,
    loss_on_one_leg/1,
    ssrc_change/1,
    garbage_is_dropped/1,
    move_keeps_the_port/1,
    owner_death_closes/1,
    stop_closes/1,
    tick_trace/1,
    probe_calibration/1,
    rtcp_sender_reports/1,
    rtcp_port_pair/1,
    rtcp_not_forwarded/1,
    bye_on_remove_and_stop/1,
    bye_forwarded/1,
    csrc_list/1,
    csrc_list_capped/1,
    source_filter/1,
    timestamp_after_overrun/1,
    ssrc_collision/1,
    member_timeout/1
]).

-define(F, [440, 1100, 1700, 2300]).
%% a tone at amplitude 6000 reads about -14.7 dBFS; a present tone must
%% be within 3 dB of that, an absent one 40 dB below it
-define(PRESENT, -18.0).
-define(ABSENT, -54.7).
-define(LO, {127, 0, 0, 1}).

all() ->
    [
        three_party,
        four_party,
        join_and_leave,
        mute,
        loss_on_one_leg,
        ssrc_change,
        garbage_is_dropped,
        move_keeps_the_port,
        owner_death_closes,
        stop_closes,
        tick_trace,
        probe_calibration,
        rtcp_sender_reports,
        rtcp_port_pair,
        rtcp_not_forwarded,
        bye_on_remove_and_stop,
        bye_forwarded,
        csrc_list,
        csrc_list_capped,
        source_filter,
        timestamp_after_overrun,
        ssrc_collision,
        member_timeout
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_mix),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_mix).

%% ---- cases ----

three_party(_Config) ->
    {Conf, Eps} = conference(lists:sublist(?F, 3)),
    judge_n_minus_one(Conf, Eps),
    close(Conf, Eps).

four_party(_Config) ->
    {Conf, Eps} = conference(?F),
    judge_n_minus_one(Conf, Eps),
    close(Conf, Eps).

%% A party joining is heard from then on; a party leaving stops being
%% heard and stops receiving.
join_and_leave(_Config) ->
    {Conf, [A, B] = Eps} = conference([440, 1100]),
    C = join(Conf, 1700),
    listen([A, B, C], 1000),
    ct:log("legs after join: ~p", [chappe_mix:legs(Conf)]),
    assert_hears(A, [1100, 1700], [440]),
    ok = chappe_mix:remove_leg(Conf, leg(B)),
    listen([A, C], 1000),
    assert_hears(A, [1700], [440, 1100]),
    assert_hears(C, [440], [1100, 1700]),
    close(Conf, Eps ++ [C]).

%% A muted party hears everyone and is heard by no one.
mute(_Config) ->
    {Conf, [A, _B, C] = Eps} = conference([440, 1100, 1700]),
    ok = chappe_mix:mute(Conf, leg(C), true),
    listen(Eps, 1000),
    assert_hears(A, [1100], [440, 1700]),
    assert_hears(C, [440, 1100], [1700]),
    ok = chappe_mix:mute(Conf, leg(C), false),
    listen(Eps, 1000),
    assert_hears(A, [1100, 1700], [440]),
    close(Conf, Eps).

%% 5% random loss on one leg: the others are still heard cleanly, the
%% lossy one is still heard, and the loss is counted.
loss_on_one_leg(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    A = join(Conf, 440),
    B = join(Conf, 1100),
    C = join(Conf, 1700, #{loss => 0.05}),
    listen([A, B, C], 2000),
    assert_hears(A, [1100, 1700], [440]),
    assert_hears(B, [440, 1700], [1100]),
    #{lost := Lost} = leg_stats(Conf, leg(C)),
    ?assert(Lost > 0),
    close(Conf, [A, B, C]).

%% A sender changing SSRC mid-stream (a re-INVITE, a failover) is still
%% heard after the switch.
ssrc_change(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    A = join(Conf, 440),
    B = join(Conf, 1100, #{ssrc_switch_after => 10}),
    timer:sleep(400),
    listen([A, B], 1000),
    assert_hears(A, [1100], [440]),
    close(Conf, [A, B]).

%% Bytes that are not RTP, and RTCP, are counted and dropped; the
%% conference keeps mixing.
garbage_is_dropped(_Config) ->
    {Conf, [A, B] = Eps} = conference([440, 1100]),
    {ok, S} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}]),
    Port = local_port(Conf, leg(B)),
    [
        ok = gen_udp:send(S, {127, 0, 0, 1}, Port, G)
     || G <- [<<>>, <<"junk">>, <<2:2, 0:6, 200, 0:48, 0:32>>]
    ],
    gen_udp:close(S),
    listen(Eps, 1000),
    assert_hears(A, [1100], [440]),
    ?assert(is_process_alive(Conf)),
    close(Conf, Eps).

%% A leg moved to another conference keeps its port and far end, so the
%% peer needs no re-INVITE: it leaves the first mix and joins the second.
move_keeps_the_port(_Config) ->
    {Conf1, [A, B] = Eps1} = conference([440, 1100]),
    {Conf2, [C] = Eps2} = conference([1700]),
    Port = local_port(Conf1, leg(B)),
    {ok, Moved} = chappe_mix:move_leg(Conf1, leg(B), Conf2),
    ?assertEqual(Port, local_port(Conf2, Moved)),
    ?assertEqual({error, not_found}, chappe_mix:remove_leg(Conf1, leg(B))),
    ?assertEqual({error, not_found}, chappe_mix:move_leg(Conf1, 999, Conf2)),
    listen([A, B, C], 1000),
    assert_hears(C, [1100], [440, 1700]),
    assert_hears(B, [1700], [440, 1100]),
    assert_hears(A, [], [1100, 1700]),
    %% the new owner of the socket is the second conference: stopping the
    %% first one leaves the moved leg working
    ok = chappe_mix:stop(Conf1),
    listen([B, C], 1000),
    assert_hears(C, [1100], [1700]),
    [chappe_mix_test_tone:stop(P) || {P, _, _} <- Eps1],
    close(Conf2, Eps2).

%% The conference belongs to its owner: when the owner dies the
%% conference stops and its ports are free again.
owner_death_closes(_Config) ->
    Self = self(),
    Owner = spawn(fun() ->
        {ok, C} = chappe_mix:start(#{}),
        {ok, _, #{port := P}} = chappe_mix:add_leg(C, #{}),
        Self ! {conf, C, P},
        receive
            stop -> ok
        end
    end),
    {Conf, Port} =
        receive
            {conf, C, P} -> {C, P}
        after 2000 -> ct:fail(no_conf)
        end,
    Ref = monitor(process, Conf),
    Owner ! stop,
    receive
        {'DOWN', Ref, process, Conf, _} -> ok
    after 2000 -> ct:fail(conf_survived_owner)
    end,
    assert_port_free(Port).

stop_closes(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {ok, _, #{port := Port}} = chappe_mix:add_leg(Conf, #{}),
    ok = chappe_mix:stop(Conf),
    ?assertNot(is_process_alive(Conf)),
    assert_port_free(Port).

%% With trace set, every tick reports when it was due, when it fired and
%% when its last packet went out; without it, nothing. The timer is armed
%% at millisecond resolution, truncated, so a tick can fire up to 1 ms
%% before it was due (seen on the first run of this case): allow that.
tick_trace(_Config) ->
    {ok, Quiet} = chappe_mix:start(#{}),
    {ok, Conf} = chappe_mix:start(#{trace => self()}),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{}),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {{127, 0, 0, 1}, 9}}),
    flush_ticks(),
    Ticks = [next_tick(Conf) || _ <- lists:seq(1, 10)],
    ct:log("ticks: ~p", [Ticks]),
    Ms = erlang:convert_time_unit(1, millisecond, native),
    [
        ?assert(D - Ms =< St andalso St =< Dn, {order, T})
     || #{due := D, start := St, done := Dn} = T <- Ticks
    ],
    ?assertEqual([2], lists:usort([L || #{legs := L} <- Ticks])),
    Dues = [D || #{due := D} <- Ticks],
    Period = erlang:convert_time_unit(20, millisecond, native),
    [
        ?assertEqual(0, (B - A) rem Period)
     || {A, B} <- lists:zip(
            lists:droplast(Dues), tl(Dues)
        )
    ],
    ok = chappe_mix:stop(Conf),
    flush_ticks(),
    timer:sleep(200),
    receive
        {chappe_mix_tick, Quiet, _} -> ct:fail(untraced_conf_traced)
    after 0 -> ok
    end,
    ok = chappe_mix:stop(Quiet).

%% The latency probe against a reflector that holds every packet from A
%% for exactly 60 ms before handing it to B: the probe must never report
%% less than the delay it is given, and on a loaded box not much more.
probe_calibration(_Config) ->
    {Probe, _PA, PB} = chappe_mix_probe:start(#{}),
    Delay = 60,
    {Refl, RPort} = reflector(PB, Delay),
    R = chappe_mix_probe:run(Probe, #{
        a_dst => {{127, 0, 0, 1}, RPort},
        b_dst => {{127, 0, 0, 1}, RPort},
        bursts => 10,
        gap => 10,
        settle => 5
    }),
    ct:log("calibration, ~p ms reflector: ~p", [Delay, R]),
    chappe_mix_probe:stop(Probe),
    exit(Refl, kill),
    #{latencies_us := L} = R,
    ?assert(length(L) >= 8, {bursts_lost, R}),
    ?assert(lists:min(L) >= Delay * 1000, {below_delay, R}),
    ?assert(
        chappe_mix_probe:percentile(L, 50) < (Delay + 100) * 1000, {slow, R}
    ).

%% Forwards what arrives from the probe's A socket to its B port, Delay ms
%% later. B's own stream arrives here too and is dropped.
reflector(PB, Delay) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, S} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}, {active, true}]),
        {ok, P} = inet:port(S),
        Parent ! {self(), P},
        reflect(S, PB, Delay)
    end),
    receive
        {Pid, P} -> {Pid, P}
    after 2000 -> ct:fail(reflector)
    end.

reflect(S, PB, Delay) ->
    receive
        {udp, S, _, FromPort, Pkt} when FromPort =/= PB ->
            erlang:send_after(Delay, self(), {out, Pkt}),
            reflect(S, PB, Delay);
        {udp, S, _, _, _} ->
            reflect(S, PB, Delay);
        {out, Pkt} ->
            ok = gen_udp:send(S, {127, 0, 0, 1}, PB, Pkt),
            reflect(S, PB, Delay)
    end.

next_tick(Conf) ->
    receive
        {chappe_mix_tick, Conf, T} -> T
    after 1000 -> ct:fail(no_tick_trace)
    end.

flush_ticks() ->
    receive
        {chappe_mix_tick, _, _} -> flush_ticks()
    after 0 -> ok
    end.

%% ---- RFC 3550 mixer rules, on the wire ----

%% A leg on RTCP-mux gets compound SR + SDES CNAME on its RTP port. The
%% first comes 1.03 to 3.08 s after the leg opens (half the 5 s minimum,
%% times 0.5 to 1.5, over e - 3/2), the next 2.05 to 6.16 s later: the
%% interval of 6.3.1 with the fixed bandwidth documented in
%% chappe_mix_rtcp. Upper bounds allow one 20 ms tick (the due time is
%% checked on the mix clock) and 100 ms of delivery. The sender info
%% counts what the peer got, and the report block describes the peer's
%% stream: one packet skipped, its SR echoed in LSR.
%% req: R3550-01 R3550-02 R3550-07 R3550-15 R3550-22 R3550-029 R3550-030 R3550-031 R3550-041 R3550-058 R3550-079 R3550-100 R3550-111 R3551-006 R3551-008 R3551-013
rtcp_sender_reports(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {Peer, PPort} = chappe_mix_test_peer:start(#{ssrc => 16#AAAA, skip => [5]}),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Leg, #{port := MPort, rtcp_port := MPort}} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, PPort}}
    ),
    ok = chappe_mix_test_peer:set(Peer, dst, {?LO, MPort}),
    %% the peer's own SR, 300 ms in
    timer:sleep(300),
    PeerNtp = chappe_mix_rtcp:ntp(os:system_time(microsecond)),
    ok = chappe_mix_test_peer:send(
        Peer,
        {rtp, {?LO, MPort}},
        chappe_mix_rtcp:build([
            #{
                type => sr,
                ssrc => 16#AAAA,
                ntp => PeerNtp,
                ts => 2400,
                packets => 14,
                octets => 2240,
                blocks => []
            },
            #{type => sdes, chunks => [{16#AAAA, [{cname, <<"peer@a">>}]}]}
        ])
    ),
    wait_until(fun() -> length(mixer_rtcp(Peer)) >= 2 end, 3078 + 6156 + 1000),
    Pkts = chappe_mix_test_peer:packets(Peer),
    [{rtp, T1, [Sr1, Sdes1]}, {rtp, T2, [Sr2, _]} | _] =
        chappe_mix_test_peer:rtcp(Pkts),
    ct:log("first ~p ms, next ~p ms later:~n~p~n~p~n~p", [
        T1 - T0, T2 - T1, Sr1, Sdes1, Sr2
    ]),
    ?assert(T1 - T0 >= 1026 andalso T1 - T0 =< 3078 + 120, {first, T1 - T0}),
    ?assert(T2 - T1 >= 2052 - 20 andalso T2 - T1 =< 6156 + 120, {next, T2 - T1}),
    #{ssrc := Mine} = leg_stats(Conf, Leg),
    ?assertMatch(#{type := sr, ssrc := Mine}, Sr1),
    ?assertMatch(
        #{type := sdes, chunks := [{Mine, [{cname, <<_, _/binary>>}]}]}, Sdes1
    ),
    %% the counts are what reached the peer before the report, the RTP
    %% timestamp that of the last of them, the NTP clock wall time
    Before = [
        P
     || {T, #{ssrc := S} = P} <- chappe_mix_test_peer:rtp(Pkts),
        T =< T1,
        S =:= Mine
    ],
    #{packets := N1, octets := O1, ts := Ts1, ntp := Ntp1} = Sr1,
    ?assert(abs(N1 - length(Before)) =< 1, {packets, N1, length(Before)}),
    ?assertEqual(160 * N1, O1),
    LastTs = maps:get(ts, lists:last(Before)),
    ?assert(
        lists:member(Ts1, [LastTs, (LastTs + 160) band 16#FFFFFFFF]),
        {ts, Ts1, LastTs}
    ),
    NowNtp = chappe_mix_rtcp:ntp(os:system_time(microsecond)),
    ?assert(abs(NowNtp - Ntp1) < 30 bsl 32, {ntp, Ntp1}),
    %% the reception report: one lost, the highest seq sent, the peer's
    %% SR echoed and its age
    #{blocks := [Block]} = Sr2,
    Lsr = (PeerNtp bsr 16) band 16#FFFFFFFF,
    ?assertMatch(#{ssrc := 16#AAAA, lost := 1, lsr := Lsr}, Block),
    #{highest := High, fraction := F, dlsr := Dlsr} = Block,
    ?assert(High > 1000 andalso High < 1000 + 600, {highest, High}),
    ?assert(F >= 0 andalso F < 256),
    ?assert(Dlsr > 65536, {dlsr, Dlsr}),
    #{rtcp_sent := Sent, rtcp_received := 1} = chappe_mix:stats(Conf),
    ?assert(Sent >= 2),
    chappe_mix_test_peer:stop(Peer),
    ok = chappe_mix:stop(Conf).

%% With rtcp => pair the leg's RTP port is even and RTCP uses the next
%% one, both ways: reports go to the far end's port + 1, from ours, and
%% none come on the RTP port.
%% req: R3550-205 R3550-208 R3550-211 R5761-010
rtcp_port_pair(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {Peer, PPort} = chappe_mix_test_peer:start(#{pair => true}),
    {ok, Leg, #{port := MPort, rtcp_port := RPort}} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, PPort}, rtcp => pair}
    ),
    ?assertEqual(0, MPort rem 2),
    ?assertEqual(MPort + 1, RPort),
    ok = chappe_mix_test_peer:set(Peer, dst, {?LO, MPort}),
    ok = chappe_mix_test_peer:send(
        Peer,
        {rtcp, {?LO, RPort}},
        chappe_mix_rtcp:build([#{type => rr, ssrc => 1, blocks => []}])
    ),
    wait_until(fun() -> mixer_rtcp(Peer) =/= [] end, 3078 + 1000),
    Pkts = chappe_mix_test_peer:packets(Peer),
    Rtcp = chappe_mix_test_peer:rtcp(Pkts),
    ?assertMatch([{rtcp, _, [#{type := sr}, #{type := sdes}]} | _], Rtcp),
    ?assertEqual([rtcp], lists:usort([Tag || {Tag, _, _} <- Rtcp])),
    ?assertEqual(
        [{?LO, RPort}], lists:usort([From || {rtcp, From, _, _} <- Pkts])
    ),
    ?assertMatch(#{rtcp_received := 1, rtcp_port := RPort}, leg_stats(Conf, Leg)),
    chappe_mix_test_peer:stop(Peer),
    ok = chappe_mix:stop(Conf).

%% RTCP from one leg never reaches another: B's reports come from the
%% mixer's B stream and describe only B's own source; A's SR, RR, APP and
%% XR are consumed and counted, and a bare XR on the RTP port is taken
%% for RTCP (and refused by the A.2 checks), not for RTP. A's CNAME does
%% reach B, in the SDES chunk for A's SSRC (a CSRC there), with the NAME
%% the leg was given.
%% req: R3550-06 R3550-08 R3550-09 R3550-047 R3550-137 R3551-010 R5761-003 R5761-011
rtcp_not_forwarded(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {PA, PortA} = chappe_mix_test_peer:start(#{ssrc => 16#A}),
    {PB, PortB} = chappe_mix_test_peer:start(#{ssrc => 16#B}),
    {ok, LA, #{port := MA}} = chappe_mix:add_leg(Conf, #{
        remote => {?LO, PortA}, name => <<"Alice">>
    }),
    {ok, LB, #{port := MB}} = chappe_mix:add_leg(Conf, #{
        remote => {?LO, PortB}
    }),
    ok = chappe_mix_test_peer:set(PA, dst, {?LO, MA}),
    ok = chappe_mix_test_peer:set(PB, dst, {?LO, MB}),
    timer:sleep(200),
    RrA = chappe_mix_rtcp:build([#{type => rr, ssrc => 16#A, blocks => []}]),
    FromA = [
        chappe_mix_rtcp:build([
            #{
                type => sr,
                ssrc => 16#A,
                ntp => 1,
                ts => 1,
                packets => 1,
                octets => 160,
                blocks => [block(16#B)]
            },
            #{type => sdes, chunks => [{16#A, [{cname, <<"peer@a">>}]}]}
        ]),
        chappe_mix_rtcp:build([
            #{type => rr, ssrc => 16#A, blocks => [block(16#B)]}
        ]),
        <<RrA/binary, 2:2, 0:1, 0:5, 204, 2:16, 16#A:32, "test">>,
        <<RrA/binary, 2:2, 0:1, 0:5, 207, 1:16, 16#A:32>>,
        <<2:2, 0:1, 0:5, 207, 1:16, 16#A:32>>
    ],
    [ok = chappe_mix_test_peer:send(PA, {rtp, {?LO, MA}}, P) || P <- FromA],
    wait_until(fun() -> mixer_rtcp(PB) =/= [] end, 3078 + 1000),
    RtcpB = [Parts || {_, _, Parts} <- mixer_rtcp(PB)],
    ct:log("B got: ~p", [RtcpB]),
    #{ssrc := MineB} = leg_stats(Conf, LB),
    [
        begin
            [#{ssrc := MineB, blocks := Blocks} | Rest] = Parts,
            ?assertEqual([16#B], lists:usort([S || #{ssrc := S} <- Blocks])),
            ?assertEqual([sdes], lists:usort([T || #{type := T} <- Rest]))
        end
     || Parts <- RtcpB
    ],
    Chunks = lists:append([
        Cs
     || Parts <- RtcpB, #{type := sdes, chunks := Cs} <- Parts
    ]),
    ?assert(
        lists:member(
            {16#A, [{cname, <<"peer@a">>}, {name, <<"Alice">>}]}, Chunks
        ),
        Chunks
    ),
    ?assertMatch(
        #{rtcp_received := 4, rtcp_invalid := 1, other_pt := 0},
        leg_stats(Conf, LA)
    ),
    ?assertMatch(
        #{rtcp_received := 4, rtcp_invalid := 1}, chappe_mix:stats(Conf)
    ),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB]],
    ok = chappe_mix:stop(Conf).

%% Removing a leg sends it a BYE for the mixer's SSRC on that leg and the
%% sources it was hearing, at once, and the legs left get a BYE for the
%% source that left; stopping the conference sends every leg left a BYE
%% for the mixer's SSRC and its sources. Each BYE rides a compound led by
%% an SR and an SDES CNAME, BYE last.
%% req: R3550-03 R3550-23 R3550-01 R3550-15 R3550-031 R3550-039 R3550-088
bye_on_remove_and_stop(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    [{PA, LA}, {PB, LB}, {PC, LC}] = [
        peer_leg(Conf, Ssrc)
     || Ssrc <- [16#A, 16#B, 16#C]
    ],
    wait_until(fun() -> csrcs_seen(PB) =:= [16#A, 16#C] end, 2000),
    #{ssrc := MB} = leg_stats(Conf, LB),
    ok = chappe_mix:remove_leg(Conf, LB),
    wait_until(fun() -> byes(PB) =/= [] end, 1000),
    [ByeB] = byes(PB),
    ct:log("BYE on remove: ~p", [ByeB]),
    ?assertMatch(
        [
            #{type := sr, ssrc := MB},
            #{type := sdes, chunks := [{MB, [{cname, _}]}]},
            #{type := bye}
        ],
        ByeB
    ),
    ?assertEqual(
        lists:sort([MB, 16#A, 16#C]),
        lists:sort(maps:get(ssrcs, lists:last(ByeB)))
    ),
    wait_until(fun() -> csrcs_seen(PA) =:= [16#C] end, 2000),
    wait_until(fun() -> byes(PA) =/= [] andalso byes(PC) =/= [] end, 1000),
    #{ssrc := MA} = leg_stats(Conf, LA),
    #{ssrc := MC} = leg_stats(Conf, LC),
    [LeftA] = byes(PA),
    [LeftC] = byes(PC),
    ?assertMatch([#{type := sr, ssrc := MA}, #{type := sdes}, _], LeftA),
    ?assertMatch([#{type := sr, ssrc := MC}, #{type := sdes}, _], LeftC),
    ?assertEqual([16#B], maps:get(ssrcs, lists:last(LeftA))),
    ?assertEqual([16#B], maps:get(ssrcs, lists:last(LeftC))),
    ok = chappe_mix:stop(Conf),
    wait_until(
        fun() -> length(byes(PA)) =:= 2 andalso length(byes(PC)) =:= 2 end,
        1000
    ),
    [_, ByeA] = byes(PA),
    [_, ByeC] = byes(PC),
    ?assertEqual(
        lists:sort([MA, 16#C]), lists:sort(maps:get(ssrcs, lists:last(ByeA)))
    ),
    ?assertEqual(
        lists:sort([MC, 16#A]), lists:sort(maps:get(ssrcs, lists:last(ByeC)))
    ),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB, PC]].

%% A BYE a party sends for its source is forwarded to the others, the
%% SSRC unchanged, on a compound of their own.
%% req: R3550-10 R3550-19 R3550-172
bye_forwarded(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    [{PA, LA}, {PB, LB}] = [peer_leg(Conf, Ssrc) || Ssrc <- [16#A, 16#B]],
    wait_until(fun() -> csrcs_seen(PA) =:= [16#B] end, 2000),
    #{port := MB} = leg_stats(Conf, LB),
    ok = chappe_mix_test_peer:set(PB, sending, false),
    ok = chappe_mix_test_peer:send(
        PB,
        {rtp, {?LO, MB}},
        chappe_mix_rtcp:build([
            #{type => rr, ssrc => 16#B, blocks => []},
            #{type => sdes, chunks => [{16#B, [{cname, <<"b">>}]}]},
            #{type => bye, ssrcs => [16#B]}
        ])
    ),
    wait_until(fun() -> byes(PA) =/= [] end, 1000),
    [Parts] = byes(PA),
    #{ssrc := MA} = leg_stats(Conf, LA),
    ?assertMatch([#{type := sr, ssrc := MA}, #{type := sdes} | _], Parts),
    ?assertEqual([16#B], maps:get(ssrcs, lists:last(Parts))),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB]],
    ok = chappe_mix:stop(Conf).

%% Each mixed packet names the sources in that leg's mix in its CSRC
%% list, CC set: the other unmuted legs that had a frame, never the
%% listener itself.
%% req: R3550-04 R3550-05
csrc_list(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    [{PA, _}, {PB, _}, {PC, LC}] = [
        peer_leg(Conf, Ssrc)
     || Ssrc <- [16#A, 16#B, 16#C]
    ],
    wait_until(fun() -> csrcs_seen(PA) =:= [16#B, 16#C] end, 2000),
    wait_until(fun() -> csrcs_seen(PB) =:= [16#A, 16#C] end, 1000),
    wait_until(fun() -> csrcs_seen(PC) =:= [16#A, 16#B] end, 1000),
    ok = chappe_mix:mute(Conf, LC, true),
    wait_until(fun() -> csrcs_seen(PA) =:= [16#B] end, 2000),
    ok = chappe_mix_test_peer:set(PB, sending, false),
    wait_until(fun() -> csrcs_seen(PA) =:= [] end, 2000),
    ?assertMatch([16#A], csrcs_seen(PB)),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB, PC]],
    ok = chappe_mix:stop(Conf).

%% Seventeen talkers: each listener's list holds 15, the most CC can say,
%% and never the listener.
%% req: R3550-05
csrc_list_capped(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    Peers = [peer_leg(Conf, Ssrc) || Ssrc <- lists:seq(1, 17)],
    {P1, _} = hd(Peers),
    wait_until(
        fun() -> is_list(csrcs_seen(P1)) andalso length(csrcs_seen(P1)) =:= 15 end,
        3000
    ),
    Lists = [
        C
     || {_, #{csrcs := C}} <- chappe_mix_test_peer:rtp(
            chappe_mix_test_peer:packets(P1)
        )
    ],
    ?assert(lists:max([length(C) || C <- Lists]) =:= 15),
    ?assertNot(lists:member(1, lists:append(Lists))),
    [chappe_mix_test_peer:stop(P) || {P, _} <- Peers],
    ok = chappe_mix:stop(Conf).

%% Once a leg has latched its source address, RTP from anywhere else is
%% dropped and counted, never mixed. set_remote/3 unlatches: the next
%% sender is taken, and the old one is now the stranger.
%% req: R3550-177
source_filter(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {PA, LA} = peer_leg(Conf, 16#A),
    #{port := MA} = leg_stats(Conf, LA),
    timer:sleep(200),
    {Intruder, IPort} = chappe_mix_test_peer:start(#{
        ssrc => 16#BAD, dst => {?LO, MA}
    }),
    timer:sleep(500),
    #{filtered := F1, received := R1} = leg_stats(Conf, LA),
    ?assert(F1 >= 10, {filtered, F1}),
    #{filtered := F1s} = chappe_mix:stats(Conf),
    ?assert(F1s >= F1),
    ok = chappe_mix_test_peer:set(PA, sending, false),
    timer:sleep(100),
    ok = chappe_mix:set_remote(Conf, LA, {?LO, IPort}),
    timer:sleep(300),
    #{received := R2, filtered := F2} = leg_stats(Conf, LA),
    ?assert(R2 - R1 >= 5, {not_relatched, R1, R2}),
    ok = chappe_mix_test_peer:set(PA, sending, true),
    timer:sleep(300),
    #{filtered := F3} = leg_stats(Conf, LA),
    ?assert(F3 - F2 >= 5, {old_source_accepted, F2, F3}),
    [chappe_mix_test_peer:stop(P) || P <- [PA, Intruder]],
    ok = chappe_mix:stop(Conf).

%% After an overrun (the tick fired periods late and skipped them) the
%% next packet's timestamp is ahead by the frames skipped, so the RTP
%% clock stays the sampling clock, while the sequence number still steps
%% by one. Each packet is paired with the trace of the tick that sent it:
%% both come from the conference in order, and the ticks before the leg
%% existed report no leg.
%% req: R3550-008 R3550-009 R3551-024 R3551-030
timestamp_after_overrun(_Config) ->
    {ok, Conf} = chappe_mix:start(#{trace => self()}),
    {Peer, PPort} = chappe_mix_test_peer:start(#{sending => false}),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {?LO, PPort}}),
    Traces0 = drain_ticks(Conf, 10),
    ok = sys:suspend(Conf),
    timer:sleep(150),
    ok = sys:resume(Conf),
    Traces = Traces0 ++ drain_ticks(Conf, 20),
    timer:sleep(100),
    ok = chappe_mix:stop(Conf),
    flush_ticks(),
    Pkts = [
        P
     || {_, P} <- chappe_mix_test_peer:rtp(chappe_mix_test_peer:packets(Peer))
    ],
    chappe_mix_test_peer:stop(Peer),
    Period = erlang:convert_time_unit(20, millisecond, native),
    Missed = [
        max(0, (St - D) div Period)
     || #{due := D, start := St, legs := 1} <- Traces
    ],
    ct:log("missed per tick: ~p", [Missed]),
    ?assert(lists:sum(Missed) >= 3, {no_overrun, Missed}),
    N = min(length(Pkts), length(Missed)),
    ?assert(N >= 25, {packets, length(Pkts), length(Missed)}),
    Pairs = lists:zip3(
        lists:sublist(Pkts, N - 1),
        tl(lists:sublist(Pkts, N)),
        lists:sublist(Missed, N - 1)
    ),
    [
        begin
            ?assertEqual((Seq + 1) band 16#FFFF, Seq1),
            ?assertEqual(
                (Ts + 160 * (1 + M)) band 16#FFFFFFFF, Ts1, {ts, Ts, Ts1, M}
            )
        end
     || {#{seq := Seq, ts := Ts}, #{seq := Seq1, ts := Ts1}, M} <- Pairs
    ],
    %% no silence suppression, so no talkspurt to mark, first packet too
    ?assertEqual([false], lists:usort([M || #{marker := M} <- Pkts])),
    ok.

%% A peer using the mixer's own SSRC on that leg: the mixer says BYE for
%% it and picks another, not one in use in the conference. The same
%% address colliding again is a loop, and is dropped without a second
%% change (8.2: once only); so is a packet naming our SSRC as a CSRC (our
%% stream mixed back to us). A source on another leg taking the SSRC
%% makes the leg move too: it would show as a CSRC equal to the stream's
%% own SSRC there.
%% req: R3550-25 R3550-26 R3550-180 R3550-181 R3550-11 R3550-20
ssrc_collision(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {PA, LA} = peer_leg(Conf, 16#A),
    wait_until(fun() -> csrcs_seen(PA) =/= none end, 1000),
    #{ssrc := Old} = leg_stats(Conf, LA),
    ok = chappe_mix_test_peer:set(PA, ssrc, Old),
    wait_until(fun() -> byes(PA) =/= [] end, 1000),
    [Bye] = byes(PA),
    ?assertMatch([#{ssrc := Old}, #{type := sdes} | _], Bye),
    ?assertEqual([Old], maps:get(ssrcs, lists:last(Bye))),
    #{ssrc := New, collisions := 1} = leg_stats(Conf, LA),
    ?assertNotEqual(Old, New),
    ok = chappe_mix_test_peer:clear(PA),
    timer:sleep(200),
    ?assertEqual([New], lists:usort([S || {_, #{ssrc := S}} <- rtp_seen(PA)])),
    %% the loop: the same address now sends the new SSRC
    ok = chappe_mix_test_peer:set(PA, ssrc, New),
    timer:sleep(300),
    #{loops := Loops} = leg_stats(Conf, LA),
    ?assertMatch(#{ssrc := New, collisions := 1}, leg_stats(Conf, LA)),
    ?assert(Loops >= 5, {loops, Loops}),
    ?assertEqual([], byes(PA)),
    #{collisions := 1, loops := Total} = chappe_mix:stats(Conf),
    ?assert(Total >= Loops),
    %% our SSRC in the CSRC list: a loop, not mixed, no change
    ok = chappe_mix_test_peer:set(PA, ssrc, 16#A2),
    ok = chappe_mix_test_peer:set(PA, csrcs, [7, New]),
    timer:sleep(300),
    #{loops := Loops2, received := R1} = leg_stats(Conf, LA),
    ?assert(Loops2 - Loops >= 5, {csrc_loop, Loops, Loops2}),
    ok = chappe_mix_test_peer:set(PA, csrcs, []),
    timer:sleep(300),
    #{loops := Loops3, received := R2} = leg_stats(Conf, LA),
    ?assert(R2 - R1 >= 5 andalso Loops3 - Loops2 =< 1, {R1, R2, Loops3}),
    ?assertEqual([], byes(PA)),
    %% another leg's source takes leg A's SSRC: leg A moves
    {PB, _} = peer_leg(Conf, New),
    wait_until(fun() -> byes(PA) =/= [] end, 1000),
    [ByeA] = byes(PA),
    ?assertEqual([New], maps:get(ssrcs, lists:last(ByeA))),
    #{ssrc := Newer, collisions := 2} = leg_stats(Conf, LA),
    ?assertNotEqual(New, Newer),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB]],
    ok = chappe_mix:stop(Conf).

%% A source silent for five report intervals (25 s at the 5 s minimum)
%% leaves the leg's reports: the first report after that carries no
%% block for it, and the leg no longer names a source.
%% req: R3550-17 R3550-083 R3550-085
member_timeout(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {PA, LA} = peer_leg(Conf, 16#A),
    timer:sleep(1000),
    ok = chappe_mix_test_peer:set(PA, sending, false),
    Stop = erlang:monotonic_time(millisecond),
    ?assertMatch(#{source_ssrc := 16#A}, leg_stats(Conf, LA)),
    After = fun() ->
        [
            P
         || {_, T, [P | _]} <- mixer_rtcp(PA), T > Stop + 25000 + 100
        ]
    end,
    wait_until(fun() -> After() =/= [] end, 25000 + 6156 + 2000),
    Reports = [P || {_, _, [P | _]} <- mixer_rtcp(PA)],
    ct:log("reports: ~p", [Reports]),
    ?assertMatch([#{blocks := [#{ssrc := 16#A}]} | _], Reports),
    ?assertMatch([#{blocks := []} | _], After()),
    ?assertMatch(#{source_ssrc := undefined}, leg_stats(Conf, LA)),
    chappe_mix_test_peer:stop(PA),
    ok = chappe_mix:stop(Conf).

%% ---- protocol case helpers ----

%% A raw peer streaming under Ssrc and a leg for it, each told where the
%% other is. Returns {Peer, Leg}.
peer_leg(Conf, Ssrc) ->
    {Peer, PPort} = chappe_mix_test_peer:start(#{ssrc => Ssrc}),
    {ok, Leg, #{port := MPort}} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, PPort}}
    ),
    ok = chappe_mix_test_peer:set(Peer, dst, {?LO, MPort}),
    {Peer, Leg}.

rtp_seen(Peer) ->
    chappe_mix_test_peer:rtp(chappe_mix_test_peer:packets(Peer)).

%% The CSRC list of the last mixed packet Peer got, sorted; none before
%% the first.
csrcs_seen(Peer) ->
    case lists:reverse(rtp_seen(Peer)) of
        [{_, #{csrcs := C}} | _] -> lists:sort(C);
        [] -> none
    end.

%% RTCP compounds Peer got.
mixer_rtcp(Peer) ->
    chappe_mix_test_peer:rtcp(chappe_mix_test_peer:packets(Peer)).

%% The compounds carrying a BYE, as lists of parts.
byes(Peer) ->
    [
        Parts
     || {_, _, Parts} <- mixer_rtcp(Peer),
        is_list(Parts),
        lists:any(fun(#{type := T}) -> T =:= bye end, Parts)
    ].

block(Ssrc) ->
    #{
        ssrc => Ssrc,
        fraction => 0,
        lost => 0,
        highest => 1,
        jitter => 0,
        lsr => 0,
        dlsr => 0
    }.

drain_ticks(Conf, N) ->
    [next_tick(Conf) || _ <- lists:seq(1, N)].

wait_until(Fun, Ms) ->
    wait_until(Fun, erlang:monotonic_time(millisecond) + Ms, Ms).

wait_until(Fun, Deadline, Ms) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail({timeout, Ms});
                false ->
                    timer:sleep(50),
                    wait_until(Fun, Deadline, Ms)
            end
    end.

%% ---- helpers ----

%% A conference with one endpoint per frequency. Endpoints are
%% {Pid, Leg, Freq}.
conference(Freqs) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {Conf, [join(Conf, F) || F <- Freqs]}.

join(Conf, Freq) ->
    join(Conf, Freq, #{}).

join(Conf, Freq, Opts) ->
    {ok, Leg, #{port := MixPort}} = chappe_mix:add_leg(Conf, #{}),
    {Pid, _} = chappe_mix_test_tone:endpoint(
        Opts#{freq => Freq, dst => {{127, 0, 0, 1}, MixPort}}
    ),
    {Pid, Leg, Freq}.

leg({_Pid, Leg, _F}) -> Leg.

%% Let the streams settle, then record Ms of what each endpoint hears.
listen(Eps, Ms) ->
    timer:sleep(200),
    [chappe_mix_test_tone:clear(P) || {P, _, _} <- Eps],
    timer:sleep(Ms).

%% Every party hears all the others and never itself, judged like
%% assert_hears/3 on every endpoint at once.
%%
%% The endpoints and the mixer share this node, so a loaded host stalls
%% the test senders: the leg's jitter buffer underruns and plays silence,
%% grows its prefill, then trims the catch-up burst past its depth, and
%% a mixer tick more than a period late skips the frames it missed, so a
%% second of listening can come back with two or three 200 ms windows.
%% One stall across a window edge then costs two windows and the tone
%% reads {missing, F, 3, 5}. So: wait until the mix is steady (the last
%% 200 ms of every receiver meets the contract twice in a row, up to
%% 5 s), and when a listen comes back short of presence or samples,
%% listen again, up to three times, with the same thresholds. A leak
%% fails at once in any listen: no load excuses one, and a mixer that
%% stops mixing fails all three.
judge_n_minus_one(Conf, Eps) ->
    Freqs = [F || {_, _, F} <- Eps],
    Checks = [{P, Freqs -- [F], [F]} || {P, _, F} <- Eps],
    Waited = steady(Checks, erlang:monotonic_time(millisecond) + 5000),
    ct:log("steady after ~p ms", [Waited]),
    judge(Conf, Checks, 1000, 3).

judge(Conf, Checks, Ms, Tries) ->
    [chappe_mix_test_tone:clear(P) || {P, _, _} <- Checks],
    timer:sleep(Ms),
    Results = [
        {Present,
            chappe_mix_test_tone:hears(
                P, {?PRESENT, ?ABSENT}, {Present, Absent}
            )}
     || {P, Present, Absent} <- Checks
    ],
    [ct:log("hears ~p: ~p", [Present, R]) || {Present, R} <- Results],
    Leaks = [L || {_, {error, {leaked, _, _} = L, _}} <- Results],
    Short = [E || {_, {error, E, _}} <- Results],
    case {Leaks, Short} of
        {[], []} ->
            ok;
        {[L | _], _} ->
            ct:fail(L);
        {[], [E | _]} when Tries > 1 ->
            ct:log("listening again after ~p; conference ~p, legs ~p", [
                E, chappe_mix:stats(Conf), chappe_mix:legs(Conf)
            ]),
            judge(Conf, Checks, Ms, Tries - 1);
        {[], [E | _]} ->
            ct:fail(E)
    end.

%% Poll every 200 ms until two polls in a row find every receiver's last
%% 200 ms meeting its contract, or the deadline passes. Returns the wait.
steady(Checks, Deadline) ->
    steady(Checks, erlang:monotonic_time(millisecond), Deadline, 0).

steady(Checks, Start, Deadline, Good) ->
    timer:sleep(200),
    Now = erlang:monotonic_time(millisecond),
    Good1 =
        case lists:all(fun last_window_ok/1, Checks) of
            true -> Good + 1;
            false -> 0
        end,
    case Good1 >= 2 orelse Now > Deadline of
        true -> Now - Start;
        false -> steady(Checks, Start, Deadline, Good1)
    end.

last_window_ok({P, Present, Absent}) ->
    S = chappe_mix_test_tone:samples(P),
    N = length(S),
    N >= 1600 andalso
        lists:all(
            fun({F, L}) ->
                case lists:member(F, Absent) of
                    true -> L < ?ABSENT;
                    false -> L > ?PRESENT
                end
            end,
            chappe_mix_test_tone:levels(
                lists:nthtail(N - 1600, S), Absent ++ Present
            )
        ).

%% Judged by chappe_mix_test_tone:hears/3: an absent tone must be absent
%% from every 200 ms window, a present one present in 70% of them. Timing
%% is measured by the bench arms on a quiet box, not here.
assert_hears({Pid, _, _}, Present, Absent) ->
    case
        chappe_mix_test_tone:hears(Pid, {?PRESENT, ?ABSENT}, {Present, Absent})
    of
        {ok, Windows} ->
            ct:log("hears ~p, per window: ~p", [Present, Windows]);
        {error, Reason, Windows} ->
            ct:log("hears ~p, per window: ~p", [Present, Windows]),
            ct:fail(Reason)
    end.

leg_stats(Conf, Leg) ->
    [S] = [S || #{id := Id} = S <- chappe_mix:legs(Conf), Id =:= Leg],
    S.

local_port(Conf, Leg) ->
    maps:get(port, leg_stats(Conf, Leg)).

assert_port_free(Port) ->
    {ok, S} = gen_udp:open(Port, [binary, {ip, {127, 0, 0, 1}}]),
    gen_udp:close(S).

close(Conf, Eps) ->
    [chappe_mix_test_tone:stop(P) || {P, _, _} <- Eps],
    ok = chappe_mix:stop(Conf).
