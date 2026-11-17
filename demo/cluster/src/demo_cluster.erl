%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% One node of the cluster demo (`make demo-cluster', see README.md):
%% chappe_cluster, chappe_sip and chappe_mrf with `cluster =>
%% chappe_cluster', on the docker network of docker-compose.yml.
%%
%% Every node runs the same thing:
%%   - a registrar for alice and bob whose location store is the region's
%%     KV: a phone registered on one node is called from any node;
%%   - 3000 is a native conference room, `demo': whichever node a caller
%%     reaches, it lands in the one room the region owns;
%%   - the peer `trunk' is pinged with OPTIONS from one node of the region
%%     (probe => singleton), and every node logs its state.
%%
%% From a shell on a node (make demo-cluster-shell N=n1):
%%   demo_cluster:room()     the room: its node, pid and members
%%   demo_cluster:pinger()   the node pinging the trunk
%%   demo_cluster:trunk()    the trunk's state as this node sees it
%%   chappe_cluster:leases() every lease with its node and fence
-module(demo_cluster).

-export([start/0]).
-export([room/0, pinger/0, trunk/0]).

-define(ROOM, <<"demo">>).
-define(REALM, <<"chappe.demo">>).

-spec start() -> ok.
start() ->
    Ip = env("NODE_IP"),
    Voters = [list_to_atom(V) || V <- string:lexemes(env("VOTERS"), ",")],
    ok = application:load(chappe_cluster),
    ok = set_env(chappe_cluster, #{
        region => demo,
        voters => Voters,
        data_dir => "/data/cluster"
    }),
    ok = application:load(chappe_sip),
    ok = set_env(chappe_sip, #{
        cluster => chappe_cluster,
        %% the same on every node: edge routes hold across nodes
        flow_token_secret => list_to_binary(env("FLOW_SECRET"))
    }),
    ok = application:load(chappe_mrf),
    ok = set_env(chappe_mrf, #{cluster => chappe_cluster}),
    {ok, _} = application:ensure_all_started(chappe_mrf),
    ok = chappe_sip:start(#{
        contact => iolist_to_binary(["sip:", Ip, ":5060"]),
        media => #{
            rtpengine => #{
                nodes => [#{name => rtpe, host => env("RTPENGINE_IP"), port => 22222}]
            },
            mix => #{ip => {0, 0, 0, 0}, advertise => Ip}
        }
    }),
    ok = chappe_mrf:start(#{}),
    Users = [{<<"alice">>, <<"alice-demo">>}, {<<"bob">>, <<"bob-demo">>}],
    Registrar = chappe_sip:registrar(#{
        auth => #{
            realm => ?REALM,
            domain => [?REALM],
            secret => fun(U) -> secret(U, Users) end
        },
        domains => any
    }),
    ok = chappe_sip:register(Registrar),
    ok = chappe_sip:invite(fun invite/2),
    Keeper = spawn(fun keeper/0),
    ok = chappe_sip:peer_subscribe(Keeper),
    ok = chappe_sip:peer_add(trunk, #{
        uri => iolist_to_binary(["sip:trunk@", env("TRUNK_IP"), ":5060"]),
        interval_ms => 2000,
        timeout_ms => 1000,
        probe => singleton
    }),
    log("up: SIP ~s:5060, voters ~p", [Ip, Voters]).

env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_env, Name});
        V -> V
    end.

set_env(App, Env) ->
    maps:foreach(fun(K, V) -> ok = application:set_env(App, K, V) end, Env).

secret(User, Users) ->
    case lists:keyfind(User, 1, Users) of
        {_, Pass} -> {ok, Pass};
        false -> error
    end.

%% 3000: the room; a user: wherever it registered, through its node's
%% edge route when it has one.
invite(Req, Res) ->
    case user(chappe_sip_req:uri(Req)) of
        <<"3000">> -> conference(Req, Res);
        User -> call_user(User, Req, Res)
    end.

conference(Req, Res) ->
    case chappe_mrf:conference(?ROOM, #{}) of
        {ok, Conf} ->
            case chappe_mrf_conf:join(Conf, {call, Req, Res}, #{}) of
                {ok, Member} ->
                    log("~s joined room ~s on ~s", [Member, ?ROOM, node(Conf)]);
                {error, Why} ->
                    log("join refused: ~p", [Why]),
                    _ = chappe_sip_res:send(Res, 503)
            end;
        {error, Why} ->
            log("no room: ~p", [Why]),
            _ = chappe_sip_res:send(Res, 503)
    end.

%% Through the B2BUA, to every binding of the user, each with its route
%% set: on another node than the one holding its flow, the edge route
%% comes first.
call_user(User, Req, Res) ->
    Aor = <<"sip:", User/binary, "@", ?REALM/binary>>,
    case chappe_sip:bindings(Aor) of
        [] ->
            _ = chappe_sip_res:send(Res, 480);
        Bindings ->
            Dests = [
                {C, #{flow => F, route_set => Path}}
             || #{contact := C, send_flow := F, path := Path} <- Bindings
            ],
            log("call to ~s: ~p", [User, [{N, C} || #{node := N, contact := C} <- Bindings]]),
            case chappe_sip:create_b2bua(Req, Res, {parallel, Dests}, #{}) of
                {ok, Legs} -> _ = chappe_sip_b2b:relay(Legs);
                {error, Why} -> log("call to ~s failed: ~p", [User, Why])
            end
    end.

user(Uri) ->
    case chappe_sip_uri:parse(Uri) of
        {ok, #{user := U}} when is_binary(U) -> U;
        _ -> <<>>
    end.

keeper() ->
    receive
        {chappe_sip_peer, Name, State} ->
            log("peer ~p is ~p (pinged from ~p)", [Name, State, pinger()]),
            keeper();
        _ ->
            keeper()
    end.

%% ---- shell ----

-spec room() -> #{node := node(), pid := pid(), members := [map()]} | none.
room() ->
    case chappe_cluster:owner({chappe_mrf_conf, ?ROOM}) of
        {ok, #{node := Node, pid := Pid}} ->
            Members =
                case chappe_mrf_conf:members(Pid) of
                    L when is_list(L) -> L;
                    _ -> []
                end,
            #{node => Node, pid => Pid, members => Members};
        _ ->
            none
    end.

-spec pinger() -> node() | none.
pinger() ->
    case chappe_cluster:whereis_singleton({chappe_sip_peer, trunk}) of
        {ok, Pid} -> node(Pid);
        none -> none
    end.

-spec trunk() -> map() | not_found.
trunk() ->
    case chappe_sip:peer_status(trunk) of
        {ok, Info} -> Info;
        {error, not_found} -> not_found
    end.

log(Fmt, Args) ->
    io:format("demo ~s: " ++ Fmt ++ "~n", [node() | Args]).
