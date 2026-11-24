%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
-module(chappe_mix_rtcp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NTP, 16#E7654321ABCD0000).

block() ->
    #{
        ssrc => 16#11223344,
        fraction => 25,
        lost => 3,
        highest => 70001,
        jitter => 12,
        lsr => 16#4321ABCD,
        dlsr => 65536
    }.

sr() ->
    #{
        type => sr,
        ssrc => 16#DEADBEEF,
        ntp => ?NTP,
        ts => 16000,
        packets => 100,
        octets => 16000,
        blocks => [block()]
    }.

%% R3550-028: the SR as 6.4.1 lays it out: RC 1, PT 200, length in
%% 32-bit words minus one, sender info, then one 24-octet report block
%% with a 24-bit signed cumulative loss.
sr_wire_test() ->
    ?assertEqual(
        <<2:2, 0:1, 1:5, 200, 12:16, 16#DEADBEEF:32, ?NTP:64, 16000:32, 100:32,
            16000:32, 16#11223344:32, 25, 3:24/signed, 70001:32, 12:32,
            16#4321ABCD:32, 65536:32>>,
        chappe_mix_rtcp:build([sr()])
    ).

rr_wire_test() ->
    ?assertEqual(
        <<2:2, 0:1, 0:5, 201, 1:16, 7:32>>,
        chappe_mix_rtcp:build([#{type => rr, ssrc => 7, blocks => []}])
    ).

%% R3550-109 R3550-110: items are not padded one by one; the list ends with at
%% least one null octet and nulls pad the chunk to 32 bits. A chunk whose
%% items end on a boundary still gets its terminator: four nulls.
sdes_wire_test_() ->
    Build = fun(Chunks) ->
        chappe_mix_rtcp:build([#{type => sdes, chunks => Chunks}])
    end,
    [
        %% 4 + 2 + 2 = 8 octets of items: a full word of nulls follows
        ?_assertEqual(
            <<2:2, 0:1, 1:5, 202, 3:16, 9:32, 1, 2, "ab", 0, 0, 0, 0>>,
            Build([{9, [{cname, <<"ab">>}]}])
        ),
        %% 4 + 2 + 3 = 9: three nulls to reach 12
        ?_assertEqual(
            <<2:2, 0:1, 1:5, 202, 3:16, 9:32, 1, 3, "abc", 0, 0, 0>>,
            Build([{9, [{cname, <<"abc">>}]}])
        ),
        %% two chunks, CNAME and NAME in the second
        ?_assertEqual(
            <<2:2, 0:1, 2:5, 202, 6:16, 9:32, 1, 1, "a", 0, 10:32, 1, 1, "b", 2,
                3, "Bob", 0, 0, 0, 0>>,
            Build([
                {9, [{cname, <<"a">>}]},
                {10, [{cname, <<"b">>}, {name, <<"Bob">>}]}
            ])
        )
    ].

%% R3550-136: BYE carries its sources, then an optional reason padded
%% with nulls to 32 bits.
bye_wire_test_() ->
    Build = fun(P) -> chappe_mix_rtcp:build([P#{type => bye}]) end,
    [
        ?_assertEqual(
            <<2:2, 0:1, 2:5, 203, 2:16, 1:32, 2:32>>,
            Build(#{ssrcs => [1, 2]})
        ),
        ?_assertEqual(
            <<2:2, 0:1, 1:5, 203, 3:16, 1:32, 4, "left", 0, 0, 0>>,
            Build(#{ssrcs => [1], reason => <<"left">>})
        ),
        ?_assertEqual(
            <<2:2, 0:1, 1:5, 203, 2:16, 1:32, 3, "abc">>,
            Build(#{ssrcs => [1], reason => <<"abc">>})
        )
    ].

%% R3550-031 R3550-040: a compound packet parses back into its parts, in order.
roundtrip_test() ->
    Parts = [
        sr(),
        #{
            type => sdes,
            chunks => [
                {16#DEADBEEF, [{cname, <<"mix@example">>}]},
                {5, [{cname, <<"five">>}, {name, <<"Five">>}]}
            ]
        },
        #{type => bye, ssrcs => [16#DEADBEEF, 5], reason => <<"bye">>}
    ],
    Bin = chappe_mix_rtcp:build(Parts),
    ?assertEqual(0, byte_size(Bin) rem 4),
    ?assertEqual({ok, Parts}, chappe_mix_rtcp:parse(Bin)),
    RR = [#{type => rr, ssrc => 1, blocks => [block(), block()]}],
    ?assertEqual({ok, RR}, chappe_mix_rtcp:parse(chappe_mix_rtcp:build(RR))).

%% An SDES item of a type we do not name, and a packet type we do not
%% know (XR, 207), are kept as numbers rather than refused: the checks of
%% A.2 do not look at the type of a later packet.
unknown_test() ->
    Sdes = <<2:2, 0:1, 1:5, 202, 2:16, 9:32, 5, 1, "x", 0>>,
    Xr = <<2:2, 0:1, 0:5, 207, 1:16, 9:32>>,
    Rr = chappe_mix_rtcp:build([#{type => rr, ssrc => 9, blocks => []}]),
    ?assertEqual(
        {ok, [
            #{type => rr, ssrc => 9, blocks => []},
            #{type => sdes, chunks => [{9, [{5, <<"x">>}]}]},
            #{type => other, pt => 207}
        ]},
        chappe_mix_rtcp:parse(<<Rr/binary, Sdes/binary, Xr/binary>>)
    ).

%% RFC 3550 A.2 (no catalogue row): the validity checks on a received compound
%% packet.
validity_test_() ->
    Rr = chappe_mix_rtcp:build([#{type => rr, ssrc => 1, blocks => []}]),
    Bye = chappe_mix_rtcp:build([#{type => bye, ssrcs => [1]}]),
    Sdes = chappe_mix_rtcp:build([#{type => sdes, chunks => [{1, []}]}]),
    Bad = fun(B) ->
        ?_assertEqual({error, invalid}, chappe_mix_rtcp:parse(B))
    end,
    [
        ?_assertMatch(
            {ok, [_, _]}, chappe_mix_rtcp:parse(<<Rr/binary, Bye/binary>>)
        ),
        Bad(<<>>),
        %% version 1
        Bad(<<1:2, 0:1, 0:5, 201, 1:16, 1:32>>),
        %% first packet neither SR nor RR
        Bad(<<Bye/binary, Rr/binary>>),
        Bad(Sdes),
        %% padding bit on the first packet
        Bad(<<2:2, 1:1, 0:5, 201, 1:16, 1:32>>),
        %% lengths do not add up: a stray octet, a short packet
        Bad(<<Rr/binary, 0>>),
        Bad(<<2:2, 0:1, 0:5, 201, 2:16, 1:32>>),
        %% a later packet with the wrong version
        Bad(<<Rr/binary, 1:2, 0:1, 1:5, 203, 1:16, 1:32>>),
        %% counts larger than the packet holds
        Bad(<<2:2, 0:1, 1:5, 201, 1:16, 1:32>>),
        Bad(<<Rr/binary, 2:2, 0:1, 2:5, 203, 1:16, 1:32>>),
        %% an SDES chunk with no terminator
        Bad(<<Rr/binary, 2:2, 0:1, 1:5, 202, 2:16, 1:32, 1, 2, "ab">>)
    ].

%% R3550-02 R3550-079 R3551-006: the interval of A.7. Two members that both
%% send, a 100-octet average: the 5 s minimum (2.5 s before the first report)
%% wins, times the random factor, divided by e - 3/2.
interval_test_() ->
    C = 2.71828 - 1.5,
    [
        ?_assert(
            close(
                2.5 * 0.5 / C,
                chappe_mix_rtcp:interval(2, 2, true, 100.0, true, 0.0)
            )
        ),
        ?_assert(
            close(
                5.0 * 1.5 / C,
                chappe_mix_rtcp:interval(2, 2, true, 100.0, false, 1.0)
            )
        ),
        ?_assert(
            close(
                5.0 / C, chappe_mix_rtcp:interval(2, 2, true, 100.0, false, 0.5)
            )
        ),
        %% 200 members, one sender, not us: receivers share 75% of the
        %% 500 octet/s RTCP bandwidth, 199 of them at 100 octets each
        ?_assert(
            close(
                100.0 * 199 / 375 / C,
                chappe_mix_rtcp:interval(200, 1, false, 100.0, false, 0.5)
            )
        ),
        %% the same with us the sender: the 25% share among 1 sender
        ?_assert(
            close(
                5.0 / C,
                chappe_mix_rtcp:interval(200, 1, true, 100.0, false, 0.5)
            )
        )
    ].

close(A, B) -> abs(A - B) < 1.0e-6.

%% R3551-013 R3550-058: the report block for the source a leg receives: loss
%% since the last report as a fraction of 256, cumulative loss, extended
%% highest sequence, jitter, LSR and DLSR.
report_block_test() ->
    %% seq 65530..65541 (across the wrap), 65535 missing, sent every 160
    %% ticks and received on time
    Seqs = [S band 16#FFFF || S <- lists:seq(65530, 65541), S =/= 65535],
    Src = feed(Seqs, 1000),
    {B1, Src1} = chappe_mix_rtcp:report_block(Src, 0),
    %% 12 expected, 11 received: 256 * 1 div 12 = 21; no SR heard yet
    ?assertEqual(
        #{
            ssrc => 77,
            fraction => 21,
            lost => 1,
            highest => 65541,
            jitter => 0,
            lsr => 0,
            dlsr => 0
        },
        B1
    ),
    %% no loss since: fraction 0, cumulative unchanged
    Src2 = lists:foldl(
        fun(S, A) ->
            chappe_mix_rtcp:src_update(A, S, S * 160, 1000 + S * 160)
        end,
        Src1,
        [6, 7]
    ),
    %% the peer's SR arrived 1.5 s ago
    Src3 = chappe_mix_rtcp:src_sr(Src2, ?NTP, 1000000),
    {B2, _} = chappe_mix_rtcp:report_block(Src3, 2500000),
    ?assertMatch(
        #{fraction := 0, lost := 1, lsr := 16#4321ABCD, dlsr := 98304}, B2
    ).

%% R3550-103 R3550-104 (A.8): a source that arrives 80 ticks late on every other
%% packet has a jitter that grows toward 80.
jitter_test() ->
    Src = lists:foldl(
        fun(N, A) ->
            Late = (N rem 2) * 80,
            chappe_mix_rtcp:src_update(A, N, N * 160, N * 160 + Late)
        end,
        chappe_mix_rtcp:src_new(1, 0, 0, 0),
        lists:seq(1, 200)
    ),
    {#{jitter := J}, _} = chappe_mix_rtcp:report_block(Src, 0),
    ?assert(J > 60 andalso J =< 80, J).

feed([S0 | Seqs], Off) ->
    lists:foldl(
        fun(S, A) ->
            chappe_mix_rtcp:src_update(A, S, S * 160, Off + S * 160)
        end,
        chappe_mix_rtcp:src_new(77, S0, S0 * 160, Off + S0 * 160),
        Seqs
    ).

%% NTP time: seconds since 1900 in the high word, the fraction in the low.
ntp_test() ->
    ?assertEqual(2208988800 bsl 32, chappe_mix_rtcp:ntp(0)),
    ?assertEqual(
        (2208988801 bsl 32) + (1 bsl 31), chappe_mix_rtcp:ntp(1500000)
    ).

%% RFC 7022: a CNAME is 96 random bits, base64, different each time.
cname_test() ->
    A = chappe_mix_rtcp:cname(),
    ?assertEqual(16, byte_size(A)),
    ?assertNotEqual(A, chappe_mix_rtcp:cname()).
