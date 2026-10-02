%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The RTP session of one mixer leg as RFC 3550 sees it, as plain data:
%% the mixer's SSRC and sender state on that leg, the one source the leg
%% receives and its reception statistics, the RTCP schedule, and the
%% conflict list of 8.2. The conference owns the sockets; it sends what
%% this module builds and hands it what arrives.
-module(chappe_mix_session).

-export([new/2, ssrc/1, src_ssrc/1, csrcs/1, info/1]).
-export([header/1, sent/3, sent_event/2, advance/2]).
-export([rtp_in/4, renew/2, rtcp_in/5, rtcp_invalid/1, csrc_items/3]).
-export([due/2, timeout/2, report/5, reported/2, sent_any/1]).

-export_type([session/0, ssrc/0, addr/0]).

%% the probable size of our first report, IP and UDP included (6.3.2)
-define(AVG0, 108.0).
%% a source silent this long leaves the reports: five intervals at the
%% 5 s minimum, which decides the interval here (6.3.5)
-define(TIMEOUT_S, 25).
-define(MAX_SDES, 4).
-define(MAX_CONFLICTS, 8).

-type ssrc() :: 0..16#FFFFFFFF.
-type addr() :: {inet:ip_address(), inet:port_number()}.

-record(sess, {
    ssrc :: ssrc(),
    seq :: 0..65535,
    ts :: 0..16#FFFFFFFF,
    %% timestamp of the last packet sent, for the SR
    last_ts = 0 :: 0..16#FFFFFFFF,
    %% the CSRC list of the last packet sent
    csrcs = [] :: [ssrc()],
    %% packets and payload octets sent under the current SSRC
    pkts = 0 :: non_neg_integer(),
    octets = 0 :: non_neg_integer(),
    %% the source received, when it was last heard (native monotonic),
    %% and what its SDES said
    src :: chappe_mix_rtcp:src() | undefined,
    heard_at = 0 :: integer(),
    sdes = #{} :: #{ssrc() => [{cname | name, binary()}]},
    %% addresses that used our SSRC, RTP and RTCP apart (8.2)
    conflicts = [] :: [{rtp | rtcp, addr()}],
    %% when the next report is due (native monotonic)
    next :: integer(),
    avg = ?AVG0 :: float(),
    initial = true :: boolean(),
    sent = 0 :: non_neg_integer(),
    received = 0 :: non_neg_integer(),
    invalid = 0 :: non_neg_integer(),
    collisions = 0 :: non_neg_integer(),
    loops = 0 :: non_neg_integer()
}).

-opaque session() :: #sess{}.

