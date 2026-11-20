%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc RTCP (RFC 3550 section 6) for a receiver: compound packets parsed
%% and built, the reception statistics of one source (appendix A.1, A.3,
%% A.8), and the report interval (6.2, A.7). Pure: chappe_audio_rtp keeps
%% the state and the sockets.
%%
%% parse/1 is total and checks a whole compound packet as A.2 asks:
%% version 2 throughout, SR or RR first with no padding, and lengths that
%% add up to the datagram. A packet type it does not know is kept as
%% #{type => other, pt => PT} and never becomes an atom, nor does an SDES
%% item other than CNAME and NAME.
%%
%% A source's statistics follow A.1 without the probation (the receiver
%% latches to its sender first): a jump past MAX_DROPOUT counts only once
%% a second packet follows it in sequence, and then the statistics start
%% again. The jitter is A.8's integer estimator, kept scaled by 16.
%%
%% The interval is A.7's, for a session of 80 kbit/s (PCMU at 20 ms with
%% its RTP, UDP and IPv4 headers), so RTCP gets 5% of it, 500 octets/s.
%% Timer reconsideration (6.3.6) is not done, as the members are fixed,
%% so the result is not divided by e - 3/2: the interval is the 5 s
%% minimum (2.5 s before the first report) times 0.5 to 1.5.
-module(chappe_audio_rtcp).

-export([is_rtcp/1, parse/1, build/1]).
-export([interval/5, interval/6, avg_size/2, ntp/1, cname/0]).
-export([src_new/1, src_rtp/4, src_sr/3, src_cname/2, src_heard/1]).
-export([src_info/1, block/2]).

-export_type([ssrc/0, part/0, block/0, src/0]).

-define(SR, 200).
-define(RR, 201).
-define(SDES, 202).
-define(BYE, 203).
-define(SEQ_MOD, 65536).
-define(MAX_DROPOUT, 3000).
-define(MAX_MISORDER, 100).
%% octets/s: 5% of 80 kbit/s
-define(RTCP_BW, 500.0).
-define(MIN_INTERVAL, 5.0).
%% UDP and IPv4 headers, counted in the average size (A.7)
-define(UDP_IP, 28).
%% seconds from 1900 (NTP) to 1970 (Unix)
-define(NTP_EPOCH, 2208988800).

-type ssrc() :: 0..16#FFFFFFFF.
-type block() :: #{
    ssrc := ssrc(),
    fraction := 0..255,
    lost := integer(),
    highest := 0..16#FFFFFFFF,
    jitter := non_neg_integer(),
    lsr := 0..16#FFFFFFFF,
    dlsr := 0..16#FFFFFFFF
}.
-type item() :: {cname | name | 0..255, binary()}.
-type part() ::
    #{
        type := sr,
        ssrc := ssrc(),
        ntp := non_neg_integer(),
        ts := 0..16#FFFFFFFF,
        packets := non_neg_integer(),
        octets := non_neg_integer(),
        blocks := [block()]
    }
    | #{type := rr, ssrc := ssrc(), blocks := [block()]}
    | #{type := sdes, chunks := [{ssrc(), [item()]}]}
    | #{type := bye, ssrcs := [ssrc()], reason => binary()}
    | #{type := other, pt := 0..255}.

%% One source's reception statistics (A.1, A.3, A.8).
-record(src, {
    ssrc :: ssrc(),
    %% undefined until its first RTP packet
    max_seq :: 0..65535 | undefined,
    base_seq = 0 :: 0..65535,
    cycles = 0 :: non_neg_integer(),
    bad_seq = ?SEQ_MOD + 1 :: 0..?SEQ_MOD + 1,
    received = 0 :: non_neg_integer(),
    expected_prior = 0 :: non_neg_integer(),
    received_prior = 0 :: non_neg_integer(),
    %% relative transit time of the last packet, timestamp units
    transit :: integer() | undefined,
    %% the jitter times 16 (A.8)
    jitter = 0 :: non_neg_integer(),
    %% the middle 32 bits of the last SR's NTP time, and when it came
    lsr = 0 :: 0..16#FFFFFFFF,
    lsr_at :: integer() | undefined,
    cname :: binary() | undefined,
    %% an RTP packet came since the last report
    heard = false :: boolean()
}).

