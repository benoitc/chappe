%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc The RTCP session of one RTP receiver (chappe_audio_rtp), pure: the
%% receiver's SSRC and CNAME, its sources' reception statistics, what the
%% source's RTCP said, where the reports go, and the next report.
%% chappe_audio_rtp keeps the sockets, the SRTCP key and the timer;
%% chappe_audio_rtcp has the packets and the statistics of one source.
%%
%% The receiver and its sources are the members of the session, the
%% sources its senders (RFC 3550 6.2, A.7); at most 31 sources are kept,
%% one RR's worth. A source that sends BYE is marked as gone (6.2.1):
%% for ?BYE_GRACE_US after it, a straggler that UDP reordered behind the
%% BYE (a sequence number at or below the highest one at the BYE) counts
%% against its entry, so its statistics do not start again, but it is
%% left out of the reports and of the member count. A newer sequence
%% number is the source sending again under the same SSRC: the mark
%% ends and the entry goes on (A.1). Past the grace the entry is
%% removed, lazily, at the next report or packet of that source, and a
%% packet then starts a new one.
%% A source that takes the receiver's SSRC makes it draw another (8.2).
%%
%% The functions taking Now (microseconds, monotonic) are the pure core;
%% the others read the clock.
-module(chappe_audio_rtp_rtcp).

-export([new/3, mode/1, rtp/2, rtp/3, input/3, input/4, interval/1]).
-export([report/2, report/3, sent/2]).
-export([has_sent/1, dest/3, stats/1]).

-export_type([session/0, mode/0, addr/0]).

-type mode() :: mux | port.
-type addr() :: {inet:ip_address(), inet:port_number()}.

-record(session, {
    mode :: mode(),
    %% where the source's RTCP came from, and the RTCP address its SDP gave
    from :: addr() | undefined,
    remote :: addr() | undefined,
    ssrc :: chappe_audio_rtcp:ssrc(),
    cname :: binary(),
    sources = #{} :: #{chappe_audio_rtcp:ssrc() => chappe_audio_rtcp:src()},
    %% the sources that sent BYE: when (microseconds, monotonic), and
    %% their highest sequence number then (none before any RTP)
    byes = #{} :: #{
        chappe_audio_rtcp:ssrc() => {integer(), 0..65535 | undefined}
    },
    avg_size = 100.0 :: float(),
    initial = true :: boolean(),
    sent = 0 :: non_neg_integer(),
    received = 0 :: non_neg_integer()
}).

-opaque session() :: #session{}.

%% the sources one RR reports on
-define(MAX_SOURCES, 31).
%% how long a source's entry outlives its BYE: the 5 s minimum report
%% interval (6.2); UDP reordering is far shorter
-define(BYE_GRACE_US, 5000000).

%% A session in Mode, with the source's RTCP address from its SDP (or
%% undefined) and the receiver's CNAME.
-spec new(mode(), addr() | undefined, binary()) -> session().
new(Mode, Remote, Cname) ->
    #session{mode = Mode, remote = Remote, ssrc = new_ssrc(), cname = Cname}.

-spec mode(session()) -> mode().
mode(#session{mode = M}) -> M.

%% An RTP packet of a source, in its statistics (A.1, A.8); arrival in
%% units of the 8000 Hz G.711 clock. RTCP and what does not parse count
%% for nothing.
-spec rtp(session(), binary()) -> session().
rtp(S, Packet) ->
    rtp(S, Packet, erlang:monotonic_time(microsecond)).

-spec rtp(session(), binary(), integer()) -> session().
rtp(S, Packet, Now) ->
    %% RFC 5761 4: SR to XR and the feedback types are RTCP, never RTP
    case chappe_audio_rtcp:is_rtcp(Packet) of
        true -> S;
        false -> rtp_stats(S, Packet, Now)
    end.

rtp_stats(
    S, <<2:2, _:6, _M:1, _PT:7, Seq:16, Ts:32, Ssrc:32, _/binary>>, Now
) ->
    Arrival = Now * 8 div 1000,
    with_source(
        Ssrc,
        fun(Src) -> chappe_audio_rtcp:src_rtp(Src, Seq, Ts, Arrival) end,
        collision(Ssrc, resume(Ssrc, Seq, expire(Ssrc, Now, S)))
    );
rtp_stats(S, _Packet, _Now) ->
    S.

%% A compound packet of the source, plain, from From: SR, SDES CNAME and
%% BYE are read and other packets ignored (6.1); one that does not parse
%% (A.2) is dropped.
-spec input(session(), binary(), addr()) -> session().
input(S, Packet, From) ->
    input(S, Packet, From, erlang:monotonic_time(microsecond)).

-spec input(session(), binary(), addr(), integer()) -> session().
input(S, Packet, From, Now) ->
    case chappe_audio_rtcp:parse(Packet) of
        {ok, Parts} ->
            lists:foldl(
                fun(Part, A) -> part(Part, Now, A) end,
                S#session{
                    from = From,
                    received = S#session.received + 1,
                    avg_size = chappe_audio_rtcp:avg_size(
                        S#session.avg_size, byte_size(Packet)
                    )
                },
                Parts
            );
        {error, invalid} ->
            S
    end.

