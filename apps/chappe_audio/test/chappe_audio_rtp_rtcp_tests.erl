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
