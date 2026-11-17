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
%% (its write/2 says dropped). RTP of another payload type, RTCP and
%% anything that does not parse is dropped.
%%
%% Source: RTP is taken from the sender only. The stream latches to the
%% first source at the remote address it was given (any port, as a NAT may
%% change it; the sender sends from where it receives, RFC 4961), and
%% drops every other source from then on. A stream started with remote =>
%% undefined latches to the first source.
%%
%% SRTP: started with srtp => Ctx (chappe_audio_srtp:new/1, from the
%% sender's a=crypto line), the stream takes SRTP only (RFC 3711): each
%% packet is authenticated, checked against the replay window and
%% decrypted (chappe_audio_srtp:unprotect/2) before it is decoded, and an
%% SRTCP packet on the same port (RFC 5761) is authenticated and dropped.
%% It latches to its source only once a packet authenticates there, so a
%% forged packet cannot take the stream. A packet that fails (forged,
%% replayed, malformed, past the key's lifetime) is dropped and counted
%% (stats/1); the first failure is logged, then at most one line per
%% 10 s window with the count since the last one. rekey/2 gives the stream
%% the sender's new key. The keys stay in the context and format_status/1
%% leaves them out of every report.
-module(chappe_audio_rtp).
-behaviour(gen_server).

-export([start/1, start_link/1, stop/1, port/1, stats/1, rekey/2]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    format_status/1
]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    sock :: gen_udp:socket(),
    port :: inet:port_number(),
    owner_mon :: reference(),
    sink :: {store, module(), term()} | {pid, pid()},
    tag :: atom(),
    max_queue :: pos_integer(),
    label :: binary(),
    %% the client's address as its SDP gave it, and the source latched
    remote :: {inet:ip_address(), inet:port_number()} | undefined,
    latched :: {inet:ip_address(), inet:port_number()} | undefined,
    packets = 0 :: non_neg_integer(),
    %% SRTP (redacted in reports), the packets it dropped, and the
    %% failures not logged yet with the time of the last log line
    srtp :: chappe_audio_srtp:ctx() | undefined | redacted,
    failed = 0 :: non_neg_integer(),
    replayed = 0 :: non_neg_integer(),
    unlogged = 0 :: non_neg_integer(),
    logged_at :: integer() | undefined
}).
%% one log line per window of failed SRTP packets, in ms
-define(LOG_WINDOW, 10000).
-type state() :: #state{}.

-define(ACTIVE, 50).

%% Args: #{owner := pid(), ip := inet:ip_address(), label := binary(),
%% sink := {store, Module, StoreMeta} | {pid, pid()}, max_queue =>
%% pos_integer(), remote => {inet:ip_address(), inet:port_number()} |
%% undefined, srtp => chappe_audio_srtp:ctx() | undefined, ports =>
%% {Min, Max} | undefined, tag => atom()}.
%%
%% ports: the socket binds a free port of the range, trying each once from
%% a random offset and skipping those in use; none free is {error,
%% no_port}. undefined (the default) binds any port. The stream takes no
%% RTCP: muxed RTCP is dropped, and nothing listens on the port above.
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

%% The packets taken, and the SRTP packets dropped: failed (forged,
%% malformed, an unknown MKI, the key's lifetime past, too many SSRCs) and
%% replayed.
-spec stats(pid()) ->
    #{
        packets := non_neg_integer(),
        failed := non_neg_integer(),
        replayed := non_neg_integer()
    }.
stats(Pid) ->
    gen_server:call(Pid, stats).

%% The client's new key for an SRTP stream (RFC 4568 7.1.4), its
%% rollover counters and replay lists kept; ignored on a plain stream.
-spec rekey(pid(), chappe_audio_srtp:ctx()) -> ok.
rekey(Pid, Ctx) ->
    gen_server:call(Pid, {rekey, Ctx}).

