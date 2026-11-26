%% Samples, once a second, the counters of every chappe_mix conference of
%% the running demo node: ticks, overruns, the tick lateness histogram and
%% each leg's jitter buffer counters. One Erlang term per line:
%% {SystemTimeMs, [{ConfPid, Stats, Legs}]}.
%% Usage: erl -sname mixprobe -hidden -setcookie chappe-demo -noshell \
%%            -pa DIR -run mixprobe main demo@localhost OUT
-module(mixprobe).
-export([main/1]).

main([Node, Out]) ->
    N = list_to_atom(Node),
    {ok, F} = file:open(Out, [write]),
    loop(N, F).

loop(N, F) ->
    T = erlang:system_time(millisecond),
    S =
        case
            rpc:call(N, supervisor, which_children, [chappe_mix_conf_sup], 2000)
        of
            L when is_list(L) ->
                [
                    {P, rpc:call(N, chappe_mix, stats, [P], 2000),
                        rpc:call(N, chappe_mix, legs, [P], 2000)}
                 || {_, P, _, _} <- L, is_pid(P)
                ];
            E ->
                E
        end,
    io:format(F, "~0p.~n", [{T, S}]),
    timer:sleep(max(0, 1000 - (erlang:system_time(millisecond) - T))),
    loop(N, F).
