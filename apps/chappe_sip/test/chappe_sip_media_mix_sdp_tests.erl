%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The SDP of a mixer leg at both rates: G.711 on its static payload types
%% in an 8 kHz room, L16/16000 (RFC 3551 4.5.11) on a dynamic one with
%% telephone-event at 16000 (RFC 4733 2.4) in a 16 kHz room.
-module(chappe_sip_media_mix_sdp_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, chappe_sip_media_mix_sdp).

sdp(Fmts, Lines) ->
    iolist_to_binary([
        <<"v=0\r\no=- 1 1 IN IP4 10.0.0.9\r\ns=-\r\nc=IN IP4 10.0.0.9\r\n">>,
        <<"t=0 0\r\nm=audio 4000 RTP/AVP ">>,
        Fmts,
        <<"\r\n">>,
        Lines
    ]).

%% what rtpengine 26.3 offers the mixer with the 16 kHz flags
%% (apps/chappe_mix/test/audit/ATTEMPTS.md, the L16 gate)
rtpengine_offer() ->
    sdp(<<"97 98">>, [
        <<"a=rtpmap:97 L16/16000\r\n">>,
        <<"a=rtpmap:98 telephone-event/16000\r\n">>,
        <<"a=fmtp:98 0-15\r\n">>,
        <<"a=sendrecv\r\na=rtcp-mux\r\na=ptime:20\r\n">>
    ]).

l16_offer_test() ->
    {ok, R} = ?M:accept_offer(rtpengine_offer(), 16000),
    ?assertMatch(
        #{
            law := l16,
            pt := 97,
            endpoint := {{10, 0, 0, 9}, 4000},
            mux := true,
            dtmf := #{pt := 98}
        },
        R
    ),
    #{dtmf := #{events := Ev}} = R,
    ?assertEqual(lists:seq(0, 15), Ev).

%% the first L16 at 16000, mono, in the offer's order; stereo, 8 kHz and
%% 44.1 kHz L16 are not the room's format
l16_pick_test() ->
    Offer = sdp(<<"10 99 100 101 102">>, [
        <<"a=rtpmap:99 L16/16000/2\r\n">>,
        <<"a=rtpmap:100 L16/8000\r\n">>,
        <<"a=rtpmap:101 l16/16000/1\r\n">>,
        <<"a=rtpmap:102 L16/16000\r\n">>
    ]),
    ?assertMatch({ok, #{law := l16, pt := 101}}, ?M:accept_offer(Offer, 16000)),
    ?assertEqual(
        {error, no_common_codec},
        ?M:accept_offer(sdp(<<"10 11">>, []), 16000)
    ).

%% A PCMU-only offer (a caller with no rtpengine in front) cannot join a
%% 16 kHz room; an L16 offer cannot join an 8 kHz one.
pcmu_to_16k_refused_test() ->
    Pcmu = sdp(<<"0 101">>, [
        <<"a=rtpmap:0 PCMU/8000\r\n">>,
        <<"a=rtpmap:101 telephone-event/8000\r\n">>
    ]),
    ?assertEqual({error, no_common_codec}, ?M:accept_offer(Pcmu, 16000)),
    ?assertMatch({ok, #{law := ulaw, pt := 0}}, ?M:accept_offer(Pcmu)),
    ?assertEqual({error, no_common_codec}, ?M:accept_offer(rtpengine_offer())).

%% telephone-event is taken at the room's clock only (RFC 4733 2.4: the
%% rate is the unit of its timestamps and durations)
dtmf_clock_test() ->
    Mixed = sdp(<<"96 101 102">>, [
        <<"a=rtpmap:96 L16/16000\r\n">>,
        <<"a=rtpmap:101 telephone-event/8000\r\n">>,
        <<"a=rtpmap:102 telephone-event/16000\r\n">>
    ]),
    ?assertMatch({ok, #{dtmf := #{pt := 102}}}, ?M:accept_offer(Mixed, 16000)),
    Wrong = sdp(<<"96 101">>, [
        <<"a=rtpmap:96 L16/16000\r\n">>,
        <<"a=rtpmap:101 telephone-event/8000\r\n">>
    ]),
    ?assertMatch({ok, #{dtmf := undefined}}, ?M:accept_offer(Wrong, 16000)),
    G711 = sdp(<<"8 101 102">>, [
        <<"a=rtpmap:101 telephone-event/16000\r\n">>,
        <<"a=rtpmap:102 telephone-event/8000\r\n">>
    ]),
    ?assertMatch(
        {ok, #{law := alaw, dtmf := #{pt := 102}}}, ?M:accept_offer(G711)
    ).

local(Law, Extra) ->
    maps:merge(
        #{addr => {10, 0, 0, 5}, port => 30000, law => Law, mux => true},
        Extra
    ).

%% The answer names the offer's payload type and the room's clock.
l16_answer_test() ->
    A = ?M:answer(rtpengine_offer(), local(l16, #{pt => 97, dtmf_pt => 98})),
    [
        ?assertNotEqual(nomatch, binary:match(A, L), L)
     || L <- [
            <<"m=audio 30000 RTP/AVP 97 98\r\n">>,
            <<"a=rtpmap:97 L16/16000\r\n">>,
            <<"a=rtpmap:98 telephone-event/16000\r\n">>,
            <<"a=fmtp:98 0-16\r\n">>,
            <<"a=ptime:20\r\n">>
        ]
    ],
    ?assertEqual(nomatch, binary:match(A, <<"/8000">>)).

%% The mixer's own offer at 16 kHz: L16 on 96 unless the leg says, and
%% telephone-event/16000.
l16_offer_out_test() ->
    O = ?M:offer(local(l16, #{dtmf_pt => 101})),
    [
        ?assertNotEqual(nomatch, binary:match(O, L), L)
     || L <- [
            <<"m=audio 30000 RTP/AVP 96 101\r\n">>,
            <<"a=rtpmap:96 L16/16000\r\n">>,
            <<"a=rtpmap:101 telephone-event/16000\r\n">>
        ]
    ],
    ?assertEqual({ok, #{law => l16, pt => 96}}, pick_law(O, 16000)).

%% The 8 kHz offer is the one of before.
g711_offer_out_test() ->
    O = ?M:offer(local(alaw, #{dtmf_pt => 101})),
    [
        ?assertNotEqual(nomatch, binary:match(O, L), L)
     || L <- [
            <<"m=audio 30000 RTP/AVP 8 101\r\n">>,
            <<"a=rtpmap:8 PCMA/8000\r\n">>,
            <<"a=rtpmap:101 telephone-event/8000\r\n">>
        ]
    ].

%% Reading the answer to an L16 offer: its payload type and events, at
%% 16 kHz; a G.711 answer to it is not the leg's format.
l16_read_answer_test() ->
    {ok, R} = ?M:read_answer(rtpengine_offer(), l16),
    ?assertMatch(#{pt := 97, dtmf := #{pt := 98}}, R),
    Pcmu = sdp(<<"0">>, [<<"a=rtpmap:0 PCMU/8000\r\n">>]),
    ?assertEqual({error, no_common_codec}, ?M:read_answer(Pcmu, l16)),
    ?assertMatch({ok, #{pt := 0}}, ?M:read_answer(Pcmu, ulaw)),
    ?assertEqual({error, {law_mismatch, ulaw}}, ?M:read_answer(Pcmu, alaw)).

pick_law(Sdp, Rate) ->
    case ?M:accept_offer(Sdp, Rate) of
        {ok, #{law := L, pt := P}} -> {ok, #{law => L, pt => P}};
        Err -> Err
    end.
