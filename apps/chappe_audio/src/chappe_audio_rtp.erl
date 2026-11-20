%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc One received RTP stream: a UDP socket that takes the stream's RTP
%% (RFC 3550), decodes its G.711 (PCMU or PCMA, RFC 3551) to 16-bit linear
%% PCM (chappe_audio_pcm) and hands it to its sink: a recording of the
%% store, or a process. A SIPREC recording server (chappe_sip_siprec_srs)
%% runs one per recorded stream; start one with chappe_audio:rtp_receiver/1.
%%
%% One process per stream, under chappe_audio_rtp_sup, owned by the
%% process that started it: it stops when the owner exits or on stop/1,
%% and then finishes its store recording. A stream that crashes leaves the
%% store's partial file to its sweep and never touches its owner or the
%% other streams.
%%
%% Bounds: the socket is read {active, N} at a time; a process sink gets
%% {Tag, Stream, {audio, Pcm}} (Tag is the tag option, default
%% chappe_audio_rtp) and frames are dropped while its queue holds
%% max_queue messages (default 500); the store's writer has its own bound
%% (its write/2 says dropped). RTP of another payload type and anything
%% that does not parse is dropped.
%%
%% Source: RTP is taken from the sender only. The stream latches to the
%% first source at the remote address it was given (any port, as a NAT may
%% change it; the sender sends from where it receives, RFC 4961), and
%% drops every other source from then on. A stream started with remote =>
%% undefined latches to the first source. When the sender moves
%% (remote/2), the stream learns again the same way from the new address,
%% any port, and drops the source it had latched for a grace window of
%% 1 s, so a late packet from the old source cannot take it. Past the
%% window, with no new source latched, the old source may latch again: a
%% sender whose SDP port alone changed, still sending from where it did
%% (its sending port need not be its SDP port), is heard again.
%%
%% SRTP: started with srtp => Ctx (chappe_audio_srtp:new/1, from the
%% sender's a=crypto line), the stream takes SRTP only (RFC 3711): each
%% packet is authenticated, checked against the replay window and
%% decrypted (chappe_audio_srtp:unprotect/2) before it is decoded, and an
%% SRTCP packet is authenticated before it is read. It latches to its
%% source only once a packet authenticates there, so a forged packet
%% cannot take the stream. A packet that fails (forged, replayed,
%% malformed, past the key's lifetime) is dropped and counted (stats/1);
%% the first failure is logged, then at most one line per 10 s window with
%% the count since the last one. rekey/2,3 give the stream new keys. The
%% keys stay in the contexts and format_status/1 leaves them out of every
%% report.
%%
%% RTCP (RFC 3550 6, RFC 7866 8.1.1): with rtcp => none (the default) the
%% stream takes no RTCP: muxed RTCP is dropped (SRTCP authenticated, then
%% dropped) and nothing listens on the port above. With rtcp => mux it
%% takes RTCP on its RTP port (RFC 5761 4: the second octet 192 to 223);
%% with rtcp => port its RTP port is even and it takes RTCP on the odd one
%% above (RFC 3550 11), from its source's address only. It then keeps each
%% source's reception statistics (chappe_audio_rtcp: A.1, A.3, A.8; at
%% most 31 sources, one RR's worth), reads SR, SDES and BYE, and sends a
%% receiver report on the interval of 6.2 (a 5 s minimum, 2.5 s for the
%% first, times 0.5 to 1.5): an RR with one block per source heard since
%% the last one, then SDES with its CNAME. It sends from the socket it
%% takes RTCP on (symmetric RTCP, RFC 7866 8.1.8), to where the source's
%% RTCP came from, else to its RTP address (mux) or the port above it
%% (port), else to remote. Stopping after a report sends a BYE. An SRTP
%% stream protects its reports with srtcp_out, a context of its own key
%% (the one its SDP answer gave, RFC 4568); without one it sends none.
-module(chappe_audio_rtp).
-behaviour(gen_server).

-export([start/1, start_link/1, stop/1, port/1, rtcp_port/1, stats/1]).
-export([rekey/2, rekey/3, remote/2]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    format_status/1
]).

-include_lib("kernel/include/logger.hrl").

-type addr() :: {inet:ip_address(), inet:port_number()}.

-record(state, {
    sock :: gen_udp:socket(),
    port :: inet:port_number(),
    owner_mon :: reference(),
    sink :: {store, module(), term()} | {pid, pid()},
    tag :: atom(),
    max_queue :: pos_integer(),
    label :: binary(),
    %% the client's address as its SDP gave it, the source latched, and
    %% the one latched before the sender moved (remote/2), not taken again
    %% until the monotonic time (ms) it holds
    remote :: addr() | undefined,
    latched :: addr() | undefined,
    moved_from :: {addr(), integer()} | undefined,
    packets = 0 :: non_neg_integer(),
    %% SRTP (redacted in reports), the packets it dropped, and the
    %% failures not logged yet with the time of the last log line
    srtp :: chappe_audio_srtp:ctx() | undefined | redacted,
    failed = 0 :: non_neg_integer(),
    replayed = 0 :: non_neg_integer(),
    unlogged = 0 :: non_neg_integer(),
    logged_at :: integer() | undefined,
    %% RTCP (undefined with rtcp => none), the socket above the RTP port
    %% (rtcp => port), and the receiver's own key for its SRTCP (redacted
    %% in reports)
    rtcp :: chappe_audio_rtp_rtcp:session() | undefined,
    rtcp_sock :: gen_udp:socket() | undefined,
    srtcp_out :: chappe_audio_srtp:ctx() | undefined | redacted
}).
%% one log line per window of failed SRTP packets, in ms
-define(LOG_WINDOW, 10000).
%% how long the source latched before a move is dropped, in ms
-define(MOVE_GRACE, 1000).
-type state() :: #state{}.

