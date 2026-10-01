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

-export([init/0, start_group/2, sent/1, latency/1]).

-define(FRAME, 160).

%% Build the G.711 tables in this node.
init() ->
    chappe_mix_g711:init().

%% Start a group feeding Dsts ([{Ip, Port}]) with Kind (tone | silence |
%% {lossy, Fraction}: the tone, each packet dropped with that probability
%% before it is sent). The process is not linked to the caller; it lives
%% until the node goes.
start_group(Dsts, Kind) ->
    Parent = self(),
    Pid = spawn(fun() -> group(Parent, Dsts, Kind) end),
    receive
        {Pid, ready} -> Pid
    after 5000 -> error(group_start)
    end.

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
%% chappe_mix_probe:run/2 takes them.
latency(Opts) ->
    {Probe, _, _} = chappe_mix_probe:start(#{}),
    R = chappe_mix_probe:run(Probe, Opts),
    chappe_mix_probe:stop(Probe),
    R.

%% ---- group ----

group(Parent, Dsts, Kind) ->
    {ok, Sock} = gen_udp:open(0, [
        binary, {ip, {127, 0, 0, 1}}, {active, false}, {recbuf, 4096}
    ]),
    Frames = list_to_tuple(frames(Kind)),
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
    Parent ! {self(), ready},
    loop(Sock, Frames, Legs, 0, 0, erlang:monotonic_time(millisecond)).

%% Sent counts the sends the socket accepted, not the ones attempted.
loop(Sock, Frames, Legs, N, Sent, Next) ->
    Payload = element(N rem tuple_size(Frames) + 1, Frames),
    Loss = get(loss),
    Results = [
        send_or_drop(
            Loss,
            Sock,
            Ip,
            Port,
            chappe_mix_rtp:build(#{
                pt => 0,
                seq => (Seq + N) band 16#FFFF,
                ts => ((Seq + N) * ?FRAME) band 16#FFFFFFFF,
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
%% 200 ms, so the cycle is seamless), or one frame of silence.
frames(tone) ->
    [
        chappe_mix_g711:encode_frame(
            ulaw,
            [
                round(6000 * math:sin(2 * math:pi() * 500 * I / 8000))
             || I <- lists:seq(K * ?FRAME, K * ?FRAME + ?FRAME - 1)
            ]
        )
     || K <- lists:seq(0, 9)
    ];
frames({lossy, _}) ->
    frames(tone);
frames(silence) ->
    [binary:copy(<<16#FF>>, ?FRAME)].