part(#{type := sr, ssrc := Ssrc, ntp := Ntp}, Now, S) ->
    with_source(
        Ssrc,
        fun(Src) -> chappe_audio_rtcp:src_sr(Src, Ntp, Now) end,
        collision(Ssrc, expire(Ssrc, Now, S))
    );
part(#{type := sdes, chunks := Chunks}, _Now, S) ->
    lists:foldl(fun cname/2, S, Chunks);
part(#{type := bye, ssrcs := Ssrcs}, Now, S) ->
    lists:foldl(fun(Ssrc, A) -> bye(Ssrc, Now, A) end, S, Ssrcs);
part(_Part, _Now, S) ->
    S.

cname({Ssrc, Items}, S) ->
    case lists:keyfind(cname, 1, Items) of
        {cname, C} ->
            with_source(
                Ssrc, fun(Src) -> chappe_audio_rtcp:src_cname(Src, C) end, S
            );
        false ->
            S
    end.

%% a known source marked as gone at its first BYE; a BYE for a source
%% never heard creates nothing
bye(Ssrc, Now, #session{sources = Srcs, byes = Byes} = S) ->
    case Srcs of
        #{Ssrc := Src} when not is_map_key(Ssrc, Byes) ->
            S#session{byes = Byes#{Ssrc => {Now, highest(Src)}}};
        #{} ->
            S
    end.

highest(Src) ->
    case chappe_audio_rtcp:src_info(Src) of
        #{received := 0} -> undefined;
        #{highest := H} -> H band 16#FFFF
    end.

%% a marked source sending a sequence number newer than its highest at
%% the BYE (A.1, modulo 2^16) is back: the mark ends
resume(Ssrc, Seq, #session{byes = Byes} = S) ->
    case Byes of
        #{Ssrc := {_, High}} ->
            case newer(Seq, High) of
                true -> S#session{byes = maps:remove(Ssrc, Byes)};
                false -> S
            end;
        #{} ->
            S
    end.

%% Seq after High in sequence space; any packet when no RTP came before
newer(_Seq, undefined) ->
    true;
newer(Seq, High) ->
    D = (Seq - High) band 16#FFFF,
    D >= 1 andalso D < 16#8000.

%% the entry of a source whose BYE grace is over, removed
expire(Ssrc, Now, #session{sources = Srcs, byes = Byes} = S) ->
    case Byes of
        #{Ssrc := {At, _}} when Now - At >= ?BYE_GRACE_US ->
            S#session{
                sources = maps:remove(Ssrc, Srcs),
                byes = maps:remove(Ssrc, Byes)
            };
        #{} ->
            S
    end.

%% every entry whose BYE grace is over, removed
expire_all(Now, #session{byes = Byes} = S) ->
    maps:fold(fun(Ssrc, _, A) -> expire(Ssrc, Now, A) end, S, Byes).

collision(Ssrc, #session{ssrc = Ssrc} = S) -> S#session{ssrc = new_ssrc()};
collision(_Ssrc, S) -> S.

%% a source's statistics updated, a new one only while there is room
with_source(Ssrc, Fun, #session{sources = Srcs} = S) ->
    case Srcs of
        #{Ssrc := Src} ->
            S#session{sources = Srcs#{Ssrc := Fun(Src)}};
        #{} when map_size(Srcs) < ?MAX_SOURCES ->
            S#session{
                sources = Srcs#{Ssrc => Fun(chappe_audio_rtcp:src_new(Ssrc))}
            };
        #{} ->
            S
    end.

new_ssrc() ->
    <<Ssrc:32>> = crypto:strong_rand_bytes(4),
    Ssrc.

%% The time to the next report in ms (6.2, A.7).
-spec interval(session()) -> pos_integer().
interval(#session{
    sources = Srcs, byes = Byes, avg_size = Avg, initial = Initial
}) ->
    %% a source that sent BYE is no longer a member
    N = map_size(Srcs) - map_size(Byes),
    chappe_audio_rtcp:interval(max(2, N + 1), N, false, Avg, Initial).

%% The next compound packet, plain: an RR with a block per source heard
%% since the last one (an empty RR when none was, 6.4.2), SDES with the
%% CNAME (6.1), and with Bye a BYE (6.3.7). A source that sent BYE has
%% no block (6.2.1).
-spec report(session(), boolean()) -> {binary(), session()}.
report(S, Bye) ->
    report(S, Bye, erlang:monotonic_time(microsecond)).

-spec report(session(), boolean(), integer()) -> {binary(), session()}.
report(S0, Bye, Now) ->
    #session{sources = Srcs, byes = Byes, ssrc = Me, cname = Cname} =
        S = expire_all(Now, S0),
    {Blocks, Srcs1} = maps:fold(
        fun(Ssrc, Src, {Bs, Acc}) ->
            case
                chappe_audio_rtcp:src_heard(Src) andalso
                    not is_map_key(Ssrc, Byes)
            of
                true ->
                    {B, Src1} = chappe_audio_rtcp:block(Src, Now),
                    {[B | Bs], Acc#{Ssrc := Src1}};
                false ->
                    {Bs, Acc}
            end
        end,
        {[], Srcs},
        Srcs
    ),
    Parts =
        [
            #{type => rr, ssrc => Me, blocks => lists:reverse(Blocks)},
            #{type => sdes, chunks => [{Me, [{cname, Cname}]}]}
        ] ++ [#{type => bye, ssrcs => [Me]} || Bye],
    {chappe_audio_rtcp:build(Parts), S#session{sources = Srcs1}}.

%% A packet of Size octets went out.
-spec sent(session(), non_neg_integer()) -> session().
sent(#session{sent = N, avg_size = Avg} = S, Size) ->
    S#session{
        initial = false,
        sent = N + 1,
        avg_size = chappe_audio_rtcp:avg_size(Avg, Size)
    }.

%% Whether a report went out: a BYE needs one first (6.3.7).
-spec has_sent(session()) -> boolean().
has_sent(#session{sent = N}) -> N > 0.

%% Where reports go, given the RTP source latched and the remote address
%% of its SDP: where the source's RTCP came from; else its RTP address
%% (mux) or the port above it (port, 11), or the RTCP address its SDP
%% gave; else remote. A source on port 65535 has no port above it, and
%% so no report.
-spec dest(session(), addr() | undefined, addr() | undefined) ->
    addr() | undefined.
dest(#session{from = {_, _} = F}, _Latched, _Remote) -> F;
dest(#session{mode = mux}, {_, _} = L, _Remote) -> L;
dest(#session{mode = mux}, undefined, Remote) -> Remote;
dest(#session{mode = port, remote = {_, _} = R}, _Latched, _Remote) -> R;
dest(#session{mode = port}, {Ip, P}, _Remote) -> above(Ip, P);
dest(#session{mode = port}, undefined, {Ip, P}) -> above(Ip, P);
dest(#session{}, _Latched, _Remote) -> undefined.

%% a source on the last port has no port above it: no report goes
above(Ip, P) when P < 65535 -> {Ip, P + 1};
above(_Ip, _P) -> undefined.

%% What stats/1 of the receiver adds.
-spec stats(session()) ->
    #{
        rtcp_sent := non_neg_integer(),
        rtcp_received := non_neg_integer(),
        sources := [map()]
    }.
stats(#session{sent = Sent, received = Received, sources = Srcs}) ->
    #{
        rtcp_sent => Sent,
        rtcp_received => Received,
        sources => [
            chappe_audio_rtcp:src_info(Src)
         || {_, Src} <- lists:sort(maps:to_list(Srcs))
        ]
    }.