-define(ACTIVE, 50).
%% tries at an even port and the one above it, with no range
-define(PAIR_TRIES, 32).

%% Args: #{owner := pid(), ip := inet:ip_address(), label := binary(),
%% sink := {store, Module, StoreMeta} | {pid, pid()}, max_queue =>
%% pos_integer(), remote => {inet:ip_address(), inet:port_number()} |
%% undefined, srtp => chappe_audio_srtp:ctx() | undefined, ports =>
%% {Min, Max} | undefined, tag => atom(), rtcp => none | mux | port,
%% rtcp_remote => {inet:ip_address(), inet:port_number()} | undefined,
%% cname => binary(), srtcp_out => chappe_audio_srtp:ctx() | undefined}.
%%
%% ports: the socket binds a free port of the range, trying each once from
%% a random offset and skipping those in use; with rtcp => port an even
%% port whose next one is free too; none free is {error, no_port}.
%% undefined (the default) binds any port. A bad rtcp is {error,
%% {bad_option, rtcp}}.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Args) ->
    supervisor:start_child(chappe_audio_rtp_sup, [Args]).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% Finish the stream: the store recording is closed, its id returned.
-spec stop(pid()) -> {ok, binary()} | ok.
stop(Pid) ->
    try
        gen_server:call(Pid, stop, 10000)
    catch
        exit:_ -> ok
    end.

%% The port the stream is to be sent to.
-spec port(pid()) -> inet:port_number().
port(Pid) ->
    gen_server:call(Pid, port).

%% The port its RTCP is to be sent to: the RTP port with rtcp => mux, the
%% one above with rtcp => port, undefined with rtcp => none.
-spec rtcp_port(pid()) -> inet:port_number() | undefined.
rtcp_port(Pid) ->
    gen_server:call(Pid, rtcp_port).

%% The packets taken, and the SRTP packets dropped: failed (forged,
%% malformed, an unknown MKI, the key's lifetime past, too many SSRCs) and
%% replayed. With RTCP on, also the compound packets sent and taken, and
%% each source's statistics (chappe_audio_rtcp:src_info/1).
-spec stats(pid()) ->
    #{
        packets := non_neg_integer(),
        failed := non_neg_integer(),
        replayed := non_neg_integer(),
        rtcp_sent => non_neg_integer(),
        rtcp_received => non_neg_integer(),
        sources => [map()]
    }.
