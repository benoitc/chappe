%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The controller of the cluster lab (make interop-cluster). It runs on the
%% host, outside distributed Erlang: it drives the nodes of
%% apps/chappe_cluster/interop/docker-compose.yml with docker compose,
%% docker exec and erl_call, injects the faults of a seeded schedule
%% (chappe_cluster_lab_schedule), then collects every node's event log and
%% runs chappe_cluster_lab_checker on it.
%%
%% main/0 reads its settings from the environment (see test/e2e.sh) and
%% halts with 0 when the run is clean.
-module(chappe_cluster_lab).

-export([main/0]).

-define(RPC_TIMEOUT_S, 3).

main() ->
    Code =
        try run(settings()) of
            ok ->
                0;
            {error, Why} ->
                io:format("~nFAIL: ~ts~n", [Why]),
                1
        catch
            C:R:St ->
                io:format("~nFAIL: ~p:~p~n~p~n", [C, R, St]),
                1
        end,
    halt(Code).

settings() ->
    N = int("NODES", 5),
    Nodes = ["n" ++ integer_to_list(I) || I <- lists:seq(1, N)],
    N >= 3 orelse error({nodes, "NODES must be 3 to 5"}),
    N =< 5 orelse error({nodes, "NODES must be 3 to 5"}),
    #{
        mode => env("MODE", "run"),
        nodes => Nodes,
        seed => seed(),
        duration_ms => duration(env("DURATION", "5m")),
        compose => env(
            "CLB_COMPOSE", "apps/chappe_cluster/interop/docker-compose.yml"
        ),
        project => env("CLB_PROJECT", "clb"),
        out => env("CLB_OUT", "_build/clb"),
        margin_us => int("MARGIN_MS", 0) * 1000,
        selftest => env("SELFTEST", "1") =/= "0",
        keep => env("KEEP", "0") =:= "1"
    }.

seed() ->
    case env("SEED", "") of
        "" -> erlang:phash2({os:system_time(), self()});
        S -> list_to_integer(S)
    end.

duration(S) ->
    case string:to_integer(S) of
        {N, "s"} -> N * 1000;
        {N, "m"} -> N * 60000;
        {N, ""} -> N * 1000;
        _ -> error({duration, S})
    end.

