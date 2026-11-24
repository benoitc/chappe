%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% The traffic side of the bench, run in a peer node (a second OS
%% process) so that the mixer node's scheduler utilisation and tick
%% lateness count the mixer and nothing else.
%%
%% A sender group is one process and one UDP socket feeding many legs:
%% every 20 ms it sends each leg one pre-encoded PCMU frame. The socket
%% is never read. The mixer latches every leg of the group onto it, so
%% the mixer pays for its sends in full, and the kernel drops what
%% arrives once the small receive buffer is full: the group spends its
%% time sending, not decoding what comes back.
-module(chappe_mix_bench_load).

-export([
    init/0, start_group/2, open_group/2, feed/2, stop_group/1, sent/1, latency/1
]).

-define(FRAME, 160).

%% Build the G.711 tables in this node.
init() ->
    chappe_mix_g711:init().

%% Start a group feeding Dsts ([{Ip, Port}]) with Kind ({at, Rate, Kind}:
%% the same at 16000, L16 on payload type 96; else PCMU at 8000: tone | silence |
%% {lossy, Fraction}: the tone, each packet dropped with that probability
%% before it is sent). The process is not linked to the caller; it lives
%% until the node goes.
start_group(Dsts, Kind) ->
    {Pid, _Port} = open_group(Kind, {127, 0, 0, 1}),
    ok = feed(Pid, Dsts),
    Pid.

%% A group whose socket is bound to Ip and that sends nothing until feed/2
%% names its legs: a SIP peer needs the port for its SDP before it knows
%% where to send. Returns {Pid, Port}.
open_group(Kind, Ip) ->
    Parent = self(),
    Pid = spawn(fun() -> group(Parent, Kind, Ip) end),
    receive
        {Pid, ready, Port} -> {Pid, Port}
    after 5000 -> error(group_start)
    end.

%% Start the group sending to Dsts ([{Ip, Port}]).
feed(Pid, Dsts) ->
    Pid ! {feed, Dsts},
    ok.

stop_group(Pid) ->
    exit(Pid, kill),
    ok.

%% Packets the groups have handed to their sockets so far, summed. Read
%% before and after a step, it says whether the traffic the step asked
%% for was actually offered, or the senders fell behind.
sent(Groups) ->
    lists:sum([group_sent(G) || G <- Groups]).

group_sent(G) ->
    G ! {sent, self()},
    receive
        {G, sent, N} -> N
    after 5000 -> 0
    end.

%% Run chappe_mix_probe here against A and B legs of a mixer; Opts as
%% chappe_mix_probe:run/2 takes them, and probe: the probe's own options
%% (law and rate, for a 16 kHz room).
latency(Opts) ->
    {Probe, _, _} = chappe_mix_probe:start(maps:get(probe, Opts, #{})),
    R = chappe_mix_probe:run(Probe, Opts),
    chappe_mix_probe:stop(Probe),
    R.

%% ---- group ----

group(Parent, Kind0, Bind) ->
    {ok, Sock} = gen_udp:open(0, [
        binary, {ip, Bind}, {active, false}, {recbuf, 4096}
    ]),
    {ok, Own} = inet:port(Sock),
    Parent ! {self(), ready, Own},
    Dsts =
        receive
            {feed, D} -> D
        end,
    {Rate, Kind} = at(Kind0),
    Frames = {list_to_tuple(frames(Kind, Rate)), pt(Rate), Rate div 50},
    Loss =
        case Kind of
            {lossy, F} -> F;
            _ -> 0.0
        end,
    put(loss, Loss),
    Legs = [
        {Ip, Port, rand:uniform(16#FFFFFFF), rand:uniform(30000)}
     || {Ip, Port} <- Dsts
    ],
    loop(Sock, Frames, Legs, 0, 0, erlang:monotonic_time(millisecond)).

%% Sent counts the sends the socket accepted, not the ones attempted.
loop(Sock, {Payloads, Pt, Step} = Frames, Legs, N, Sent, Next) ->
    Payload = element(N rem tuple_size(Payloads) + 1, Payloads),
    Loss = get(loss),
    Results = [
        send_or_drop(
            Loss,
            Sock,
            Ip,
            Port,
            chappe_mix_rtp:build(#{
                pt => Pt,
                seq => (Seq + N) band 16#FFFF,
                ts => ((Seq + N) * Step) band 16#FFFFFFFF,
                ssrc => Ssrc,
                marker => false,
                payload => Payload
            })
        )
     || {Ip, Port, Ssrc, Seq} <- Legs
    ],
    %% a dropped packet was not offered: it does not count as sent
    Sent1 = Sent + length([ok || ok <- Results]),
    Next1 = Next + 20,
    erlang:send_after(Next1, self(), tick, [{abs, true}]),
    wait_tick(Sent1),
    loop(Sock, Frames, Legs, N + 1, Sent1, Next1).

send_or_drop(Loss, Sock, Ip, Port, Pkt) ->
    case Loss > 0 andalso rand:uniform() < Loss of
        true -> dropped;
        false -> gen_udp:send(Sock, Ip, Port, Pkt)
    end.

wait_tick(Sent) ->
    receive
        tick ->
            ok;
        {sent, From} ->
            From ! {self(), sent, Sent},
            wait_tick(Sent)
    end.

%% Ten frames of a 500 Hz tone at -14.7 dBFS (a whole number of cycles in
%% 200 ms, so the cycle is seamless), or one frame of silence: PCMU at
%% 8000, L16 (big-endian) at 16000.
frames(tone, Rate) ->
    F = Rate div 50,
    [
        encode(Rate, [
            round(6000 * math:sin(2 * math:pi() * 500 * I / Rate))
         || I <- lists:seq(K * F, K * F + F - 1)
        ])
     || K <- lists:seq(0, 9)
    ];
frames({lossy, _}, Rate) ->
    frames(tone, Rate);
frames(silence, 8000) ->
    [binary:copy(<<16#FF>>, ?FRAME)];
frames(silence, Rate) ->
    [<<0:(Rate div 50 * 16)>>].

encode(8000, Samples) -> chappe_mix_g711:encode_frame(ulaw, Samples);
encode(_Rate, Samples) -> <<<<S:16/big-signed>> || S <- Samples>>.

%% A kind of traffic at a rate ({at, Rate, Kind}), else PCMU at 8000.
at({at, Rate, Kind}) -> {Rate, Kind};
at(Kind) -> {8000, Kind}.

%% the payload type of each rate's format, as the mixer's legs take it
pt(8000) -> 0;
pt(_Rate) -> 96.