stats(Pid) ->
    gen_server:call(Pid, stats).

%% The client's new key for an SRTP stream (RFC 4568 7.1.4), its
%% rollover counters and replay lists kept; ignored on a plain stream.
-spec rekey(pid(), chappe_audio_srtp:ctx()) -> ok.
rekey(Pid, Ctx) ->
    gen_server:call(Pid, {rekey, Ctx}).

%% rekey/2, and the receiver's own new key for its SRTCP (the one the new
%% answer gives), its SRTCP index kept (RFC 3711 3.4).
-spec rekey(pid(), chappe_audio_srtp:ctx(), chappe_audio_srtp:ctx()) -> ok.
rekey(Pid, Ctx, Out) ->
    gen_server:call(Pid, {rekey, Ctx, Out}).

%% The sender moved (a new address or port in its SDP): the stream learns
%% its source again as at its start, the first one at the new address on
%% any port (a NAT may change it; undefined: the first source), and drops
%% a late packet from exactly the source it had latched (or, with none
%% latched since the last move, the one it dropped then) for 1 s. The
%% SRTP context, its replay lists and the counters carry on.
-spec remote(pid(), addr() | undefined) -> ok.
remote(Pid, Remote) ->
    gen_server:call(Pid, {remote, Remote}).

-spec init(map()) -> {ok, state()} | {stop, term()} | {error, no_port}.
init(#{owner := Owner, ip := Ip, label := Label, sink := Sink0} = Args) ->
    Mode = maps:get(rtcp, Args, none),
    case
        is_mode(Mode) andalso open(Ip, maps:get(ports, Args, undefined), Mode)
    of
        false ->
            {stop, {bad_option, rtcp}};
        {ok, Sock, RtcpSock} ->
            {ok, Port} = inet:port(Sock),
            case open_sink(Sink0) of
                {ok, Sink} ->
                    S = #state{
                        sock = Sock,
                        port = Port,
                        owner_mon = erlang:monitor(process, Owner),
                        sink = Sink,
                        tag = maps:get(tag, Args, ?MODULE),
                        max_queue = maps:get(max_queue, Args, 500),
                        label = Label,
                        remote = maps:get(remote, Args, undefined),
                        srtp = maps:get(srtp, Args, undefined),
                        rtcp = session(Mode, Args),
                        rtcp_sock = RtcpSock,
                        srtcp_out = maps:get(srtcp_out, Args, undefined)
                    },
                    {ok, schedule(S)};
                {error, Why} ->
                    close(Sock, RtcpSock),
                    {stop, Why}
            end;
        {error, no_port} ->
            {error, no_port};
        {error, Why} ->
            {stop, Why}
    end.

is_mode(none) -> true;
is_mode(mux) -> true;
is_mode(port) -> true;
is_mode(_) -> false.

session(none, _Args) ->
    undefined;
session(Mode, Args) ->
    chappe_audio_rtp_rtcp:new(
        Mode,
        maps:get(rtcp_remote, Args, undefined),
        maps:get(cname, Args, chappe_audio_rtcp:cname())
    ).

