%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A fixed-depth jitter buffer for one incoming RTP stream, as plain data.
%%
%% The mixer pops one frame per tick. Frames are keyed by extended
%% sequence number, so reordering inside the buffer is repaired and the
%% 16-bit wrap is not a gap. The rules, in the order pop/1 applies them:
%%
%%   - the expected frame is there: play it and move on;
%%   - a later frame is there but not the expected one: the expected one is
%%     lost, play silence for it and move on;
%%   - the buffer is empty: an underrun. Play silence and wait, so a packet
%%     that is only late (jitter) is still played instead of dropped.
%%
%% Playout starts once `prefill' frames are buffered, and again after an
%% underrun. The prefill starts at one frame and grows by one at each
%% underrun, up to depth - 1. Without that, a sender whose 20 ms clock is
%% in phase with the mixer's races the tick on every packet and half its
%% frames play as silence: holding the playout point alone gives no slack,
%% because the late frame is consumed by the very next tick.
%%
%% push/4 drops a frame older than the playout point (late) and, past the
%% depth, drops the oldest frames so a sender running faster than the tick
%% cannot grow the latency without bound. A new SSRC, or a sequence jump
%% too large to be loss, restarts the buffer on the new stream.
-module(chappe_mix_jbuf).

-export([new/1, push/4, pop/1, stats/1]).

-export_type([jbuf/0]).

-define(RESYNC, 3000).

-record(jbuf, {
    depth :: pos_integer(),
    ssrc :: non_neg_integer() | undefined,
    %% extended seq of the next frame to play; undefined before the first
    next :: integer() | undefined,
    %% highest extended seq seen, the anchor for extending the next one
    last :: integer() | undefined,
    frames = #{} :: #{integer() => binary()},
    %% frames to hold before playout starts or resumes after an underrun
    prefill = 1 :: pos_integer(),
    playing = false :: boolean(),
    received = 0 :: non_neg_integer(),
    lost = 0 :: non_neg_integer(),
    late = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer()
}).

-opaque jbuf() :: #jbuf{}.

-spec new(pos_integer()) -> jbuf().
new(Depth) when is_integer(Depth), Depth > 0 ->
    #jbuf{depth = Depth}.

-spec push(non_neg_integer(), 0..65535, binary(), jbuf()) -> jbuf().
push(Ssrc, Seq, Payload, #jbuf{ssrc = Ssrc, next = Next, last = Last} = J) when
    Next =/= undefined
->
    Ext = chappe_mix_rtp:extend_seq(Seq, Last),
    place(Ext, Ssrc, Seq, Payload, J);
push(Ssrc, Seq, Payload, J) ->
    restart(Ssrc, Seq, Payload, J).

-spec pop(jbuf()) -> {binary() | silence, jbuf()}.
pop(#jbuf{next = undefined} = J) ->
    {silence, J};
pop(#jbuf{playing = false, prefill = Prefill, frames = Frames} = J) when
    map_size(Frames) < Prefill
->
    {silence, J};
pop(#jbuf{next = Next, frames = Frames} = J) ->
    case maps:take(Next, Frames) of
        {Payload, Rest} ->
            {Payload, J#jbuf{next = Next + 1, frames = Rest, playing = true}};
        error when map_size(Frames) =:= 0 ->
            Prefill = min(J#jbuf.prefill + 1, max(1, J#jbuf.depth - 1)),
            {silence, J#jbuf{playing = false, prefill = Prefill}};
        error ->
            {silence, J#jbuf{
                next = Next + 1, lost = J#jbuf.lost + 1, playing = true
            }}
    end.

-spec stats(jbuf()) -> #{atom() => non_neg_integer()}.
stats(#jbuf{} = J) ->
    #{
        received => J#jbuf.received,
        lost => J#jbuf.lost,
        late => J#jbuf.late,
        dropped => J#jbuf.dropped,
        buffered => map_size(J#jbuf.frames),
        prefill => J#jbuf.prefill
    }.

%% ---- internal ----

place(Ext, Ssrc, Seq, Payload, #jbuf{next = Next} = J) when
    abs(Ext - Next) > ?RESYNC
->
    restart(Ssrc, Seq, Payload, J);
place(Ext, _Ssrc, _Seq, _Payload, #jbuf{next = Next} = J) when Ext < Next ->
    J#jbuf{late = J#jbuf.late + 1};
place(Ext, _Ssrc, _Seq, Payload, #jbuf{last = Last} = J) ->
    trim(J#jbuf{
        frames = maps:put(Ext, Payload, J#jbuf.frames),
        last = max(Ext, Last),
        received = J#jbuf.received + 1
    }).

restart(Ssrc, Seq, Payload, J) ->
    J#jbuf{
        ssrc = Ssrc,
        next = Seq,
        last = Seq,
        frames = #{Seq => Payload},
        playing = false,
        received = J#jbuf.received + 1
    }.

trim(#jbuf{depth = Depth, frames = Frames} = J) when
    map_size(Frames) > Depth
->
    Oldest = lists:min(maps:keys(Frames)),
    Rest = maps:remove(Oldest, Frames),
    trim(J#jbuf{
        frames = Rest,
        next = lists:min(maps:keys(Rest)),
        dropped = J#jbuf.dropped + 1
    });
trim(J) ->
    J.