run(#{mode := Mode, nodes := Nodes, seed := Seed} = Cfg) ->
    io:format(
        "cluster lab: mode=~s nodes=~p SEED=~p DURATION=~ps~n",
        [Mode, length(Nodes), Seed, maps:get(duration_ms, Cfg) div 1000]
    ),
    ok = up(Cfg),
    Result =
        try
            Ids = ids(Cfg),
            Cfg1 = Cfg#{ids => Ids, net => maps:get(project, Cfg) ++ "_lab"},
            ok = wait_mesh(Cfg1, 90000),
            Caps = caps(Cfg1),
            io:format("faults available: ~p~n", [Caps]),
            case Mode of
                "topology" ->
                    selftest(Cfg1, Caps);
                "run" ->
                    case maps:get(selftest, Cfg1) of
                        true -> ok = selftest(Cfg1, Caps);
                        false -> ok
                    end,
                    schedule_run(Cfg1, Caps)
            end
        after
            down(Cfg)
        end,
    io:format(
        "~nSEED=~p (replay: SEED=~p DURATION=~ps make interop-cluster)~n", [
            Seed, Seed, maps:get(duration_ms, Cfg) div 1000
        ]
    ),
    Result.

%% ---- the lab ---------------------------------------------------------------

up(#{nodes := Nodes} = Cfg) ->
    os:putenv("CLB_NODES", lists:join(" ", Nodes)),
    os:putenv("CLB_PROJECT", maps:get(project, Cfg)),
    _ = compose(Cfg, ["down", "-v", "--remove-orphans"], 120000),
    {0, _} = check(compose(Cfg, ["build", "n1"], 1200000)),
    {0, _} = check(
        compose(
            Cfg, ["up", "-d", "--wait", "--wait-timeout", "120" | Nodes], 300000
        )
    ),
    ok.

down(#{keep := true}) ->
    io:format("KEEP=1: the lab is left running~n");
down(Cfg) ->
    _ = compose(Cfg, ["down", "-v", "--remove-orphans"], 120000),
    ok.

ids(#{nodes := Nodes} = Cfg) ->
    maps:from_list([
        begin
            {0, Out} = check(compose(Cfg, ["ps", "-a", "-q", Node], 30000)),
            {Node, string:trim(Out)}
        end
     || Node <- Nodes
    ]).

id(#{ids := Ids}, Node) -> maps:get(Node, Ids).

%% ---- reachability ----------------------------------------------------------

%% Every node reaches every other one over distributed Erlang.
wait_mesh(#{nodes := Nodes} = Cfg, Timeout) ->
    Pairs = [{A, B} || A <- Nodes, B <- Nodes, A =/= B],
    wait(
        fun() -> lists:all(fun({A, B}) -> reach(Cfg, A, B) end, Pairs) end,
        Timeout,
        "every node reaches every other node"
    ).

reach(Cfg, From, To) ->
    Args = io_lib:format("[lab@~s, erlang, node, [], ~p]", [
        To, ?RPC_TIMEOUT_S * 1000
    ]),
    Want = list_to_atom("lab@" ++ To),
    case erl_call(Cfg, From, "rpc call " ++ lists:flatten(Args)) of
        {ok, Want} -> true;
        _ -> false
    end.

%% apply(Mod, Fun, Args) on a node, the result parsed.
erl_call(Cfg, Node, Apply) ->
    erl_call(Cfg, Node, Apply, ?RPC_TIMEOUT_S + 5).

erl_call(Cfg, Node, Apply, TimeoutS) ->
    Cmd = [
        "exec",
        id(Cfg, Node),
        "erl_call",
        "-sname",
        "lab",
        "-timeout",
        integer_to_list(TimeoutS),
        "-a",
        Apply
    ],
    case docker(Cmd, (TimeoutS + 5) * 1000) of
        {0, Out} -> parse_term(Out);
        Other -> {error, Other}
    end.

parse_term(Out) ->
    case erl_scan:string(string:trim(Out) ++ ".") of
        {ok, Toks, _} ->
            case erl_parse:parse_term(Toks) of
                {ok, T} -> {ok, T};
                _ -> {error, Out}
            end;
        _ ->
            {error, Out}
    end.

%% ---- faults ----------------------------------------------------------------

caps(#{nodes := [N1 | _]} = Cfg) ->
    Iptables = root(Cfg, N1, "iptables -L OUTPUT -n") =:= 0,
    Tc = root(Cfg, N1, "tc qdisc show") =:= 0,
    [isolate, kill] ++ [split || Iptables] ++ [delay || Tc].

apply_action(Cfg, {isolate, Nodes}) ->
    [disconnect(Cfg, N) || N <- Nodes],
    ok;
apply_action(Cfg, {heal, {isolate, Nodes}}) ->
    [connect(Cfg, N) || N <- Nodes],
    ok;
apply_action(Cfg, {split, Minority, Rest}) ->
    Ips = [ip(Cfg, N) || N <- Rest],
    Rules = lists:append([
        [
            "iptables -A INPUT -s ",
            Ip,
            " -j DROP; iptables -A OUTPUT -d ",
            Ip,
            " -j DROP; "
        ]
     || Ip <- Ips
    ]),
    [0 = root(Cfg, N, lists:flatten(Rules)) || N <- Minority],
    ok;
apply_action(Cfg, {heal, {split, Minority, _}}) ->
    [
        0 = root(Cfg, N, "iptables -F INPUT; iptables -F OUTPUT")
     || N <- Minority
    ],
    ok;
apply_action(Cfg, {kill, Nodes}) ->
    {0, _} = check(compose(Cfg, ["kill", "-s", "KILL" | Nodes], 60000)),
    ok;
apply_action(Cfg, {heal, {kill, Nodes}}) ->
    {0, _} = check(compose(Cfg, ["start" | Nodes], 120000)),
    ok;
apply_action(Cfg, {delay, Node, Ms}) ->
    Cmd = io_lib:format("tc qdisc add dev $(~s) root netem delay ~pms ~pms", [
        dev(), Ms, max(1, Ms div 5)
    ]),
    0 = root(Cfg, Node, lists:flatten(Cmd)),
    ok;
apply_action(Cfg, {heal, {delay, Node, _}}) ->
    0 = root(
        Cfg,
        Node,
        lists:flatten(io_lib:format("tc qdisc del dev $(~s) root", [dev()]))
    ),
    ok.

dev() ->
    "ip -o -4 addr show | awk '$2 != \"lo\" {print $2; exit}'".

disconnect(#{net := Net} = Cfg, Node) ->
    {0, _} = check(
        docker(["network", "disconnect", "-f", Net, id(Cfg, Node)], 30000)
    ).

connect(#{net := Net} = Cfg, Node) ->
    {0, _} = check(
        docker(
            ["network", "connect", "--alias", Node, Net, id(Cfg, Node)], 30000
        )
    ).

ip(Cfg, Node) ->
    Fmt = "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
    {0, Out} = check(docker(["inspect", "-f", Fmt, id(Cfg, Node)], 30000)),
    string:trim(Out).

%% A shell command as root in a node.
root(Cfg, Node, Cmd) ->
    {Status, _} = docker(
        ["exec", "-u", "0", id(Cfg, Node), "sh", "-c", Cmd], 30000
    ),
    Status.

%% ---- the self-test: each fault does what it says ---------------------------

selftest(#{nodes := [A, B, C | _]} = Cfg, Caps) ->
    io:format("self-test: faults apply and heal~n"),
    Steps =
        [{isolate, [A]} || lists:member(isolate, Caps)] ++
            [
                {split, [A], (maps:get(nodes, Cfg) -- [A])}
             || lists:member(split, Caps)
            ] ++
            [{kill, [B]}],
    lists:foreach(
        fun(Fault) ->
            [Cut | _] = cut(Fault),
            Other = hd([N || N <- [A, B, C], N =/= Cut]),
            Third = hd([N || N <- [A, B, C], N =/= Cut, N =/= Other]),
            ok = apply_action(Cfg, Fault),
            ok = wait(
                fun() -> not reach(Cfg, Other, Cut) end,
                30000,
                io_lib:format("~p: ~s cannot reach ~s", [Fault, Other, Cut])
            ),
            true = reach(Cfg, Other, Third),
            ok = apply_action(Cfg, {heal, Fault}),
            ok = wait_mesh(Cfg, 90000),
            io:format("  ok ~p~n", [Fault])
        end,
        Steps
    ),
    case lists:member(delay, Caps) of
        true ->
            ok = apply_action(Cfg, {delay, A, 200}),
            0 = root(Cfg, A, "tc qdisc show | grep -q netem"),
            ok = apply_action(Cfg, {heal, {delay, A, 200}}),
            1 = root(Cfg, A, "tc qdisc show | grep -q netem"),
            io:format("  ok ~p~n", [{delay, A, 200}]);
        false ->
            io:format("  skipped delay: tc is not usable in this docker host~n")
    end,
    ok.

cut({isolate, Ns}) -> Ns;
cut({split, Ns, _}) -> Ns;
cut({kill, Ns}) -> Ns.

%% ---- the randomized run ----------------------------------------------------

schedule_run(Cfg, Caps) ->
    #{nodes := Nodes, seed := Seed, duration_ms := Duration} = Cfg,
    case has_cluster(Cfg) of
        false ->
            {error, "chappe_cluster is not in the node image"};
        true ->
            Sched = chappe_cluster_lab_schedule:build(
                Seed, Duration, Nodes, Caps
            ),
            io:format("schedule (SEED=~p):~n~s", [
                Seed, chappe_cluster_lab_schedule:describe(Sched)
            ]),
            T0 = erlang:monotonic_time(millisecond),
            lists:foreach(
                fun({At, Action}) ->
                    sleep_until(T0 + At),
                    io:format("[~8.3f s, wall ~p us] ~p~n", [
                        (erlang:monotonic_time(millisecond) - T0) / 1000,
                        os:system_time(microsecond),
                        Action
                    ]),
                    ok = apply_action(Cfg, Action)
                end,
                Sched
            ),
            sleep_until(T0 + Duration - 10000),
            ok = wait_mesh(Cfg, 90000),
            Live = live(Cfg),
            ok = stop_clients(Cfg),
            Dir = collect(Cfg),
            verdict(Cfg, Dir, Live, Sched)
    end.

has_cluster(#{nodes := [N1 | _]} = Cfg) ->
    case erl_call(Cfg, N1, "code which [chappe_cluster]") of
        {ok, non_existing} -> false;
        {ok, _} -> true;
        _ -> false
    end.

%% After the last heal every node claims again within ten seconds.
live(#{nodes := Nodes} = Cfg) ->
    Before = [{N, claims(Cfg, N)} || N <- Nodes],
    timer:sleep(10000),
    [N || {N, C0} <- Before, claims(Cfg, N) =< C0].

claims(Cfg, Node) ->
    case erl_call(Cfg, Node, "chappe_cluster_lab_client stats []") of
        {ok, #{claim_ok := C}} -> C;
        _ -> 0
    end.

stop_clients(#{nodes := Nodes} = Cfg) ->
    [
        {ok, ok} = erl_call(Cfg, N, "chappe_cluster_lab_client stop []", 120)
     || N <- Nodes
    ],
    ok.

collect(#{nodes := Nodes, out := Out, seed := Seed} = Cfg) ->
    Dir = filename:join([Out, "logs", integer_to_list(Seed)]),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    [
        {0, _} = check(
            compose(Cfg, ["cp", N ++ ":/logs", filename:join(Dir, N)], 60000)
        )
     || N <- Nodes
    ],
    Dir.

verdict(#{margin_us := Margin}, Dir, Dead, Sched) ->
    {Events, Bad} = chappe_cluster_lab_checker:read_logs(Dir),
    Stats = chappe_cluster_lab_checker:stats(Events),
    io:format("~nlogs: ~s~nfaults: ~p~nevents: ~p (~p cut lines)~n", [
        Dir, length(Sched) div 2, Stats, Bad
    ]),
    case chappe_cluster_lab_checker:check(Events, #{margin_us => Margin}) of
        {violation, V} ->
            io:format("~s", [chappe_cluster_lab_checker:format(V)]),
            {error, "the lease checker found a violation"};
        ok when map_get(claims, Stats) =:= 0 ->
            {error, "no lease was ever claimed"};
        ok when Dead =/= [] ->
            {error,
                io_lib:format("no claim after the last heal on ~p", [Dead])};
        ok ->
            io:format(
                "~nPASS: no overlapping lease, fences grow on every key~n"
            ),
            ok
    end.

%% ---- helpers ---------------------------------------------------------------

sleep_until(T) ->
    case T - erlang:monotonic_time(millisecond) of
        Ms when Ms > 0 -> timer:sleep(Ms);
        _ -> ok
    end.

wait(Fun, Timeout, What) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Fun, Deadline, What).

wait_loop(Fun, Deadline, What) ->
    case Fun() of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error({timeout, lists:flatten(What)});
                false ->
                    timer:sleep(1000),
                    wait_loop(Fun, Deadline, What)
            end
    end.

compose(#{compose := File, project := P}, Args, Timeout) ->
    docker(["compose", "-p", P, "-f", File | Args], Timeout).

check({0, _} = Ok) ->
    Ok;
check({Status, Out}) ->
    io:format("docker failed (~p):~n~s~n", [Status, Out]),
    {Status, Out}.

docker(Args, Timeout) ->
    Exe = os:find_executable("docker"),
    Port = open_port({spawn_executable, Exe}, [
        {args, [lists:flatten(A) || A <- Args]},
        exit_status,
        stderr_to_stdout,
        binary
    ]),
    collect_port(Port, [], erlang:monotonic_time(millisecond) + Timeout).

collect_port(Port, Acc, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, D}} ->
            collect_port(Port, [D | Acc], Deadline);
        {Port, {exit_status, S}} ->
            {S, binary_to_list(iolist_to_binary(lists:reverse(Acc)))}
    after Left ->
        true = port_close(Port),
        {timeout, binary_to_list(iolist_to_binary(lists:reverse(Acc)))}
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        V -> V
    end.

int(Name, Default) ->
    list_to_integer(env(Name, integer_to_list(Default))).
