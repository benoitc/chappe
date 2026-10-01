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
    sends_to_configured_remote/1,
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
        sends_to_configured_remote,
        {group, codec}
    ].

groups() ->
    [{codec, [], [empty_rr_first, jitter_formula]}].

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
%% 160 octets of payload for 20 ms.
%% req: R3551-060 R3551-061 R3551-062 R3550-001
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
    Heard = [P || {_, #{payload := P}} <- rtp_in(drain(SB))],
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

%% ---- RTCP on the wire ----

%% Every RTCP datagram the mixer sends in a conference's life (SRs with
%% a report block, SDES with CSRC chunks, the BYE of an SSRC collision,
%% which carries a reason, the BYE of a leg that leaves and of the stop)
%% is walked by hand: version 2, no padding bit, length fields that add
%% up to the datagram in 32-bit words; SDES items end in a null and each
%% chunk is null padded to 32 bits; a BYE reason is null padded. The
%% item lengths are picked so the chunks need different paddings, our
%% own CNAME a whole word of nulls.
%% req: R3550-028 R3550-097 R3550-109 R3550-110 R3550-136
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

%% ---- codec: states and formulas ----

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

%% RTP by hand: X=1 adds a two-word extension after the CSRCs.
rtp(#{pt := PT, seq := Seq, ts := Ts, ssrc := Ssrc, payload := P} = M) ->
    Csrcs = maps:get(csrcs, M, []),
    {X, Ext} =
        case maps:get(ext, M, false) of
            true -> {1, <<16#BEDE:16, 2:16, 16#DEADBEEF:32, 16#CAFEF00D:32>>};
            false -> {0, <<>>}
        end,
    Csrc = <<<<C:32>> || C <- Csrcs>>,
    <<2:2, 0:1, X:1, (length(Csrcs)):4, 0:1, PT:7, (Seq band 16#FFFF):16,
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