%% the RTCP mode: none without a session
mode(#state{rtcp = undefined}) -> none;
mode(#state{rtcp = R}) -> chappe_audio_rtp_rtcp:mode(R).

close(Sock, undefined) ->
    gen_udp:close(Sock);
close(Sock, RtcpSock) ->
    gen_udp:close(Sock),
    gen_udp:close(RtcpSock).

%% the RTP socket, and with rtcp => port the RTCP one on the port above
open(Ip, Ports, port) ->
    open_pair(Ip, Ports);
open(Ip, Ports, _Rtcp) ->
    case open(Ip, Ports) of
        {ok, Sock} -> {ok, Sock, undefined};
        Err -> Err
    end.

%% a socket on any port, or on the first free port of the range from a
%% random offset
open(Ip, undefined) ->
    udp(Ip, 0);
open(Ip, {Min, Max}) ->
    N = Max - Min + 1,
    open(Ip, Min, N, rand:uniform(N) - 1, N).

open(_Ip, _Min, _N, _At, 0) ->
    {error, no_port};
open(Ip, Min, N, At, Left) ->
    case udp(Ip, Min + At) of
        {error, eaddrinuse} -> open(Ip, Min, N, (At + 1) rem N, Left - 1);
        Other -> Other
    end.

%% RFC 3550 11: RTP on an even port, RTCP on the next one
open_pair(Ip, undefined) ->
    any_pair(Ip, ?PAIR_TRIES);
open_pair(Ip, {Min, Max}) ->
    First = Min + (Min band 1),
    case (Max - 1 - First) div 2 + 1 of
        N when N > 0, First + 1 =< Max ->
            pair(Ip, First, N, rand:uniform(N) - 1, N);
        _ ->
            {error, no_port}
    end.

any_pair(_Ip, 0) ->
    {error, no_port};
any_pair(Ip, Tries) ->
    case udp(Ip, 0) of
        {ok, Sock} ->
            {ok, P} = inet:port(Sock),
            case P rem 2 =:= 0 andalso P < 65535 andalso udp(Ip, P + 1) of
                {ok, RtcpSock} ->
                    {ok, Sock, RtcpSock};
                _ ->
                    gen_udp:close(Sock),
                    any_pair(Ip, Tries - 1)
            end;
        Err ->
            Err
    end.

pair(_Ip, _First, _N, _At, 0) ->
    {error, no_port};
pair(Ip, First, N, At, Left) ->
    P = First + 2 * At,
    Next = fun() -> pair(Ip, First, N, (At + 1) rem N, Left - 1) end,
    case udp(Ip, P) of
        {ok, Sock} ->
            case udp(Ip, P + 1) of
                {ok, RtcpSock} ->
                    {ok, Sock, RtcpSock};
                {error, eaddrinuse} ->
                    gen_udp:close(Sock),
                    Next();
                Err ->
                    gen_udp:close(Sock),
                    Err
            end;
        {error, eaddrinuse} ->
            Next();
        Err ->
            Err
    end.

udp(Ip, Port) ->
    gen_udp:open(Port, [binary, {ip, Ip}, {active, ?ACTIVE}]).

%% The store seam: a recording of the store module (chappe_audio_store or
%% any module with the same open/2, write/2 and close/2) opened with
%% open/2, fed 16-bit PCM with write/2 and finished with close/2.
open_sink({store, Mod, Meta}) ->
    case Mod:open(Meta, #{owner => self()}) of
        {ok, Rec} -> {ok, {store, Mod, Rec}};
        {error, _} = E -> E
    end;
open_sink({pid, Pid}) when is_pid(Pid) ->
    {ok, {pid, Pid}}.

handle_call(port, _From, #state{port = P} = S) ->
    {reply, P, S};
handle_call(rtcp_port, _From, S) ->
    {reply, rtcp_port_of(mode(S), S), S};
handle_call(stats, _From, S) ->
    {reply, stats_of(S), S};
handle_call({rekey, _Ctx}, _From, #state{srtp = undefined} = S) ->
    {reply, ok, S};
handle_call({rekey, Ctx}, _From, #state{srtp = Old} = S) ->
    {reply, ok, S#state{srtp = chappe_audio_srtp:rekey(Old, Ctx)}};
handle_call({rekey, _Ctx, _Out}, _From, #state{srtp = undefined} = S) ->
    {reply, ok, S};
handle_call({rekey, Ctx, Out}, _From, #state{srtp = Old} = S) ->
    {reply, ok, S#state{
        srtp = chappe_audio_srtp:rekey(Old, Ctx),
        srtcp_out = rekey_out(S#state.srtcp_out, Out)
    }};
handle_call({remote, Remote}, _From, S) ->
    {reply, ok, S#state{
        remote = Remote, latched = undefined, moved_from = moved_from(S)
    }};
handle_call(stop, _From, S) ->
    {stop, normal, close_sink(S), S#state{sink = {pid, self()}}}.

rekey_out(undefined, Out) -> Out;
rekey_out(Old, Out) -> chappe_audio_srtp:rekey(Old, Out).

rtcp_port_of(none, _S) -> undefined;
rtcp_port_of(mux, #state{port = P}) -> P;
rtcp_port_of(port, #state{port = P}) -> P + 1.

stats_of(#state{packets = P, failed = F, replayed = R, rtcp = Rtcp}) ->
    Base = #{packets => P, failed => F, replayed => R},
    case Rtcp of
        undefined -> Base;
        _ -> maps:merge(Base, chappe_audio_rtp_rtcp:stats(Rtcp))
    end.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({udp, Sock, Ip, Port, Packet}, #state{sock = Sock} = S) ->
    case source(Ip, Port, S) of
        {ok, From} -> {noreply, take(mode(S), Packet, From, S)};
        drop -> {noreply, S}
    end;
handle_info({udp, Sock, Ip, Port, Packet}, #state{rtcp_sock = Sock} = S) ->
    case rtcp_source(Ip, S) of
        true -> {noreply, rtcp_port_in(Packet, {Ip, Port}, S)};
        false -> {noreply, S}
    end;
handle_info({udp_passive, Sock}, #state{sock = Sock} = S) ->
    ok = inet:setopts(Sock, [{active, ?ACTIVE}]),
    {noreply, S};
handle_info({udp_passive, Sock}, #state{rtcp_sock = Sock} = S) ->
    ok = inet:setopts(Sock, [{active, ?ACTIVE}]),
    {noreply, S};
handle_info(rtcp_report, S) ->
    {noreply, schedule(report(false, S))};
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = S) ->
    _ = close_sink(S),
    {stop, normal, S#state{sink = {pid, self()}}};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Why, #state{sock = Sock, rtcp_sock = RtcpSock} = S) ->
    _ = bye(S),
    close(Sock, RtcpSock).

%% the SRTP keys never reach a crash report or sys:get_status/1
format_status(#{state := #state{} = S} = Status) ->
    Status#{state := S#state{srtp = redacted, srtcp_out = redacted}};
format_status(Status) ->
    Status.

%% the source a move blocks: the one latched, else the one the last move
%% blocked; for a new grace window
moved_from(#state{latched = undefined, moved_from = undefined}) ->
    undefined;
moved_from(#state{latched = undefined, moved_from = {Old, _Until}}) ->
    {Old, erlang:monotonic_time(millisecond) + ?MOVE_GRACE};
moved_from(#state{latched = Old}) ->
    {Old, erlang:monotonic_time(millisecond) + ?MOVE_GRACE}.

%% the latched source; before it, the first one from the client's address,
%% the one latched before the sender moved only once its window is over
source(Ip, Port, #state{latched = {Ip, Port}}) ->
    {ok, {Ip, Port}};
source(_Ip, _Port, #state{latched = {_, _}}) ->
    drop;
source(Ip, Port, #state{moved_from = {{Ip, Port}, Until}} = S) ->
    case erlang:monotonic_time(millisecond) < Until of
        true -> drop;
        false -> learn(Ip, Port, S)
    end;
source(Ip, Port, S) ->
    learn(Ip, Port, S).

%% the first source from the client's address, any port, or any source
learn(Ip, Port, #state{remote = {Ip, _}}) ->
    {ok, {Ip, Port}};
learn(Ip, Port, #state{remote = undefined}) ->
    {ok, {Ip, Port}};
learn(_Ip, _Port, _S) ->
    drop.

%% RTCP on the port above: from the source's address only
rtcp_source(Ip, #state{latched = {Ip, _}}) -> true;
rtcp_source(_Ip, #state{latched = {_, _}}) -> false;
rtcp_source(Ip, #state{remote = {Ip, _}}) -> true;
rtcp_source(_Ip, #state{remote = undefined}) -> true;
rtcp_source(_Ip, _S) -> false.

%% A packet from an acceptable source: plain RTP latches to it; SRTP only
%% once the packet authenticates. With rtcp => mux, RTCP on the port
%% (RFC 5761 4) is read; otherwise it is dropped, SRTCP once it
%% authenticates.
take(Mode, Packet, From, #state{srtp = undefined} = S) ->
    case Mode =:= mux andalso chappe_audio_rtcp:is_rtcp(Packet) of
        true -> rtcp_in(Packet, From, S);
        false -> rtp(Packet, S#state{latched = From})
    end;
take(Mode, Packet, From, #state{srtp = Ctx} = S) ->
    case chappe_audio_rtcp:is_rtcp(Packet) of
        true ->
            Rtcp = chappe_audio_srtp:unprotect_rtcp(Packet, Ctx),
            srtcp(Mode, Rtcp, From, S);
        false ->
            srtp(chappe_audio_srtp:unprotect(Packet, Ctx), From, S)
    end.

srtp({ok, Rtp, Ctx}, From, S) ->
    rtp(Rtp, S#state{srtp = Ctx, latched = From});
srtp({error, Why}, _From, S) ->
    dropped(Why, S).

srtcp(mux, {ok, Rtcp, Ctx}, From, S) ->
    rtcp_in(Rtcp, From, S#state{srtp = Ctx, latched = From});
srtcp(_Mode, {ok, _Rtcp, Ctx}, From, S) ->
    S#state{srtp = Ctx, latched = From};
srtcp(_Mode, {error, Why}, _From, S) ->
    dropped(Why, S).

%% a packet on the RTCP port: SRTCP once it authenticates, or RTCP
rtcp_port_in(Packet, From, #state{srtp = undefined} = S) ->
    rtcp_in(Packet, From, S);
rtcp_port_in(Packet, From, #state{srtp = Ctx} = S) ->
    case chappe_audio_srtp:unprotect_rtcp(Packet, Ctx) of
        {ok, Rtcp, Ctx1} -> rtcp_in(Rtcp, From, S#state{srtp = Ctx1});
        {error, Why} -> dropped(Why, S)
    end.

rtcp_in(Packet, From, #state{rtcp = R} = S) ->
    S#state{rtcp = chappe_audio_rtp_rtcp:input(R, Packet, From)}.

%% an RTP packet: in its source's statistics with RTCP on, then decoded
rtp(Rtp, #state{rtcp = undefined} = S) ->
    packet(Rtp, S);
rtp(Rtp, #state{rtcp = R} = S) ->
    packet(Rtp, S#state{rtcp = chappe_audio_rtp_rtcp:rtp(R, Rtp)}).

%% RFC 3711 3.3 step 5: a replayed or forged packet is discarded and the
%% event SHOULD be logged; once per window, so a flood costs one line
dropped(replay, #state{replayed = R, unlogged = U} = S) ->
    log_drops(S#state{replayed = R + 1, unlogged = U + 1});
dropped(_Why, #state{failed = F, unlogged = U} = S) ->
    log_drops(S#state{failed = F + 1, unlogged = U + 1}).

log_drops(#state{logged_at = At, unlogged = U} = S) ->
    Now = erlang:monotonic_time(millisecond),
    case At =:= undefined orelse Now - At >= ?LOG_WINDOW of
        true ->
            ?LOG_WARNING(#{
                what => siprec_srtp_dropped,
                label => S#state.label,
                dropped => U,
                failed => S#state.failed,
                replayed => S#state.replayed
            }),
            S#state{unlogged = 0, logged_at = Now};
        false ->
            S
    end.

close_sink(#state{sink = {store, Mod, Rec}, packets = N}) ->
    Mod:close(Rec, #{packets => N});
close_sink(#state{sink = {pid, _}}) ->
    ok.

%% ---- RTCP reports ----

%% the next report on the interval of RFC 3550 6.2
schedule(#state{rtcp = undefined} = S) ->
    S;
schedule(#state{rtcp = R} = S) ->
    _ = erlang:send_after(
        chappe_audio_rtp_rtcp:interval(R), self(), rtcp_report
    ),
    S.

%% RFC 3550 6.3.7: leaving, a BYE, only after a report went out
bye(#state{rtcp = undefined}) ->
    ok;
bye(#state{rtcp = R} = S) ->
    case chappe_audio_rtp_rtcp:has_sent(R) of
        true ->
            _ = report(true, S),
            ok;
        false ->
            ok
    end.

%% a report to where the source's RTCP goes, if it is known, from the
%% socket RTCP comes in on (symmetric RTCP, RFC 7866 8.1.8)
report(Bye, #state{rtcp = R, latched = L, remote = Remote} = S) ->
    case chappe_audio_rtp_rtcp:dest(R, L, Remote) of
        undefined ->
            S;
        {Ip, Port} ->
            {Bin, R1} = chappe_audio_rtp_rtcp:report(R, Bye),
            case protect(Bin, S#state{rtcp = R1}) of
                {ok, Out, S1} ->
                    case send(rtcp_out_sock(S1), Ip, Port, Out) of
                        ok ->
                            R2 = chappe_audio_rtp_rtcp:sent(R1, byte_size(Out)),
                            S1#state{rtcp = R2};
                        {error, _} ->
                            S1
                    end;
                skip ->
                    S
            end
    end.

%% RFC 3711 3.4: on an SRTP stream, SRTCP with the receiver's own key, or
%% nothing
protect(Bin, #state{srtp = undefined} = S) ->
    {ok, Bin, S};
protect(_Bin, #state{srtcp_out = undefined}) ->
    skip;
protect(Bin, #state{srtcp_out = Ctx} = S) ->
    case chappe_audio_srtp:protect_rtcp(Bin, Ctx) of
        {ok, Out, Ctx1} -> {ok, Out, S#state{srtcp_out = Ctx1}};
        {error, _} -> skip
    end.

%% a report that cannot go (a bad address, the network down) is lost,
%% never the receiver
send(Sock, Ip, Port, Bin) ->
    try
        gen_udp:send(Sock, Ip, Port, Bin)
    catch
        error:Why -> {error, Why}
    end.

rtcp_out_sock(#state{rtcp_sock = undefined, sock = Sock}) -> Sock;
rtcp_out_sock(#state{rtcp_sock = Sock}) -> Sock.

%% ---- RTP ----

%% RTP v2 (RFC 3550 5.1) with PCMU (0) or PCMA (8): the payload past the
%% CSRCs and any header extension, padding removed
packet(
    <<2:2, P:1, X:1, CC:4, _M:1, PT:7, _Seq:16, _Ts:32, _Ssrc:32, Rest/binary>>,
    S
) when
    PT =:= 0; PT =:= 8
->
    case payload(P, X, CC, Rest) of
        {ok, Payload} ->
            sink(chappe_audio_pcm:decode(law(PT), Payload), S#state{
                packets = S#state.packets + 1
            });
        error ->
            S
    end;
packet(_Other, S) ->
    S.

law(0) -> ulaw;
law(8) -> alaw.

payload(P, X, CC, Bin) ->
    Skip = CC * 4,
    case Bin of
        <<_:Skip/binary, Rest/binary>> -> extension(P, X, Rest);
        _ -> error
    end.

extension(P, 1, <<_:16, Len:16, Rest/binary>>) ->
    Skip = Len * 4,
    case Rest of
        <<_:Skip/binary, Body/binary>> -> padding(P, Body);
        _ -> error
    end;
extension(_P, 1, _) ->
    error;
extension(P, 0, Body) ->
    padding(P, Body).

padding(0, Body) ->
    {ok, Body};
padding(1, <<>>) ->
    error;
padding(1, Body) ->
    case binary:last(Body) of
        N when N =< byte_size(Body) ->
            {ok, binary:part(Body, 0, byte_size(Body) - N)};
        _ ->
            error
    end.

sink(Pcm, #state{sink = {store, Mod, Rec}} = S) ->
    _ = Mod:write(Rec, Pcm),
    S;
sink(Pcm, #state{sink = {pid, Pid}, max_queue = Max, tag = Tag} = S) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N < Max ->
            Pid ! {Tag, self(), {audio, Pcm}};
        _ ->
            ok
    end,
    S.
