%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% RFC 3550 and 3551 rows of the mixer proved on the wire: hand-built
%% RTP from a plain socket in, the mixer's RTP and RTCP read back as bytes
%% and walked by this suite's own parser, not chappe_mix_rtcp's. Two
%% cases (the `codec' group) call the session and RTCP modules directly,
%% where the row is about a state the mixer does not reach on the wire or
%% about a formula.
-module(chappe_mix_rfc_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    g711_octets_through_the_mix/1,
    unknown_pt_not_mixed/1,
    silence_suppression_resume/1,
    rtcp_on_the_wire/1,
    no_bye_from_a_leg_that_never_sent/1,
    new_ssrc_not_seen/1,
    conflicts_rtp_and_rtcp_apart/1,
    interval_bounds/1,
    bye_grace/1,
    bye_resume/1,
    bye_resume_wrap/1,
    sends_to_configured_remote/1,
    sender_30ms/1,
    sender_10ms/1,
    sender_200ms/1,
    dtmf_forwarded/1,
    dtmf_follows_relations/1,
    cascaded_csrcs/1,
    rtcp_to_the_given_port/1,
    empty_rr_first/1,
    jitter_formula/1
]).

-define(LO, {127, 0, 0, 1}).

all() ->
    [
        g711_octets_through_the_mix,
        unknown_pt_not_mixed,
        silence_suppression_resume,
        rtcp_on_the_wire,
        no_bye_from_a_leg_that_never_sent,
        new_ssrc_not_seen,
        conflicts_rtp_and_rtcp_apart,
        sends_to_configured_remote,
        sender_30ms,
        sender_10ms,
        sender_200ms,
        dtmf_forwarded,
        dtmf_follows_relations,
        cascaded_csrcs,
        rtcp_to_the_given_port,
        {group, codec}
    ].

groups() ->
    [
        {codec, [], [
            empty_rr_first,
            jitter_formula,
            interval_bounds,
            bye_grace,
            bye_resume,
            bye_resume_wrap
        ]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(chappe_mix),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_mix).

%% ---- RTP and G.711 on the wire ----

%% Leg A sends one fixed frame of 160 G.711 octets covering both signs,
%% behind two CSRCs and a header extension; leg B, the only listener,
%% hears A alone, so every mixed packet it gets is that frame (the one
%% mu-law negative zero, 0x7F, comes back as 0xFF) or silence. A wrong
%% payload offset past the extension, a codec table with a wrong sign or
%% a sample that is not one octet all change the bytes. Every packet is
%% 160 octets of payload for 20 ms. The extension A sent is not carried
%% over: every packet the mixer sends has X=0 and its payload right after
%% the CSRC list.
%% req: R3551-060 R3551-061 R3551-062 R3550-001 R3550-022
g711_octets_through_the_mix(_Config) ->
    [octets_through(Law) || Law <- [ulaw, alaw]],
    %% one octet is one sample, and the sign is the MSB: mu-law 1 and
    %% A-law (after its 0x55 mask) 1 are positive
    [
        ?assertEqual(160, length(chappe_mix_g711:decode_frame(L, frame(L))))
     || L <- [ulaw, alaw]
    ],
    [
        ?assert(sign(chappe_mix_g711:decode_frame(ulaw, <<C>>)) =:= msb(C))
     || C <- lists:seq(0, 255), C =/= 16#7F, C =/= 16#FF
    ],
    [
        ?assert(sign(chappe_mix_g711:decode_frame(alaw, <<C>>)) =:= msb(C))
     || C <- lists:seq(0, 255)
    ].

sign([S]) when S > 0 -> 1;
sign([S]) when S < 0 -> 0.

msb(C) -> C bsr 7.

octets_through(Law) ->
    {ok, Conf} = chappe_mix:start(#{law => Law}),
    {SA, PA} = open(),
    {SB, PB} = open(),
    {ok, _, #{port := MA}} = chappe_mix:add_leg(Conf, #{remote => {?LO, PA}}),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {?LO, PB}}),
    Frame = frame(Law),
    Pkts = [
        rtp(#{
            pt => law_pt(Law),
            seq => N,
            ts => N * 160,
            ssrc => 16#A,
            csrcs => [1, 2],
            ext => true,
            payload => Frame
        })
     || N <- lists:seq(1, 50)
    ],
    stream(SA, {?LO, MA}, Pkts),
    timer:sleep(100),
    ok = chappe_mix:stop(Conf),
    Raw = drain(SB),
    Heard = [P || {_, #{payload := P}} <- rtp_in(Raw)],
    Mixed = [B || {_, B} <- Raw, not is_rtcp(B)],
    ?assertNotEqual([], Mixed),
    [?assertMatch(<<2:2, _:1, 0:1, _/bits>>, B) || B <- Mixed],
    [
        ?assertEqual(12 + 4 * CC + 160, byte_size(B))
     || <<_:4, CC:4, _/binary>> = B <- Mixed
    ],
    Expect = expected(Law, Frame),
    Silence = binary:copy(silence(Law), 160),
    ct:log("~p: ~p packets, ~p the frame", [
        Law, length(Heard), length([P || P <- Heard, P =:= Expect])
    ]),
    ?assertEqual([160], lists:usort([byte_size(P) || P <- Heard])),
    ?assertEqual([], [P || P <- Heard, P =/= Expect, P =/= Silence]),
    ?assert(length([P || P <- Heard, P =:= Expect]) >= 10),
    [gen_udp:close(S) || S <- [SA, SB]].

%% 160 codes over both signs: mu-law 0x00..0x9F, A-law 0x60..0xFF.
frame(ulaw) -> list_to_binary(lists:seq(0, 159));
frame(alaw) -> list_to_binary(lists:seq(96, 255)).

expected(ulaw, F) -> <<<<(norm(C))>> || <<C>> <= F>>;
expected(alaw, F) -> F.

norm(16#7F) -> 16#FF;
norm(C) -> C.

silence(ulaw) -> <<16#FF>>;
silence(alaw) -> <<16#D5>>.

law_pt(ulaw) -> 0;
law_pt(alaw) -> 8.

%% Comfort noise (13) and a dynamic type (96) carrying loud audio are
%% not decoded into the mix: B hears only silence, and A counts them.
%% req: R3550-006
unknown_pt_not_mixed(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {SA, PA} = open(),
    {SB, PB} = open(),
    {ok, LA, #{port := MA}} = chappe_mix:add_leg(Conf, #{remote => {?LO, PA}}),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {?LO, PB}}),
    Pkts = [
        rtp(#{
            pt => PT,
            seq => N,
            ts => N * 160,
            ssrc => 16#A,
            payload => frame(ulaw)
        })
     || {N, PT} <- lists:zip(
            lists:seq(1, 40), lists:append(lists:duplicate(20, [13, 96]))
        )
    ],
    stream(SA, {?LO, MA}, Pkts),
    timer:sleep(100),
    [#{other_pt := Other}] = [
        L
     || #{id := Id} = L <- chappe_mix:legs(Conf), Id =:= LA
    ],
    ok = chappe_mix:stop(Conf),
    Heard = [P || {_, #{payload := P}} <- rtp_in(drain(SB))],
    ?assert(length(Heard) >= 20),
    ?assertEqual([binary:copy(<<16#FF>>, 160)], lists:usort(Heard)),
    ?assertEqual(40, Other),
    [gen_udp:close(S) || S <- [SA, SB]].

%% A sender that suppresses silence stops for a second, then resumes with
%% the next sequence number and a timestamp that jumped with the clock.
%% The gap is played as silence (the mixer keeps sending), the leg is
%% not reset, the gap is not counted as loss, and the audio after it is
%% mixed again.
%% req: R3551-021
silence_suppression_resume(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {SA, PA} = open(),
    {SB, PB} = open(),
    {ok, LA, #{port := MA}} = chappe_mix:add_leg(Conf, #{remote => {?LO, PA}}),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {?LO, PB}}),
    Frame = frame(ulaw),
    Talk = fun(Seqs, TsOff) ->
        [
            rtp(#{
                pt => 0,
                seq => N,
                ts => TsOff + N * 160,
                ssrc => 16#A,
                payload => Frame
            })
         || N <- Seqs
        ]
    end,
    stream(SA, {?LO, MA}, Talk(lists:seq(1, 25), 0)),
    timer:sleep(1000),
    First = rtp_in(drain(SB)),
    %% 50 frames of silence were not sent: the timestamp moves on by them
    stream(SA, {?LO, MA}, Talk(lists:seq(26, 50), 50 * 160)),
    timer:sleep(100),
    [Leg] = [L || #{id := Id} = L <- chappe_mix:legs(Conf), Id =:= LA],
    ok = chappe_mix:stop(Conf),
    Second = rtp_in(drain(SB)),
    Expect = expected(ulaw, Frame),
    Silent = binary:copy(<<16#FF>>, 160),
    Gap = lists:reverse(
        lists:takewhile(
            fun({_, #{payload := P}}) -> P =:= Silent end,
            lists:reverse(First)
        )
    ),
    ct:log("leg ~p, gap ~p packets", [Leg, length(Gap)]),
    %% about 50 silent packets while A said nothing
    ?assert(length(Gap) >= 30, {gap, length(Gap)}),
    ?assert(length([x || {_, #{payload := P}} <- Second, P =:= Expect]) >= 10),
    ?assertMatch(#{lost := 0, source_ssrc := 16#A}, Leg),
    [gen_udp:close(S) || S <- [SA, SB]].

%% A peer that sends from another port than the one configured: the
%% mixer takes its RTP (latching that address) but still sends RTP and
%% RTCP to the configured port, never to the source port.
%% req: R3550-210
sends_to_configured_remote(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {S1, P1} = open(),
    {S2, _P2} = open(),
    {ok, Leg, #{port := M}} = chappe_mix:add_leg(Conf, #{remote => {?LO, P1}}),
    Pkts = [
        rtp(#{pt => 0, seq => N, ts => N * 160, ssrc => 16#A, payload => frame(ulaw)})
     || N <- lists:seq(1, 170)
    ],
    Pid = spawn_link(fun() -> stream(S2, {?LO, M}, Pkts) end),
    Deadline = erlang:monotonic_time(millisecond) + 3078 + 1000,
    Got = until_rtcp(S1, Deadline, []),
    [#{source := Src, received := R}] = [
        L
     || #{id := Id} = L <- chappe_mix:legs(Conf), Id =:= Leg
    ],
    ok = chappe_mix:stop(Conf),
    unlink(Pid),
    exit(Pid, kill),
    {ok, P2} = inet:port(S2),
    ?assertEqual({?LO, P2}, Src),
    ?assert(R > 10),
    ?assert(length(rtp_in(Got)) > 10),
    ?assert(length(rtcp_in(Got)) >= 1),
    ?assertEqual([], drain(S2)),
    [gen_udp:close(S) || S <- [S1, S2]].

until_rtcp(Sock, Deadline, Acc) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    receive
        {udp, Sock, _, _, B} ->
            Acc1 = [{erlang:monotonic_time(millisecond), B} | Acc],
            case is_rtcp(B) of
                true -> lists:reverse(Acc1);
                false -> until_rtcp(Sock, Deadline, Acc1)
            end
    after max(0, Left) -> ct:fail({no_rtcp, length(Acc)})
    end.

%% ---- packet sizes other than 20 ms ----

%% A sender of 30 ms packets (240 octets) is heard whole: the mixer
%% plays its samples on its own 20 ms clock, so each listener hears the
%% tone in every judging window, and no 20 ms frame it gets has a run of
%% 10 ms of silence in it (the mixer would play one if it cut a packet to
%% 20 ms or played a frame it only had half of). Nothing is trimmed.
%% req: R3551-029
sender_30ms(_Config) ->
    framing(30).

%% The same for 10 ms packets (80 octets): two make a frame.
%% req: R3551-029
sender_10ms(_Config) ->
    framing(10).

%% A 200 ms packet (1600 octets, the most RFC 3551 4.2 asks a receiver
%% to take) is accepted whole: none is dropped or trimmed, and its audio
%% is heard over the next ten ticks.
%% req: R3551-032
sender_200ms(_Config) ->
    {Verdicts, Gaps, Leg} = framing_run(200, 3000),
    ct:log("200 ms: ~p, gaps ~p, leg ~p", [Verdicts, Gaps, Leg]),
    [?assertMatch({ok, _}, V) || V <- Verdicts],
    ?assertMatch(#{dropped := 0, late := 0}, Leg),
    ?assert(maps:get(received, Leg) >= 10, Leg).

framing(Ptime) ->
    {Verdicts, Gaps, Leg} = framing_run(Ptime, 2000),
    ct:log("~p ms: gaps ~w of ~w frames, leg ~p", [
        Ptime, [G || {G, _} <- Gaps], [N || {_, N} <- Gaps], Leg
    ]),
    [?assertMatch({ok, _}, V) || V <- Verdicts],
    %% a loaded box can stall the sender into an underrun, a silent frame:
    %% allow one in fifty, where a cut or a half frame gaps a third or all
    [?assert(G * 50 =< N, {gaps, G, N}) || {G, N} <- Gaps],
    ?assertMatch(#{dropped := 0}, Leg).

%% A tone at 1100 Hz from a sender of Ptime ms packets, two silent
%% listeners; each listener's verdict (70% of windows hold the tone), its
%% frames with 80 or more silent samples, and the sender's leg.
framing_run(Ptime, ListenMs) ->
    {ok, Conf} = chappe_mix:start(#{}),
    Listeners = [
        begin
            {Ep, Port} = chappe_mix_test_tone:endpoint(#{freq => none}),
            {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {?LO, Port}}),
            Ep
        end
     || _ <- [1, 2]
    ],
    {ok, LS, #{port := MS}} = chappe_mix:add_leg(Conf, #{ptime => Ptime}),
    {Sender, _} = chappe_mix_test_tone:endpoint(#{
        freq => 1100, ptime => Ptime, dst => {?LO, MS}
    }),
    timer:sleep(1000),
    [chappe_mix_test_tone:clear(L) || L <- Listeners],
    timer:sleep(ListenMs),
    Verdicts = [
        chappe_mix_test_tone:hears(L, {-18.0, -54.7}, {[1100], []})
     || L <- Listeners
    ],
    Gaps = [
        {chappe_mix_test_tone:gaps(Fs, 80), length(Fs)}
     || L <- Listeners, Fs <- [chappe_mix_test_tone:frames(L)]
    ],
    Leg = leg(Conf, LS),
    [chappe_mix_test_tone:stop(P) || P <- [Sender | Listeners]],
    ok = chappe_mix:stop(Conf),
    {Verdicts, Gaps, Leg}.

%% ---- RFC 4733 telephone-event forwarding ----

%% A sends audio (a fixed frame) and two digits as RFC 4733 events on
%% payload type 101, in place of audio packets as a phone does: '1'
%% (event 1) as a start packet with M set, two updates, and three end
%% packets with E set; then '#' (event 11) the same way. B negotiated the
%% events on payload type 96, C did not negotiate them, and D lists only
%% events 0 to 9.
%%
%% B gets every event packet of both digits, on its own payload type,
%% payload byte for byte (event, E bit, volume, duration), with the M bit
%% it came with, one timestamp for all the packets of an event and, for
%% the next event, the mixer's clock at its start (A's timestamps jump by
%% a second in between, as after a pause), under the mixer's SSRC with A's as the CSRC,
%% within a tick of A sending it. Its sequence numbers step by one across
%% audio and events. C gets no event, D gets '1' and not '#'. The events
%% are not mixed: every audio packet B and C get is A's frame or silence.
%% A payload type nobody negotiated (97) is still dropped.
%% req: R4733-001 R4733-002 R4733-003 R4733-004 R4733-005 R4733-006
%% req: R4733-007 R4733-008 R4733-009 R3550-006
dtmf_forwarded(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {SA, PA} = open(),
    {RB, PB} = recorder(),
    {RC, PC} = recorder(),
    {RD, PD} = recorder(),
    {ok, LA, #{port := MA}} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, PA}, dtmf_pt => 101}
    ),
    {ok, LB, _} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, PB}, dtmf_pt => 96}
    ),
    {ok, _, _} = chappe_mix:add_leg(Conf, #{remote => {?LO, PC}}),
    {ok, _, _} = chappe_mix:add_leg(
        Conf,
        #{remote => {?LO, PD}, dtmf_pt => 101, dtmf_events => lists:seq(0, 9)}
    ),
    Frame = frame(ulaw),
    %% from packet 41 on, A's timestamps jump by a second, as after a
    %% pause in a sender that suppresses silence
    Clock = fun
        (N) when N >= 41 -> N * 160 + 8000;
        (N) -> N * 160
    end,
    Audio = fun(N) ->
        {audio,
            rtp(#{
                pt => 0, seq => N, ts => Clock(N), ssrc => 16#A, payload => Frame
            })}
    end,
    Ev = fun(Seq, Event, M, E, Dur, Ts) ->
        {event,
            rtp(#{
                pt => 101,
                seq => Seq,
                ts => Ts,
                ssrc => 16#A,
                marker => M,
                payload => <<Event, E:1, 0:1, 10:6, Dur:16>>
            })}
    end,
    Digit = fun(Seq0, Event) ->
        Ts = Clock(Seq0),
        [
            Ev(Seq0, Event, true, 0, 160, Ts),
            Ev(Seq0 + 1, Event, false, 0, 320, Ts),
            Ev(Seq0 + 2, Event, false, 0, 480, Ts),
            Ev(Seq0 + 3, Event, false, 1, 640, Ts),
            Ev(Seq0 + 4, Event, false, 1, 640, Ts),
            Ev(Seq0 + 5, Event, false, 1, 640, Ts)
        ]
    end,
    Odd = {audio,
        rtp(#{pt => 97, seq => 47, ts => 47 * 160, ssrc => 16#A, payload => Frame})},
    Plan =
        [Audio(N) || N <- lists:seq(1, 20)] ++ Digit(21, 1) ++
            [Audio(N) || N <- lists:seq(27, 40)] ++ Digit(41, 11) ++
            [Odd] ++ [Audio(N) || N <- lists:seq(48, 60)],
    Sent = stream_timed(SA, {?LO, MA}, Plan),
    timer:sleep(100),
    #{ssrc := Mine} = leg(Conf, LB),
    #{events := EventsIn, other_pt := OtherIn} = leg(Conf, LA),
    ok = chappe_mix:stop(Conf),
    B = rtp_recorded(RB),
    C = rtp_recorded(RC),
    D = rtp_recorded(RD),
    gen_udp:close(SA),
    BEv = [{T, P} || {T, #{pt := 96} = P} <- B],
    ct:log("B: ~p packets, ~p events; A counted ~p events, ~p other", [
        length(B), length(BEv), EventsIn, OtherIn
    ]),
    ?assertEqual({12, 1}, {EventsIn, OtherIn}),
    SentEv = [{T, P} || {T, {event, Bin}} <- Sent, {ok, P} <- [chappe_mix_rtp:parse(Bin)]],
    %% every event packet, payload for payload, in order
    ?assertEqual(
        [Pl || {_, #{payload := Pl}} <- SentEv], [Pl || {_, #{payload := Pl}} <- BEv]
    ),
    %% M on the first packet of each event only
    ?assertEqual(
        [M || {_, #{marker := M}} <- SentEv], [M || {_, #{marker := M}} <- BEv]
    ),
    %% one timestamp per event, a later one for the next
    {E1, E2} = lists:split(6, BEv),
    [Ts1] = lists:usort([Ts || {_, #{ts := Ts}} <- E1]),
    [Ts2] = lists:usort([Ts || {_, #{ts := Ts}} <- E2]),
    Step = (Ts2 - Ts1) band 16#FFFFFFFF,
    ct:log("event timestamps on B: ~p then ~p (+~p)", [Ts1, Ts2, Step]),
    %% the second event starts 20 packets (3200 samples) after the
    %% first on the mixer's clock, whatever A's timestamps did
    ?assert(abs(Step - 3200) =< 480, {Ts1, Ts2}),
    %% the mixer's SSRC, A's as the CSRC
    ?assertEqual([Mine], lists:usort([S || {_, #{ssrc := S}} <- B])),
    ?assertEqual([[16#A]], lists:usort([Cs || {_, #{csrcs := Cs}} <- BEv])),
    %% one sequence across audio and events
    Seqs = [S || {_, #{seq := S}} <- B],
    ?assertEqual(
        [(hd(Seqs) + I) band 16#FFFF || I <- lists:seq(0, length(Seqs) - 1)],
        Seqs
    ),
    %% within a tick of being sent
    Delays = [TB - TA || {{TA, _}, {TB, _}} <- lists:zip(SentEv, BEv)],
    ct:log("forwarding delay (us): max ~p, all ~w", [lists:max(Delays), Delays]),
    ?assert(lists:max(Delays) =< 20000, Delays),
    %% C negotiated no events; D only 0 to 9
    ?assertEqual([0], lists:usort([PT || {_, #{pt := PT}} <- C])),
    ?assertEqual(
        [1], lists:usort([E || {_, #{pt := 101, payload := <<E, _/binary>>}} <- D])
    ),
    ?assertEqual(6, length([x || {_, #{pt := 101}} <- D])),
    %% never mixed: the audio is A's frame or silence
    Expect = expected(ulaw, Frame),
    Silent = binary:copy(<<16#FF>>, 160),
    [
        ?assertEqual(
            [], [Pl || {_, #{pt := 0, payload := Pl}} <- X, Pl =/= Expect, Pl =/= Silent]
        )
     || X <- [B, C, D]
    ],
    ?assert(length([x || {_, #{pt := 0, payload := Pl}} <- B, Pl =:= Expect]) >= 20).

%% Events go where audio goes: B, kept from hearing A, gets none of A's
%% events; C, which the room sends nothing (recvonly), gets none; D gets
%% them. Once A is muted, nobody gets its events.
dtmf_follows_relations(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {SA, PA} = open(),
    {ok, LA, #{port := MA}} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, PA}, dtmf_pt => 101}
    ),
    Recs = [
        begin
            {R, P} = recorder(),
            {ok, L, _} = chappe_mix:add_leg(
                Conf, Opts#{remote => {?LO, P}, dtmf_pt => 96}
            ),
            {R, L}
        end
     || Opts <- [#{}, #{direction => recvonly}, #{}]
    ],
    [{RB, LB}, {RC, _}, {RD, _}] = Recs,
    ok = chappe_mix:relate(Conf, LB, LA, nohear),
    Ev = fun(Seq, M, E) ->
        rtp(#{
            pt => 101,
            seq => Seq,
            ts => 1600,
            ssrc => 16#A,
            marker => M,
            payload => <<3, E:1, 0:1, 10:6, 320:16>>
        })
    end,
    Send = fun(Pkts) -> [ok = gen_udp:send(SA, ?LO, MA, P) || P <- Pkts] end,
    Send([Ev(1, true, 0), Ev(2, false, 1)]),
    timer:sleep(100),
    ok = chappe_mix:mute(Conf, LA, true),
    Send([Ev(3, true, 0), Ev(4, false, 1)]),
    timer:sleep(100),
    ok = chappe_mix:stop(Conf),
    gen_udp:close(SA),
    Events = fun(R) -> [S || {_, #{pt := 96, seq := S}} <- rtp_recorded(R)] end,
    [B, C, D] = [Events(R) || R <- [RB, RC, RD]],
    ct:log("events at B ~p, C ~p, D ~p", [B, C, D]),
    ?assertEqual({0, 0, 2}, {length(B), length(C), length(D)}).

%% Sent at one item every 20 ms; the send time of each, microseconds.
stream_timed(Sock, {Ip, Port}, Plan) ->
    T0 = erlang:monotonic_time(millisecond),
    {Sent, _} = lists:mapfoldl(
        fun({_, Bin} = Item, K) ->
            wait_until(T0 + 20 * K),
            T = erlang:monotonic_time(microsecond),
            ok = gen_udp:send(Sock, Ip, Port, Bin),
            {{T, Item}, K + 1}
        end,
        0,
        Plan
    ),
    Sent.

%% A socket owned by a process that stamps each datagram on arrival.
recorder() ->
    Self = self(),
    Pid = spawn_link(fun() ->
        {S, P} = open(),
        Self ! {self(), P},
        record(S, [])
    end),
    receive
        {Pid, P} -> {Pid, P}
    after 2000 -> ct:fail(recorder)
    end.

record(S, Acc) ->
    receive
        {udp, S, _, _, B} ->
            record(S, [{erlang:monotonic_time(microsecond), B} | Acc]);
        {get, From} ->
            From ! {self(), lists:reverse(Acc)},
            gen_udp:close(S)
    end.

%% The RTP a recorder got, parsed, with arrival times.
rtp_recorded(Pid) ->
    Pid ! {get, self()},
    receive
        {Pid, Pkts} -> rtp_in(Pkts)
    after 2000 -> ct:fail(recorded)
    end.

%% ---- cascaded mixers and the RTCP port ----

%% A is another mixer upstream: its packets carry the CSRCs 111 and 222.
%% B is a plain talker. C, listening, gets packets whose CSRC list names
%% the sources A mixed (not A itself) and B; B's list names A's sources;
%% A's names B only (RFC 3550 7.4).
%% req: R3550-24
cascaded_csrcs(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {PA, LA} = peer(Conf, 16#A, #{}),
    ok = chappe_mix_test_peer:set(PA, csrcs, [111, 222]),
    {PB, LB} = peer(Conf, 16#B, #{}),
    {PC, LC} = peer(Conf, 16#C, #{}),
    ok = chappe_mix_test_peer:set(PC, sending, false),
    Csrcs = fun(Leg) -> lists:sort(maps:get(csrcs, leg(Conf, Leg))) end,
    wait(
        fun() ->
            Csrcs(LC) =:= [16#B, 111, 222] andalso Csrcs(LB) =:= [111, 222] andalso
                Csrcs(LA) =:= [16#B]
        end,
        2000
    ),
    %% and on the wire (the datagram may still be on its way to C)
    OnWire = fun() ->
        case
            lists:reverse(
                chappe_mix_test_peer:rtp(chappe_mix_test_peer:packets(PC))
            )
        of
            [{_, #{csrcs := Cs}} | _] -> lists:sort(Cs);
            [] -> []
        end
    end,
    wait(fun() -> OnWire() =:= [16#B, 111, 222] end, 1000),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB, PC]],
    ok = chappe_mix:stop(Conf).

%% A media-level a=rtcp gives an RTCP port (and address) other than the
%% RTP port + 1: the leg's reports go there, for a leg on a port pair
%% (given when the leg opens) and for a muxed one (given with
%% set_remote/3), and not to the RTP port or the port after it.
%% req: R3605-001 R3550-211
rtcp_to_the_given_port(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {S1, P1} = open(),
    {R1, Q1} = open(),
    {S2, P2} = open(),
    {R2, Q2} = open(),
    {ok, _, _} = chappe_mix:add_leg(
        Conf, #{remote => {?LO, P1}, rtcp => pair, rtcp_remote => {?LO, Q1}}
    ),
    {ok, L2, _} = chappe_mix:add_leg(Conf, #{}),
    ok = chappe_mix:set_remote(
        Conf, L2, #{remote => {?LO, P2}, rtcp_remote => {?LO, Q2}}
    ),
    ?assertMatch(#{rtcp_remote := {?LO, Q2}}, leg(Conf, L2)),
    Deadline = erlang:monotonic_time(millisecond) + 3078 + 1000,
    G1 = until_rtcp(R1, Deadline, []),
    G2 = until_rtcp(R2, Deadline, []),
    ok = chappe_mix:stop(Conf),
    timer:sleep(50),
    ?assert(length(rtcp_in(G1)) >= 1),
    ?assert(length(rtcp_in(G2)) >= 1),
    %% the BYEs of the stop went there too, and no RTCP to the RTP ports
    ?assertEqual([], rtcp_in(drain(S1) ++ drain(S2))),
    [gen_udp:close(S) || S <- [S1, R1, S2, R2]].

%% ---- RTCP on the wire ----

%% Every RTCP datagram the mixer sends in a conference's life (SRs with
%% a report block, SDES with CSRC chunks, the BYE of an SSRC collision,
%% which carries a reason, the BYE of a leg that leaves and of the stop)
%% is walked by hand: version 2, no padding bit, length fields that add
%% up to the datagram in 32-bit words; SDES items end in a null and each
%% chunk is null padded to 32 bits; a BYE reason is null padded. The
%% item lengths are picked so the chunks need different paddings, our
%% own CNAME a whole word of nulls. Each datagram, BYEs included, starts
%% with an SR or an RR.
%% req: R3550-028 R3550-097 R3550-109 R3550-110 R3550-136 R3550-046
rtcp_on_the_wire(_Config) ->
    %% 4 + 2 + 10 = 16: a whole word of nulls
    {ok, Conf} = chappe_mix:start(#{cname => <<"0123456789">>}),
    {PA, LA} = peer(Conf, 16#A, #{name => <<"Alice">>}),
    {PB, LB} = peer(Conf, 16#B, #{}),
    #{port := MA} = leg(Conf, LA),
    #{port := MB} = leg(Conf, LB),
    %% 4 + 2 + 1 = 7 (one null), 4 + 2 + 2 + 2 + 3 = 13 (three)
    sdes(PA, MA, 16#A, [{cname, <<"a">>}]),
    sdes(PB, MB, 16#B, [{cname, <<"bb">>}, {name, <<"Bob">>}]),
    wait(fun() -> length(mixer_rtcp(PA)) >= 1 andalso length(mixer_rtcp(PB)) >= 1 end, 3078 + 1000),
    %% an SSRC collision on A: BYE with a reason
    #{ssrc := Old} = leg(Conf, LA),
    ok = chappe_mix_test_peer:set(PA, ssrc, Old),
    wait(fun() -> lists:any(fun has_reason/1, mixer_rtcp(PA)) end, 1000),
    ok = chappe_mix:remove_leg(Conf, LB),
    ok = chappe_mix:stop(Conf),
    timer:sleep(100),
    All = mixer_rtcp(PA) ++ mixer_rtcp(PB),
    ct:log("~p datagrams", [length(All)]),
    Walked = [walk(B) || B <- All],
    Firsts = lists:usort([PT || [{PT, _, _} | _] <- Walked]),
    ct:log("first packet types: ~p", [Firsts]),
    ?assertEqual([], Firsts -- [200, 201]),
    ?assertEqual(length(All), length([W || [{PT, _, _} | _] = W <- Walked,
                                           PT =:= 200 orelse PT =:= 201])),
    Sdes = [P || Ps <- Walked, {202, _, _} = P <- Ps],
    Pads = lists:usort(lists:append([chunk_pads(Body, N) || {202, N, Body} <- Sdes])),
    ct:log("SDES chunk padding seen: ~p", [Pads]),
    %% a whole word of nulls, and two other paddings
    ?assert(lists:member(4, Pads) andalso length(Pads) >= 3, Pads),
    Byes = [P || Ps <- Walked, {203, _, _} = P <- Ps],
    ?assert(length(Byes) >= 3),
    ?assert(lists:any(fun({203, N, Body}) -> bye_reason(Body, N) =/= none end, Byes)),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB]].

has_reason(B) ->
    lists:any(
        fun({203, N, Body}) -> bye_reason(Body, N) =/= none; (_) -> false end,
        walk(B)
    ).

%% A compound datagram by hand: every packet V=2, P=0, length in words
%% minus one; the lengths add up to the datagram, which is a multiple of
%% 4. Returns [{PT, Count, Body}].
walk(<<>>) ->
    [];
walk(<<V:2, P:1, Count:5, PT, Len:16, Rest/binary>> = B) ->
    ?assertEqual(0, byte_size(B) rem 4),
    ?assertEqual(2, V),
    ?assertEqual(0, P),
    Bytes = Len * 4,
    ?assert(byte_size(Rest) >= Bytes, {short, PT, Len, byte_size(Rest)}),
    <<Body:Bytes/binary, Next/binary>> = Rest,
    [{PT, Count, Body} | walk(Next)].

%% Each chunk: SSRC, items, a null type octet, then only nulls to the
%% next 32-bit boundary. Returns the number of nulls after each chunk's
%% last item.
chunk_pads(<<>>, 0) ->
    [];
chunk_pads(<<_Ssrc:32, Rest/binary>>, N) when N > 0 ->
    {Used, After} = items(Rest, 0),
    Pad = (4 - (Used rem 4)) rem 4,
    Nulls = 1 + Pad,
    ?assert(Pad =:= 0 orelse byte_size(After) >= Pad),
    <<Zeros:Pad/binary, Next/binary>> = After,
    ?assertEqual(binary:copy(<<0>>, Pad), Zeros),
    ?assertEqual(0, (4 + Used + Pad) rem 4),
    [Nulls | chunk_pads(Next, N - 1)].

%% Items up to and including the null type octet: octets used and what
%% follows.
items(<<0, Rest/binary>>, Used) -> {Used + 1, Rest};
items(<<_T, L, _:L/binary, Rest/binary>>, Used) -> items(Rest, Used + 2 + L).

%% After SC sources, an optional length-prefixed reason, then only nulls
%% to the end of the (32-bit aligned) packet.
bye_reason(Body, N) ->
    Bytes = N * 4,
    case Body of
        <<_:Bytes/binary>> ->
            none;
        <<_:Bytes/binary, L, Reason:L/binary, Pad/binary>> ->
            ?assertEqual(binary:copy(<<0>>, byte_size(Pad)), Pad),
            ?assert(byte_size(Pad) < 4),
            Reason
    end.

%% ---- BYE and SSRC ----

%% A leg added and removed before any tick sent it anything gets no BYE
%% (and no packet at all). The conference is suspended while the two
%% calls are queued behind the tick already due, so no tick can run
%% between them.
%% req: R3550-090
no_bye_from_a_leg_that_never_sent(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {S, P} = open(),
    ok = sys:suspend(Conf),
    timer:sleep(50),
    Self = self(),
    Add = spawn(fun() ->
        Self ! {added, chappe_mix:add_leg(Conf, #{remote => {?LO, P}})}
    end),
    wait(fun() -> queued(Conf) >= 2 end, 1000),
    %% the first leg of a conference is leg 1
    Rm = spawn(fun() -> Self ! {removed, chappe_mix:remove_leg(Conf, 1)} end),
    wait(fun() -> queued(Conf) >= 3 end, 1000),
    ok = sys:resume(Conf),
    {ok, 1, _} = receive {added, A} -> A after 2000 -> ct:fail(no_add) end,
    ok = receive {removed, R} -> R after 2000 -> ct:fail(no_remove) end,
    timer:sleep(300),
    ok = chappe_mix:stop(Conf),
    ?assertEqual([], drain(S)),
    _ = [Add, Rm],
    gen_udp:close(S).

queued(Pid) ->
    {message_queue_len, N} = process_info(Pid, message_queue_len),
    N.

%% The SSRC drawn after a collision is not one already in the
%% conference: with the draws scripted, the candidates equal to the
%% other leg's source, to the other leg's own SSRC and to the old SSRC
%% are drawn again, and the fourth is taken.
%% req: R3550-189
new_ssrc_not_seen(_Config) ->
    Draws = {1111, 2222, 16#B0B, 2222, 1111, 3333},
    C = counters:new(1, []),
    Draw = fun() ->
        ok = counters:add(C, 1, 1),
        element(counters:get(C, 1), Draws)
    end,
    {ok, Conf} = chappe_mix:start(#{ssrc_draw => Draw}),
    {PA, LA} = peer(Conf, 16#A, #{}),
    {PB, LB} = peer(Conf, 16#B0B, #{}),
    ?assertMatch(#{ssrc := 1111}, leg(Conf, LA)),
    ?assertMatch(#{ssrc := 2222}, leg(Conf, LB)),
    wait(fun() -> maps:get(source_ssrc, leg(Conf, LB)) =:= 16#B0B end, 1000),
    ok = chappe_mix_test_peer:set(PA, ssrc, 1111),
    wait(fun() -> maps:get(collisions, leg(Conf, LA)) =:= 1 end, 1000),
    ?assertMatch(#{ssrc := 3333}, leg(Conf, LA)),
    ?assertEqual(6, counters:get(C, 1)),
    [chappe_mix_test_peer:stop(P) || P <- [PA, PB]],
    ok = chappe_mix:stop(Conf).

%% With rtcp-mux one address sends both RTP and RTCP, and the conflict
%% list keeps the two apart (8.2): RTP under the mixer's SSRC from that
%% address is a collision (the SSRC changes); an SR under the new SSRC
%% from the same address is a collision too, not a loop, since only its
%% RTP was seen colliding; RTP under the third SSRC from there again is
%% then a loop, and so is RTCP.
%% req: R3550-182
conflicts_rtp_and_rtcp_apart(_Config) ->
    {ok, Conf} = chappe_mix:start(#{}),
    {S, P} = open(),
    {ok, L, #{port := M, rtcp_port := M}} =
        chappe_mix:add_leg(Conf, #{remote => {?LO, P}}),
    Rtp = fun(Ssrc, N) ->
        ok = gen_udp:send(S, ?LO, M, rtp(#{pt => 0, seq => N, ts => N * 160,
                                           ssrc => Ssrc,
                                           payload => frame(ulaw)}))
    end,
    Sr = fun(Ssrc) ->
        ok = gen_udp:send(S, ?LO, M, chappe_mix_rtcp:build([
            #{type => sr, ssrc => Ssrc, ntp => 0, ts => 0, packets => 1,
              octets => 160, blocks => []}
        ]))
    end,
    Counts = fun() ->
        #{collisions := C, loops := Lo, ssrc := Ss} = leg(Conf, L),
        {C, Lo, Ss}
    end,
    {0, 0, S1} = Counts(),
    Rtp(S1, 1),
    wait(fun() -> element(1, Counts()) =:= 1 end, 1000),
    {1, 0, S2} = Counts(),
    ?assertNotEqual(S1, S2),
    Sr(S2),
    wait(fun() -> element(1, Counts()) =:= 2 end, 1000),
    {2, 0, S3} = Counts(),
    ?assertNotEqual(S2, S3),
    Rtp(S3, 2),
    wait(fun() -> element(2, Counts()) =:= 1 end, 1000),
    Sr(S3),
    wait(fun() -> element(2, Counts()) =:= 2 end, 1000),
    ?assertEqual({2, 2, S3}, Counts()),
    ok = chappe_mix:stop(Conf),
    gen_udp:close(S).

%% ---- codec: states and formulas ----

%% The report interval of 6.2 / A.7 at its bounds: the 5 s minimum (2.5 s
%% before the first report), the RTCP bandwidth split a quarter to the
%% senders and three quarters to the receivers when senders are a quarter
%% of the members or fewer, and the random factor 0.5 to 1.5 over e - 3/2.
%% req: R3550-077
interval_bounds(_Config) ->
    Comp = 2.71828 - 1.5,
    Near = fun(Want, Got) ->
        ?assert(abs(Want - Got) =< 1.0e-6 * Want, {Want, Got})
    end,
    Low = 0.0,
    High = 1.0 - 1.0e-9,
    I = fun chappe_mix_rtcp:interval/6,
    %% small conference: the minimum governs
    Near(5.0 * 0.5 / Comp, I(2, 2, true, 100.0, false, Low)),
    Near(5.0 * 1.5 / Comp, I(2, 2, true, 100.0, false, High)),
    Near(2.5 * 0.5 / Comp, I(2, 2, true, 100.0, true, Low)),
    Near(2.5 * 1.5 / Comp, I(2, 2, true, 100.0, true, High)),
    %% 100 members, 2 senders: a sender shares 25% of 500 B/s with one
    %% other sender, a receiver 75% with 97 others
    Near(1000.0 * 2 / 125.0 * 0.5 / Comp, I(100, 2, true, 1000.0, false, Low)),
    Near(1000.0 * 98 / 375.0 * 1.5 / Comp, I(100, 2, false, 1000.0, false, High)),
    %% senders above a quarter: everyone shares the whole bandwidth
    Near(1000.0 * 100 / 500.0 * 0.5 / Comp, I(100, 50, true, 1000.0, false, Low)),
    %% the drawn factor spreads over the whole range
    Draws = [
        chappe_mix_rtcp:interval(2, 2, true, 100.0, false)
     || _ <- lists:seq(1, 2000)
    ],
    {Min, Max} = {lists:min(Draws), lists:max(Draws)},
    ct:log("2000 draws in [~.3f, ~.3f]", [Min, Max]),
    ?assert(Min >= 5.0 * 0.5 / Comp - 1.0e-9),
    ?assert(Max =< 5.0 * 1.5 / Comp + 1.0e-9),
    ?assert(Min < 5.0 * 0.6 / Comp andalso Max > 5.0 * 1.4 / Comp, {Min, Max}).

%% A session that has sent nothing starts its compound with an empty RR
%% (RC 0), then SDES; a BYE compound from it starts the same way and ends
%% with the BYE. The mixer sends RTP from the first tick it knows a far
%% end, so on the wire every report it makes is an SR; this is the path
%% for a session before that.
%% req: R3550-035 R3550-105
empty_rr_first(_Config) ->
    S0 = chappe_mix_session:new(16#1234, erlang:monotonic_time()),
    NoChunks = fun(_) -> [] end,
    {Pkt, S1} = chappe_mix_session:report(S0, <<"cn">>, NoChunks, [], 0),
    ?assertMatch(
        <<2:2, 0:1, 0:5, 201, 1:16, 16#1234:32, 2:2, 0:1, 1:5, 202, _/binary>>,
        Pkt
    ),
    {Bye, _} = chappe_mix_session:report(
        S1, <<"cn">>, NoChunks, [#{type => bye, ssrcs => [16#1234]}], 0
    ),
    [{201, 0, <<16#1234:32>>}, {202, 1, _}, {203, 1, <<16#1234:32>>}] = walk(Bye).

%% RFC 3550 6.2.1: a source that sent BYE is marked, not deleted. A
%% straggler from it (a sequence number at or below the highest one at
%% the BYE) inside the 5 s grace does not bring it back: no source for
%% the CSRC lists, no report block. Past the grace even an old sequence
%% number from that SSRC is a new source again.
%% req: R3550-071
bye_grace(_Config) ->
    Ms = fun(N) -> erlang:convert_time_unit(N, millisecond, native) end,
    T0 = erlang:monotonic_time(),
    Us = fun(T) -> erlang:convert_time_unit(T, native, microsecond) end,
    Addr = {{127, 0, 0, 1}, 4000},
    Pkt = fun(Seq) ->
        #{
            pt => 0,
            seq => Seq,
            ts => Seq * 160,
            ssrc => 16#A,
            marker => false,
            payload => <<>>
        }
    end,
    NoChunks = fun(_) -> [] end,
    S0 = chappe_mix_session:new(16#1234, T0),
    S1 = lists:foldl(
        fun(Seq, A) ->
            {ok, A1, _} = chappe_mix_session:rtp_in(A, Pkt(Seq), Addr, T0),
            A1
        end,
        S0,
        [1, 2, 3]
    ),
    ?assertEqual(16#A, chappe_mix_session:src_ssrc(S1)),
    Bye = [#{type => bye, ssrcs => [16#A]}],
    {S2, false, [16#A]} = chappe_mix_session:rtcp_in(
        S1, Bye, 8, Addr, Us(T0 + Ms(100))
    ),
    ?assertEqual(undefined, chappe_mix_session:src_ssrc(S2)),
    %% the straggler, inside the grace
    {gone, S2a} = chappe_mix_session:rtp_in(S2, Pkt(3), Addr, T0 + Ms(105)),
    R3 = chappe_mix_session:rtp_in(S2a, Pkt(2), Addr, T0 + Ms(110)),
    ?assertMatch({gone, _}, R3),
    {gone, S3} = R3,
    ?assertEqual(undefined, chappe_mix_session:src_ssrc(S3)),
    {Rep, S4} = chappe_mix_session:report(
        S3, <<"cn">>, NoChunks, [], Us(T0 + Ms(200))
    ),
    {ok, [#{type := rr, blocks := []} | _]} = chappe_mix_rtcp:parse(Rep),
    %% a second BYE for it is not forwarded again
    {_, false, []} = chappe_mix_session:rtcp_in(
        S4, Bye, 8, Addr, Us(T0 + Ms(300))
    ),
    %% past the grace: a new source
    {ok, S5, true} = chappe_mix_session:rtp_in(
        S4, Pkt(2), Addr, T0 + Ms(100 + 5000)
    ),
    ?assertEqual(16#A, chappe_mix_session:src_ssrc(S5)),
    %% a report past the grace drops the mark with no packet
    S6 = chappe_mix_session:timeout(S3, T0 + Ms(100 + 5000)),
    {ok, S7, true} = chappe_mix_session:rtp_in(
        S6, Pkt(2), Addr, T0 + Ms(100 + 5000)
    ),
    ?assertEqual(16#A, chappe_mix_session:src_ssrc(S7)).

%% RFC 3550 6.2.1, A.1: a packet newer than the highest sequence number
%% at the BYE is the source sending again (a client that says BYE and
%% restarts under the same SSRC on hold and unhold), not a straggler: the
%% mark ends at once and the source continues its entry, mixed and
%% reported on again.
%% req: R3550-071
bye_resume(_Config) ->
    {S, T0, Addr, Pkt} = bye_session([1, 2, 3]),
    Ms = fun(N) -> erlang:convert_time_unit(N, millisecond, native) end,
    {ok, S1, true} = chappe_mix_session:rtp_in(S, Pkt(4), Addr, T0 + Ms(110)),
    ?assertEqual(16#A, chappe_mix_session:src_ssrc(S1)),
    %% the entry goes on: a later straggler is a reordered packet of it
    {ok, S2, false} = chappe_mix_session:rtp_in(
        S1, Pkt(2), Addr, T0 + Ms(120)
    ),
    {Rep, _} = chappe_mix_session:report(
        S2, <<"cn">>, fun(_) -> [] end, [], 0
    ),
    {ok, [#{type := rr, blocks := [#{ssrc := 16#A, highest := 4}]} | _]} =
        chappe_mix_rtcp:parse(Rep).

%% The comparison wraps (A.1): with 65535 the highest at the BYE, 0 is
%% newer and 65530 a straggler; with 10, 65530 is older across the wrap.
%% req: R3550-071
bye_resume_wrap(_Config) ->
    Ms = fun(N) -> erlang:convert_time_unit(N, millisecond, native) end,
    {S, T0, Addr, Pkt} = bye_session([65534, 65535]),
    {gone, _} = chappe_mix_session:rtp_in(S, Pkt(65530), Addr, T0 + Ms(110)),
    {gone, _} = chappe_mix_session:rtp_in(S, Pkt(65535), Addr, T0 + Ms(110)),
    {ok, S1, true} = chappe_mix_session:rtp_in(S, Pkt(0), Addr, T0 + Ms(110)),
    ?assertEqual(16#A, chappe_mix_session:src_ssrc(S1)),
    {W, TW, AddrW, PktW} = bye_session([9, 10]),
    {gone, _} = chappe_mix_session:rtp_in(W, PktW(65530), AddrW, TW + Ms(110)),
    {ok, _, true} = chappe_mix_session:rtp_in(W, PktW(11), AddrW, TW + Ms(110)).

%% A session that heard Seqs from source 16#A, then its BYE 100 ms on.
bye_session(Seqs) ->
    T0 = erlang:monotonic_time(),
    Addr = {{127, 0, 0, 1}, 4000},
    Pkt = fun(Seq) ->
        #{
            pt => 0,
            seq => Seq,
            ts => (Seq * 160) band 16#FFFFFFFF,
            ssrc => 16#A,
            marker => false,
            payload => <<>>
        }
    end,
    S0 = lists:foldl(
        fun(Seq, A) ->
            {ok, A1, _} = chappe_mix_session:rtp_in(A, Pkt(Seq), Addr, T0),
            A1
        end,
        chappe_mix_session:new(16#1234, T0),
        Seqs
    ),
    At = erlang:convert_time_unit(
        T0 + erlang:convert_time_unit(100, millisecond, native),
        native,
        microsecond
    ),
    {S, false, [16#A]} = chappe_mix_session:rtcp_in(
        S0, [#{type => bye, ssrcs => [16#A]}], 8, Addr, At
    ),
    {S, T0, Addr, Pkt}.

%% The interarrival jitter of the report block against appendix A.8 run
%% here on a scripted arrival pattern (irregular delays, a reordered
%% pair, a timestamp wrap).
%% req: R3550-104
jitter_formula(_Config) ->
    Delays = [0, 40, 7, 300, 12, 12, 95, 0, 0, 250, 3, 160, 80, 1, 500, 20],
    Pattern = [
        {Seq, (16#FFFFF000 + Seq * 160) band 16#FFFFFFFF, D}
     || {Seq, D} <- lists:zip(lists:seq(1, length(Delays)), Delays)
    ],
    %% seq 5 and 6 arrive swapped
    {A, [P5, P6 | B]} = lists:split(4, Pattern),
    Order = A ++ [P6, P5 | B],
    Arrival = fun({Seq, _Ts, D}) -> 1000 + Seq * 160 + D end,
    [{Seq0, Ts0, _} = First | Rest] = Order,
    Src = lists:foldl(
        fun({Seq, Ts, _} = P, Acc) ->
            chappe_mix_rtcp:src_update(Acc, Seq, Ts, Arrival(P))
        end,
        chappe_mix_rtcp:src_new(9, Seq0, Ts0, Arrival(First)),
        Rest
    ),
    {#{jitter := J}, _} = chappe_mix_rtcp:report_block(Src, 0),
    ?assertEqual(a8(Order, Arrival), J).

%% Appendix A.8, as written: transit = arrival - ts (in 32-bit
%% arithmetic), d = |transit - last|, jitter += (d - jitter) / 16,
%% reported truncated.
a8([First | Rest], Arrival) ->
    T0 = transit(First, Arrival),
    {_, J} = lists:foldl(
        fun(P, {Last, J}) ->
            T = transit(P, Arrival),
            D = abs(signed32(T - Last)),
            {T, J + (D - J) / 16}
        end,
        {T0, 0.0},
        Rest
    ),
    trunc(J).

transit({_, Ts, _} = P, Arrival) -> Arrival(P) - Ts.

signed32(X) ->
    <<S:32/signed>> = <<X:32>>,
    S.

%% ---- helpers ----

open() ->
    {ok, S} = gen_udp:open(0, [binary, {ip, ?LO}, {active, true}]),
    {ok, P} = inet:port(S),
    {S, P}.

%% One packet every 20 ms from Sock; returns when the last is sent.
stream(Sock, {Ip, Port}, Pkts) ->
    T0 = erlang:monotonic_time(millisecond),
    lists:foldl(
        fun(Pkt, K) ->
            wait_until(T0 + 20 * K),
            ok = gen_udp:send(Sock, Ip, Port, Pkt),
            K + 1
        end,
        0,
        Pkts
    ),
    ok.

wait_until(T) ->
    case T - erlang:monotonic_time(millisecond) of
        W when W > 0 -> timer:sleep(W);
        _ -> ok
    end.

%% Everything Sock received so far, oldest first.
drain(Sock) ->
    receive
        {udp, Sock, _, _, B} -> [{0, B} | drain(Sock)]
    after 0 -> []
    end.

is_rtcp(<<2:2, _:6, B, _/binary>>) -> B >= 192 andalso B =< 223;
is_rtcp(_) -> false.

rtp_in(Pkts) ->
    [
        {T, P}
     || {T, B} <- Pkts, not is_rtcp(B), {ok, P} <- [chappe_mix_rtp:parse(B)]
    ].

rtcp_in(Pkts) -> [B || {_, B} <- Pkts, is_rtcp(B)].

%% RTP by hand: X=1 adds a two-word extension after the CSRCs; marker
%% sets M.
rtp(#{pt := PT, seq := Seq, ts := Ts, ssrc := Ssrc, payload := P} = M) ->
    Csrcs = maps:get(csrcs, M, []),
    {X, Ext} =
        case maps:get(ext, M, false) of
            true -> {1, <<16#BEDE:16, 2:16, 16#DEADBEEF:32, 16#CAFEF00D:32>>};
            false -> {0, <<>>}
        end,
    Csrc = <<<<C:32>> || C <- Csrcs>>,
    Mk =
        case maps:get(marker, M, false) of
            true -> 1;
            false -> 0
        end,
    <<2:2, 0:1, X:1, (length(Csrcs)):4, Mk:1, PT:7, (Seq band 16#FFFF):16,
        (Ts band 16#FFFFFFFF):32, Ssrc:32, Csrc/binary, Ext/binary, P/binary>>.

peer(Conf, Ssrc, LegOpts) ->
    {Peer, PPort} = chappe_mix_test_peer:start(#{ssrc => Ssrc}),
    {ok, Leg, #{port := MPort}} = chappe_mix:add_leg(
        Conf, LegOpts#{remote => {?LO, PPort}}
    ),
    ok = chappe_mix_test_peer:set(Peer, dst, {?LO, MPort}),
    {Peer, Leg}.

sdes(Peer, MPort, Ssrc, Items) ->
    ok = chappe_mix_test_peer:send(
        Peer,
        {rtp, {?LO, MPort}},
        chappe_mix_rtcp:build([
            #{type => rr, ssrc => Ssrc, blocks => []},
            #{type => sdes, chunks => [{Ssrc, Items}]}
        ])
    ).

leg(Conf, Leg) ->
    [L] = [L || #{id := Id} = L <- chappe_mix:legs(Conf), Id =:= Leg],
    L.

%% The RTCP datagrams Peer got, as bytes.
mixer_rtcp(Peer) ->
    [B || {rtp, _, _, B} <- chappe_mix_test_peer:packets(Peer), is_rtcp(B)].

wait(Fun, Ms) ->
    wait(Fun, erlang:monotonic_time(millisecond) + Ms, Ms).

wait(Fun, Deadline, Ms) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> ct:fail({timeout, Ms});
                false -> timer:sleep(20), wait(Fun, Deadline, Ms)
            end
    end.