-spec init(map()) -> {ok, state()} | {stop, term()} | {error, no_port}.
init(#{owner := Owner, ip := Ip, label := Label, sink := Sink0} = Args) ->
    case open(Ip, maps:get(ports, Args, undefined)) of
        {ok, Sock} ->
            {ok, Port} = inet:port(Sock),
            case open_sink(Sink0) of
                {ok, Sink} ->
                    {ok, #state{
                        sock = Sock,
                        port = Port,
                        owner_mon = erlang:monitor(process, Owner),
                        sink = Sink,
                        tag = maps:get(tag, Args, ?MODULE),
                        max_queue = maps:get(max_queue, Args, 500),
                        label = Label,
                        remote = maps:get(remote, Args, undefined),
                        srtp = maps:get(srtp, Args, undefined)
                    }};
                {error, Why} ->
                    gen_udp:close(Sock),
                    {stop, Why}
            end;
        {error, no_port} ->
            {error, no_port};
        {error, Why} ->
            {stop, Why}
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
handle_call(stats, _From, #state{packets = P, failed = F, replayed = R} = S) ->
    {reply, #{packets => P, failed => F, replayed => R}, S};
handle_call({rekey, _Ctx}, _From, #state{srtp = undefined} = S) ->
    {reply, ok, S};
handle_call({rekey, Ctx}, _From, #state{srtp = Old} = S) ->
    {reply, ok, S#state{srtp = chappe_audio_srtp:rekey(Old, Ctx)}};
handle_call(stop, _From, S) ->
    {stop, normal, close_sink(S), S#state{sink = {pid, self()}}}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({udp, Sock, Ip, Port, Packet}, #state{sock = Sock} = S) ->
    case source(Ip, Port, S) of
        {ok, From} -> {noreply, take(Packet, From, S)};
        drop -> {noreply, S}
    end;
handle_info({udp_passive, Sock}, #state{sock = Sock} = S) ->
    ok = inet:setopts(Sock, [{active, ?ACTIVE}]),
    {noreply, S};
handle_info({'DOWN', Mon, process, _, _}, #state{owner_mon = Mon} = S) ->
    _ = close_sink(S),
    {stop, normal, S#state{sink = {pid, self()}}};
handle_info(_Msg, S) ->
    {noreply, S}.

terminate(_Why, #state{sock = Sock}) ->
    gen_udp:close(Sock).

%% the SRTP keys never reach a crash report or sys:get_status/1
format_status(#{state := #state{} = S} = Status) ->
    Status#{state := S#state{srtp = redacted}};
format_status(Status) ->
    Status.

%% the latched source; before it, the first one from the client's address
source(Ip, Port, #state{latched = {Ip, Port}}) ->
    {ok, {Ip, Port}};
source(_Ip, _Port, #state{latched = {_, _}}) ->
    drop;
source(Ip, Port, #state{remote = {Ip, _}}) ->
    {ok, {Ip, Port}};
source(Ip, Port, #state{remote = undefined}) ->
    {ok, {Ip, Port}};
source(_Ip, _Port, _S) ->
    drop.

%% A packet from an acceptable source: plain RTP latches to it; SRTP only
%% once the packet authenticates. Muxed SRTCP (RFC 5761 4) is checked and
%% dropped: the recording needs none of it.
take(Packet, From, #state{srtp = undefined} = S) ->
    packet(Packet, S#state{latched = From});
take(Packet, From, #state{srtp = Ctx} = S) ->
    case chappe_audio_srtp:is_rtcp(Packet) of
        true -> srtcp(chappe_audio_srtp:unprotect_rtcp(Packet, Ctx), From, S);
        false -> srtp(chappe_audio_srtp:unprotect(Packet, Ctx), From, S)
    end.

srtp({ok, Rtp, Ctx}, From, S) ->
    packet(Rtp, S#state{srtp = Ctx, latched = From});
srtp({error, Why}, _From, S) ->
    dropped(Why, S).

srtcp({ok, _Rtcp, Ctx}, From, S) ->
    S#state{srtp = Ctx, latched = From};
srtcp({error, Why}, _From, S) ->
    dropped(Why, S).

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
