%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc One recorded stream at a recording server (chappe_sip_siprec_srs):
%% a UDP socket that takes the stream's RTP (RFC 3550), decodes its G.711
%% (PCMU or PCMA, RFC 3551) to 16-bit linear PCM and hands it to its sink:
%% a recording of the store, or a process.
%%
%% One process per stream, under chappe_sip_siprec_rtp_sup, owned by the
%% process that answered the recording session: it stops when the owner
%% exits or on stop/1, and then finishes its store recording. A stream
%% that crashes leaves the store's partial file to its sweep and never
%% touches the session or the other streams.
%%
%% Bounds: the socket is read {active, N} at a time; a process sink gets
%% {chappe_sip_siprec_rtp, Stream, {audio, Pcm}} and frames are dropped
%% while its queue holds max_queue messages (default 500); the store's
%% writer has its own bound (its write/2 says dropped). RTP of another
%% payload type, RTCP and anything that does not parse is dropped.
%%
%% Source: RTP is taken from the recording client only. The stream latches
%% to the first source at the address the client's SDP gave for it (any
%% port, as a NAT may change it; the client sends from where it receives,
%% RFC 4961), and drops every other source from then on. A stream whose SDP
%% gives no usable address, or started with remote => undefined, latches
%% to the first source.
-module(chappe_sip_siprec_rtp).
-behaviour(gen_server).

-export([start/1, start_link/1, stop/1, port/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([decode/2]).

-record(state, {
    sock :: gen_udp:socket(),
    port :: inet:port_number(),
    owner_mon :: reference(),
    sink :: {store, module(), term()} | {pid, pid()},
    max_queue :: pos_integer(),
    label :: binary(),
    %% the client's address as its SDP gave it, and the source latched
    remote :: {inet:ip_address(), inet:port_number()} | undefined,
    latched :: {inet:ip_address(), inet:port_number()} | undefined,
    packets = 0 :: non_neg_integer()
}).
-type state() :: #state{}.

-define(ACTIVE, 50).

%% Args: #{owner := pid(), ip := inet:ip_address(), label := binary(),
%% sink := {store, Module, StoreMeta} | {pid, pid()}, max_queue =>
%% pos_integer(), remote => {inet:ip_address(), inet:port_number()} |
%% undefined}.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Args) ->
    supervisor:start_child(chappe_sip_siprec_rtp_sup, [Args]).

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

-spec init(map()) -> {ok, state()} | {stop, term()}.
init(#{owner := Owner, ip := Ip, label := Label, sink := Sink0} = Args) ->
    case gen_udp:open(0, [binary, {ip, Ip}, {active, ?ACTIVE}]) of
        {ok, Sock} ->
            {ok, Port} = inet:port(Sock),
            case open_sink(Sink0) of
                {ok, Sink} ->
                    {ok, #state{
                        sock = Sock,
                        port = Port,
                        owner_mon = erlang:monitor(process, Owner),
                        sink = Sink,
                        max_queue = maps:get(max_queue, Args, 500),
                        label = Label,
                        remote = maps:get(remote, Args, undefined)
                    }};
                {error, Why} ->
                    gen_udp:close(Sock),
                    {stop, Why}
            end;
        {error, Why} ->
            {stop, Why}
    end.

%% The store seam: a recording of the store module (chappe_audio_store by
%% default, see chappe_sip_siprec_srs:store/1) opened with open/2 and fed
%% 16-bit PCM with write/2, finished with close/2.
open_sink({store, Mod, Meta}) ->
    case Mod:open(Meta, #{owner => self()}) of
        {ok, Rec} -> {ok, {store, Mod, Rec}};
        {error, _} = E -> E
    end;
open_sink({pid, Pid}) when is_pid(Pid) ->
    {ok, {pid, Pid}}.

handle_call(port, _From, #state{port = P} = S) ->
    {reply, P, S};
handle_call(stop, _From, S) ->
    {stop, normal, close_sink(S), S#state{sink = {pid, self()}}}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({udp, Sock, Ip, Port, Packet}, #state{sock = Sock} = S) ->
    case source(Ip, Port, S) of
        {ok, S1} -> {noreply, packet(Packet, S1)};
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

%% the latched source; before it, the first one from the client's address
source(Ip, Port, #state{latched = {Ip, Port}} = S) ->
    {ok, S};
source(_Ip, _Port, #state{latched = {_, _}}) ->
    drop;
source(Ip, Port, #state{remote = {Ip, _}} = S) ->
    {ok, S#state{latched = {Ip, Port}}};
source(Ip, Port, #state{remote = undefined} = S) ->
    {ok, S#state{latched = {Ip, Port}}};
source(_Ip, _Port, _S) ->
    drop.

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
            sink(decode(law(PT), Payload), S#state{
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
sink(Pcm, #state{sink = {pid, Pid}, max_queue = Max} = S) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N < Max ->
            Pid ! {?MODULE, self(), {audio, Pcm}};
        _ ->
            ok
    end,
    S.

%% G.711 (ITU-T G.711, the reference arithmetic) to 16-bit little-endian
%% linear PCM.
-spec decode(ulaw | alaw, binary()) -> binary().
decode(Law, Bin) ->
    <<<<(sample(Law, B)):16/little-signed>> || <<B>> <= Bin>>.

sample(ulaw, U0) ->
    U = bnot U0 band 16#FF,
    Exp = (U bsr 4) band 7,
    T = ((((U band 16#0F) bsl 3) + 16#84) bsl Exp) - 16#84,
    case U band 16#80 of
        0 -> T;
        _ -> -T
    end;
sample(alaw, A0) ->
    A = A0 bxor 16#55,
    T0 = (A band 16#0F) bsl 4,
    T =
        case (A band 16#70) bsr 4 of
            0 -> T0 + 8;
            1 -> T0 + 16#108;
            Seg -> (T0 + 16#108) bsl (Seg - 1)
        end,
    case A band 16#80 of
        0 -> -T;
        _ -> T
    end.
