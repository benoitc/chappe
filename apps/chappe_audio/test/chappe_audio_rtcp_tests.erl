%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_audio_rtcp (RFC 3550 section 6 and appendix A, receive side):
%% compound packets parsed and built byte for byte, the reception
%% statistics of A.1, A.3 and A.8, LSR and DLSR on the values of the
%% RFC's figure 2, the interval of 6.2 and A.7, and the RFC 5761 4 test.
-module(chappe_audio_rtcp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(R, chappe_audio_rtcp).

h(Hex) -> binary:decode_hex(Hex).

%% ---- RFC 5761 4 ----

%% the second octet 192 to 223 is RTCP: SR 200 to APP 204 are RTP payload
%% types 72 to 76 with the marker bit set
%% req: R5761-4-1
is_rtcp_test() ->
    ?assert(?R:is_rtcp(h(<<"81c8000bcafebabe">>))),
    [?assert(?R:is_rtcp(<<16#80, (128 + PT), 0, 0>>)) || PT <- lists:seq(72, 76)],
    ?assert(?R:is_rtcp(<<16#80, 223, 0, 0>>)),
    ?assertNot(?R:is_rtcp(<<16#80, 0, 0, 1>>)),
    ?assertNot(?R:is_rtcp(<<16#80, (128 + 8), 0, 1>>)),
    ?assertNot(?R:is_rtcp(<<16#80, 224>>)),
    ?assertNot(?R:is_rtcp(<<>>)).

%% ---- parse ----

%% SR (6.4.1) with one report block, then SDES (6.5) with a CNAME
parse_sr_sdes_test() ->
    Sr = h(<<
        "81c8000c"
        "00001234"
        "b44db70520000000"
        "000003e8"
        "00000032"
        "00001f40"
        "cafebabe"
        "0a000005"
        "00010064"
        "00000007"
        "b7052000"
        "00054000"
    >>),
    Sdes = h(<<"81ca0003" "00001234" "0103616263" "000000">>),
    ?assertEqual(
        {ok, [
            #{
                type => sr,
                ssrc => 16#1234,
                ntp => 16#b44db70520000000,
                ts => 1000,
                packets => 50,
                octets => 8000,
                blocks => [
                    #{
                        ssrc => 16#cafebabe,
                        fraction => 10,
                        lost => 5,
                        highest => 16#10064,
                        jitter => 7,
                        lsr => 16#b7052000,
                        dlsr => 16#54000
                    }
                ]
            },
            #{type => sdes, chunks => [{16#1234, [{cname, <<"abc">>}]}]}
        ]},
        ?R:parse(<<Sr/binary, Sdes/binary>>)
    ).

%% an RR, an unknown type kept by number (6.1: ignored, never an atom),
%% and a BYE with its reason (6.6)
%% req: R3550-6.1-4
parse_rr_other_bye_test() ->
    Rr = h(<<"81c90001" "00000001">>),
    Rr0 = h(<<"80c90001" "00000001">>),
    App = h(<<"80cc0002" "00000001" "61626364">>),
    Bye = h(<<"81cb0002" "00000001" "03627965">>),
    ?assertEqual(
        {ok, [
            #{type => rr, ssrc => 1, blocks => []},
            #{type => other, pt => 204},
            #{type => bye, ssrcs => [1], reason => <<"bye">>}
        ]},
        ?R:parse(<<Rr0/binary, App/binary, Bye/binary>>)
    ),
    %% RC 1 with no block is not a valid RR
    ?assertEqual({error, invalid}, ?R:parse(Rr)).

%% A.2: version 2, SR or RR first without padding, lengths that add up
%% req: R3550-6.1-1
parse_invalid_test() ->
    Rr = h(<<"80c90001" "00000001">>),
    [
        ?assertEqual({error, invalid}, ?R:parse(B))
     || B <- [
            <<>>,
            h(<<"40c90001" "00000001">>),
            h(<<"80ca0001" "00000001">>),
            h(<<"a0c90001" "00000001">>),
            <<Rr/binary, 16#80>>,
            h(<<"80c90002" "00000001">>),
            <<Rr/binary, (h(<<"40ca0000">>))/binary>>
        ]
    ],
    %% padding on the last packet is allowed
    ?assertMatch(
        {ok, [#{type := rr}, #{type := bye, ssrcs := [1]}]},
        ?R:parse(<<Rr/binary, (h(<<"a1cb0002" "00000001" "00000004">>))/binary>>)
    ).

%% ---- build ----

%% RR then SDES CNAME, as the receiver sends it (6.1, 6.4.2, 6.5)
build_rr_sdes_test() ->
    Block = #{
        ssrc => 16#cafebabe,
        fraction => 10,
        lost => -1,
        highest => 16#10064,
        jitter => 7,
        lsr => 16#b7052000,
        dlsr => 16#54000
    },
    Bin = ?R:build([
        #{type => rr, ssrc => 16#1234, blocks => [Block]},
        #{type => sdes, chunks => [{16#1234, [{cname, <<"abcd">>}]}]}
    ]),
    ?assertEqual(
        h(<<
            "81c90007"
            "00001234"
            "cafebabe"
            "0affffff"
            "00010064"
            "00000007"
            "b7052000"
            "00054000"
            "81ca0003"
            "00001234"
            "010461626364"
            "0000"
        >>),
        Bin
    ),
    ?assertMatch({ok, [#{type := rr, blocks := [Block]}, #{type := sdes}]}, ?R:parse(Bin)).

%% an empty RR (RC 0, 6.4.2), then SDES and BYE
%% req: R3550-6.4.2-1
build_empty_rr_bye_test() ->
    Bin = ?R:build([
        #{type => rr, ssrc => 1, blocks => []},
        #{type => sdes, chunks => [{1, [{cname, <<"abc">>}]}]},
        #{type => bye, ssrcs => [1]}
    ]),
    ?assertEqual(h(<<"80c90001" "00000001" "81ca0003" "00000001" "01036162" "63000000" "81cb0001" "00000001">>), Bin),
    ?assertEqual(0, byte_size(Bin) rem 4).

%% ---- reception statistics (A.1, A.3, A.8) ----

%% packets 1 to 100 but 10 of them: 10 lost of 100 expected, fraction
%% 10 * 256 div 100 = 25 (6.4.1, A.3)
%% req: R3550-6.4.1-1 R3550-6.4.1-2
loss_test() ->
    Lost = [5, 10, 20, 30, 40, 50, 60, 70, 80, 90],
    S = feed(?R:src_new(7), [Q || Q <- lists:seq(1, 100), not lists:member(Q, Lost)]),
    {B, S1} = ?R:block(S, 0),
    ?assertMatch(#{ssrc := 7, fraction := 25, lost := 10, highest := 100}, B),
    %% the next interval loses nothing: fraction 0, cumulative kept
    {B2, _} = ?R:block(feed(S1, lists:seq(101, 150)), 0),
    ?assertMatch(#{fraction := 0, lost := 10, highest := 150}, B2).

%% duplicates make the loss negative; the fraction is then 0
duplicates_test() ->
    S = feed(?R:src_new(7), [1, 2, 2, 3, 3, 4]),
    {B, _} = ?R:block(S, 0),
    ?assertMatch(#{fraction := 0, lost := -2, highest := 4}, B).

%% the sequence number wraps: the cycles count in the top 16 bits (A.1)
%% req: R3550-6.4.1-2
wrap_test() ->
    S = feed(?R:src_new(7), lists:seq(65530, 65535) ++ lists:seq(0, 5)),
    {B, _} = ?R:block(S, 0),
    ?assertMatch(#{lost := 0, highest := 16#10005}, B).

%% a jump past MAX_DROPOUT is a restart once a second packet follows it
%% in sequence (A.1): the statistics start again
restart_test() ->
    S = feed(?R:src_new(7), lists:seq(1, 10) ++ [20000]),
    {B, _} = ?R:block(S, 0),
    ?assertMatch(#{highest := 10, lost := 0}, B),
    {B2, _} = ?R:block(feed(S, [20001, 20002]), 0),
    ?assertMatch(#{highest := 20002, lost := 0}, B2).

%% A.8: J += (|D| - J) / 16, kept scaled by 16; one packet 160 units
%% late gives 10, the next on time 10 + (0 - 10) / 16, reported 9
%% req: R3550-6.4.1-3 R3550-6.4.1-4
jitter_test() ->
    S0 = ?R:src_rtp(?R:src_new(7), 1, 0, 1000),
    S1 = ?R:src_rtp(S0, 2, 160, 1000 + 320),
    {B1, _} = ?R:block(S1, 0),
    ?assertMatch(#{jitter := 10}, B1),
    S2 = ?R:src_rtp(S1, 3, 320, 1000 + 480),
    {B2, _} = ?R:block(S2, 0),
    ?assertMatch(#{jitter := 9}, B2),
    %% steady packets keep it at 0
    S3 = lists:foldl(
        fun(I, A) -> ?R:src_rtp(A, I, I * 160, 5 + I * 160) end,
        ?R:src_new(8),
        lists:seq(1, 50)
    ),
    {B3, _} = ?R:block(S3, 0),
    ?assertMatch(#{jitter := 0}, B3).

%% the RTP timestamp wraps at 32 bits: the transit difference stays small
jitter_wrap_test() ->
    S0 = ?R:src_rtp(?R:src_new(7), 1, 16#FFFFFF60, 0),
    S1 = ?R:src_rtp(S0, 2, 0, 160),
    {B, _} = ?R:block(S1, 0),
    ?assertMatch(#{jitter := 0}, B).

%% RFC 3550 figure 2 (6.4.1): an SR of ntp_sec 0xb44db705, ntp_frac
%% 0x20000000 gives LSR 0xb705:2000; reported 5.250 s later, DLSR is
%% 0x0005:4000
%% req: R3550-6.4.1-5
lsr_dlsr_test() ->
    S0 = feed(?R:src_new(7), [1]),
    {B0, _} = ?R:block(S0, 0),
    ?assertMatch(#{lsr := 0, dlsr := 0}, B0),
    S1 = ?R:src_sr(S0, 16#b44db70520000000, 1000000),
    {B1, _} = ?R:block(S1, 1000000 + 5250000),
    ?assertMatch(#{lsr := 16#b7052000, dlsr := 16#54000}, B1).

info_test() ->
    S = ?R:src_cname(feed(?R:src_new(7), [1, 2, 4]), <<"src@x">>),
    ?assertMatch(
        #{ssrc := 7, cname := <<"src@x">>, received := 3, lost := 1, highest := 4},
        ?R:src_info(S)
    ),
    ?assertNot(?R:src_heard(?R:src_new(9))),
    ?assert(?R:src_heard(S)),
    {_, S1} = ?R:block(S, 0),
    ?assertNot(?R:src_heard(S1)).

%% ---- the interval (6.2, A.7) ----

%% two members, one sender (the source), a 100-octet average: the
%% bandwidth term is far below the minimum, which decides, randomised to
%% 0.5 to 1.5 times; the first one uses half the minimum
%% req: R3550-6.2-1 R3550-6.2-2 R3550-6.3-1
interval_test() ->
    ?assertEqual(1250, ?R:interval(2, 1, false, 100.0, true, 0.0)),
    ?assertEqual(3750, ?R:interval(2, 1, false, 100.0, true, 1.0)),
    ?assertEqual(2500, ?R:interval(2, 1, false, 100.0, false, 0.0)),
    ?assertEqual(5000, ?R:interval(2, 1, false, 100.0, false, 0.5)),
    ?assertEqual(7500, ?R:interval(2, 1, false, 100.0, false, 1.0)),
    %% many members: n * C passes the minimum (1000 receivers, 3/4 of
    %% 500 octets/s: 1000 * 100 / 375 = 266.7 s)
    ?assertEqual(266667, ?R:interval(1001, 1, false, 100.0, false, 0.5)),
    [
        ?assert(T >= 2500 andalso T =< 7500)
     || _ <- lists:seq(1, 100), T <- [?R:interval(2, 1, false, 100.0, false)]
    ].

avg_size_test() ->
    ?assertEqual(100.0, ?R:avg_size(100.0, 72)),
    %% A.7: avg = (size + 28) / 16 + avg * 15 / 16, 28 the UDP and IPv4
    %% headers
    ?assertEqual(106.25, ?R:avg_size(100.0, 172)).

%% ---- CNAME and SSRC ----

cname_test() ->
    C = ?R:cname(),
    ?assertEqual(16, byte_size(C)),
    ?assertNotEqual(C, ?R:cname()).

ntp_test() ->
    %% 1970-01-01 is 2208988800 s past the NTP epoch; half a second is
    %% 0x80000000
    ?assertEqual((2208988800 bsl 32) bor 16#80000000, ?R:ntp(500000)).

%% ---- helpers ----

%% packets of SSRC 7 at 20 ms, on time
feed(S, Seqs) ->
    lists:foldl(fun(Q, A) -> ?R:src_rtp(A, Q, Q * 160, Q * 160) end, S, Seqs).
