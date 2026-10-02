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
-export([is_event/2, event_codes/1, takes_events/2, send_event/5]).
-export([set_remote/2]).
-export([speaks/1, hears/1, mute_direction/2, hears_from/2]).
-export([rtcp_send/4]).

-export_type([addr/0]).

-define(FRAME, 160).
-define(ACTIVE, 64).

-type addr() :: {inet:ip_address(), inet:port_number()}.

%% A leg with id Id. Defaults: ip, law and depth of the conference, and
%% the SSRC it starts under.
-spec open(pos_integer(), map(), map()) -> {ok, #leg{}} | {error, term()}.
open(Id, Opts, #{ip := Ip, law := Law, depth := Depth, ssrc := Ssrc} = Dfl) ->
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
                ptime = maps:get(ptime, Opts, 20),
                direction = initial_direction(Opts),
                injected = maps:get(injected, Opts, false),
                dtmf_pt = maps:get(dtmf_pt, Opts, undefined),
                %% no events list from the far end: the DTMF digits only
                %% (RFC 4733 2.5.1.1)
                dtmf_events = maps:get(dtmf_events, Opts, lists:seq(0, 15)),
                name = maps:get(name, Opts, undefined),
                jbuf = chappe_mix_jbuf:new(
                    Depth,
                    silence_code(maps:get(law, Opts, Law)),
                    maps:get(prefill_shrink, Dfl, false)
                ),
                sess = chappe_mix_session:new(Ssrc, erlang:monotonic_time()),
                rtcp = Rtcp,
                rtcp_sock = RtcpSock,
                rtcp_remote = maps:get(rtcp_remote, Opts, undefined),
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
            ptime => L#leg.ptime,
            mute => not speaks(L),
            direction => L#leg.direction,
            injected => L#leg.injected,
            nohear => L#leg.nohear,
            tx => L#leg.tx,
            bad => L#leg.bad,
            other_pt => L#leg.other_pt,
            dtmf_pt => L#leg.dtmf_pt,
            dtmf_events => L#leg.dtmf_events,
            events => L#leg.events,
            events_sent => L#leg.events_sent,
            filtered => L#leg.filtered,
            rtcp => L#leg.rtcp,
            rtcp_port => L#leg.rtcp_port,
            rtcp_remote => L#leg.rtcp_remote,
            in_csrcs => L#leg.in_csrcs
        }
    ).

