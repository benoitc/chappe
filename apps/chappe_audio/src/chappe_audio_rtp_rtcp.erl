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
%% one RR's worth. A source that sends BYE is dropped (6.2.1). A source
%% that takes the receiver's SSRC makes it draw another (8.2).
-module(chappe_audio_rtp_rtcp).

-export([new/3, mode/1, rtp/2, input/3, interval/1, report/2, sent/2]).
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
    avg_size = 100.0 :: float(),
    initial = true :: boolean(),
    sent = 0 :: non_neg_integer(),
    received = 0 :: non_neg_integer()
}).

-opaque session() :: #session{}.

%% the sources one RR reports on
-define(MAX_SOURCES, 31).

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
rtp(S, <<2:2, _:6, _M:1, PT:7, Seq:16, Ts:32, Ssrc:32, _/binary>>) when
    PT < 72; PT > 76
->
    Arrival = erlang:monotonic_time(microsecond) * 8 div 1000,
    with_source(
        Ssrc,
        fun(Src) -> chappe_audio_rtcp:src_rtp(Src, Seq, Ts, Arrival) end,
        collision(Ssrc, S)
    );
rtp(S, _Packet) ->
    S.

%% A compound packet of the source, plain, from From: SR, SDES CNAME and
%% BYE are read and other packets ignored (6.1); one that does not parse
%% (A.2) is dropped.
-spec input(session(), binary(), addr()) -> session().
input(S, Packet, From) ->
    case chappe_audio_rtcp:parse(Packet) of
        {ok, Parts} ->
            Now = erlang:monotonic_time(microsecond),
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
        collision(Ssrc, S)
    );
part(#{type := sdes, chunks := Chunks}, _Now, S) ->
    lists:foldl(fun cname/2, S, Chunks);
part(#{type := bye, ssrcs := Ssrcs}, _Now, #session{sources = Srcs} = S) ->
    S#session{sources = maps:without(Ssrcs, Srcs)};
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
interval(#session{sources = Srcs, avg_size = Avg, initial = Initial}) ->
    N = map_size(Srcs),
    chappe_audio_rtcp:interval(max(2, N + 1), N, false, Avg, Initial).

%% The next compound packet, plain: an RR with a block per source heard
%% since the last one (an empty RR when none was, 6.4.2), SDES with the
%% CNAME (6.1), and with Bye a BYE (6.3.7).
-spec report(session(), boolean()) -> {binary(), session()}.
report(#session{sources = Srcs, ssrc = Me, cname = Cname} = S, Bye) ->
    Now = erlang:monotonic_time(microsecond),
    {Blocks, Srcs1} = maps:fold(
        fun(Ssrc, Src, {Bs, Acc}) ->
            case chappe_audio_rtcp:src_heard(Src) of
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
%% gave; else remote.
-spec dest(session(), addr() | undefined, addr() | undefined) ->
    addr() | undefined.
dest(#session{from = {_, _} = F}, _Latched, _Remote) -> F;
dest(#session{mode = mux}, {_, _} = L, _Remote) -> L;
dest(#session{mode = mux}, undefined, Remote) -> Remote;
dest(#session{mode = port, remote = {_, _} = R}, _Latched, _Remote) -> R;
dest(#session{mode = port}, {Ip, P}, _Remote) -> {Ip, P + 1};
dest(#session{mode = port}, undefined, {Ip, P}) -> {Ip, P + 1};
dest(#session{}, undefined, undefined) -> undefined.

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
