%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc What a tick and an RFC 4733 event do to the legs of one conference, as
%% plain functions over its legs: chappe_mix_conf owns the process, the
%% clock and the RTCP, and hands the legs here.
%%
%% A tick pops one frame per leg, sums the frames of the legs the room
%% takes from, and sends each leg the room sends to the sum less its own
%% frame and those of the legs it does not hear, naming the others in its
%% CSRC list (RFC 3550 7.1, 7.4). An event goes, never mixed, to the legs
%% that hear its source and negotiated telephone-event.
-module(chappe_mix_room).

-include("chappe_mix_leg.hrl").

-export([mix/4, forward_event/3, talk_params/2]).

-export_type([legs/0, talk/0]).

%% at most this many CSRCs fit in the RTP header
-define(MAX_CSRC, 15).

-type legs() :: #{pos_integer() => #leg{}}.
%% Talker detection, when someone listens: the energy over a frame that
%% counts as talk, and how many frames in a row start and stop it.
-type talk() ::
    undefined
    | #{threshold := number(), start := pos_integer(), stop := pos_integer()}.

%% An RFC 4733 event from one leg goes to every other leg that
%% negotiated telephone-event and lists its codes, never into the mix.
%% Its payload goes as it came, duration included: a room has one clock
%% (every leg's RTP timestamp runs at the room's rate, telephone-event
%% at 8000 in an 8 kHz room, at 16000 in a 16 kHz one), so a duration in
%% the sender's timestamp units is one in the listener's too. On
%% each, it keeps one timestamp for the whole event: the event start is
%% mapped onto that leg's output clock when it comes (M set, or the first
%% packet seen), and every later packet of the event, segments and end
%% retransmissions included, keeps that offset. A muted leg's events are
%% not heard either.
-spec forward_event(chappe_mix_rtp:packet(), pos_integer(), legs()) -> legs().
forward_event(_P, FromId, Legs) when not is_map_key(FromId, Legs) ->
    Legs;
forward_event(P, FromId, Legs) ->
    case maps:get(FromId, Legs) of
        #leg{direction = D} when D =:= sendonly; D =:= inactive ->
            Legs;
        From ->
            #{ts := Ts, marker := M, payload := Payload, ssrc := Src} = P,
            Codes = chappe_mix_leg:event_codes(Payload),
            Offs0 =
                case M of
                    true -> #{};
                    false -> From#leg.dtmf_off
                end,
            {Offs, Legs1} = maps:fold(
                fun(Id, T, {OAcc, SAcc} = Acc) ->
                    case
                        chappe_mix_leg:hears_from(FromId, T) andalso
                            chappe_mix_leg:takes_events(Codes, T)
                    of
                        true ->
                            Off = event_offset(Id, Ts, T, OAcc),
                            T1 = chappe_mix_leg:send_event(
                                T, (Ts + Off) band 16#FFFFFFFF, M, Payload, [
                                    Src
                                ]
                            ),
                            {OAcc#{Id => Off}, SAcc#{Id => T1}};
                        false ->
                            Acc
                    end
                end,
                {Offs0, Legs},
                Legs
            ),
            Legs1#{FromId => From#leg{dtmf_off = Offs}}
    end.

