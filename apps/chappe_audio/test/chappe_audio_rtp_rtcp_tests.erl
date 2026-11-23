%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% chappe_audio_rtp_rtcp, the RTCP session of one receiver: where its
%% reports go, and what counts as RTP in its statistics.
-module(chappe_audio_rtp_rtcp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(S, chappe_audio_rtp_rtcp).
-define(IP, {192, 0, 2, 1}).

%% RFC 3550 11: the port above the source's RTP port, unless there is none
dest_port_above_test() ->
    S = ?S:new(port, undefined, <<"c">>),
    ?assertEqual({?IP, 4001}, ?S:dest(S, {?IP, 4000}, undefined)),
    ?assertEqual({?IP, 4001}, ?S:dest(S, undefined, {?IP, 4000})),
    %% a source on the last port has no port above it: no report
    ?assertEqual(undefined, ?S:dest(S, {?IP, 65535}, undefined)),
    ?assertEqual(undefined, ?S:dest(S, undefined, {?IP, 65535})),
    ?assertEqual(undefined, ?S:dest(S, undefined, undefined)),
    %% the RTCP address of the SDP, or where RTCP came from, still do
    R = ?S:new(port, {?IP, 5000}, <<"c">>),
    ?assertEqual({?IP, 5000}, ?S:dest(R, {?IP, 65535}, undefined)),
    Heard = ?S:input(S, rr(), {?IP, 6000}),
    ?assertEqual({?IP, 6000}, ?S:dest(Heard, {?IP, 65535}, undefined)).

dest_mux_test() ->
    S = ?S:new(mux, undefined, <<"c">>),
    ?assertEqual({?IP, 65535}, ?S:dest(S, {?IP, 65535}, undefined)),
    ?assertEqual({?IP, 4000}, ?S:dest(S, undefined, {?IP, 4000})),
    ?assertEqual(undefined, ?S:dest(S, undefined, undefined)).

%% RFC 5761 4: a packet whose second octet is 192 to 223 is RTCP, so a
%% muxed PSFB (206), RTPFB (205) or XR (207) never counts as RTP
feedback_not_rtp_test() ->
    S0 = ?S:new(port, undefined, <<"c">>),
    Psfb = <<16#81, 206, 0, 2, 16#9999:32, 16#1234:32>>,
    Rtpfb = <<16#81, 205, 0, 2, 16#9998:32, 16#1234:32>>,
    Xr = <<16#80, 207, 0, 1, 16#9997:32>>,
    Rtp = <<16#80, 0, 0, 1, 0:32, 16#1234:32, 16#FF>>,
    S = lists:foldl(fun(P, A) -> ?S:rtp(A, P) end, S0, [Psfb, Rtpfb, Xr, Rtp]),
    ?assertMatch(
        #{sources := [#{ssrc := 16#1234, received := 1}]}, ?S:stats(S)
    ).

rr() ->
    <<16#80, 201, 0, 1, 16#1234:32>>.

%% RFC 3550 6.2.1: a straggler sent before the BYE and arriving after it
%% (at or below the highest sequence number at the BYE) counts against
%% the source's entry, its statistics kept
%% req: R3550-6.2.1-1
straggler_after_bye_test() ->
    S1 = heard([1, 2, 4], 0),
    S2 = ?S:input(S1, rr_bye(), {?IP, 6000}, 100000),
    S3 = ?S:rtp(S2, rtp(3), 110000),
    ?assertMatch(
        #{sources := [#{ssrc := 16#1234, received := 4, lost := 0}]},
        ?S:stats(S3)
    ).

%% RFC 3550 6.2.1: a source that sent BYE has left, the next RR has no
%% block for it, even with a straggler heard
%% req: R3550-6.2.1-1
bye_not_reported_test() ->
    S1 = ?S:input(heard([1, 3], 0), rr_bye(), {?IP, 6000}, 100000),
    S2 = ?S:rtp(S1, rtp(2), 110000),
    {Bin, _} = ?S:report(S2, false, 200000),
    ?assertMatch(
        {ok, [#{type := rr, blocks := []} | _]}, chappe_audio_rtcp:parse(Bin)
    ).

%% RFC 3550 6.2.1: past the grace the entry is deleted, and a packet from
%% that SSRC starts a new one
%% req: R3550-6.2.1-1
new_entry_after_grace_test() ->
    S1 = ?S:input(heard([1, 2, 3], 0), rr_bye(), {?IP, 6000}, 100000),
    S2 = ?S:rtp(S1, rtp(2), 100000 + 5000000),
    ?assertMatch(
        #{sources := [#{ssrc := 16#1234, received := 1}]}, ?S:stats(S2)
    ),
    {Bin, _} = ?S:report(S2, false, 100000 + 5000000),
    ?assertMatch(
        {ok, [#{type := rr, blocks := [#{ssrc := 16#1234}]} | _]},
        chappe_audio_rtcp:parse(Bin)
    ),
    %% a report past the grace removes the entry with no packet
    S3 = ?S:input(heard([1], 0), rr_bye(), {?IP, 6000}, 100000),
    {_, S4} = ?S:report(S3, false, 100000 + 5000000),
    ?assertMatch(#{sources := []}, ?S:stats(S4)).

%% RFC 3550 6.2.1, A.1: a packet newer than the highest sequence number
%% at the BYE is the source sending again under the same SSRC, not a
%% straggler: the mark ends and the source, its entry continued, is in
%% the next report
%% req: R3550-6.2.1-1
resume_after_bye_test() ->
    S1 = ?S:input(heard([1, 2, 3], 0), rr_bye(), {?IP, 6000}, 100000),
    S2 = ?S:rtp(S1, rtp(4), 110000),
    ?assertMatch(
        #{sources := [#{ssrc := 16#1234, received := 4, lost := 0}]},
        ?S:stats(S2)
    ),
    {Bin, _} = ?S:report(S2, false, 200000),
    ?assertMatch(
        {ok, [#{type := rr, blocks := [#{ssrc := 16#1234}]} | _]},
        chappe_audio_rtcp:parse(Bin)
    ).

%% The comparison wraps (A.1): with 65535 the highest at the BYE, 0 is
%% newer and 65530 a straggler; with 10, 65530 is older across the wrap
%% req: R3550-6.2.1-1
resume_wrap_test() ->
    S1 = ?S:input(heard([65534, 65535], 0), rr_bye(), {?IP, 6000}, 100000),
    ?assertEqual([], blocks(?S:rtp(S1, rtp(65530), 110000))),
    ?assertEqual([], blocks(?S:rtp(S1, rtp(65535), 110000))),
    ?assertMatch([#{ssrc := 16#1234}], blocks(?S:rtp(S1, rtp(0), 110000))),
    W = ?S:input(heard([9, 10], 0), rr_bye(), {?IP, 6000}, 100000),
    ?assertEqual([], blocks(?S:rtp(W, rtp(65530), 110000))),
    ?assertMatch([#{ssrc := 16#1234}], blocks(?S:rtp(W, rtp(11), 110000))).

%% the report blocks of the next RR
blocks(S) ->
    {Bin, _} = ?S:report(S, false, 200000),
    {ok, [#{type := rr, blocks := Blocks} | _]} = chappe_audio_rtcp:parse(Bin),
    Blocks.

%% a session that heard the source's packets Seqs at Now
heard(Seqs, Now) ->
    S0 = ?S:new(port, undefined, <<"c">>),
    lists:foldl(fun(Seq, A) -> ?S:rtp(A, rtp(Seq), Now) end, S0, Seqs).

rtp(Seq) ->
    <<16#80, 0, Seq:16, ((Seq * 160) band 16#FFFFFFFF):32, 16#1234:32, 16#FF>>.

%% an RR of the source and its BYE
rr_bye() ->
    <<16#80, 201, 0, 1, 16#1234:32, 16#81, 203, 0, 1, 16#1234:32>>.