%% A new far end (and the leg options that come with it): the source
%% latches are reset, so its first packet is taken.
-spec set_remote(map(), #leg{}) -> #leg{}.
set_remote(#{remote := Remote} = Opts, L) ->
    L#leg{
        remote = Remote,
        source = undefined,
        rtcp_source = undefined,
        %% a new far end: an RTCP address only if it comes with it
        rtcp_remote = maps:get(rtcp_remote, Opts, undefined),
        dtmf_pt = maps:get(dtmf_pt, Opts, L#leg.dtmf_pt),
        dtmf_events = maps:get(dtmf_events, Opts, L#leg.dtmf_events)
    }.

%% Whether the room takes this leg's audio into the mix.
-spec speaks(#leg{}) -> boolean().
speaks(#leg{direction = D}) -> D =:= sendrecv orelse D =:= recvonly.

%% Whether the room sends this leg anything.
-spec hears(#leg{}) -> boolean().
hears(#leg{direction = D}) -> D =:= sendrecv orelse D =:= sendonly.

%% Whether this leg hears leg Id: it hears the room, Id is not itself and
%% it was not told not to.
-spec hears_from(pos_integer(), #leg{}) -> boolean().
hears_from(Id, #leg{id = Mine, nohear = No} = L) ->
    Id =/= Mine andalso hears(L) andalso not lists:member(Id, No).

%% The direction a leg opens with: mute => true mutes it on top.
initial_direction(Opts) ->
    D = maps:get(direction, Opts, sendrecv),
    case maps:get(mute, Opts, false) of
        true -> mute_direction(D, true);
        false -> D
    end.

%% Muting is the room no longer taking from the leg; unmuting gives that
%% back. What the room sends the leg does not change.
-spec mute_direction(sendrecv | sendonly | recvonly | inactive, boolean()) ->
    sendrecv | sendonly | recvonly | inactive.
mute_direction(sendrecv, true) -> sendonly;
mute_direction(recvonly, true) -> inactive;
mute_direction(sendonly, false) -> sendrecv;
mute_direction(inactive, false) -> recvonly;
mute_direction(D, _) -> D.

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
%% source latch to itself), buffer the audio by its timestamp, whatever
%% its size.
-spec take(chappe_mix_rtp:packet(), addr(), #leg{}) -> #leg{}.
take(
    #{pt := PT, ssrc := Ssrc, seq := Seq, ts := Ts, payload := P} = Pkt, From, L
) ->
    L1 = L#leg{
        source = latch_source(L, From),
        remote = latch(L#leg.remote, From)
    },
    case PT =:= law_pt(L#leg.law) of
        true ->
            L1#leg{
                jbuf = chappe_mix_jbuf:push(Ssrc, Seq, Ts, P, L1#leg.jbuf),
                in_csrcs = maps:get(csrcs, Pkt, [])
            };
        false when PT =:= L#leg.dtmf_pt ->
            %% telephone-event: never mixed, the conference forwards it
            L1#leg{events = L1#leg.events + 1};
        false ->
            %% comfort noise, anything else we do not mix
            L1#leg{other_pt = L1#leg.other_pt + 1}
    end.

%% A telephone-event packet of this leg's (RFC 4733).
-spec is_event(chappe_mix_rtp:packet(), #leg{}) -> boolean().
is_event(#{pt := PT}, #leg{dtmf_pt = PT}) -> PT =/= undefined;
is_event(_P, _L) -> false.

%% The event codes in an event payload: one per 4-octet report.
-spec event_codes(binary()) -> [0..255].
event_codes(<<E, _:3/binary, Rest/binary>>) -> [E | event_codes(Rest)];
event_codes(_) -> [].

%% Whether this leg takes events with these codes: it negotiated the
%% payload, lists every code, and has a far end.
-spec takes_events([0..255], #leg{}) -> boolean().
takes_events(_Codes, #leg{dtmf_pt = undefined}) ->
    false;
takes_events(_Codes, #leg{remote = undefined}) ->
    false;
takes_events(Codes, #leg{dtmf_events = Events}) ->
    Codes =/= [] andalso
        lists:all(fun(C) -> lists:member(C, Events) end, Codes).

latch(undefined, From) -> From;
latch(Addr, _From) -> Addr.

latch_source(#leg{remote = From}, From) -> From;
latch_source(#leg{source = Source}, From) -> latch(Source, From).

law_pt(ulaw) -> 0;
law_pt(alaw) -> 8.

%% ---- out ----

%% This tick's 20 ms frame from the jitter buffer, as code words, or
%% none. The buffer makes 20 ms frames out of packets of any size.
-spec pop(#leg{}) -> {#leg{}, binary() | none}.
pop(#leg{jbuf = J0} = L) ->
    case chappe_mix_jbuf:pop(J0) of
        {silence, J} -> {L#leg{jbuf = J}, none};
        {Payload, J} -> {L#leg{jbuf = J}, Payload}
    end.

%% Send a mixed frame, already encoded in the leg's law (none: silence),
%% naming Csrcs, if the far end is known. The conference does not call it
%% for a leg the room sends nothing (see hears/1).
-spec send(#leg{}, binary() | none, [non_neg_integer()]) -> #leg{}.
send(#leg{remote = undefined} = L, _Mixed, _Csrcs) ->
    L;
send(#leg{remote = {Ip, Port}, law = Law, sess = Sess} = L, Mixed, Csrcs) ->
    Payload =
        case Mixed of
            none -> silence(Law);
            _ -> Mixed
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

%% Forward one telephone-event packet on this leg: its payload as it
%% came, on this leg's payload type, timestamp Ts on this leg's clock,
%% the next sequence number of this leg's stream (RFC 4733 2.1).
-spec send_event(#leg{}, 0..16#FFFFFFFF, boolean(), binary(), [
    non_neg_integer()
]) -> #leg{}.
send_event(
    #leg{remote = {Ip, Port}, sess = Sess} = L, Ts, Marker, Payload, Csrcs
) ->
    Hdr = chappe_mix_session:header(Sess),
    Pkt = chappe_mix_rtp:build(Hdr#{
        ts => Ts,
        pt => L#leg.dtmf_pt,
        marker => Marker,
        csrcs => Csrcs,
        payload => Payload
    }),
    _ = gen_udp:send(L#leg.sock, Ip, Port, Pkt),
    L#leg{
        events_sent = L#leg.events_sent + 1,
        sess = chappe_mix_session:sent_event(Sess, byte_size(Payload))
    }.

-spec advance(#leg{}, non_neg_integer()) -> #leg{}.
advance(#leg{sess = Sess} = L, Step) ->
    L#leg{sess = chappe_mix_session:advance(Sess, Step)}.

silence(Law) -> binary:copy(<<(silence_code(Law))>>, ?FRAME).

silence_code(ulaw) -> 16#FF;
silence_code(alaw) -> 16#D5.

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

%% Reports go where signalling said (RFC 3605), else where the RTP goes
%% or to the port after it (RFC 3550 11), not to wherever the far end's
%% RTCP comes from.
rtcp_dest(#leg{rtcp_remote = {_, _} = To}) -> To;
rtcp_dest(#leg{rtcp = mux, remote = Remote}) -> Remote;
rtcp_dest(#leg{rtcp = pair, remote = {Ip, Port}}) -> {Ip, Port + 1};
rtcp_dest(#leg{}) -> undefined.
