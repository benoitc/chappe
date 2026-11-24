%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The RTP session on a 16 kHz clock: the jitter of the receiver reports
%% counts in timestamp units of the room's rate (RFC 3550 A.8), and the
%% RTCP schedule does not depend on the rate.
-module(chappe_mix_session_tests).

-include_lib("eunit/include/eunit.hrl").

-define(T0, 1000000000).

%% A sender whose packets are evenly spaced on its own clock has no
%% jitter, whatever the rate: 20 ms packets stepping 320 at 16 kHz, 160
%% at 8 kHz.
steady_sender_test() ->
    ?assertEqual(0, jitter(16000, 320, fun(_) -> 0 end)),
    ?assertEqual(0, jitter(8000, 160, fun(_) -> 0 end)).

%% The same arrival spread reads twice as many timestamp units at
%% 16 kHz as at 8 kHz.
jitter_in_rate_units_test() ->
    Spread = fun(N) ->
        case N rem 2 of
            0 -> 3000;
            1 -> -3000
        end
    end,
    J8 = jitter(8000, 160, Spread),
    J16 = jitter(16000, 320, Spread),
    ?assert(J8 > 0),
    ?assert(abs(J16 - 2 * J8) =< 2, {J8, J16}).

%% A 16 kHz sender read on an 8 kHz clock would show half its timestamp
%% step as jitter on every packet (160 units): the session must use the
%% room's rate, not 8000.
wrong_clock_test() ->
    ?assert(jitter(8000, 320, fun(_) -> 0 end) >= 150).

%% The report schedule is the same at both rates: the interval comes from
%% the members, the report size and the 5 s minimum (RFC 3550 6.3).
interval_same_test() ->
    rand:seed(exsss, {1, 2, 3}),
    S8 = chappe_mix_session:new(1, ?T0, 8000),
    rand:seed(exsss, {1, 2, 3}),
    S16 = chappe_mix_session:new(1, ?T0, 16000),
    Due = fun(S) ->
        hd([
            T
         || T <- lists:seq(?T0, ?T0 + us(20000000), us(1000)),
            chappe_mix_session:due(S, T)
        ])
    end,
    ?assertEqual(Due(S8), Due(S16)).

us(N) -> erlang:convert_time_unit(N, microsecond, native).

%% The jitter of 200 packets 20 ms apart, timestamps stepping Step on a
%% Rate clock, each arriving Spread(N) us off its slot.
jitter(Rate, Step, Spread) ->
    S0 = chappe_mix_session:new(16#1000, ?T0, Rate),
    S = lists:foldl(
        fun(N, Acc) ->
            P = #{
                ssrc => 16#A0,
                seq => N,
                ts => N * Step,
                csrcs => [],
                pt => 96,
                marker => false,
                payload => <<>>
            },
            At = ?T0 + us(N * 20000 + Spread(N)),
            {ok, Acc1, _} = chappe_mix_session:rtp_in(
                Acc, P, {{127, 0, 0, 1}, 9}, At
            ),
            Acc1
        end,
        S0,
        lists:seq(1, 200)
    ),
    {Pkt, _} = chappe_mix_session:report(
        S, <<"t">>, fun(_) -> [] end, [], 5000000
    ),
    {ok, [#{type := rr, blocks := [#{jitter := J}]} | _]} =
        chappe_mix_rtcp:parse(Pkt),
    J.