%% The offset from the event's timestamps to leg Id's clock: kept from
%% the event start, or taken now (the timestamp of its next packet).
event_offset(Id, Ts, #leg{sess = Sess}, Offs) ->
    case maps:find(Id, Offs) of
        {ok, Off} ->
            Off;
        error ->
            #{ts := Now} = chappe_mix_session:header(Sess),
            Now - Ts
    end.

%% ---- mixing ----

%% One tick: pop a frame per leg, sum what the room takes, and send each
%% leg what it hears. Missed: ticks skipped, for the timestamp, which
%% steps by Frame, the samples of a frame at the room's rate, per tick. With
%% Talk, the legs that start or stop talking this tick, as {Leg, true |
%% false}. Also returned, for taps: the frames in the sum by leg, and the
%% sum.
-spec mix(legs(), non_neg_integer(), talk(), pos_integer()) ->
    {
        legs(),
        [{pos_integer(), boolean()}],
        #{pos_integer() => chappe_mix_dsp:frame()},
        chappe_mix_dsp:mixed()
    }.
mix(Legs, _Missed, _Talk, _Frame) when map_size(Legs) =:= 0 ->
    {Legs, [], #{}, chappe_mix_dsp:silence()};
mix(Legs0, Missed, Talk, Frame) ->
    Popped = [chappe_mix_leg:pop(L) || L <- maps:values(Legs0)],
    %% the frames in the sum, by leg: what the room takes from a leg that
    %% had something to play
    Frames = maps:from_list([
        {L#leg.id, {L#leg.codec, Codes}}
     || {L, Codes} <- Popped, Codes =/= none, chappe_mix_leg:speaks(L)
    ]),
    {Sum, Levels} = sum(Frames, Talk, Frame),
    Mixed = chappe_mix_dsp:mixed(Sum),
    %% who is in the sum, by leg, for the CSRC lists: a leg's source, the
    %% sources an upstream mixer named in what it sent (7.4), or the
    %% mixer itself for media the room injects (7.1)
    Talkers = [
        {Id, contributors(L, Ssrc)}
     || {#leg{id = Id} = L, _} <- Popped,
        is_map_key(Id, Frames),
        Ssrc <- [src_ssrc(L)],
        Ssrc =/= undefined
    ],
    %% the timestamp moves with the sampling clock, skipped ticks included
    Step = Frame * (1 + Missed),
    Legs = maps:from_list([
        {
            L#leg.id,
            chappe_mix_leg:advance(
                heard(L, Mixed, Frames, Talkers),
                Step
            )
        }
     || {L, _Codes} <- Popped
    ]),
    {Legs1, Events} = talk(Legs, Levels, Talk),
    {Legs1, Events, Frames, Mixed}.

%% The sum of the frames, and their energies when Talk asks for them.
sum(Frames, undefined, Frame) ->
    {
        maps:fold(
            fun(_, {Codec, Codes}, Acc) ->
                chappe_mix_dsp:add(Acc, Codec, Codes)
            end,
            chappe_mix_dsp:new(Frame),
            Frames
        ),
        #{}
    };
sum(Frames, _Talk, Frame) ->
    maps:fold(
        fun(Id, {Codec, Codes}, {Acc, Ls}) ->
            {Acc1, E} = chappe_mix_dsp:add_level(Acc, Codec, Codes),
            {Acc1, Ls#{Id => E}}
        end,
        {chappe_mix_dsp:new(Frame), #{}},
        Frames
    ).

%% Talker detection from the conference options: a frame of Frame
%% samples counts as talk over Db dBFS RMS (talk_threshold, default -40),
%% talk starts after talk_start_ms of it and stops after talk_stop_ms
%% without (defaults 60 and 300), each rounded to whole 20 ms frames.
-spec talk_params(map(), pos_integer()) -> talk().
talk_params(Opts, Frame) ->
    Db = maps:get(talk_threshold, Opts, -40),
    Rms = 32768 * math:pow(10, Db / 20),
    #{
        threshold => Frame * Rms * Rms,
        start => max(1, maps:get(talk_start_ms, Opts, 60) div 20),
        stop => max(1, maps:get(talk_stop_ms, Opts, 300) div 20)
    }.

%% Hysteresis on each leg's energy: it starts talking after Start frames
%% in a row over the threshold, and stops after Stop frames under it (no
%% frame in the sum counts as under).
talk(Legs, _Levels, undefined) ->
    {Legs, []};
talk(Legs, Levels, #{threshold := Thr, start := Start, stop := Stop}) ->
    maps:fold(
        fun(Id, #leg{talking = T, talk_run = Run} = L, {Acc, Ev}) ->
            Above = maps:get(Id, Levels, 0) > Thr,
            Need =
                case T of
                    true -> Stop;
                    false -> Start
                end,
            case {Above =:= T, Run + 1 >= Need} of
                {true, _} ->
                    {Acc#{Id => L#leg{talk_run = 0}}, Ev};
                {false, true} ->
                    L1 = L#leg{talking = Above, talk_run = 0},
                    {Acc#{Id => L1}, [{Id, Above} | Ev]};
                {false, false} ->
                    {Acc#{Id => L#leg{talk_run = Run + 1}}, Ev}
            end
        end,
        {Legs, []},
        Legs
    ).

%% What leg L hears this tick, sent: the sum less its own frame and those
%% of the legs it does not hear (the frames in the sum only), naming the
%% others in its CSRC list. A leg the room sends nothing is not encoded.
heard(#leg{codec = Codec, id = Id, nohear = No} = L, Mixed, Frames, Talkers) ->
    case chappe_mix_leg:hears(L) of
        false ->
            L;
        true ->
            Out = [
                maps:get(K, Frames)
             || K <- [Id | No], is_map_key(K, Frames)
            ],
            Ssrc = chappe_mix_session:ssrc(L#leg.sess),
            {Payload, Gain} = chappe_mix_dsp:encode(
                Mixed, Codec, Out, L#leg.gain
            ),
            chappe_mix_leg:send(
                L#leg{gain = Gain},
                Payload,
                csrcs([Id | No], Ssrc, Talkers, ?MAX_CSRC)
            )
    end.

%% What a talking leg puts in a CSRC list: the mixer itself for media the
%% room injects, the CSRCs of an already mixed input, else its source's
%% SSRC (RFC 3550 7.1, 7.4).
contributors(#leg{injected = true}, _Ssrc) -> mixer;
contributors(#leg{in_csrcs = []}, Ssrc) -> [Ssrc];
contributors(#leg{in_csrcs = Csrcs}, _Ssrc) -> Csrcs.

%% The sources in a leg's mix: every talker's but those of the legs in
%% Skip (itself and those it does not hear), at most N; the mixer, as a
%% source, is the leg's own SSRC Mine.
csrcs(_Skip, _Mine, _Talkers, 0) ->
    [];
csrcs(_Skip, _Mine, [], _N) ->
    [];
csrcs(Skip, Mine, [{Id, Cs} | T], N) ->
    case lists:member(Id, Skip) of
        true -> csrcs(Skip, Mine, T, N);
        false -> take_csrcs(sources(Cs, Mine), Skip, Mine, T, N)
    end.

sources(mixer, Mine) -> [Mine];
sources(Cs, _Mine) -> Cs.

take_csrcs([], Skip, Mine, T, N) ->
    csrcs(Skip, Mine, T, N);
take_csrcs(_Cs, _Skip, _Mine, _T, 0) ->
    [];
take_csrcs([C | Cs], Skip, Mine, T, N) ->
    [C | take_csrcs(Cs, Skip, Mine, T, N - 1)].

src_ssrc(#leg{sess = Sess}) -> chappe_mix_session:src_ssrc(Sess).
