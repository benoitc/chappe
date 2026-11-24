%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The mixer behind a real rtpengine, the way a product deploys it: every
%% party is anchored by rtpengine, which transcodes to PCMU towards the
%% mixer, and N-1 is checked by Goertzel at each party. Skipped unless
%% RTPENGINE_HOST is set; the media cases also need RTPENGINE_MEDIA_IP,
%% the address rtpengine reaches this machine at. `make interop-mix' brings
%% up apps/chappe_rtpengine/interop and sets both.
%%
%% Three parties:
%%
%%   pcmu   PCMU end to end, rtpengine relaying
%%   pcma   the party speaks PCMA; rtpengine transcodes to PCMU
%%   opus   the party speaks PCMU into one rtpengine call that encodes
%%          opus, a plain UDP relay on this host carries the opus to a
%%          second call that decodes it to PCMU for the mixer, and back.
%%          No Erlang opus codec is needed, and both directions of the
%%          negotiated opus leg go through rtpengine's encoder and decoder.
-module(chappe_mix_live_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    transcoded_n_minus_one/1,
    thirty_ms_n_minus_one/1,
    dtmf_through_rtpengine/1,
    taps_through_rtpengine/1,
    hd_band_through_rtpengine/1,
    hd_dtmf_through_rtpengine/1
]).

-define(NODE, chappe_mix_live).
%% the same judge as the loopback suite: present within 3 dB of the
%% tone, absent 40 dB below it
-define(PRESENT, -18.0).
-define(ABSENT, -54.7).

all() ->
    [
        transcoded_n_minus_one,
        thirty_ms_n_minus_one,
        dtmf_through_rtpengine,
        taps_through_rtpengine,
        hd_band_through_rtpengine,
        hd_dtmf_through_rtpengine
    ].

init_per_suite(Config) ->
    case {os:getenv("RTPENGINE_HOST"), os:getenv("RTPENGINE_MEDIA_IP")} of
        {false, _} ->
            {skip, "RTPENGINE_HOST not set"};
        {_, M} when M =:= false; M =:= "" ->
            {skip, "RTPENGINE_MEDIA_IP not set"};
        {Host, MediaIp} ->
            Port =
                case os:getenv("RTPENGINE_PORT") of
                    false -> 2223;
                    P -> list_to_integer(P)
                end,
            {ok, _} = application:ensure_all_started(chappe_rtpengine),
            {ok, _} = application:ensure_all_started(chappe_mix),
            ok = chappe_rtpengine:add_node(?NODE, #{host => Host, port => Port}),
            {ok, RtpeIp} = inet:parse_address(Host),
            [{rtpe_ip, RtpeIp}, {media_ip, list_to_binary(MediaIp)} | Config]
    end.

end_per_suite(_Config) ->
    _ = chappe_rtpengine:remove_node(?NODE),
    _ = application:stop(chappe_mix),
    _ = application:stop(chappe_rtpengine),
    ok.

%% Each party hears the other two and not itself, whatever codec its leg
%% negotiated with rtpengine.
transcoded_n_minus_one(Config) ->
    n_minus_one(Config, [{pcmu, 440}, {pcma, 1100}, {opus, 1700}]).

%% A party that sends 30 ms PCMU packets, relayed as they are by
%% rtpengine, is heard by the others and hears them, next to a 20 ms PCMU
%% and a PCMA party.
thirty_ms_n_minus_one(Config) ->
    n_minus_one(Config, [{pcmu, 440}, {pcmu30, 1100}, {pcma, 1700}]).

n_minus_one(Config, Kinds) ->
    {ok, Conf} = chappe_mix:start(#{ip => {0, 0, 0, 0}}),
    Parties = [party(Config, Conf, Kind, F) || {Kind, F} <- Kinds],
    Freqs = [F || #{freq := F} <- Parties],
    %% rtpengine sets up codec handlers on the first packets; let the
    %% transcoders settle before recording
    timer:sleep(2000),
    [chappe_mix_test_tone:clear(P) || #{ep := P} <- Parties],
    timer:sleep(2000),
    ct:log("mixer legs: ~p", [chappe_mix:legs(Conf)]),
    Results = [
        {Kind, F,
            chappe_mix_test_tone:hears(
                P, {?PRESENT, ?ABSENT}, {Freqs -- [F], [F]}
            )}
     || #{kind := Kind, freq := F, ep := P} <- Parties
    ],
    ct:log("per party: ~p", [Results]),
    %% a 30 ms party is heard whole in every 20 ms frame: its tone is not
    %% cut or half missing (allowing one frame in fifty for a stall)
    Weak = [
        {Kind, chappe_mix_test_tone:weak_frames(Fs, F30, ?PRESENT), length(Fs)}
     || #{kind := pcmu30, freq := F30} <- Parties,
        #{kind := Kind, ep := P} <- Parties,
        Kind =/= pcmu30,
        Fs <- [chappe_mix_test_tone:frames(P)]
    ],
    ct:log("frames short of the 30 ms party's tone: ~p", [Weak]),
    [cleanup(P) || P <- Parties],
    ok = chappe_mix:stop(Conf),
    [
        ?assertMatch({_, _, {ok, _}}, {Kind, F, R})
     || {Kind, F, R} <- Results
    ],
    [?assert(W * 50 =< N, {weak, Kind, W, N}) || {Kind, W, N} <- Weak],
    ok.

%% Taps behind rtpengine: the PCMA party's tap carries its tone decoded
%% to PCM (rtpengine transcodes it to PCMU towards the mixer) and not the
%% other party's, and the room's tap carries both.
taps_through_rtpengine(Config) ->
    {ok, Conf} = chappe_mix:start(#{ip => {0, 0, 0, 0}}),
    [#{leg := LA}, _] =
        Parties = [
            party(Config, Conf, Kind, F)
         || {Kind, F} <- [{pcma, 440}, {pcmu, 1100}]
        ],
    timer:sleep(2000),
    {ok, TA} = chappe_mix:tap(Conf, LA, #{}),
    {ok, TR} = chappe_mix:tap(Conf, room, #{}),
    Party = tap_samples(Conf, TA, 100),
    Room = tap_samples(Conf, TR, 100),
    [cleanup(P) || P <- Parties],
    ok = chappe_mix:stop(Conf),
    [{440, A440}, {1100, A1100}] = chappe_mix_test_tone:levels(Party, [
        440, 1100
    ]),
    [{440, R440}, {1100, R1100}] = chappe_mix_test_tone:levels(Room, [440, 1100]),
    ct:log("party tap 440 ~.1f 1100 ~.1f, room tap 440 ~.1f 1100 ~.1f", [
        A440, A1100, R440, R1100
    ]),
    ?assert(A440 > ?PRESENT - 6),
    ?assert(A1100 < ?ABSENT),
    ?assert(R440 > ?PRESENT - 6 andalso R1100 > ?PRESENT - 6).

%% N tap messages of Tap, as samples, skipping the other taps'.
tap_samples(_Conf, _Tap, 0) ->
    [];
tap_samples(Conf, Tap, N) ->
    receive
        {chappe_mix, Conf, {tap, Tap, Pcm}} ->
            [S || <<S:16/little-signed>> <= Pcm] ++
                tap_samples(Conf, Tap, N - 1)
    after 2000 -> ct:fail(no_tap)
    end.

%% RFC 4733 events through rtpengine: both parties negotiate PCMU and
%% telephone-event 101 with rtpengine on both sides of it, A sends a
%% digit (start with M, updates, three end packets with E) in place of
%% audio packets, and B gets each event packet through the mixer and
%% rtpengine, payload as sent, the M bit on the first only, one timestamp
%% for the whole event.
dtmf_through_rtpengine(Config) ->
    Media = ?config(media_ip, Config),
    RtpeIp = ?config(rtpe_ip, Config),
    {ok, Conf} = chappe_mix:start(#{ip => {0, 0, 0, 0}}),
    Open = fun() ->
        {ok, S} = gen_udp:open(0, [binary, {ip, {0, 0, 0, 0}}, {active, true}]),
        {ok, P} = inet:port(S),
        {S, P}
    end,
    Party = fun({Sock, Port}) ->
        {ok, Leg, #{port := MixPort}} = chappe_mix:add_leg(
            Conf, #{rtcp => pair, dtmf_pt => 101}
        ),
        {Sess, ToParty, ToMixer} = call(
            Media,
            sdp(Media, Port, pcmu_dtmf),
            #{},
            sdp(Media, MixPort, pcmu_dtmf)
        ),
        ok = chappe_mix:set_remote(Conf, Leg, {RtpeIp, ToMixer}),
        {Sock, {RtpeIp, ToParty}, Sess}
    end,
    {SA, ToA, SessA} = Party(Open()),
    {SB, ToB, SessB} = Party(Open()),
    Silence = binary:copy(<<16#FF>>, 160),
    Audio = fun(N) ->
        chappe_mix_rtp:build(#{
            pt => 0,
            seq => N,
            ts => N * 160,
            ssrc => 16#A,
            marker => false,
            payload => Silence
        })
    end,
    Ev = fun(N, M, E, Dur) ->
        chappe_mix_rtp:build(#{
            pt => 101,
            seq => N,
            ts => 100 * 160,
            ssrc => 16#A,
            marker => M,
            payload => <<5, E:1, 0:1, 10:6, Dur:16>>
        })
    end,
    Digit = [
        Ev(100, true, 0, 160),
        Ev(101, false, 0, 320),
        Ev(102, false, 0, 480),
        Ev(103, false, 1, 640),
        Ev(104, false, 1, 640),
        Ev(105, false, 1, 640)
    ],
    Plan =
        [Audio(N) || N <- lists:seq(1, 99)] ++ Digit ++
            [Audio(N) || N <- lists:seq(106, 130)],
    %% B sends silence too, so rtpengine has both sides flowing
    BPlan = [Audio(N) || N <- lists:seq(1, 130)],
    T0 = erlang:monotonic_time(millisecond),
    lists:foldl(
        fun({PA, PB}, K) ->
            wait_ms(T0 + 20 * K),
            {IpA, PortA} = ToA,
            {IpB, PortB} = ToB,
            ok = gen_udp:send(SA, IpA, PortA, PA),
            ok = gen_udp:send(SB, IpB, PortB, PB),
            K + 1
        end,
        0,
        lists:zip(Plan, BPlan)
    ),
    timer:sleep(500),
    ct:log("mixer legs: ~p", [chappe_mix:legs(Conf)]),
    Got = [
        P
     || {ok, #{pt := 101} = P} <- [chappe_mix_rtp:parse(B) || B <- udp_all(SB)]
    ],
    ct:log("B got ~p event packets: ~p", [length(Got), Got]),
    [chappe_rtpengine_session:stop(S) || S <- [SessA, SessB]],
    [gen_udp:close(S) || S <- [SA, SB]],
    ok = chappe_mix:stop(Conf),
    Sent = [
        maps:get(payload, P)
     || {ok, P} <- [chappe_mix_rtp:parse(D) || D <- Digit]
    ],
    ?assertEqual(Sent, [maps:get(payload, P) || P <- Got]),
    ?assertEqual(
        [true, false, false, false, false, false],
        [maps:get(marker, P) || P <- Got]
    ),
    ?assertMatch([_], lists:usort([maps:get(ts, P) || P <- Got])).

%% ---- a 16 kHz room ----

%% A 16 kHz room behind rtpengine 26.3: four parties, each an L16/16000
%% tone endpoint whose leg to the mixer goes through a real codec. l16
%% is relayed as it is; g722, opus and pcmu speak L16 into a first
%% rtpengine call that encodes the codec, a relay carries it to a second
%% call that decodes it to L16/16000 for the mixer (the 16 kHz flags of
%% chappe_sip_media:mixer_params/2), and back. One party at a time plays
%% the 16 kHz band probe, the others are silent, and each listener's
%% recording goes through the band check: the four probe tones within
%% 6 dB (a codec), nothing folded onto 2000 and 3000 Hz. The G.722 and
%% Opus paths carry the whole band both ways; the PCMU one drops 5000 and
%% 6000 Hz, both ways, and fails.
hd_band_through_rtpengine(Config) ->
    {ok, Conf} = chappe_mix:start(#{ip => {0, 0, 0, 0}, rate => 16000}),
    Parties = [hd_party(Config, Conf, K) || K <- [l16, g722, opus, pcmu]],
    Probe = list_to_tuple(chappe_mix_test_tone:band_probe(200)),
    Cal = chappe_mix_test_tone:band_calibrate(tuple_to_list(Probe)),
    timer:sleep(2000),
    ct:log("mixer legs: ~p", [chappe_mix:legs(Conf)]),
    Round = fun(Sender, Listeners) ->
        [Ep ! {signal, {0}} || #{ep := Ep} <- Parties],
        #{ep := S} = hd_kind(Sender, Parties),
        S ! {signal, Probe},
        timer:sleep(1500),
        Eps = [{K, maps:get(ep, hd_kind(K, Parties))} || K <- Listeners],
        [chappe_mix_test_tone:clear(Ep) || {_, Ep} <- Eps],
        timer:sleep(2500),
        [
            {Sender, K,
                chappe_mix_test_tone:band_check(
                    chappe_mix_test_tone:samples(Ep), Cal, #{tolerance => 6.0}
                )}
         || {K, Ep} <- Eps
        ]
    end,
    Results =
        Round(l16, [g722, opus, pcmu]) ++ Round(g722, [l16]) ++
            Round(opus, [l16]) ++ Round(pcmu, [l16]),
    ct:log("band checks (sender, listener, result): ~p", [Results]),
    [cleanup(P) || P <- Parties],
    ok = chappe_mix:stop(Conf),
    Want = fun
        (pcmu, _) -> fail;
        (_, pcmu) -> fail;
        (_, _) -> ok
    end,
    [
        ?assertEqual(Want(S, L), verdict(R), {S, L, R})
     || {S, L, R} <- Results
    ],
    ok.

verdict(ok) -> ok;
verdict({error, _}) -> fail.

%% telephone-event/16000 out of a G.722 caller: party A speaks G.722 and
%% telephone-event/8000 (G.722's RTP clock) into rtpengine, which hands
%% the mixer L16/16000 and telephone-event/16000; party B is relayed as
%% L16 and telephone-event/16000. A's digit reaches B through the mixer
%% on B's telephone-event, at 16000: the event code, the M bit on the
%% first packet only, one timestamp, the end bit on the last ones.
hd_dtmf_through_rtpengine(Config) ->
    Media = ?config(media_ip, Config),
    RtpeIp = ?config(rtpe_ip, Config),
    {ok, Conf} = chappe_mix:start(#{ip => {0, 0, 0, 0}, rate => 16000}),
    Open = fun() ->
        {ok, S} = gen_udp:open(0, [binary, {ip, {0, 0, 0, 0}}, {active, true}]),
        {ok, P} = inet:port(S),
        {S, P}
    end,
    {SA, PA} = Open(),
    {SB, PB} = Open(),
    %% A: G.722 with telephone-event/8000, transcoded to the room's L16
    {SessA, ToA, ToMixerA, LA} = call_with(
        Media,
        sdp(Media, PA, g722_dtmf),
        #{codec => #{mask => [<<"all">>], transcode => l16_flags()}},
        fun(ToMixer) -> mixer_leg(Conf, Media, ToMixer) end
    ),
    %% B: L16 with telephone-event/16000, relayed
    {SessB, ToB, ToMixerB, LB} = call_with(
        Media,
        sdp(Media, PB, l16_dtmf),
        #{},
        fun(ToMixer) -> mixer_leg(Conf, Media, ToMixer) end
    ),
    ok = chappe_mix:set_remote(Conf, LA, {RtpeIp, ToMixerA}),
    ok = chappe_mix:set_remote(Conf, LB, {RtpeIp, ToMixerB}),
    G722 = binary:copy(<<0>>, 160),
    AudioA = fun(N) ->
        chappe_mix_rtp:build(#{
            pt => 9,
            seq => N,
            ts => N * 160,
            ssrc => 16#A,
            marker => false,
            payload => G722
        })
    end,
    AudioB = fun(N) ->
        chappe_mix_rtp:build(#{
            pt => 96,
            seq => N,
            ts => N * 320,
            ssrc => 16#B,
            marker => false,
            payload => <<0:5120>>
        })
    end,
    Ev = fun(N, M, E, Dur) ->
        chappe_mix_rtp:build(#{
            pt => 101,
            seq => N,
            ts => 100 * 160,
            ssrc => 16#A,
            marker => M,
            payload => <<5, E:1, 0:1, 10:6, Dur:16>>
        })
    end,
    Digit = [
        Ev(100, true, 0, 160),
        Ev(101, false, 0, 320),
        Ev(102, false, 0, 480),
        Ev(103, false, 1, 640),
        Ev(104, false, 1, 640),
        Ev(105, false, 1, 640)
    ],
    Plan =
        [AudioA(N) || N <- lists:seq(1, 99)] ++ Digit ++
            [AudioA(N) || N <- lists:seq(106, 140)],
    BPlan = [AudioB(N) || N <- lists:seq(1, 140)],
    T0 = erlang:monotonic_time(millisecond),
    lists:foldl(
        fun({XA, XB}, K) ->
            wait_ms(T0 + 20 * K),
            {IpA, PortA} = {RtpeIp, ToA},
            {IpB, PortB} = {RtpeIp, ToB},
            ok = gen_udp:send(SA, IpA, PortA, XA),
            ok = gen_udp:send(SB, IpB, PortB, XB),
            K + 1
        end,
        0,
        lists:zip(Plan, BPlan)
    ),
    timer:sleep(500),
    ct:log("mixer legs: ~p", [chappe_mix:legs(Conf)]),
    Got = [
        P
     || {ok, #{pt := 101} = P} <- [chappe_mix_rtp:parse(B) || B <- udp_all(SB)]
    ],
    ct:log("B got ~p event packets: ~p", [length(Got), Got]),
    Durations = [D || #{payload := <<_, _, D:16>>} <- Got],
    ct:log("durations at B: ~w (A sent 160 to 640 at 8000)", [Durations]),
    [chappe_rtpengine_session:stop(S) || S <- [SessA, SessB]],
    [gen_udp:close(S) || S <- [SA, SB]],
    ok = chappe_mix:stop(Conf),
    ?assertNotEqual([], Got),
    %% rtpengine takes the 8000 durations to 16000 on the way in, and the
    %% mixer forwards them as they are: the room's clock
    ?assertEqual([320, 640, 960, 1280, 1280, 1280], Durations),
    ?assertEqual([5], lists:usort([E || #{payload := <<E, _/binary>>} <- Got])),
    ?assertMatch([#{marker := true} | _], Got),
    ?assertEqual([false], lists:usort([M || #{marker := M} <- tl(Got)])),
    ?assertMatch([_], lists:usort([Ts || #{ts := Ts} <- Got])),
    ?assertMatch(
        #{payload := <<5, 1:1, _:7, _:16>>}, lists:last(Got)
    ).

l16_flags() ->
    [<<"L16/16000/1">>, <<"telephone-event/16000">>].

%% A mixer leg for the L16 (and telephone-event/16000) rtpengine offers
%% toward the mixer, on the payload types it chose; the SDP answering it.
mixer_leg(Conf, Media, ToMixer) ->
    Pt = rtpmap_pt(ToMixer, <<"L16/16000">>),
    Te = rtpmap_pt(ToMixer, <<"telephone-event/16000">>),
    Opts =
        case Te of
            undefined -> #{rtcp => pair, pt => Pt};
            _ -> #{rtcp => pair, pt => Pt, dtmf_pt => Te}
        end,
    {ok, Leg, #{port := MixPort}} = chappe_mix:add_leg(Conf, Opts),
    {sdp(Media, MixPort, {l16, Pt, Te}), Leg}.

rtpmap_pt(Sdp, Codec) ->
    case
        re:run(
            Sdp,
            <<"a=rtpmap:([0-9]+) ", Codec/binary, "\r\n">>,
            [{capture, all_but_first, binary}, caseless]
        )
    of
        {match, [Pt]} -> binary_to_integer(Pt);
        nomatch -> undefined
    end.

%% One 16 kHz party: an L16/16000 endpoint and the rtpengine call or
%% calls between it and its mixer leg.
hd_party(Config, Conf, Kind) ->
    Media = ?config(media_ip, Config),
    RtpeIp = ?config(rtpe_ip, Config),
    {Ep, EpPort} = chappe_mix_test_tone:endpoint(#{
        freq => 0,
        signal => {0},
        ip => {0, 0, 0, 0},
        law => l16,
        rate => 16000
    }),
    Mixer = fun(ToMixer) -> mixer_leg(Conf, Media, ToMixer) end,
    {Sessions, ToParty, Leg, Relay} =
        case Kind of
            l16 ->
                {S, To, ToMixer, L} = call_with(
                    Media, sdp(Media, EpPort, l16), #{}, Mixer
                ),
                ok = chappe_mix:set_remote(Conf, L, {RtpeIp, ToMixer}),
                {[S], To, L, undefined};
            _ ->
                Codec = codec_name(Kind),
                {Relay0, H1, H2} = relay_start(),
                %% call 1: the party's L16 <-> the codec toward the relay
                {S1, To, ToRelay1} = call(
                    Media,
                    sdp(Media, EpPort, l16),
                    #{codec => #{mask => [<<"all">>], transcode => [Codec]}},
                    sdp(Media, H1, Kind)
                ),
                %% call 2: the codec from the relay <-> L16 for the mixer
                {S2, ToRelay2, ToMixer2, L} = call_with(
                    Media,
                    sdp(Media, H2, Kind),
                    #{
                        codec => #{
                            mask => [<<"all">>], transcode => l16_flags()
                        }
                    },
                    Mixer
                ),
                ok = chappe_mix:set_remote(Conf, L, {RtpeIp, ToMixer2}),
                Relay0 ! {peers, {RtpeIp, ToRelay1}, {RtpeIp, ToRelay2}},
                {[S1, S2], To, L, Relay0}
        end,
    Ep ! {dst, {RtpeIp, ToParty}},
    #{kind => Kind, ep => Ep, leg => Leg, sessions => Sessions, relay => Relay}.

codec_name(g722) -> <<"G722">>;
codec_name(opus) -> <<"opus">>;
codec_name(pcmu) -> <<"PCMU">>.

hd_kind(K, Parties) ->
    hd([P || #{kind := K1} = P <- Parties, K1 =:= K]).

%% An offer from the caller side, then the answer AnswerFun writes from
%% what rtpengine offers the callee (returning {Sdp, Extra}). Returns the
%% session, the rtpengine ports the caller and the callee send to, and
%% Extra.
call_with(_Media, OfferSdp, Flags, AnswerFun) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    CallId = <<"chappe-mix-live-", Suffix/binary>>,
    {ok, S} = chappe_rtpengine:start_session(#{call_id => CallId, node => ?NODE}),
    {ok, Offer} = chappe_rtpengine_session:offer(
        S,
        maps:merge(
            #{
                from_tag => <<"caller-", Suffix/binary>>,
                sdp => OfferSdp,
                ice => remove
            },
            Flags
        )
    ),
    OfferOut = chappe_rtpengine_ng:sdp(Offer),
    {AnswerSdp, Extra} = AnswerFun(OfferOut),
    {ok, Answer} = chappe_rtpengine_session:answer(S, #{
        to_tag => <<"callee-", Suffix/binary>>, sdp => AnswerSdp, ice => remove
    }),
    AnswerOut = chappe_rtpengine_ng:sdp(Answer),
    ct:log("offer out:~n~s~nanswer out:~n~s", [OfferOut, AnswerOut]),
    {S, audio_port(AnswerOut), audio_port(OfferOut), Extra}.

wait_ms(T) ->
    case T - erlang:monotonic_time(millisecond) of
        W when W > 0 -> timer:sleep(W);
        _ -> ok
    end.

udp_all(Sock) ->
    receive
        {udp, Sock, _, _, B} -> [B | udp_all(Sock)]
    after 0 -> []
    end.

%% ---- parties ----

%% One party: a tone endpoint (law of its own codec), a mixer leg, and
%% the rtpengine call or calls between them.
party(Config, Conf, Kind, Freq) ->
    Media = ?config(media_ip, Config),
    RtpeIp = ?config(rtpe_ip, Config),
    Law =
        case Kind of
            pcma -> alaw;
            _ -> ulaw
        end,
    Ptime =
        case Kind of
            pcmu30 -> 30;
            _ -> 20
        end,
    {Ep, EpPort} = chappe_mix_test_tone:endpoint(#{
        freq => Freq, ip => {0, 0, 0, 0}, law => Law, ptime => Ptime
    }),
    %% the SDP below has no a=rtcp-mux, so RTCP goes on the next port up
    %% (RFC 5761 5.1.1); muxed, rtpengine logs our SRs as RTP with an
    %% unknown payload type 72
    {ok, Leg, #{port := MixPort}} = chappe_mix:add_leg(Conf, #{rtcp => pair}),
    {Sessions, ToParty, ToMixer, Relay} = anchor(
        Kind, Media, RtpeIp, EpPort, MixPort
    ),
    ok = chappe_mix:set_remote(Conf, Leg, {RtpeIp, ToMixer}),
    Ep ! {dst, {RtpeIp, ToParty}},
    #{
        kind => Kind,
        freq => Freq,
        ep => Ep,
        leg => Leg,
        sessions => Sessions,
        relay => Relay
    }.

anchor(pcmu30, Media, _RtpeIp, EpPort, MixPort) ->
    {S, ToParty, ToMixer} = call(
        Media, sdp(Media, EpPort, pcmu, 30), #{}, sdp(Media, MixPort, pcmu)
    ),
    {[S], ToParty, ToMixer, undefined};
anchor(pcmu, Media, _RtpeIp, EpPort, MixPort) ->
    {S, ToParty, ToMixer} = call(
        Media, sdp(Media, EpPort, pcmu), #{}, sdp(Media, MixPort, pcmu)
    ),
    {[S], ToParty, ToMixer, undefined};
anchor(pcma, Media, _RtpeIp, EpPort, MixPort) ->
    {S, ToParty, ToMixer} = call(
        Media,
        sdp(Media, EpPort, pcma),
        #{codec => #{mask => ['PCMA'], transcode => ['PCMU']}},
        sdp(Media, MixPort, pcmu)
    ),
    {[S], ToParty, ToMixer, undefined};
anchor(opus, Media, RtpeIp, EpPort, MixPort) ->
    {Relay, H1, H2} = relay_start(),
    %% call 1: party PCMU <-> opus towards the relay
    {S1, ToParty, ToRelay1} = call(
        Media,
        sdp(Media, EpPort, pcmu),
        #{codec => #{mask => ['PCMU'], transcode => [<<"opus">>]}},
        sdp(Media, H1, opus)
    ),
    %% call 2: opus from the relay <-> PCMU towards the mixer
    {S2, ToRelay2, ToMixer} = call(
        Media,
        sdp(Media, H2, opus),
        #{codec => #{mask => [<<"opus">>], transcode => ['PCMU']}},
        sdp(Media, MixPort, pcmu)
    ),
    Relay ! {peers, {RtpeIp, ToRelay1}, {RtpeIp, ToRelay2}},
    {[S1, S2], ToParty, ToMixer, Relay}.

%% offer from the caller side, answer from the callee side. Returns the
%% session, the rtpengine port the caller sends to, and the one the
%% callee sends to.
call(_Media, OfferSdp, Flags, AnswerSdp) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    CallId = <<"chappe-mix-live-", Suffix/binary>>,
    {ok, S} = chappe_rtpengine:start_session(#{call_id => CallId, node => ?NODE}),
    {ok, Offer} = chappe_rtpengine_session:offer(
        S,
        maps:merge(
            #{
                from_tag => <<"caller-", Suffix/binary>>,
                sdp => OfferSdp,
                ice => remove
            },
            Flags
        )
    ),
    OfferOut = chappe_rtpengine_ng:sdp(Offer),
    {ok, Answer} = chappe_rtpengine_session:answer(S, #{
        to_tag => <<"callee-", Suffix/binary>>, sdp => AnswerSdp, ice => remove
    }),
    AnswerOut = chappe_rtpengine_ng:sdp(Answer),
    ct:log("offer out:~n~s~nanswer out:~n~s", [OfferOut, AnswerOut]),
    {S, audio_port(AnswerOut), audio_port(OfferOut)}.

cleanup(#{ep := Ep, sessions := Ss, relay := Relay}) ->
    chappe_mix_test_tone:stop(Ep),
    [chappe_rtpengine_session:stop(S) || S <- Ss],
    case Relay of
        undefined -> ok;
        Pid -> exit(Pid, kill)
    end,
    ok.

%% ---- opus relay ----

%% Two sockets on this host: what rtpengine's first call sends to H1 goes
%% out of H2 to the second call, and the other way round.
relay_start() ->
    Parent = self(),
    Pid = spawn(fun() ->
        Opts = [binary, {ip, {0, 0, 0, 0}}, {active, true}],
        {ok, S1} = gen_udp:open(0, Opts),
        {ok, S2} = gen_udp:open(0, Opts),
        {ok, P1} = inet:port(S1),
        {ok, P2} = inet:port(S2),
        Parent ! {self(), ports, P1, P2},
        receive
            {peers, To1, To2} -> relay_loop(S1, S2, To1, To2)
        end
    end),
    receive
        {Pid, ports, P1, P2} -> {Pid, P1, P2}
    after 5000 -> ct:fail(relay_start)
    end.

relay_loop(S1, S2, {Ip1, Port1} = To1, {Ip2, Port2} = To2) ->
    receive
        {udp, S1, _, _, Pkt} ->
            _ = gen_udp:send(S2, Ip2, Port2, Pkt),
            relay_loop(S1, S2, To1, To2);
        {udp, S2, _, _, Pkt} ->
            _ = gen_udp:send(S1, Ip1, Port1, Pkt),
            relay_loop(S1, S2, To1, To2)
    end.

%% ---- SDP ----

sdp(Ip, Port, Codec) ->
    sdp(Ip, Port, Codec, 20).

sdp(Ip, Port, Codec, Ptime) ->
    {Pts, Maps} =
        case Codec of
            pcmu ->
                {<<"0">>, [<<"a=rtpmap:0 PCMU/8000\r\n">>]};
            pcma ->
                {<<"8">>, [<<"a=rtpmap:8 PCMA/8000\r\n">>]};
            opus ->
                {<<"96">>, [<<"a=rtpmap:96 opus/48000/2\r\n">>]};
            pcmu_dtmf ->
                {<<"0 101">>, [
                    <<"a=rtpmap:0 PCMU/8000\r\n">>,
                    <<"a=rtpmap:101 telephone-event/8000\r\n">>,
                    <<"a=fmtp:101 0-16\r\n">>
                ]};
            g722 ->
                {<<"9">>, [<<"a=rtpmap:9 G722/8000\r\n">>]};
            g722_dtmf ->
                {<<"9 101">>, [
                    <<"a=rtpmap:9 G722/8000\r\n">>,
                    <<"a=rtpmap:101 telephone-event/8000\r\n">>,
                    <<"a=fmtp:101 0-16\r\n">>
                ]};
            l16 ->
                {<<"96">>, [<<"a=rtpmap:96 L16/16000\r\n">>]};
            l16_dtmf ->
                {<<"96 101">>, [
                    <<"a=rtpmap:96 L16/16000\r\n">>,
                    <<"a=rtpmap:101 telephone-event/16000\r\n">>,
                    <<"a=fmtp:101 0-16\r\n">>
                ]};
            {l16, Pt, undefined} ->
                P = integer_to_binary(Pt),
                {P, [<<"a=rtpmap:", P/binary, " L16/16000\r\n">>]};
            {l16, Pt, Te} ->
                P = integer_to_binary(Pt),
                T = integer_to_binary(Te),
                {<<P/binary, " ", T/binary>>, [
                    <<"a=rtpmap:", P/binary, " L16/16000\r\n">>,
                    <<"a=rtpmap:", T/binary, " telephone-event/16000\r\n">>,
                    <<"a=fmtp:", T/binary, " 0-16\r\n">>
                ]}
        end,
    iolist_to_binary([
        <<"v=0\r\no=- 1 1 IN IP4 ">>,
        Ip,
        <<"\r\ns=mix\r\nc=IN IP4 ">>,
        Ip,
        <<"\r\nt=0 0\r\nm=audio ">>,
        integer_to_binary(Port),
        <<" RTP/AVP ">>,
        Pts,
        <<"\r\n">>,
        Maps,
        <<"a=ptime:">>,
        integer_to_binary(Ptime),
        <<"\r\na=sendrecv\r\n">>
    ]).

audio_port(Sdp) ->
    {Pos, Len} = binary:match(Sdp, <<"m=audio ">>),
    Rest = binary:part(Sdp, Pos + Len, byte_size(Sdp) - Pos - Len),
    binary_to_integer(hd(binary:split(Rest, <<" ">>))).
