%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc A fixed-depth jitter buffer for one incoming RTP stream, as plain data.
%%
%% Packets are kept by RTP timestamp, that is by the offset of their first
%% sample, so a sender may use any packet size: 10, 20, 30 ms, up to the
%% 200 ms RFC 3551 4.2 asks a receiver to take. The mixer pops one 20 ms
%% frame (160 samples) per tick, whatever the packets were. Timestamps and
%% sequence numbers are extended past their wrap, so reordering inside the
%% buffer is repaired and a wrap is not a gap. The rules, in the order
%% pop/1 applies them:
%%
%%   - the samples of the next frame are there: play them and move on;
%%   - part of them is missing and later samples are there: the missing
%%     part is lost, play the law's silence byte for it and move on;
%%   - the buffer runs out inside the frame, or is empty: an underrun.
%%     Play silence and wait, so a packet that is only late (jitter) is
%%     still played instead of dropped, and a frame is never played half
%%     silent because the rest of it has not arrived yet.
%%
%% A gap in timestamps is told from loss by the sequence numbers: when
%% the packet after a gap has the next sequence number, the gap is a pause
%% of a sender that suppresses silence (RFC 3551 4.1), and the playout
%% point jumps over it instead of playing it out; when packets are
%% missing, only their time is played as silence.
%%
%% Playout starts once `prefill' frames' worth of samples are buffered,
%% and again after an underrun. The prefill starts at one frame and grows
%% by one at each underrun, up to depth - 1, and, when the buffer is made
%% with new/3 asking for it, shrinks by one, skipping a frame, after 10 s
%% without one. Without that, a sender whose
%% 20 ms clock is in phase with the mixer's races the tick on every packet
%% and half its frames play as silence: holding the playout point alone
%% gives no slack, because the late frame is consumed by the very next
%% tick.
%%
%% push/5 drops a packet that ends before the playout point (late) and,
%% past the depth (in frames' worth of samples, plus what a packet longer
%% than a frame holds over one), drops the oldest packets so a sender
%% running faster than the tick cannot grow the latency without bound. A new
%% SSRC, or a jump too large to be loss, restarts the buffer on the new
%% stream.
-module(chappe_mix_jbuf).

-export([new/1, new/2, new/3, push/4, push/5, pop/1, stats/1]).

-export_type([jbuf/0]).

-define(FRAME, 160).
-define(RESYNC, 3000).
%% frames played without an underrun before a grown prefill shrinks: 10 s
-define(SHRINK, 500).

-record(jbuf, {
    depth :: pos_integer(),
    %% the law's silence code word, played for lost samples
    fill :: byte(),
    ssrc :: non_neg_integer() | undefined,
    %% extended timestamp of the next sample to play; undefined before the
    %% first packet
    next :: integer() | undefined,
    %% highest extended timestamp and sequence number seen, the anchors
    %% for extending the next ones
    last_ts :: integer() | undefined,
    last_seq :: integer() | undefined,
    %% by extended timestamp: {extended seq, payload, samples}
    chunks = #{} :: #{integer() => {integer(), binary(), non_neg_integer()}},
    %% the packet last played from, {extended seq, samples}
    prev :: {integer(), non_neg_integer()} | undefined,
    %% frames to hold before playout starts or resumes after an underrun
    prefill = 1 :: pos_integer(),
    playing = false :: boolean(),
    %% a frame of this stream has played
    started = false :: boolean(),
    received = 0 :: non_neg_integer(),
    lost = 0 :: non_neg_integer(),
    late = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    underruns = 0 :: non_neg_integer(),
    %% frames played since the last underrun, and prefill shrinks
    steady = 0 :: non_neg_integer(),
    shrunk = 0 :: non_neg_integer(),
    %% whether a grown prefill shrinks (opt-in until measured)
    shrink = false :: boolean()
}).

-opaque jbuf() :: #jbuf{}.

%% A buffer of Depth frames for mu-law (silence 0xFF).
-spec new(pos_integer()) -> jbuf().
new(Depth) ->
    new(Depth, 16#FF).

%% A buffer of Depth frames that plays Fill for lost samples.
-spec new(pos_integer(), byte()) -> jbuf().
new(Depth, Fill) ->
    new(Depth, Fill, false).

%% Shrink: whether a prefill that grew is taken back after 10 s without
%% an underrun.
-spec new(pos_integer(), byte(), boolean()) -> jbuf().
new(Depth, Fill, Shrink) when is_integer(Depth), Depth > 0 ->
    #jbuf{depth = Depth, fill = Fill, shrink = Shrink}.

%% A packet of one 20 ms frame, placed by its sequence number alone (its
%% timestamp taken as Seq x 160).
-spec push(non_neg_integer(), 0..65535, binary(), jbuf()) -> jbuf().
push(Ssrc, Seq, Payload, #jbuf{ssrc = Ssrc, next = Next} = J) when
    Next =/= undefined
->
    Ext = chappe_mix_rtp:extend_seq(Seq, J#jbuf.last_seq),
    place(Ssrc, Ext, Ext * ?FRAME, Payload, ?FRAME, J);
push(Ssrc, Seq, Payload, J) ->
    restart(Ssrc, Seq, Seq * ?FRAME, Payload, ?FRAME, J).

%% A packet of G.711 code words, one per sample, placed by timestamp.
-spec push(non_neg_integer(), 0..65535, 0..16#FFFFFFFF, binary(), jbuf()) ->
    jbuf().
push(_Ssrc, _Seq, _Ts, <<>>, J) ->
    %% 0 ms: taken, nothing to play
    J#jbuf{received = J#jbuf.received + 1};
push(Ssrc, Seq, Ts, Payload, #jbuf{ssrc = Ssrc, next = Next} = J) when
    Next =/= undefined
->
    ExtSeq = chappe_mix_rtp:extend_seq(Seq, J#jbuf.last_seq),
    ExtTs = extend_ts(Ts, J#jbuf.last_ts),
    place(Ssrc, ExtSeq, ExtTs, Payload, byte_size(Payload), J);
push(Ssrc, Seq, Ts, Payload, J) ->
    restart(Ssrc, Seq, Ts, Payload, byte_size(Payload), J).

-spec pop(jbuf()) -> {binary() | silence, jbuf()}.
pop(#jbuf{next = undefined} = J) ->
    {silence, J};
pop(#jbuf{playing = false, prefill = Prefill} = J) ->
    case buffered(J) < Prefill * ?FRAME of
        true -> {silence, underrun_tick(J)};
        false -> steady(play(J))
    end;
pop(J) ->
    steady(play(J)).

-spec stats(jbuf()) -> #{atom() => non_neg_integer()}.
stats(#jbuf{} = J) ->
    #{
        received => J#jbuf.received,
        lost => J#jbuf.lost,
        late => J#jbuf.late,
        dropped => J#jbuf.dropped,
        underruns => J#jbuf.underruns,
        prefill_shrunk => J#jbuf.shrunk,
        buffered => map_size(J#jbuf.chunks),
        prefill => J#jbuf.prefill
    }.

%% ---- playing ----

%% A tick that played (not an underrun) counts toward shrinking a prefill
%% that grew: after 10 s without an underrun it is taken back by one, and
%% the frame of slack it held is skipped, so a burst long gone stops
%% costing a frame of latency for the rest of the call.
steady({_, #jbuf{playing = false}} = Underrun) ->
    Underrun;
steady({Frame, #jbuf{steady = N, prefill = P, shrink = true} = J}) when
    N + 1 >= ?SHRINK, P > 1
->
    {Frame,
        skip(J#jbuf{steady = 0, prefill = P - 1, shrunk = J#jbuf.shrunk + 1})};
steady({Frame, #jbuf{steady = N} = J}) ->
    {Frame, J#jbuf{steady = N + 1}}.

%% Drop the next frame's worth of samples, if a whole one is buffered.
skip(#jbuf{chunks = Chunks} = J) ->
    case buffered(J) >= ?FRAME andalso next_frame(J) of
        {done, _, Pos, Prev1, _, _} -> played(Pos, Prev1, Chunks, J);
        _ -> J
    end.

%% A 20 ms packet right at the playout point is the frame as it came.
play(#jbuf{next = Next, chunks = Chunks} = J) ->
    case maps:find(Next, Chunks) of
        {ok, {Seq, Payload, ?FRAME}} ->
            {Payload,
                played(
                    Next + ?FRAME, {Seq, ?FRAME}, maps:remove(Next, Chunks), J
                )};
        _ ->
            assemble(J)
    end.

%% The next frame's samples from the playout point (see frame/8).
next_frame(#jbuf{next = Next, chunks = Chunks, prev = Prev, fill = Fill}) ->
    Sorted = lists:keysort(1, maps:to_list(Chunks)),
    frame(Sorted, Next, ?FRAME, Prev, Fill, [], false, false).

assemble(#jbuf{chunks = Chunks} = J) ->
    case next_frame(J) of
        {done, _Acc, Pos, Prev1, false, true} ->
            %% nothing of the stream in this frame: lost
            {silence, (played(Pos, Prev1, Chunks, J))#jbuf{
                lost = J#jbuf.lost + 1
            }};
        {done, Acc, Pos, Prev1, Taken, Filled} when Taken ->
            Lost =
                case Filled of
                    true -> J#jbuf.lost + 1;
                    false -> J#jbuf.lost
                end,
            Frame = iolist_to_binary(lists:reverse(Acc)),
            {Frame, (played(Pos, Prev1, Chunks, J))#jbuf{lost = Lost}};
        short ->
            {silence, underrun(J)}
    end.

%% Fill Need samples from Pos on. Returns {done, Acc, NextPos, Prev,
%% Taken, Filled} or short when the stream runs out first.
frame(_Chunks, Pos, 0, Prev, _Fill, Acc, Taken, Filled) ->
    {done, Acc, Pos, Prev, Taken, Filled};
frame([], _Pos, _Need, _Prev, _Fill, _Acc, _Taken, _Filled) ->
    short;
frame(
    [{Ts, {_, _, Dur}} | Rest], Pos, Need, Prev, Fill, Acc, Taken, Filled
) when
    Ts + Dur =< Pos
->
    frame(Rest, Pos, Need, Prev, Fill, Acc, Taken, Filled);
frame(
    [{Ts, {Seq, Bin, Dur}} | _] = Chunks, Pos, Need, _Prev, Fill, Acc, _, F
) when
    Ts =< Pos
->
    N = min(Need, Ts + Dur - Pos),
    Part = samples(Bin, Pos - Ts, N, Fill),
    frame(Chunks, Pos + N, Need - N, {Seq, Dur}, Fill, [Part | Acc], true, F);
frame([{Ts, {Seq, _, _}} | _] = Chunks, Pos0, Need, Prev, Fill, Acc, Taken, F) ->
    %% a gap: a pause in the sender's talk is skipped, lost packets are
    %% filled for their own time only
    Pos = max(Pos0, resume_at(Ts, Seq, Prev)),
    N = min(Need, Ts - Pos),
    Gap = binary:copy(<<Fill>>, N),
    frame(
        Chunks,
        Pos + N,
        Need - N,
        Prev,
        Fill,
        [Gap | Acc],
        Taken,
        F orelse N > 0
    ).

%% Where the stream picks up again before the packet at Ts: its own
%% start, less the time of the packets missing between the last one
%% played and it.
resume_at(Ts, _Seq, undefined) ->
    Ts;
resume_at(Ts, Seq, {PSeq, PDur}) ->
    Ts - max(0, Seq - PSeq - 1) * PDur.

%% N samples from offset Off of a payload; a payload shorter than its
%% duration (push/4) is silence past its end.
samples(Bin, Off, N, _Fill) when Off + N =< byte_size(Bin) ->
    binary:part(Bin, Off, N);
samples(Bin, Off, N, Fill) when Off < byte_size(Bin) ->
    Have = byte_size(Bin) - Off,
    <<
        (binary:part(Bin, Off, Have))/binary,
        (binary:copy(<<Fill>>, N - Have))/binary
    >>;
samples(_Bin, _Off, N, Fill) ->
    binary:copy(<<Fill>>, N).

played(Pos, Prev, Chunks, J) ->
    J#jbuf{
        next = Pos,
        prev = Prev,
        chunks = maps:filter(
            fun(Ts, {_, _, Dur}) -> Ts + Dur > Pos end, Chunks
        ),
        playing = true,
        started = true
    }.

underrun(#jbuf{} = J) ->
    Prefill = min(J#jbuf.prefill + 1, max(1, J#jbuf.depth - 1)),
    underrun_tick(J#jbuf{playing = false, prefill = Prefill, steady = 0}).

%% An empty tick counts once the stream has played.
underrun_tick(#jbuf{started = true} = J) ->
    J#jbuf{underruns = J#jbuf.underruns + 1};
underrun_tick(J) ->
    J.

%% Samples buffered from the playout point on.
buffered(#jbuf{next = Next, chunks = Chunks}) ->
    maps:fold(
        fun(Ts, {_, _, Dur}, Acc) -> Acc + max(0, Ts + Dur - max(Ts, Next)) end,
        0,
        Chunks
    ).

%% ---- placing ----

place(Ssrc, Seq, Ts, Payload, Dur, #jbuf{next = Next} = J) when
    abs(Ts - Next) > ?RESYNC * ?FRAME
->
    restart(Ssrc, Seq, Ts, Payload, Dur, J);
place(_Ssrc, _Seq, Ts, _Payload, Dur, #jbuf{next = Next} = J) when
    Ts + Dur =< Next
->
    J#jbuf{late = J#jbuf.late + 1};
place(_Ssrc, Seq, Ts, Payload, Dur, J) ->
    trim(Dur, J#jbuf{
        chunks = maps:put(Ts, {Seq, Payload, Dur}, J#jbuf.chunks),
        last_ts = max(Ts, J#jbuf.last_ts),
        last_seq = max(Seq, J#jbuf.last_seq),
        received = J#jbuf.received + 1
    }).

restart(Ssrc, Seq, Ts, Payload, Dur, J) ->
    J#jbuf{
        ssrc = Ssrc,
        next = Ts,
        last_ts = Ts,
        last_seq = Seq,
        chunks = #{Ts => {Seq, Payload, Dur}},
        prev = undefined,
        playing = false,
        received = J#jbuf.received + 1
    }.

%% Past the depth, the oldest packets go. A packet longer than a frame
%% (Dur, the one just placed) raises the bound by what it holds over a
%% frame, so a 200 ms sender keeps the packet still playing when the next
%% one comes; for 20 ms packets the bound is the depth.
trim(Dur, #jbuf{depth = Depth, chunks = Chunks} = J) ->
    Limit = (Depth - 1) * ?FRAME + max(?FRAME, Dur),
    case map_size(Chunks) > 1 andalso buffered(J) > Limit of
        true ->
            Oldest = lists:min(maps:keys(Chunks)),
            Rest = maps:remove(Oldest, Chunks),
            trim(Dur, J#jbuf{
                chunks = Rest,
                next = lists:min(maps:keys(Rest)),
                prev = undefined,
                dropped = J#jbuf.dropped + 1
            });
        false ->
            J
    end.

%% Extend a 32-bit timestamp to the cycle closest to the last extended
%% one, as chappe_mix_rtp:extend_seq/2 does for sequence numbers.
extend_ts(Ts, Last) ->
    nearest_ts((Last band (bnot 16#FFFFFFFF)) bor Ts, Last).

nearest_ts(Cand, Last) when Cand - Last > 16#80000000 -> Cand - 16#100000000;
nearest_ts(Cand, Last) when Last - Cand > 16#80000000 -> Cand + 16#100000000;
nearest_ts(Cand, _Last) -> Cand.
