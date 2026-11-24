%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A raw RTP peer for the protocol cases: it streams PCMU silence on a
%% 20 ms clock under an SSRC you choose and keeps every datagram it
%% receives, RTP and RTCP alike, with its arrival time, so a case can
%% look at the wire rather than at what the tone endpoints decode.
-module(chappe_mix_test_peer).

-export([
    start/1,
    stop/1,
    port/1,
    packets/1,
    clear/1,
    set/3,
    send/3,
    rtp/1,
    rtcp/1
]).

%% Opts: dst (endpoint, unset: send nothing), ssrc, seq, sending (default
%% true), skip (sequence offsets never sent, to make loss), pair (also
%% open the next port up for RTCP; the RTP port is even), rate (RTP
%% clock, default 8000: each 20 ms packet carries rate / 50 bytes of
%% silence and moves the timestamp as much). Returns {Pid, RtpPort}.
start(Opts) ->
    Parent = self(),
    Pid = spawn_link(fun() -> init(Parent, Opts) end),
    receive
        {Pid, port, Port} -> {Pid, Port}
    after 2000 -> error(peer_start)
    end.

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ok.

port(Pid) -> call(Pid, port).

%% Every datagram received so far, oldest first:
%% {rtp | rtcp, From, MonotonicMs, Bin}; the tag is the socket it came in
%% on.
packets(Pid) -> call(Pid, packets).

clear(Pid) -> call(Pid, clear).

%% Change dst, ssrc, csrcs or sending on the fly.
set(Pid, Key, Val) -> call(Pid, {set, Key, Val}).

%% Send Bin from the rtp or rtcp socket to To.
send(Pid, {Sock, To}, Bin) -> call(Pid, {send, Sock, To, Bin}).

%% The RTP packets among Pkts, parsed, with their arrival times.
rtp(Pkts) ->
    [
        {T, P}
     || {rtp, _, T, B} <- Pkts, {ok, P} <- [chappe_mix_rtp:parse(B)]
    ].

%% The RTCP compound packets among Pkts, parsed (A.2 checks applied: an
%% invalid one is kept as {error, invalid, Bin}), with the socket they
%% came in on.
rtcp(Pkts) ->
    [
        {Tag, T, parse_rtcp(B)}
     || {Tag, _, T, B} <- Pkts,
        Tag =:= rtcp orelse chappe_mix_rtp:parse(B) =:= {error, rtcp}
    ].

parse_rtcp(B) ->
    case chappe_mix_rtcp:parse(B) of
        {ok, Parts} -> Parts;
        {error, invalid} -> {error, invalid, B}
    end.

call(Pid, Req) ->
    Ref = make_ref(),
    Pid ! {Req, self(), Ref},
    receive
        {Ref, Reply} -> Reply
    after 2000 -> error({peer_call, Req})
    end.

%% ---- process ----

init(Parent, Opts) ->
    {Rtp, Rtcp} = open(maps:get(pair, Opts, false), 50),
    {ok, Port} = inet:port(Rtp),
    Parent ! {self(), port, Port},
    S = #{
        rtp => Rtp,
        rtcp => Rtcp,
        dst => maps:get(dst, Opts, undefined),
        ssrc => maps:get(ssrc, Opts, rand:uniform(16#FFFFFFF)),
        seq => maps:get(seq, Opts, 1000),
        n => 0,
        skip => maps:get(skip, Opts, []),
        sending => maps:get(sending, Opts, true),
        frame => maps:get(rate, Opts, 8000) div 50,
        next => erlang:monotonic_time(millisecond),
        rx => []
    },
    self() ! tick,
    loop(S).

open(false, _) ->
    {ok, S} = gen_udp:open(0, sock_opts()),
    {S, undefined};
open(true, 0) ->
    error(no_port_pair);
open(true, Tries) ->
    {ok, S} = gen_udp:open(0, sock_opts()),
    {ok, P} = inet:port(S),
    case P rem 2 =:= 0 andalso gen_udp:open(P + 1, sock_opts()) of
        {ok, S1} ->
            {S, S1};
        _ ->
            gen_udp:close(S),
            open(true, Tries - 1)
    end.

sock_opts() -> [binary, {ip, {127, 0, 0, 1}}, {active, true}].

loop(#{rtp := Rtp, rtcp := Rtcp} = S) ->
    receive
        tick ->
            S1 = send_frame(S),
            Next = maps:get(next, S1) + 20,
            erlang:send_after(Next, self(), tick, [{abs, true}]),
            loop(S1#{next => Next});
        {udp, Sock, Ip, Port, Bin} ->
            Tag =
                case Sock of
                    Rtp -> rtp;
                    Rtcp -> rtcp
                end,
            T = erlang:monotonic_time(millisecond),
            loop(S#{rx => [{Tag, {Ip, Port}, T, Bin} | maps:get(rx, S)]});
        {port, From, Ref} ->
            {ok, P} = inet:port(Rtp),
            From ! {Ref, P},
            loop(S);
        {packets, From, Ref} ->
            From ! {Ref, lists:reverse(maps:get(rx, S))},
            loop(S);
        {clear, From, Ref} ->
            From ! {Ref, ok},
            loop(S#{rx => []});
        {{set, K, V}, From, Ref} ->
            From ! {Ref, ok},
            loop(S#{K => V});
        {{send, Tag, {Ip, Port}, Bin}, From, Ref} ->
            From ! {Ref, gen_udp:send(maps:get(Tag, S), Ip, Port, Bin)},
            loop(S)
    end.

send_frame(#{dst := undefined} = S) ->
    S;
send_frame(#{sending := false} = S) ->
    S;
send_frame(#{dst := {Ip, Port}, n := N, seq := Seq0, frame := Frame} = S) ->
    Seq = (Seq0 + N) band 16#FFFF,
    case lists:member(N, maps:get(skip, S)) of
        true ->
            ok;
        false ->
            Pkt = chappe_mix_rtp:build(#{
                pt => 0,
                seq => Seq,
                ts => (N * Frame) band 16#FFFFFFFF,
                ssrc => maps:get(ssrc, S),
                marker => N =:= 0,
                csrcs => maps:get(csrcs, S, []),
                payload => binary:copy(<<16#FF>>, Frame)
            }),
            ok = gen_udp:send(maps:get(rtp, S), Ip, Port, Pkt)
    end,
    S#{n => N + 1}.
