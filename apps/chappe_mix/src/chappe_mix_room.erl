%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% What a tick and an RFC 4733 event do to the legs of one conference, as
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

-export([mix/2, forward_event/3]).

-export_type([legs/0]).

-define(FRAME, 160).
%% at most this many CSRCs fit in the RTP header
-define(MAX_CSRC, 15).

-type legs() :: #{pos_integer() => #leg{}}.

%% An RFC 4733 event from one leg goes to every other leg that
%% negotiated telephone-event and lists its codes, never into the mix. On
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
%% leg what it hears. Missed: ticks skipped, for the timestamp.
-spec mix(legs(), non_neg_integer()) -> legs().
mix(Legs, _Missed) when map_size(Legs) =:= 0 ->
    Legs;
mix(Legs0, Missed) ->
    Popped = [chappe_mix_leg:pop(L) || L <- maps:values(Legs0)],
    %% the frames in the sum, by leg: what the room takes from a leg that
    %% had something to play
    Frames = maps:from_list([
        {L#leg.id, {L#leg.law, Codes}}
     || {L, Codes} <- Popped, Codes =/= none, chappe_mix_leg:speaks(L)
    ]),
    Sum = maps:fold(
        fun(_, {Law, Codes}, Acc) -> chappe_mix_dsp:add(Acc, Law, Codes) end,
        chappe_mix_dsp:new(),
        Frames
    ),
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
    Step = ?FRAME * (1 + Missed),
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
    Legs.

%% What leg L hears this tick, sent: the sum less its own frame and those
%% of the legs it does not hear (the frames in the sum only), naming the
%% others in its CSRC list. A leg the room sends nothing is not encoded.
heard(#leg{law = Law, id = Id, nohear = No} = L, Mixed, Frames, Talkers) ->
    case chappe_mix_leg:hears(L) of
        false ->
            L;
        true ->
            Out = [
                maps:get(K, Frames)
             || K <- [Id | No], is_map_key(K, Frames)
            ],
            Ssrc = chappe_mix_session:ssrc(L#leg.sess),
            chappe_mix_leg:send(
                L,
                chappe_mix_dsp:encode(Mixed, Law, Out),
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