%% A session under Ssrc, opened at Now (native monotonic). Sequence and
%% timestamp start at random (5.1).
-spec new(ssrc(), integer()) -> session().
new(Ssrc, Now) ->
    schedule(
        #sess{
            ssrc = Ssrc,
            seq = rand:uniform(16#10000) - 1,
            ts = rand:uniform(16#100000000) - 1,
            next = Now
        },
        Now
    ).

-spec ssrc(session()) -> ssrc().
ssrc(#sess{ssrc = Ssrc}) -> Ssrc.

-spec src_ssrc(session()) -> ssrc() | undefined.
src_ssrc(#sess{src = undefined}) -> undefined;
src_ssrc(#sess{src = Src}) -> chappe_mix_rtcp:src_ssrc(Src).

-spec csrcs(session()) -> [ssrc()].
csrcs(#sess{csrcs = C}) -> C.

-spec info(session()) -> #{atom() => term()}.
info(#sess{} = S) ->
    #{
        ssrc => S#sess.ssrc,
        source_ssrc => src_ssrc(S),
        csrcs => S#sess.csrcs,
        collisions => S#sess.collisions,
        loops => S#sess.loops,
        rtcp_sent => S#sess.sent,
        rtcp_received => S#sess.received,
        rtcp_invalid => S#sess.invalid
    }.

%% ---- RTP out ----

%% The header fields of the next packet.
-spec header(session()) ->
    #{seq := 0..65535, ts := 0..16#FFFFFFFF, ssrc := ssrc()}.
header(#sess{seq = Seq, ts = Ts, ssrc = Ssrc}) ->
    #{seq => Seq, ts => Ts, ssrc => Ssrc}.

%% A packet went out naming Csrcs, with Octets of payload: the sequence
%% number steps by one.
-spec sent(session(), [ssrc()], non_neg_integer()) -> session().
sent(#sess{} = S, Csrcs, Octets) ->
    S#sess{
        seq = (S#sess.seq + 1) band 16#FFFF,
        last_ts = S#sess.ts,
        csrcs = Csrcs,
        pkts = S#sess.pkts + 1,
        octets = S#sess.octets + Octets
    }.

%% A telephone-event packet went out between two mixed ones, with Octets
%% of payload: it takes the next sequence number (RFC 4733 2.5.1.6) and
%% counts in the SR, but leaves the CSRC list and the SR timestamp alone.
-spec sent_event(session(), non_neg_integer()) -> session().
sent_event(#sess{} = S, Octets) ->
    S#sess{
        seq = (S#sess.seq + 1) band 16#FFFF,
        pkts = S#sess.pkts + 1,
        octets = S#sess.octets + Octets
    }.

%% The timestamp follows the sampling clock, sent or not.
-spec advance(session(), non_neg_integer()) -> session().
advance(#sess{ts = Ts} = S, Step) ->
    S#sess{ts = (Ts + Step) band 16#FFFFFFFF}.

%% ---- RTP in ----

%% A packet from Addr. Our own SSRC in it is a collision the first time
%% from that address and a loop after (8.2); our SSRC in its CSRC list is
%% our stream mixed back to us, a loop. On a collision the caller says
%% BYE for the old SSRC, calls renew/2, and hands the packet in again.
-spec rtp_in(session(), chappe_mix_rtp:packet(), addr(), integer()) ->
    {ok, session(), New :: boolean()} | {loop | collision, session()}.
rtp_in(#sess{ssrc = Ssrc} = S, #{ssrc := Ssrc}, Addr, _Now) ->
    conflict({rtp, Addr}, S);
rtp_in(
    #sess{ssrc = Mine} = S,
    #{ssrc := Ssrc, seq := Seq, ts := Ts} = P,
    _Addr,
    Now
) ->
    case lists:member(Mine, maps:get(csrcs, P, [])) of
        true ->
            {loop, S#sess{loops = S#sess.loops + 1}};
        false ->
            %% arrival in 8 kHz timestamp units, for the jitter (A.8)
            Arrival =
                erlang:convert_time_unit(Now, native, microsecond) div 125,
            {Src, New} =
                case S#sess.src of
                    undefined ->
                        {chappe_mix_rtcp:src_new(Ssrc, Seq, Ts, Arrival), true};
                    Src0 ->
                        case chappe_mix_rtcp:src_ssrc(Src0) of
                            Ssrc ->
                                {
                                    chappe_mix_rtcp:src_update(
                                        Src0, Seq, Ts, Arrival
                                    ),
                                    false
                                };
                            _ ->
                                {
                                    chappe_mix_rtcp:src_new(
                                        Ssrc, Seq, Ts, Arrival
                                    ),
                                    true
                                }
                        end
                end,
            {ok, S#sess{src = Src, heard_at = Now}, New}
    end.

conflict(Addr, #sess{conflicts = C} = S) ->
    case lists:member(Addr, C) of
        true ->
            {loop, S#sess{loops = S#sess.loops + 1}};
        false ->
            {collision, S#sess{
                conflicts = lists:sublist([Addr | C], ?MAX_CONFLICTS)
            }}
    end.

%% A new SSRC after a collision, with fresh sender counts (6.4.1).
-spec renew(session(), ssrc()) -> session().
renew(#sess{} = S, Ssrc) ->
    S#sess{
        ssrc = Ssrc, pkts = 0, octets = 0, collisions = S#sess.collisions + 1
    }.

%% ---- RTCP in ----

%% A valid compound of Size octets from Addr. SR timing feeds our report
%% block, CNAME and NAME are kept to describe the source as a CSRC to the
%% others. Returns whether our SSRC collided and the SSRCs of the source
%% that said BYE, for the caller to forward.
-spec rtcp_in(
    session(), [chappe_mix_rtcp:part()], non_neg_integer(), addr(), integer()
) ->
    {session(), Collided :: boolean(), Gone :: [ssrc()]}.
rtcp_in(#sess{} = S, Parts, Size, Addr, NowUs) ->
    S1 = S#sess{received = S#sess.received + 1, avg = avg(S#sess.avg, Size)},
    lists:foldl(
        fun(P, Acc) -> part(P, Addr, NowUs, Acc) end, {S1, false, []}, Parts
    ).

part(#{type := T, ssrc := Ssrc}, Addr, _Now, {#sess{ssrc = Ssrc} = S, C, Gone}) when
    T =:= sr; T =:= rr
->
    case conflict({rtcp, Addr}, S) of
        {loop, S1} -> {S1, C, Gone};
        {collision, S1} -> {S1, true, Gone}
    end;
part(#{type := sr, ssrc := Ssrc, ntp := Ntp}, _Addr, Now, {S, C, Gone}) ->
    case src_ssrc(S) of
        Ssrc ->
            {
                S#sess{src = chappe_mix_rtcp:src_sr(S#sess.src, Ntp, Now)},
                C,
                Gone
            };
        _ ->
            {S, C, Gone}
    end;
part(#{type := sdes, chunks := Chunks}, _Addr, _Now, {S, C, Gone}) ->
    {lists:foldl(fun sdes_in/2, S, Chunks), C, Gone};
part(#{type := bye, ssrcs := Ssrcs}, _Addr, _Now, {S, C, Gone}) ->
    Mine = src_ssrc(S),
    case Mine =/= undefined andalso lists:member(Mine, Ssrcs) of
        true ->
            {
                S#sess{src = undefined, sdes = maps:remove(Mine, S#sess.sdes)},
                C,
                [Mine | Gone]
            };
        false ->
            {S, C, Gone}
    end;
part(_Other, _Addr, _Now, Acc) ->
    Acc.

%% CNAME and NAME only, for a bounded number of SSRCs.
sdes_in({Ssrc, Items}, #sess{sdes = Sdes} = S) ->
    Kept = [I || {K, _} = I <- Items, K =:= cname orelse K =:= name],
    case
        Kept =/= [] andalso
            (maps:is_key(Ssrc, Sdes) orelse map_size(Sdes) < ?MAX_SDES)
    of
        true -> S#sess{sdes = maps:put(Ssrc, Kept, Sdes)};
        false -> S
    end.

-spec rtcp_invalid(session()) -> session().
rtcp_invalid(#sess{invalid = N} = S) -> S#sess{invalid = N + 1}.

%% The SDES items to send for our source when another leg lists it as a
%% CSRC: the CNAME it sent (7.3 has the mixer forward it) and, with
%% Names, the NAME the leg was given or else the one it sent. Nothing
%% without a CNAME.
-spec csrc_items(session(), binary() | undefined, boolean()) ->
    [{cname | name, binary()}].
csrc_items(S, Name, Names) ->
    Items = maps:get(src_ssrc(S), S#sess.sdes, []),
    case lists:keyfind(cname, 1, Items) of
        false ->
            [];
        Cname when not Names -> [Cname];
        Cname when Name =:= undefined ->
            [Cname | [I || {name, _} = I <- Items]];
        Cname ->
            [Cname, {name, Name}]
    end.

%% ---- RTCP out ----

-spec due(session(), integer()) -> boolean().
due(#sess{next = Next}, Now) -> Next =< Now.

%% Checked once per report (6.3.5): a source not heard for five
%% intervals is no longer reported on, nor counted as a member.
-spec timeout(session(), integer()) -> session().
timeout(#sess{src = undefined} = S, _Now) ->
    S;
timeout(#sess{heard_at = At} = S, Now) ->
    case Now - At > erlang:convert_time_unit(?TIMEOUT_S, second, native) of
        true -> S#sess{src = undefined};
        false -> S
    end.

%% True once we sent RTP or RTCP: a leg that never did gets no BYE
%% (6.3.7).
-spec sent_any(session()) -> boolean().
sent_any(#sess{pkts = P, sent = R}) -> P > 0 orelse R > 0.

%% A compound packet from our SSRC: SR (an empty RR before we sent any
%% RTP) with the block for our source, SDES with Cname and the CSRC
%% chunks, then Extra. NAME items ride every third report only (RFC
%% 3551 2), so Chunks is a fun of whether they may. Returns the packet
%% and the session that sent it.
-spec report(
    session(),
    binary(),
    fun((boolean()) -> list()),
    [chappe_mix_rtcp:part()],
    integer()
) ->
    {binary(), session()}.
report(#sess{ssrc = Ssrc} = S, Cname, Chunks, Extra, NowUs) ->
    {Blocks, Src} =
        case S#sess.src of
            undefined ->
                {[], undefined};
            Src0 ->
                {B, Src1} = chappe_mix_rtcp:report_block(Src0, NowUs),
                {[B], Src1}
        end,
    Report =
        case S#sess.pkts of
            0 ->
                #{type => rr, ssrc => Ssrc, blocks => Blocks};
            N ->
                %% the timestamp of the packet sent this tick, taken with
                %% the wall clock now: the same instant within the tick
                #{
                    type => sr,
                    ssrc => Ssrc,
                    ntp => chappe_mix_rtcp:ntp(os:system_time(microsecond)),
                    ts => S#sess.last_ts,
                    packets => N band 16#FFFFFFFF,
                    octets => S#sess.octets band 16#FFFFFFFF,
                    blocks => Blocks
                }
        end,
    Sdes = #{
        type => sdes,
        chunks => [{Ssrc, [{cname, Cname}]} | Chunks(S#sess.sent rem 3 =:= 0)]
    },
    Pkt = chappe_mix_rtcp:build([Report, Sdes | Extra]),
    {Pkt, S#sess{
        src = Src, sent = S#sess.sent + 1, avg = avg(S#sess.avg, byte_size(Pkt))
    }}.

%% A periodic report went out (or had nowhere to go) at Now: the next one
%% is one interval on.
-spec reported(session(), integer()) -> session().
reported(S, Now) ->
    schedule(S#sess{initial = false}, Now).

schedule(#sess{src = Src, pkts = Pkts} = S, Now) ->
    Heard =
        case Src of
            undefined -> 0;
            _ -> 1
        end,
    WeSent = Pkts > 0,
    Senders =
        case WeSent of
            true -> Heard + 1;
            false -> Heard
        end,
    Secs = chappe_mix_rtcp:interval(
        1 + Heard, Senders, WeSent, S#sess.avg, S#sess.initial
    ),
    S#sess{
        next =
            Now +
                erlang:convert_time_unit(
                    round(Secs * 1000000), microsecond, native
                )
    }.

%% 6.3.3: the average compound size, IP and UDP headers included.
avg(Avg, Size) ->
    Avg + (Size + 28 - Avg) / 16.
