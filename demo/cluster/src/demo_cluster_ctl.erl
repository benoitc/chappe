%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The smoke test's eyes on the cluster demo (smoke.sh): run from the ctl
%% container as `erl ... -eval demo_cluster_ctl:main(["cmd", ...])', it
%% asks the nodes over distribution and prints one line; it halts 0 when
%% what it waits for came, 1 otherwise.
%%
%%   ready                  every node of NODES is up and live
%%   room MEMBERS [AVOID]   wait until the room has MEMBERS members on a
%%                          node other than AVOID; print that node
%%   pinger [AVOID]         wait until a node other than AVOID pings the
%%                          trunk; print it
%%   sources NODE           the trunk saw OPTIONS in the last 3 s from
%%                          NODE's address only
%%   trunk STATE            every live node sees the trunk STATE
%%   live NODE              wait until NODE is back and live
%%   leases                 print chappe_cluster:leases()
-module(demo_cluster_ctl).

-export([main/1]).

-define(WAIT, 60).

-spec main([string()]) -> no_return().
main(Args) ->
    Result =
        try
            run(Args)
        catch
            C:W:St -> {error, {C, W, St}}
        end,
    case Result of
        {ok, Out} ->
            io:format("~s~n", [Out]),
            halt(0);
        {error, Why} ->
            io:format("ctl ~p: ~p~n", [Args, Why]),
            halt(1)
    end.

nodes_env() ->
    [list_to_atom(N) || N <- string:lexemes(os:getenv("NODES"), ",")].

up() ->
    [N || N <- nodes_env(), net_adm:ping(N) =:= pong].

run(["ready"]) ->
    wait(?WAIT * 5, fun() ->
        All = nodes_env(),
        case [N || N <- All, live(N)] of
            All -> {ok, "ready"};
            _ -> false
        end
    end);
run(["room", Members | Avoid]) ->
    Want = list_to_integer(Members),
    wait(?WAIT, fun() ->
        case room() of
            #{node := Node, members := M} when length(M) >= Want ->
                case [atom_to_list(Node)] of
                    Avoid -> false;
                    _ -> {ok, atom_to_list(Node)}
                end;
            _ ->
                false
        end
    end);
run(["pinger" | Avoid]) ->
    wait(?WAIT, fun() ->
        case [rpc(N, demo_cluster, pinger, []) || N <- up()] of
            [P | _] when is_atom(P), P =/= none ->
                case [atom_to_list(P)] of
                    Avoid -> false;
                    _ -> {ok, atom_to_list(P)}
                end;
            _ ->
                false
        end
    end);
run(["sources", Node]) ->
    Ip = rpc(list_to_atom(Node), os, getenv, ["NODE_IP"]),
    timer:sleep(3000),
    case rpc(trunk(), demo_cluster_trunk, sources, [3000]) of
        [Ip] -> {ok, "pings from " ++ Ip ++ " only"};
        Other -> {error, {sources, Other, expected, Ip}}
    end;
run(["trunk", State]) ->
    Want = list_to_atom(State),
    wait(?WAIT, fun() ->
        Seen = [state_of(rpc(N, demo_cluster, trunk, [])) || N <- up()],
        case lists:usort(Seen) of
            [Want] -> {ok, io_lib:format("trunk ~s on ~b nodes", [State, length(Seen)])};
            _ -> false
        end
    end);
run(["live", Node]) ->
    N = list_to_atom(Node),
    wait(?WAIT * 2, fun() ->
        case live(N) of
            true -> {ok, Node ++ " live"};
            false -> false
        end
    end);
run(["leases"]) ->
    [N | _] = up(),
    {ok, io_lib:format("~p", [rpc(N, chappe_cluster, leases, [])])}.

trunk() ->
    list_to_atom(os:getenv("TRUNK_NODE")).

state_of(#{state := S}) -> S;
state_of(_) -> none.

room() ->
    case up() of
        [] -> none;
        [N | _] -> rpc(N, demo_cluster, room, [])
    end.

live(N) ->
    net_adm:ping(N) =:= pong andalso
        case rpc(N, chappe_cluster, status, []) of
            #{live := true} -> rpc(N, erlang, whereis, [chappe_sip_peers]) =/= undefined;
            _ -> false
        end.

rpc(N, M, F, A) ->
    try
        erpc:call(N, M, F, A, 5000)
    catch
        _:_ -> undefined
    end.

wait(0, _F) ->
    {error, timeout};
wait(N, F) ->
    case F() of
        {ok, _} = Ok ->
            Ok;
        false ->
            timer:sleep(1000),
            wait(N - 1, F)
    end.
