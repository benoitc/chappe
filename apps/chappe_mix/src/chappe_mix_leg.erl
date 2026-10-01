%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% What one conference leg does on its own: open its sockets (RTP, and
%% RTCP on the next port when it is not multiplexed), filter and take
%% what arrives, send its share of the mix and its RTCP. Anything that
%% looks at other legs stays in chappe_mix_conf.
-module(chappe_mix_leg).

-include("chappe_mix_leg.hrl").

-export([open/3, socks/1, close/1, info/1]).
-export([accepts_rtp/2, accepts_rtcp/2, take/3, pop/1, send/3, advance/2]).
-export([rtcp_send/4]).

-export_type([addr/0]).

-define(FRAME, 160).
-define(ACTIVE, 64).

-type addr() :: {inet:ip_address(), inet:port_number()}.

%% A leg with id Id. Defaults: ip, law and depth of the conference, and
%% the SSRC it starts under.
-spec open(pos_integer(), map(), map()) -> {ok, #leg{}} | {error, term()}.
open(Id, Opts, #{ip := Ip, law := Law, depth := Depth, ssrc := Ssrc}) ->
    Rtcp = maps:get(rtcp, Opts, mux),
    case open_socks(Rtcp, Ip) of
        {ok, Sock, RtcpSock} ->
            {ok, Port} = inet:port(Sock),
            {ok, #leg{
                id = Id,
                sock = Sock,
                port = Port,
                remote = maps:get(remote, Opts, undefined),
                law = maps:get(law, Opts, Law),
                mute = maps:get(mute, Opts, false),
                name = maps:get(name, Opts, undefined),
                jbuf = chappe_mix_jbuf:new(Depth),
                sess = chappe_mix_session:new(Ssrc, erlang:monotonic_time()),
                rtcp = Rtcp,
                rtcp_sock = RtcpSock,
                rtcp_port =
                    case Rtcp of
                        mux -> Port;
                        pair -> Port + 1
                    end
            }};
        {error, _} = Err ->
            Err
    end.

sock_opts(Ip) -> [binary, {ip, Ip}, {active, ?ACTIVE}].

open_socks(mux, Ip) ->
    case gen_udp:open(0, sock_opts(Ip)) of
        {ok, Sock} -> {ok, Sock, undefined};
        {error, _} = Err -> Err
    end;
open_socks(pair, Ip) ->
    open_pair(Ip, 32).

%% RTP on an even port, RTCP on the next one (RFC 3550 11): take ports
%% from the kernel until one is even and its neighbour is free.
open_pair(_Ip, 0) ->
    {error, no_port_pair};
open_pair(Ip, Tries) ->
    case gen_udp:open(0, sock_opts(Ip)) of
        {ok, Sock} ->
            {ok, Port} = inet:port(Sock),
            case
                Port rem 2 =:= 0 andalso gen_udp:open(Port + 1, sock_opts(Ip))
            of
                {ok, RtcpSock} ->
                    {ok, Sock, RtcpSock};
                _ ->
                    gen_udp:close(Sock),
                    open_pair(Ip, Tries - 1)
            end;
        {error, _} = Err ->
            Err
    end.

-spec socks(#leg{}) -> [gen_udp:socket()].
socks(#leg{sock = Sock, rtcp_sock = undefined}) -> [Sock];
socks(#leg{sock = Sock, rtcp_sock = RtcpSock}) -> [Sock, RtcpSock].

-spec close(#leg{}) -> ok.
close(L) ->
    [gen_udp:close(Sock) || Sock <- socks(L)],
    ok.

-spec info(#leg{}) -> map().
info(#leg{} = L) ->
    maps:merge(
        maps:merge(
            chappe_mix_jbuf:stats(L#leg.jbuf),
            chappe_mix_session:info(L#leg.sess)
        ),
        #{
            id => L#leg.id,
            port => L#leg.port,
            remote => L#leg.remote,
            source => L#leg.source,
            law => L#leg.law,
            mute => L#leg.mute,
            tx => L#leg.tx,
            bad => L#leg.bad,
            other_pt => L#leg.other_pt,
            filtered => L#leg.filtered,
            rtcp => L#leg.rtcp,
            rtcp_port => L#leg.rtcp_port
        }
    ).

%% ---- in ----

%% Once a source address is latched, RTP from anywhere else is dropped
%% and counted, except from the far end itself: a symmetric peer (RFC
%% 4961) sends from where it receives, so the far end the caller set wins
%% over a first packet that came another way (a NAT path that changed
%% when rtpengine learnt this leg's address).
-spec accepts_rtp(addr(), #leg{}) -> {boolean(), #leg{}}.
accepts_rtp(From, #leg{source = Source, remote = Remote} = L) when
    Source =/= undefined, Source =/= From, Remote =/= From
->
    {false, L#leg{filtered = L#leg.filtered + 1}};
accepts_rtp(_From, L) ->
    {true, L}.

%% On a shared port RTCP must come from the latched source; on its own
%% port the first sender is latched the same way.
-spec accepts_rtcp(addr(), #leg{}) -> {boolean(), #leg{}}.
accepts_rtcp(From, #leg{rtcp = pair, rtcp_source = undefined} = L) ->
    {true, L#leg{rtcp_source = From}};
accepts_rtcp(From, #leg{rtcp = pair, rtcp_source = From} = L) ->
    {true, L};
accepts_rtcp(From, #leg{rtcp = mux, source = Src} = L) when
    Src =:= undefined; Src =:= From
->
    {true, L};
accepts_rtcp(_From, L) ->
    {false, L#leg{filtered = L#leg.filtered + 1}}.

%% A packet the session took: latch the addresses (the far end moves the
%% source latch to itself), buffer the audio.
-spec take(chappe_mix_rtp:packet(), addr(), #leg{}) -> #leg{}.
take(#{pt := PT, ssrc := Ssrc, seq := Seq, payload := P}, From, L) ->
    L1 = L#leg{
        source = latch_source(L, From),
        remote = latch(L#leg.remote, From)
    },
    case PT =:= law_pt(L#leg.law) of
        true ->
            L1#leg{jbuf = chappe_mix_jbuf:push(Ssrc, Seq, P, L1#leg.jbuf)};
        false ->
            %% telephone-event, comfort noise, anything we do not mix
            L1#leg{other_pt = L1#leg.other_pt + 1}
    end.

latch(undefined, From) -> From;
latch(Addr, _From) -> Addr.

latch_source(#leg{remote = From}, From) -> From;
latch_source(#leg{source = Source}, From) -> latch(Source, From).

law_pt(ulaw) -> 0;
law_pt(alaw) -> 8.

%% ---- out ----

%% This tick's frame from the jitter buffer, decoded, or none.
-spec pop(#leg{}) -> {#leg{}, [integer()] | none}.
pop(#leg{jbuf = J0, law = Law} = L) ->
    case chappe_mix_jbuf:pop(J0) of
        {silence, J} ->
            {L#leg{jbuf = J}, none};
        {Payload, J} ->
            {L#leg{jbuf = J}, fit(chappe_mix_g711:decode_frame(Law, Payload))}
    end.

%% A frame of another size (another ptime) is cut or padded to 20 ms.
fit(Pcm) when length(Pcm) =:= ?FRAME -> Pcm;
fit(Pcm) when length(Pcm) > ?FRAME -> lists:sublist(Pcm, ?FRAME);
fit(Pcm) -> Pcm ++ lists:duplicate(?FRAME - length(Pcm), 0).

%% Send Pcm (none: silence), naming Csrcs, if the far end is known.
-spec send(#leg{}, [integer()] | none, [non_neg_integer()]) -> #leg{}.
send(#leg{remote = undefined} = L, _Pcm, _Csrcs) ->
    L;
send(#leg{remote = {Ip, Port}, law = Law, sess = Sess} = L, Pcm, Csrcs) ->
    Payload =
        case Pcm of
            none -> silence(Law);
            _ -> chappe_mix_g711:encode_frame(Law, Pcm)
        end,
    Hdr = chappe_mix_session:header(Sess),
    Pkt = chappe_mix_rtp:build(Hdr#{
        pt => law_pt(Law),
        %% a packet every tick, no silence suppression: M stays 0
        %% (RFC 3551 4.1)
        marker => false,
        csrcs => Csrcs,
        payload => Payload
    }),
    _ = gen_udp:send(L#leg.sock, Ip, Port, Pkt),
    L#leg{
        tx = L#leg.tx + 1,
        sess = chappe_mix_session:sent(Sess, Csrcs, byte_size(Payload))
    }.

-spec advance(#leg{}, non_neg_integer()) -> #leg{}.
advance(#leg{sess = Sess} = L, Step) ->
    L#leg{sess = chappe_mix_session:advance(Sess, Step)}.

silence(ulaw) -> binary:copy(<<16#FF>>, ?FRAME);
silence(alaw) -> binary:copy(<<16#D5>>, ?FRAME).

%% Send the leg's compound packet (see chappe_mix_session:report/5),
%% Extra last, if it has somewhere to go.
-spec rtcp_send(#leg{}, binary(), fun((boolean()) -> list()), list()) -> #leg{}.
rtcp_send(#leg{sess = Sess} = L, Cname, Chunks, Extra) ->
    case rtcp_dest(L) of
        undefined ->
            L;
        {Ip, Port} ->
            {Pkt, Sess1} = chappe_mix_session:report(
                Sess, Cname, Chunks, Extra, erlang:monotonic_time(microsecond)
            ),
            Sock =
                case L#leg.rtcp_sock of
                    undefined -> L#leg.sock;
                    RtcpSock -> RtcpSock
                end,
            _ = gen_udp:send(Sock, Ip, Port, Pkt),
            L#leg{sess = Sess1}
    end.

%% Reports go where the RTP goes, or to the port after it (RFC 3550 11),
%% not to wherever the far end's RTCP comes from.
rtcp_dest(#leg{rtcp = mux, remote = Remote}) -> Remote;
rtcp_dest(#leg{rtcp = pair, remote = {Ip, Port}}) -> {Ip, Port + 1};
rtcp_dest(#leg{}) -> undefined.