-opaque src() :: #src{}.

%% ---- demultiplexing ----

%% RFC 5761 4: on a port shared with RTP, a packet whose second octet is
%% 192 to 223 is RTCP (SR 200 to APP 204 sit where RTP payload types 72
%% to 76 with the marker bit would).
-spec is_rtcp(binary()) -> boolean().
is_rtcp(<<_, B, _/binary>>) -> B >= 192 andalso B =< 223;
is_rtcp(_) -> false.

%% ---- packets ----

%% A compound packet from its parts, in order. The count fields hold 31
%% report blocks or SDES chunks; callers stay under it.
-spec build([part()]) -> binary().
build(Parts) ->
    iolist_to_binary([part(P) || P <- Parts]).

part(#{type := rr, ssrc := Ssrc, blocks := Blocks}) ->
    packet(?RR, length(Blocks), [<<Ssrc:32>>, [block_bin(B) || B <- Blocks]]);
part(#{type := sr, ssrc := Ssrc, blocks := Blocks} = P) ->
    #{ntp := Ntp, ts := Ts, packets := Pk, octets := Oc} = P,
    packet(?SR, length(Blocks), [
        <<Ssrc:32, Ntp:64, Ts:32, Pk:32, Oc:32>>, [block_bin(B) || B <- Blocks]
    ]);
part(#{type := sdes, chunks := Chunks}) ->
    packet(?SDES, length(Chunks), [chunk(S, Items) || {S, Items} <- Chunks]);
part(#{type := bye, ssrcs := Ssrcs} = P) ->
    Reason =
        case P of
            #{reason := R0} ->
                R = text(R0),
                pad(<<(byte_size(R)), R/binary>>, 0);
            #{} ->
                <<>>
        end,
    packet(?BYE, length(Ssrcs), [[<<S:32>> || S <- Ssrcs], Reason]).

packet(PT, Count, Body0) ->
    Body = iolist_to_binary(Body0),
    <<2:2, 0:1, Count:5, PT, (byte_size(Body) div 4):16, Body/binary>>.

block_bin(#{
    ssrc := Ssrc,
    fraction := F,
    lost := Lost,
    highest := High,
    jitter := J,
    lsr := Lsr,
    dlsr := Dlsr
}) ->
    <<Ssrc:32, F, Lost:24/signed, High:32, J:32, Lsr:32, Dlsr:32>>.

%% the items, at least one null octet, then nulls to the next 32-bit
%% boundary (6.5)
chunk(Ssrc, Items) ->
    Bin = iolist_to_binary([
        <<(item_type(T)), (byte_size(text(V))), (text(V))/binary>>
     || {T, V} <- Items
    ]),
    pad(<<Ssrc:32, Bin/binary>>, 1).

item_type(cname) -> 1;
item_type(name) -> 2;
item_type(N) when is_integer(N) -> N.

text(B) when byte_size(B) > 255 -> binary:part(B, 0, 255);
text(B) -> B.

%% at least Min null octets, then more to a multiple of four
pad(Bin, Min) ->
    N = (4 - (byte_size(Bin) + Min) rem 4) rem 4 + Min,
    <<Bin/binary, 0:(N * 8)>>.

%% A compound packet, checked as A.2 asks, in its parts.
-spec parse(binary()) -> {ok, [part()]} | {error, invalid}.
parse(<<2:2, 0:1, _:5, PT, _/binary>> = Bin) when PT =:= ?SR; PT =:= ?RR ->
    try
        {ok, parts(Bin)}
    catch
        error:invalid -> {error, invalid}
    end;
parse(_) ->
    {error, invalid}.

parts(<<>>) ->
    [];
parts(<<2:2, P:1, Count:5, PT, Len:16, Rest/binary>>) ->
    Bytes = Len * 4,
    case Rest of
        %% padding only on the last packet (6.4.1)
        <<Body:Bytes/binary, Next/binary>> when P =:= 0; Next =:= <<>> ->
            [body(PT, Count, unpad(P, Body)) | parts(Next)];
        _ ->
            error(invalid)
    end;
parts(_) ->
    error(invalid).

unpad(0, Body) ->
    Body;
unpad(1, <<>>) ->
    error(invalid);
unpad(1, Body) ->
    case byte_size(Body) - binary:last(Body) of
        N when N >= 0 -> binary:part(Body, 0, N);
        _ -> error(invalid)
    end.

body(?SR, Count, <<Ssrc:32, Ntp:64, Ts:32, Pk:32, Oc:32, Blocks/binary>>) ->
    #{
        type => sr,
        ssrc => Ssrc,
        ntp => Ntp,
        ts => Ts,
        packets => Pk,
        octets => Oc,
        blocks => blocks(Count, Blocks)
    };
body(?RR, Count, <<Ssrc:32, Blocks/binary>>) ->
    #{type => rr, ssrc => Ssrc, blocks => blocks(Count, Blocks)};
body(?SDES, Count, Body) ->
    #{type => sdes, chunks => chunks(Count, Body)};
body(?BYE, Count, Body) ->
    Bytes = Count * 4,
    case Body of
        <<Ssrcs:Bytes/binary, Rest/binary>> ->
            bye([S || <<S:32>> <= Ssrcs], Rest);
        _ ->
            error(invalid)
    end;
body(PT, _Count, _Body) when PT =/= ?SR, PT =/= ?RR ->
    #{type => other, pt => PT};
body(_PT, _Count, _Body) ->
    error(invalid).

bye(Ssrcs, <<>>) ->
    #{type => bye, ssrcs => Ssrcs};
bye(Ssrcs, <<L, Reason:L/binary, _/binary>>) ->
    #{type => bye, ssrcs => Ssrcs, reason => Reason};
bye(_Ssrcs, _) ->
    error(invalid).

%% profile extensions may follow the blocks (6.4.3); they are ignored
blocks(0, _) ->
    [];
blocks(
    N,
    <<Ssrc:32, F, Lost:24/signed, High:32, J:32, Lsr:32, Dlsr:32, Rest/binary>>
) ->
    [
        #{
            ssrc => Ssrc,
            fraction => F,
            lost => Lost,
            highest => High,
            jitter => J,
            lsr => Lsr,
            dlsr => Dlsr
        }
        | blocks(N - 1, Rest)
    ];
blocks(_, _) ->
    error(invalid).

chunks(0, _) ->
    [];
chunks(N, <<Ssrc:32, Rest/binary>>) ->
    {Items, Used, Rest1} = items(Rest, 0, []),
    %% the null octet and its padding reach the next 32-bit boundary
    Skip = (4 - (Used + 1) rem 4) rem 4,
    case Rest1 of
        <<_:Skip/binary, Rest2/binary>> ->
            [{Ssrc, Items} | chunks(N - 1, Rest2)];
        _ ->
            error(invalid)
    end;
chunks(_, _) ->
    error(invalid).

items(<<0, Rest/binary>>, Used, Acc) ->
    {lists:reverse(Acc), Used, Rest};
items(<<T, L, V:L/binary, Rest/binary>>, Used, Acc) ->
    items(Rest, Used + 2 + L, [{item_name(T), V} | Acc]);
items(_, _, _) ->
    error(invalid).

item_name(1) -> cname;
item_name(2) -> name;
item_name(T) -> T.

%% ---- timing ----

%% The interval in ms (6.2, A.7), the random factor drawn here.
-spec interval(pos_integer(), non_neg_integer(), boolean(), float(), boolean()) ->
    pos_integer().
interval(Members, Senders, WeSent, Avg, Initial) ->
    interval(Members, Senders, WeSent, Avg, Initial, rand:uniform_real()).

%% R in [0, 1] places the interval at 0.5 to 1.5 times
%% max(Tmin, n * C) (A.7 steps 1 to 4).
-spec interval(
    pos_integer(), non_neg_integer(), boolean(), float(), boolean(), float()
) -> pos_integer().
interval(Members, Senders, WeSent, Avg, Initial, R) ->
    Min =
        case Initial of
            true -> ?MIN_INTERVAL / 2;
            false -> ?MIN_INTERVAL
        end,
    {Bw, N} =
        case Senders =< Members * 0.25 of
            true when WeSent -> {?RTCP_BW * 0.25, Senders};
            true -> {?RTCP_BW * 0.75, Members - Senders};
            false -> {?RTCP_BW, Members}
        end,
    max(1, round(max(Min, Avg * N / Bw) * (R + 0.5) * 1000)).

%% The average compound packet size (A.7), on a packet of Size octets
%% sent or received, its UDP and IP headers counted.
-spec avg_size(float(), non_neg_integer()) -> float().
avg_size(Avg, Size) ->
    (Size + ?UDP_IP) / 16 + Avg * 15 / 16.

%% A 64-bit NTP timestamp of a Unix time in microseconds (4).
-spec ntp(integer()) -> non_neg_integer().
ntp(Us) ->
    Secs = Us div 1000000 + ?NTP_EPOCH,
    Frac = ((Us rem 1000000) bsl 32) div 1000000,
    (Secs bsl 32) bor Frac.

%% A short-term persistent CNAME (RFC 7022 4.2): 96 random bits, base64.
-spec cname() -> binary().
cname() ->
    base64:encode(crypto:strong_rand_bytes(12)).

%% ---- reception statistics ----

%% A source not heard yet (its SSRC seen in RTCP, or about to be in RTP).
-spec src_new(ssrc()) -> src().
src_new(Ssrc) ->
    #src{ssrc = Ssrc}.

%% An RTP packet of the source: its sequence number, its RTP timestamp,
%% and its arrival time in timestamp units on a clock that does not jump.
-spec src_rtp(src(), 0..65535, 0..16#FFFFFFFF, integer()) -> src().
src_rtp(#src{max_seq = undefined} = S, Seq, Ts, Arrival) ->
    jitter((init_seq(S, Seq))#src{received = 1, heard = true}, Ts, Arrival);
src_rtp(#src{} = S, Seq, Ts, Arrival) ->
    case update_seq(S, Seq) of
        {ok, S1} -> jitter(S1#src{heard = true}, Ts, Arrival);
        {bad, S1} -> S1
    end.

init_seq(S, Seq) ->
    S#src{
        base_seq = Seq,
        max_seq = Seq,
        bad_seq = ?SEQ_MOD + 1,
        cycles = 0,
        received = 0,
        received_prior = 0,
        expected_prior = 0
    }.

%% A.1 update_seq, past the probation
update_seq(#src{max_seq = Max} = S, Seq) ->
    update_seq(S, Seq, (Seq - Max) band 16#FFFF).

%% in order, with a gap it allows; a lower number has wrapped
update_seq(#src{max_seq = Max, received = R} = S, Seq, Udelta) when
    Udelta < ?MAX_DROPOUT
->
    Cycles =
        case Seq < Max of
            true -> S#src.cycles + ?SEQ_MOD;
            false -> S#src.cycles
        end,
    {ok, S#src{max_seq = Seq, cycles = Cycles, received = R + 1}};
%% two sequential packets after a jump: the sender restarted
update_seq(#src{bad_seq = Seq} = S, Seq, Udelta) when
    Udelta =< ?SEQ_MOD - ?MAX_MISORDER
->
    S1 = init_seq(S, Seq),
    {ok, S1#src{received = 1, transit = undefined}};
%% a very large jump: taken only if the next packet follows it
update_seq(S, Seq, Udelta) when Udelta =< ?SEQ_MOD - ?MAX_MISORDER ->
    {bad, S#src{bad_seq = (Seq + 1) band 16#FFFF}};
%% a duplicate or a reordered packet
update_seq(#src{received = R} = S, _Seq, _Udelta) ->
    {ok, S#src{received = R + 1}}.

%% A.8: the transit difference, the timestamp wrapping at 32 bits
jitter(#src{transit = undefined} = S, Ts, Arrival) ->
    S#src{transit = Arrival - Ts};
jitter(#src{transit = Prev, jitter = J} = S, Ts, Arrival) ->
    Transit = Arrival - Ts,
    D = abs(wrap32(Transit - Prev)),
    S#src{transit = Transit, jitter = J + D - ((J + 8) bsr 4)}.

wrap32(D) ->
    case D band 16#FFFFFFFF of
        W when W >= 16#80000000 -> W - 16#100000000;
        W -> W
    end.

%% The source's SR, its NTP time Ntp, came at Now (microseconds,
%% monotonic).
-spec src_sr(src(), non_neg_integer(), integer()) -> src().
src_sr(S, Ntp, Now) ->
    S#src{lsr = (Ntp bsr 16) band 16#FFFFFFFF, lsr_at = Now}.

%% The CNAME of its SDES.
-spec src_cname(src(), binary()) -> src().
src_cname(S, Cname) ->
    S#src{cname = Cname}.

%% Whether an RTP packet of it came since the last report.
-spec src_heard(src()) -> boolean().
src_heard(#src{heard = H}) -> H.

%% What stats/1 of the receiver shows of it.
-spec src_info(src()) ->
    #{
        ssrc := ssrc(),
        cname := binary() | undefined,
        received := non_neg_integer(),
        lost := integer(),
        highest := non_neg_integer(),
        jitter := non_neg_integer()
    }.
src_info(#src{} = S) ->
    #{
        ssrc => S#src.ssrc,
        cname => S#src.cname,
        received => S#src.received,
        lost => expected(S) - S#src.received,
        highest => extended(S),
        jitter => S#src.jitter bsr 4
    }.

extended(#src{max_seq = undefined}) -> 0;
extended(#src{max_seq = M, cycles = C}) -> C + M.

expected(#src{max_seq = undefined}) -> 0;
expected(#src{base_seq = B} = S) -> extended(S) - B + 1.

%% The report block for the source at Now (microseconds, monotonic), and
%% the state the next one counts its fraction lost from (6.4.1, A.3).
-spec block(src(), integer()) -> {block(), src()}.
block(#src{received = Received} = S, Now) ->
    Expected = expected(S),
    Lost = Expected - Received,
    ExpInt = Expected - S#src.expected_prior,
    LostInt = ExpInt - (Received - S#src.received_prior),
    Fraction =
        case ExpInt =:= 0 orelse LostInt =< 0 of
            true -> 0;
            false -> min(255, (LostInt bsl 8) div ExpInt)
        end,
    Dlsr =
        case S#src.lsr_at of
            undefined -> 0;
            At -> (max(0, Now - At) * 65536 div 1000000) band 16#FFFFFFFF
        end,
    Block = #{
        ssrc => S#src.ssrc,
        fraction => Fraction,
        %% clamped to the 24-bit field
        lost => max(-16#800000, min(16#7FFFFF, Lost)),
        highest => extended(S) band 16#FFFFFFFF,
        jitter => S#src.jitter bsr 4,
        lsr => S#src.lsr,
        dlsr => Dlsr
    },
    {Block, S#src{
        expected_prior = Expected, received_prior = Received, heard = false
    }}.
