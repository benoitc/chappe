%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% RTCP (RFC 3550 section 6) as far as a mixer needs it: compound packets
%% built and parsed, the reception statistics of one source, and the
%% report interval.
%%
%% parse/1 is total and applies the validity checks of appendix A.2 to a
%% whole compound packet: version 2 throughout, SR or RR first with no
%% padding bit, and lengths that add up to the datagram. A packet type it
%% does not know is kept as `#{type => other, pt => PT}' and never becomes
%% an atom; so is an SDES item type other than CNAME and NAME.
%%
%% Each mixer leg is its own RTP session with two members, the mixer and
%% the far end, both senders. The interval follows A.7 with a fixed
%% session bandwidth of 80 kbit/s (PCMU at 20 ms: 160 octets of payload
%% plus 40 of RTP, UDP and IPv4 headers, 50 times a second), so the RTCP
%% share is 5% of it, 500 octets/s. With two members and reports of about
%% 100 octets the bandwidth term is far below the 5 s minimum, which
%% therefore decides: the first report comes 1.03 to 3.08 s after the leg
%% opens (half the minimum), the next ones 2.05 to 6.16 s apart. With the
%% member count fixed, timer reconsideration (6.3.6) would not move them,
%% so it is not done.
-module(chappe_mix_rtcp).

-export([build/1, parse/1]).
-export([interval/5, interval/6, ntp/1, cname/0]).
-export([src_new/4, src_update/4, src_sr/3, src_ssrc/1, src_highest/1]).
-export([report_block/2]).

-export_type([ssrc/0, part/0, block/0, src/0]).

-define(SR, 200).
-define(RR, 201).
-define(SDES, 202).
-define(BYE, 203).
-define(RTCP_BW, 500.0).
-define(MIN_INTERVAL, 5.0).
-define(COMPENSATION, (2.71828 - 1.5)).
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

%% Reception statistics of the source one leg receives (A.1, A.3, A.8).
-record(src, {
    ssrc :: ssrc(),
    %% extended sequence numbers: first seen and highest seen
    base :: integer(),
    max :: integer(),
    received = 1 :: non_neg_integer(),
    expected_prior = 0 :: non_neg_integer(),
    received_prior = 0 :: non_neg_integer(),
    %% relative transit time of the last packet, timestamp units
    transit :: integer(),
    jitter = 0.0 :: float(),
    %% middle 32 bits of the NTP time of the last SR, and when it came
    lsr = 0 :: 0..16#FFFFFFFF,
    lsr_at :: integer() | undefined
}).

-opaque src() :: #src{}.

%% ---- packets ----

%% A compound packet from its parts, in order. Report blocks and SDES
%% chunks are limited to 31 by the count field; callers stay under it.
-spec build([part()]) -> binary().
build(Parts) ->
    iolist_to_binary([part(P) || P <- Parts]).

part(#{type := sr, ssrc := Ssrc, blocks := Blocks} = P) ->
    #{ntp := Ntp, ts := Ts, packets := Pk, octets := Oc} = P,
    packet(?SR, length(Blocks), [
        <<Ssrc:32, Ntp:64, Ts:32, Pk:32, Oc:32>>, [block(B) || B <- Blocks]
    ]);
part(#{type := rr, ssrc := Ssrc, blocks := Blocks}) ->
    packet(?RR, length(Blocks), [<<Ssrc:32>>, [block(B) || B <- Blocks]]);
part(#{type := sdes, chunks := Chunks}) ->
    packet(?SDES, length(Chunks), [chunk(S, Items) || {S, Items} <- Chunks]);
part(#{type := bye, ssrcs := Ssrcs} = P) ->
    Reason =
        case P of
            #{reason := R0} ->
                R = trunc_text(R0),
                pad(<<(byte_size(R)), R/binary>>, 0);
            #{} ->
                <<>>
        end,
    packet(?BYE, length(Ssrcs), [[<<S:32>> || S <- Ssrcs], Reason]).

packet(PT, Count, Body0) ->
    Body = iolist_to_binary(Body0),
    <<2:2, 0:1, Count:5, PT, (byte_size(Body) div 4):16, Body/binary>>.

block(#{
    ssrc := Ssrc,
    fraction := F,
    lost := Lost,
    highest := High,
    jitter := J,
    lsr := Lsr,
    dlsr := Dlsr
}) ->
    <<Ssrc:32, F, Lost:24/signed, High:32, J:32, Lsr:32, Dlsr:32>>.

%% Items back to back, then at least one null octet, then nulls to the
%% next 32-bit boundary (6.5).
chunk(Ssrc, Items) ->
    Bin = iolist_to_binary([
        <<(item_type(T)), (byte_size(trunc_text(V))), (trunc_text(V))/binary>>
     || {T, V} <- Items
    ]),
    pad(<<Ssrc:32, Bin/binary>>, 1).

item_type(cname) -> 1;
item_type(name) -> 2;
item_type(N) when is_integer(N) -> N.

trunc_text(B) when byte_size(B) > 255 -> binary:part(B, 0, 255);
trunc_text(B) -> B.

%% At least Min null octets, then more up to a multiple of four.
pad(Bin, Min) ->
    N = (4 - (byte_size(Bin) + Min) rem 4) rem 4 + Min,
    <<Bin/binary, 0:(N * 8)>>.

%% A compound packet, checked per A.2 and parsed into its parts.
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
        <<Body0:Bytes/binary, Next/binary>> ->
            [body(PT, Count, unpad(P, Body0)) | parts(Next)];
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

%% Profile extensions may follow the blocks; they are ignored.
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
    %% the terminator and its padding reach the next 32-bit boundary
    Skip = (4 - (Used + 1) rem 4) rem 4,
    case Rest1 of
        <<_:Skip/binary, Rest2/binary>> ->
            [{Ssrc, Items} | chunks(N - 1, Rest2)];
        _ ->
            error(invalid)
    end;
chunks(_, _) ->
    error(invalid).

%% Returns the items, the octets they took and what follows the null
%% type octet that ends them.
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

%% The interval of A.7 in seconds, with the random factor drawn here.
-spec interval(
    pos_integer(), non_neg_integer(), boolean(), float(), boolean()
) -> float().
interval(Members, Senders, WeSent, Avg, Initial) ->
    interval(Members, Senders, WeSent, Avg, Initial, rand:uniform_real()).

%% R is the random draw in [0, 1): the result is the calculated interval
%% times 0.5 to 1.5, divided by e - 3/2 to make up for reconsideration.
-spec interval(
    pos_integer(), non_neg_integer(), boolean(), float(), boolean(), float()
) -> float().
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
    max(Min, Avg * N / Bw) * (R + 0.5) / ?COMPENSATION.

%% A 64-bit NTP timestamp from Unix time in microseconds.
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

%% A source first heard with this packet. Arrival is the arrival time in
%% timestamp units, on any clock that does not jump.
-spec src_new(ssrc(), 0..65535, 0..16#FFFFFFFF, integer()) -> src().
src_new(Ssrc, Seq, Ts, Arrival) ->
    #src{ssrc = Ssrc, base = Seq, max = Seq, transit = Arrival - Ts}.

-spec src_update(src(), 0..65535, 0..16#FFFFFFFF, integer()) -> src().
src_update(#src{max = Max, transit = Prev, jitter = J} = S, Seq, Ts, Arrival) ->
    Ext = chappe_mix_rtp:extend_seq(Seq, Max),
    Transit = Arrival - Ts,
    D = abs(wrap32(Transit - Prev)),
    S#src{
        max = max(Ext, Max),
        received = S#src.received + 1,
        transit = Transit,
        jitter = J + (D - J) / 16
    }.

%% The timestamp wraps at 32 bits; a transit difference is small.
wrap32(D) ->
    case D band 16#FFFFFFFF of
        W when W >= 16#80000000 -> W - 16#100000000;
        W -> W
    end.

%% The source's SR came in at Now (microseconds, monotonic).
-spec src_sr(src(), non_neg_integer(), integer()) -> src().
src_sr(S, Ntp, Now) ->
    S#src{lsr = (Ntp bsr 16) band 16#FFFFFFFF, lsr_at = Now}.

-spec src_ssrc(src()) -> ssrc().
src_ssrc(#src{ssrc = Ssrc}) -> Ssrc.

%% The highest sequence number seen, as on the wire (modulo 2^16).
-spec src_highest(src()) -> 0..65535.
src_highest(#src{max = Max}) -> Max band 16#FFFF.

%% The report block for the source at Now (microseconds, monotonic), and
%% the state that the next one counts its fraction lost from.
-spec report_block(src(), integer()) -> {block(), src()}.
report_block(#src{} = S, Now) ->
    Expected = S#src.max - S#src.base + 1,
    Lost = Expected - S#src.received,
    ExpInt = Expected - S#src.expected_prior,
    LostInt = ExpInt - (S#src.received - S#src.received_prior),
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
        lost => max(-16#800000, min(16#7FFFFF, Lost)),
        highest => S#src.max band 16#FFFFFFFF,
        jitter => trunc(S#src.jitter),
        lsr => S#src.lsr,
        dlsr => Dlsr
    },
    {Block, S#src{expected_prior = Expected, received_prior = S#src.received}}.
