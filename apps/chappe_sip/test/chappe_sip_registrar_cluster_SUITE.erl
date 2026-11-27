%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% The registrar on a cluster: three peer nodes, each running
%% chappe_cluster and a chappe_sip engine with `cluster => chappe_cluster',
%% a registrar and an INVITE handler that proxies to location_target/1.
%% The devices and the callers are sockets of this node.
-module(chappe_sip_registrar_cluster_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-compile([export_all, nowarn_export_all]).

-define(LEASE, 2000).
-define(RENEW, 500).
-define(AOR, <<"sip:alice@127.0.0.1">>).
-define(NAT_CONTACT, <<"<sip:alice@192.0.2.50:5060>">>).

all() ->
    [
        udp_call_through_the_edge,
        tcp_call_through_the_edge,
        ws_call_through_the_edge,
        public_contact_is_sent_directly,
        conn_token_refused_on_another_node,
        dead_flow_at_the_edge,
        busy_edge_keeps_the_binding,
        transport_503_on_a_closed_flow,
        flow_index_follows_a_sweep,
        flow_index_follows_a_move,
        resync_without_quorum_does_not_block,
        cseq_and_expires_across_nodes,
        edge_node_down,
        lost_quorum_refuses_register,
        sweep_singleton_moves,
        sweep_child_restarts_after_a_crash
    ].

init_per_suite(Config) ->
    ok = dist(),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(Case)),
    Peers = [peer("clc" ++ integer_to_list(I)) || I <- [1, 2, 3]],
    Nodes = [N || {_, N} <- Peers],
    [ok = start_cluster(N, Nodes, Dir) || N <- Nodes],
    [
        wait(
            fun() ->
                erpc:call(N, chappe_cluster_node, live, []) =/= not_live
            end,
            300
        )
     || N <- Nodes
    ],
    %% a live lease is not yet a region that takes writes: a REGISTER sent
    %% before that gets 503 (no quorum)
    [wait(fun() -> writable(N) end, 300) || N <- Nodes],
    Both = [start_sip(N) || N <- Nodes],
    [
        {peers, Peers},
        {nodes, Nodes},
        {ports, [P || {P, _} <- Both]},
        {ws_ports, [W || {_, W} <- Both]}
        | Config
    ].

end_per_testcase(_Case, Config) ->
    [stop_peer(P) || {P, _} <- ?config(peers, Config)],
    ok.

%% ---- cases ----

%% A UA behind a NAT registers on node 1; node 2 resolves it to a route
%% through node 1, and a call from node 2 reaches the UA from node 1's
%% address, record-routed there; the caller's BYE goes through node 1 to
%% the UA's flow.
%% req: R5626-R-13
udp_call_through_the_edge(Config) ->
    [N1, N2, _] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    {ok, Dev} = udp(),
    send(Dev, P1, register_req(lport(Dev), 3600, 1, ?NAT_CONTACT)),
    _ = recv_status(Dev, 200),
    [B] = wait_bindings(N2, 1),
    ?assertEqual(N1, maps:get(node, B)),
    ?assertMatch([<<"<sip:127.0.0.1:", _/binary>>], maps:get(path, B)),
    ?assertEqual(undefined, maps:get(send_flow, B)),
    ?assertMatch(
        {route, <<"sip:alice@192.0.2.50:5060">>, [_]}, maps:get(target, B)
    ),
    {ok, Caller} = udp(),
    send(Caller, P2, invite(lport(Caller), <<"cu1">>)),
    {Inv, P1} = recv_req(Dev, <<"INVITE">>),
    {ok, M} = chappe_sip_msg:parse(Inv),
    ?assertEqual(<<"sip:alice@192.0.2.50:5060">>, chappe_sip_msg:uri(M)),
    RRs = chappe_sip_msg:get_all(<<"record-route">>, M),
    ?assertEqual(2, length(RRs)),
    send(Dev, P1, ok_for(M, RRs)),
    _ = recv_status(Caller, 200),
    %% the caller's route set is the Record-Route reversed
    Bye = bye(lport(Caller), <<"cu1">>, lists:reverse(RRs)),
    send(Caller, P1, Bye),
    {_, P1} = recv_req(Dev, <<"BYE">>).

%% An RFC 5626 UA on TCP registers on node 1; a call from node 2 goes over
%% its connection, through node 1.
%% req: R5626-R-13
tcp_call_through_the_edge(Config) ->
    [N1, N2, _] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    {ok, T} = gen_tcp:connect({127, 0, 0, 1}, P1, [binary, {active, false}]),
    Ct = <<
        "<sip:alice@192.0.2.9:5070;transport=tcp;ob>"
        ";+sip.instance=\"<urn:uuid:t1>\";reg-id=1"
    >>,
    ok = gen_tcp:send(T, tcp_register(lport(T), Ct, 1)),
    {ok, R} = chappe_sip_msg:parse(tcp_recv(T, <<"SIP/2.0">>)),
    ?assertEqual(200, chappe_sip_msg:status(R)),
    [B] = wait_bindings(N2, 1),
    ?assertEqual(N1, maps:get(node, B)),
    ?assertMatch(<<"<sip:127.0.0.1:", _/binary>>, maps:get(edge, B)),
    {ok, Caller} = udp(),
    send(Caller, P2, invite(lport(Caller), <<"ct1">>)),
    {ok, Inv} = chappe_sip_msg:parse(tcp_recv(T, <<"INVITE">>)),
    ?assertEqual(
        <<"sip:alice@192.0.2.9:5070;transport=tcp;ob">>,
        chappe_sip_msg:uri(Inv)
    ),
    ok = gen_tcp:send(T, busy(Inv)),
    _ = recv_status(Caller, 486),
    gen_tcp:close(T).

%% A WebSocket UA registers on node 1: a call from node 2 reaches it over
%% its WS connection through node 1, record-routed there. The caller's BYE
%% goes through node 1 to the WS flow, and in a second call the UA's own
%% BYE goes back through node 1 to the caller.
%% req: R5626-R-13
ws_call_through_the_edge(Config) ->
    [N1, N2, _] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    [W1 | _] = ?config(ws_ports, Config),
    C = ws_connect(W1),
    ok = ws:send(C, {text, ws_register()}),
    _ = recv_ws(<<"SIP/2.0 200">>),
    [B] = wait_bindings(N2, 1),
    ?assertEqual(N1, maps:get(node, B)),
    ?assertMatch(<<"<sip:127.0.0.1:", _/binary>>, maps:get(edge, B)),
    ?assertNotEqual(nomatch, binary:match(maps:get(edge, B), <<";edge=ws">>)),
    %% the caller hangs up
    {ok, Caller} = udp(),
    send(Caller, P2, invite(lport(Caller), <<"cw1">>)),
    {ok, M} = chappe_sip_msg:parse(recv_ws(<<"INVITE ">>)),
    ?assertEqual(
        <<"sip:alice@df7jal23ls0d.invalid;transport=ws">>,
        chappe_sip_msg:uri(M)
    ),
    RRs = chappe_sip_msg:get_all(<<"record-route">>, M),
    ?assertEqual(2, length(RRs)),
    ok = ws:send(C, {text, ws_ok_for(M, RRs)}),
    _ = recv_status(Caller, 200),
    send(
        Caller,
        P1,
        bye_to(
            lport(Caller),
            <<"cw1">>,
            ws_contact_uri(),
            lists:reverse(RRs)
        )
    ),
    {ok, Bye} = chappe_sip_msg:parse(recv_ws(<<"BYE ">>)),
    ok = ws:send(C, {text, response(<<"200 OK">>, Bye, [])}),
    _ = recv_status(Caller, 200),
    %% the UA hangs up: its BYE routes back through node 1 to the caller
    send(Caller, P2, invite(lport(Caller), <<"cw2">>)),
    {ok, M2} = chappe_sip_msg:parse(recv_ws(<<"INVITE ">>)),
    RRs2 = chappe_sip_msg:get_all(<<"record-route">>, M2),
    ok = ws:send(C, {text, ws_ok_for(M2, RRs2)}),
    _ = recv_status(Caller, 200),
    ok = ws:send(C, {text, ws_bye(lport(Caller), <<"cw2">>, RRs2)}),
    {_, P1} = recv_req(Caller, <<"BYE">>),
    ws:close(C, 1000).

%% Every node shares flow_token_secret: a Record-Route or an edge route
%% naming node 1's connection 5 is node 1's only. On node 2, connection 5
%% is another device's.
conn_token_refused_on_another_node(Config) ->
    [N1, N2, _] = ?config(nodes, Config),
    RR = erpc:call(
        N1,
        chappe_sip_route,
        record_route,
        [<<"sip:127.0.0.1:5060">>, {undefined, {conn, 5}}, <<"cn1">>]
    ),
    ?assert(
        erpc:call(N1, chappe_sip_route, is_self, [RR, undefined, <<"cn1">>])
    ),
    ?assertNot(
        erpc:call(N2, chappe_sip_route, is_self, [RR, undefined, <<"cn1">>])
    ),
    Exp = erlang:system_time(second) + 60,
    Edge = erpc:call(
        N1,
        chappe_sip_flow,
        edge_route,
        [<<"sip:127.0.0.1:5060">>, {conn, 5}, <<"tcp">>, Exp]
    ),
    ?assert(
        erpc:call(N1, chappe_sip_route, is_self, [Edge, undefined, <<"x">>])
    ),
    ?assertNot(
        erpc:call(N2, chappe_sip_route, is_self, [Edge, undefined, <<"x">>])
    ),
    %% a UDP address is the same place from either node
    Udp = erpc:call(
        N1,
        chappe_sip_route,
        record_route,
        [
            <<"sip:127.0.0.1:5060">>,
            {undefined, {udp, <<"192.0.2.7">>, 5070}},
            <<"cn1">>
        ]
    ),
    ?assert(
        erpc:call(N2, chappe_sip_route, is_self, [Udp, undefined, <<"cn1">>])
    ).

%% The connection an edge route names is gone without the edge hearing of
%% it: the edge answers 430 Flow Failed (RFC 5626 5.3) and drops the
%% binding. Cut off from the quorum, it drops it once the quorum is back.
%% req: R5626-R-13
dead_flow_at_the_edge(Config) ->
    [N1, N2, N3] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    {ok, [_]} = dead_conn_binding(N1, <<"df1">>),
    [B] = wait_bindings(N2, 1),
    {ok, Caller} = udp(),
    send(Caller, P2, invite(lport(Caller), <<"cf1">>)),
    _ = recv_status(Caller, 430),
    wait(fun() -> erpc:call(N2, chappe_sip, bindings, [?AOR]) =:= [] end),
    %% again, with node 1 alone: the 430 at once, the removal later
    {ok, [_]} = dead_conn_binding(N1, <<"df2">>),
    [B2] = wait_bindings(N2, 1),
    Edge = maps:get(edge, B2),
    cut(N1, [N2, N3]),
    try
        send(Caller, P1, invite_routed(lport(Caller), <<"cf2">>, Edge)),
        _ = recv_status(Caller, 430),
        %% still stored: node 1 could not write the removal
        ?assertMatch(
            {ok, [_], _}, erpc:call(N2, chappe_cluster, get, [key(?AOR)])
        )
    after
        heal(N1, [N2, N3])
    end,
    wait(fun() -> erpc:call(N2, chappe_sip, bindings, [?AOR]) =:= [] end, 300),
    _ = B.

%% A node indexes the flow of a binding it took. The sweep, running on
%% another node, deletes the binding once expired: the first node's index
%% lets go of it too.
flow_index_follows_a_sweep(Config) ->
    Nodes = [N0 | _] = ?config(nodes, Config),
    {ok, Sweeper} = wait_sweeper(N0),
    %% a node the sweep does not run on
    [N1 | _] = Nodes -- [node(Sweeper)],
    {ok, [_]} = erpc:call(
        N1,
        chappe_sip_registry,
        register_contacts,
        [reg_req([contact(1, 2)], <<"ix1">>, 1), #{flow => 7}]
    ),
    ?assertNotEqual([], flow_index(N1)),
    wait(
        fun() ->
            erpc:call(N1, chappe_cluster, get, [key(aor())]) =:= not_found
        end,
        300
    ),
    wait(fun() -> flow_index(N1) =:= [] end, 100).

%% The device registers again through node 2: its binding is node 2's now,
%% and node 1's index lets go of it.
flow_index_follows_a_move(Config) ->
    [N1, N2 | _] = ?config(nodes, Config),
    {ok, [_]} = erpc:call(
        N1,
        chappe_sip_registry,
        register_contacts,
        [reg_req([contact(1, 3600)], <<"ix2">>, 1), #{flow => 7}]
    ),
    ?assertNotEqual([], flow_index(N1)),
    wait(fun() ->
        length(erpc:call(N2, chappe_sip_registry, bindings, [aor()])) =:= 1
    end),
    {ok, [B]} = erpc:call(
        N2,
        chappe_sip_registry,
        register_contacts,
        [reg_req([contact(1, 3600)], <<"ix3">>, 1), #{flow => 9}]
    ),
    ?assertEqual(N2, maps:get(node, B)),
    wait(fun() -> flow_index(N1) =:= [] end, 100),
    ?assertNotEqual([], flow_index(N2)).

%% Node 1 holds many AORs and loses its quorum: the resync, which reads
%% each through the leader, does not hold the registry, so a dropped flow
%% is still handled at once.
resync_without_quorum_does_not_block(Config) ->
    [N1, N2, N3] = ?config(nodes, Config),
    [
        {ok, [_]} = erpc:call(
            N1,
            chappe_sip_registry,
            register_contacts,
            [
                reg_req(
                    <<"<sip:u", (integer_to_binary(I))/binary,
                        "@example.com>">>,
                    [contact(1, 3600)],
                    <<"rq">>,
                    1
                ),
                #{flow => 100 + I}
            ]
        )
     || I <- lists:seq(1, 20)
    ],
    Reg = erpc:call(N1, erlang, whereis, [chappe_sip_registry]),
    cut(N1, [N2, N3]),
    try
        Reg ! resync,
        timer:sleep(200),
        T0 = erlang:monotonic_time(millisecond),
        ok = erpc:call(N1, chappe_sip_registry, remove_flow, [9999]),
        _ = erpc:call(N1, sys, get_state, [Reg, 10000]),
        Took = erlang:monotonic_time(millisecond) - T0,
        ct:pal("remove_flow handled after ~b ms", [Took]),
        ?assert(Took < 1000)
    after
        heal(N1, [N2, N3])
    end.

flow_index(Node) ->
    erpc:call(Node, ets, tab2list, [chappe_sip_registry_flows]).

reg_req(Contacts, CallId, CSeq) ->
    reg_req(aor(), Contacts, CallId, CSeq).

reg_req(Aor, Contacts, CallId, CSeq) ->
    Raw = iolist_to_binary(
        [
            <<"REGISTER sip:example.com SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKix">>,
            CallId,
            <<"\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: ">>,
            Aor,
            <<";tag=ft\r\n">>,
            <<"To: ">>,
            Aor,
            <<"\r\n">>,
            <<"Call-ID: ">>,
            CallId,
            <<"@ct\r\n">>,
            <<"CSeq: ">>,
            integer_to_binary(CSeq),
            <<" REGISTER\r\n">>,
            [[<<"Contact: ">>, C, <<"\r\n">>] || C <- Contacts],
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ),
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    chappe_sip_req:new(Msg, undefined, #{}).

%% The edge cannot forward for a reason other than a lost flow (its WS
%% transport is not there to take the request, as while it restarts):
%% 500, not 430, and the binding stays.
busy_edge_keeps_the_binding(Config) ->
    [N1, N2, _] = ?config(nodes, Config),
    [_, P2, _] = ?config(ports, Config),
    [W1 | _] = ?config(ws_ports, Config),
    C = ws_connect(W1),
    ok = ws:send(C, {text, ws_register()}),
    _ = recv_ws(<<"SIP/2.0 200">>),
    [_] = wait_bindings(N2, 1),
    Ws = erpc:call(N1, erlang, whereis, [chappe_sip_ws_transport]),
    true = erpc:call(N1, erlang, unregister, [chappe_sip_ws_transport]),
    try
        {ok, Caller} = udp(),
        send(Caller, P2, invite(lport(Caller), <<"cb1">>)),
        _ = recv_status(Caller, 500, 15000)
    after
        erpc:call(N1, erlang, register, [chappe_sip_ws_transport, Ws])
    end,
    timer:sleep(500),
    ?assertMatch([_], erpc:call(N1, chappe_sip, bindings, [?AOR])),
    ?assertMatch([_], erpc:call(N2, chappe_sip, bindings, [?AOR])),
    ws:close(C, 1000).

%% A connection closes while the edge forwards over it: the stack answers
%% the branch with a 503 of its own rather than an error. When the edge
%% knows that connection closed, it answers 430 and drops the binding; a
%% 503 over a live connection is relayed as any 503 (a 500 upstream).
transport_503_on_a_closed_flow(Config) ->
    [N1, N2, _] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    {ok, T} = gen_tcp:connect({127, 0, 0, 1}, P1, [binary, {active, false}]),
    Ct = <<
        "<sip:alice@192.0.2.9:5070;transport=tcp;ob>"
        ";+sip.instance=\"<urn:uuid:t5>\";reg-id=1"
    >>,
    ok = gen_tcp:send(T, tcp_register(lport(T), Ct, 1)),
    {ok, _} = chappe_sip_msg:parse(tcp_recv(T, <<"SIP/2.0">>)),
    [_] = wait_bindings(N2, 1),
    [#{flow := {conn, Id}}] = erpc:call(N1, chappe_sip, bindings, [?AOR]),
    {ok, Caller} = udp(),
    %% a live connection: the UA's own 503 goes upstream
    send(Caller, P2, invite(lport(Caller), <<"ct5a">>)),
    {ok, Inv1} = chappe_sip_msg:parse(tcp_recv(T, <<"INVITE">>)),
    ok = gen_tcp:send(T, response(<<"503 Service Unavailable">>, Inv1, [])),
    _ = recv_status(Caller, 500),
    ?assertMatch([_], erpc:call(N1, chappe_sip, bindings, [?AOR])),
    %% the connection is closed under the forward
    send(Caller, P2, invite(lport(Caller), <<"ct5b">>)),
    {ok, Inv2} = chappe_sip_msg:parse(tcp_recv(T, <<"INVITE">>)),
    Engine = erpc:call(N1, erlang, whereis, [chappe_sip_engine]),
    Engine ! {chappe_sip_engine, ws, {flow_closed, Id}},
    timer:sleep(100),
    ok = gen_tcp:send(T, response(<<"503 Service Unavailable">>, Inv2, [])),
    _ = recv_status(Caller, 430),
    wait(fun() -> erpc:call(N2, chappe_sip, bindings, [?AOR]) =:= [] end),
    gen_tcp:close(T).

%% an RFC 5626 TCP binding on Node whose connection does not exist
dead_conn_binding(Node, CallId) ->
    Raw = iolist_to_binary(
        [
            <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/TCP 127.0.0.1:5999;branch=z9hG4bK", CallId/binary,
                "\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: <sip:alice@127.0.0.1>;tag=ft\r\n">>,
            <<"To: <sip:alice@127.0.0.1>\r\n">>,
            <<"Call-ID: ", CallId/binary, "@ct\r\nCSeq: 1 REGISTER\r\n">>,
            <<
                "Contact: <sip:alice@192.0.2.9:5070;transport=tcp;ob>"
                ";+sip.instance=\"<urn:uuid:",
                CallId/binary,
                ">\";reg-id=1\r\n"
            >>,
            <<"Supported: outbound\r\nExpires: 3600\r\nContent-Length: 0\r\n\r\n">>
        ]
    ),
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    erpc:call(
        Node,
        chappe_sip_registry,
        register_contacts,
        [
            chappe_sip_req:new(Msg, undefined, #{}),
            #{outbound_flow => {conn, 987654}, transport => <<"tcp">>}
        ]
    ).

invite_routed(LP, CallId, Route) ->
    P = integer_to_binary(LP),
    <<
        "INVITE sip:alice@192.0.2.9:5070;transport=tcp;ob SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=z9hG4bKcr",
        CallId/binary,
        "\r\n"
        "Route: ",
        Route/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:bob@127.0.0.1>;tag=cb\r\n"
        "To: <sip:alice@127.0.0.1>\r\n"
        "Contact: <sip:bob@127.0.0.1:",
        P/binary,
        ">\r\n"
        "Call-ID: ",
        CallId/binary,
        "@ct\r\nCSeq: 1 INVITE\r\n"
        "Content-Length: 0\r\n\r\n"
    >>.

%% Node can no longer reach Others, nor they it (a cookie apart, so
%% distribution does not reconnect)
cut(Node, Others) ->
    [
        begin
            true = erpc:call(Node, erlang, set_cookie, [N, 'clc-cut-a']),
            true = erpc:call(N, erlang, set_cookie, [Node, 'clc-cut-b']),
            _ = erpc:call(Node, erlang, disconnect_node, [N]),
            _ = erpc:call(N, erlang, disconnect_node, [Node])
        end
     || N <- Others
    ],
    ok.

heal(Node, Others) ->
    Cookie = erlang:get_cookie(),
    [
        begin
            _ = erpc:call(Node, erlang, set_cookie, [N, Cookie]),
            _ = erpc:call(N, erlang, set_cookie, [Node, Cookie]),
            _ = erpc:call(N, net_kernel, connect_node, [Node])
        end
     || N <- Others
    ],
    ok.

%% A UA reachable at its Contact gets no edge route: node 2 sends to it
%% directly.
public_contact_is_sent_directly(Config) ->
    [_, N2, _] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    {ok, Dev} = udp(),
    send(Dev, P1, register_req(lport(Dev), 3600, 1, own_contact(Dev))),
    _ = recv_status(Dev, 200),
    [B] = wait_bindings(N2, 1),
    ?assertEqual(undefined, maps:get(edge, B)),
    ?assertEqual([], maps:get(path, B)),
    {ok, Caller} = udp(),
    send(Caller, P2, invite(lport(Caller), <<"cp1">>)),
    {_, P2} = recv_req(Dev, <<"INVITE">>).

%% RFC 3261 10.3 across nodes: a REGISTER on another node with the same
%% Call-ID and a CSeq no higher fails, a higher one with expires=0 removes
%% the binding everywhere, and Contact: * clears the AOR.
%% req: R3261-R-27 R3261-R-28 R3261-R-18
cseq_and_expires_across_nodes(Config) ->
    [N1, N2, N3] = ?config(nodes, Config),
    {ok, [_]} = reg(N1, [contact(1, 3600)], undefined, <<"c1">>, 5),
    wait(fun() ->
        length(erpc:call(N2, chappe_sip_registry, bindings, [aor()])) =:= 1
    end),
    ?assertEqual(
        {error, 400}, reg(N2, [contact(1, 1800)], undefined, <<"c1">>, 5)
    ),
    ?assertEqual(
        {error, 400}, reg(N2, [contact(1, 1800)], undefined, <<"c1">>, 4)
    ),
    {ok, [B2]} = reg(N2, [contact(1, 60)], undefined, <<"c1">>, 6),
    ?assert(maps:get(expires, B2) =< 60),
    wait(fun() ->
        [#{expires := E}] = erpc:call(N3, chappe_sip_registry, bindings, [aor()]),
        E =< 60
    end),
    {ok, []} = reg(N3, [contact(1, 0)], undefined, <<"c1">>, 7),
    wait(fun() ->
        erpc:call(N1, chappe_sip_registry, bindings, [aor()]) =:= []
    end),
    {ok, [_]} = reg(N1, [contact(2, 3600)], undefined, <<"c2">>, 1),
    {ok, [_, _]} = reg(N2, [contact(3, 3600)], undefined, <<"c3">>, 1),
    {ok, []} = reg(N3, [<<"*">>], 0, <<"c4">>, 1),
    wait(fun() ->
        erpc:call(N1, chappe_sip_registry, bindings, [aor()]) =:= []
    end),
    ?assertEqual(not_found, erpc:call(N1, chappe_cluster, get, [key(aor())])).

%% Node 1 stops: its UDP binding behind a NAT is reached directly at its
%% address, from node 2; its TCP binding is gone with the connection.
edge_node_down(Config) ->
    [{Peer1, _} | _] = ?config(peers, Config),
    [_, N2, _] = ?config(nodes, Config),
    [P1, P2, _] = ?config(ports, Config),
    {ok, Dev} = udp(),
    send(Dev, P1, register_req(lport(Dev), 3600, 1, ?NAT_CONTACT)),
    _ = recv_status(Dev, 200),
    {ok, T} = gen_tcp:connect({127, 0, 0, 1}, P1, [binary, {active, false}]),
    Ct = <<
        "<sip:alice@192.0.2.9:5070;transport=tcp;ob>"
        ";+sip.instance=\"<urn:uuid:t2>\";reg-id=1"
    >>,
    ok = gen_tcp:send(T, tcp_register(lport(T), Ct, 1)),
    {ok, _} = chappe_sip_msg:parse(tcp_recv(T, <<"SIP/2.0">>)),
    [_, _] = wait_bindings(N2, 2),
    ok = stop_peer(Peer1),
    wait(fun() -> length(erpc:call(N2, chappe_sip, bindings, [?AOR])) =:= 1 end),
    [B] = erpc:call(N2, chappe_sip, bindings, [?AOR]),
    ?assertEqual({udp, <<"127.0.0.1">>, lport(Dev)}, maps:get(send_flow, B)),
    {ok, Caller} = udp(),
    send(Caller, P2, invite(lport(Caller), <<"cd1">>)),
    {_, P2} = recv_req(Dev, <<"INVITE">>),
    gen_tcp:close(T).

%% Two of three nodes stop: a REGISTER on the last one gets 503 with
%% Retry-After within the short timeout, and a call to the UA it already
%% holds still goes through, from its replica.
lost_quorum_refuses_register(Config) ->
    [_, {Peer2, _}, {Peer3, _}] = ?config(peers, Config),
    [N1 | _] = ?config(nodes, Config),
    [P1 | _] = ?config(ports, Config),
    {ok, Dev} = udp(),
    send(Dev, P1, register_req(lport(Dev), 3600, 1, own_contact(Dev))),
    _ = recv_status(Dev, 200),
    ok = stop_peer(Peer2),
    ok = stop_peer(Peer3),
    T0 = erlang:monotonic_time(millisecond),
    send(Dev, P1, register_req(lport(Dev), 3600, 2, own_contact(Dev))),
    Resp = recv_status(Dev, 503, 8000),
    Took = erlang:monotonic_time(millisecond) - T0,
    ct:pal("503 after ~b ms", [Took]),
    ?assert(Took < 4000),
    {ok, M} = chappe_sip_msg:parse(Resp),
    ?assertEqual(<<"5">>, chappe_sip_msg:get(<<"retry-after">>, M)),
    ?assertMatch([_], erpc:call(N1, chappe_sip, bindings, [?AOR])),
    {ok, Caller} = udp(),
    send(Caller, P1, invite(lport(Caller), <<"cq1">>)),
    {_, P1} = recv_req(Dev, <<"INVITE">>).

%% The sweep runs on one node; stop that node and another one takes it
%% over and deletes the expired AOR's key.
sweep_singleton_moves(Config) ->
    Peers = ?config(peers, Config),
    Nodes = [N1 | _] = ?config(nodes, Config),
    {ok, Pid} = wait_sweeper(N1),
    Owner = node(Pid),
    [Other | _] = Nodes -- [Owner],
    {ok, [_]} = reg(Other, [contact(1, 2)], undefined, <<"s1">>, 1),
    {Peer, Owner} = lists:keyfind(Owner, 2, Peers),
    ok = stop_peer(Peer),
    wait(
        fun() ->
            case
                erpc:call(Other, chappe_cluster, whereis_singleton, [
                    sweep_name()
                ])
            of
                {ok, P} -> node(P) =/= Owner;
                none -> false
            end
        end,
        300
    ),
    wait(
        fun() ->
            erpc:call(Other, chappe_cluster, get, [key(aor())]) =:= not_found
        end,
        300
    ).

%% Kill the sweep: a new one starts, found from every node.
sweep_child_restarts_after_a_crash(Config) ->
    Nodes = [N1 | _] = ?config(nodes, Config),
    {ok, Pid} = wait_sweeper(N1),
    exit(Pid, kill),
    wait(
        fun() ->
            lists:all(
                fun(N) ->
                    case
                        erpc:call(N, chappe_cluster, whereis_singleton, [
                            sweep_name()
                        ])
                    of
                        {ok, P} -> P =/= Pid andalso is_pid(P);
                        none -> false
                    end
                end,
                Nodes
            )
        end,
        300
    ),
    {ok, [_]} = reg(N1, [contact(1, 2)], undefined, <<"s2">>, 1),
    wait(
        fun() ->
            erpc:call(N1, chappe_cluster, get, [key(aor())]) =:= not_found
        end,
        300
    ).

%% ---- peer nodes ----

dist() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            Name = list_to_atom("chappe_ct_" ++ os:getpid() ++ "@localhost"),
            {ok, _} = net_kernel:start(Name, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.

peer(Base) ->
    Name = list_to_atom(
        Base ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    [_, Host] = string:split(atom_to_list(node()), "@"),
    {ok, Peer, Node} = peer:start_link(#{
        name => Name,
        host => Host,
        connection => standard_io,
        args => ["-kernel", "prevent_overlapping_partitions", "false" | Paths]
    }),
    ok = connect(Node, 50),
    {Peer, Node}.

connect(Node, 0) ->
    error({no_connection, Node});
connect(Node, N) ->
    case net_kernel:connect_node(Node) of
        true ->
            ok;
        _ ->
            timer:sleep(200),
            connect(Node, N - 1)
    end.

stop_peer(Peer) ->
    try
        peer:stop(Peer)
    catch
        exit:_ -> ok
    end.

%% chappe_cluster on Node, one of Voters
start_cluster(Node, Voters, Dir) ->
    Cluster = #{
        voters => Voters,
        lease_ms => ?LEASE,
        renew_ms => ?RENEW,
        command_timeout => 2000,
        data_dir => Dir
    },
    ok = erpc:call(Node, application, load, [chappe_cluster]),
    [
        ok = erpc:call(Node, application, set_env, [chappe_cluster, K, V])
     || K := V <- Cluster
    ],
    {ok, _} = erpc:call(Node, application, ensure_all_started, [chappe_cluster]),
    ok.

%% chappe_sip on a cluster, a registrar and the call handler; the engine's
%% port
start_sip(Node) ->
    Sip = #{
        engine_mod => chappe_sip_nif,
        cluster => chappe_cluster,
        registrar_min_expires => 0,
        registrar_sweep_ms => 300,
        flow_token_secret => <<"clc-shared-secret-0123">>
    },
    ok = erpc:call(Node, application, load, [chappe_sip]),
    [
        ok = erpc:call(Node, application, set_env, [chappe_sip, K, V])
     || K := V <- Sip
    ],
    {ok, _} = erpc:call(Node, application, ensure_all_started, [chappe_sip]),
    Port = pick(),
    WsPort = pick(),
    ok = erpc:call(Node, ?MODULE, serve, [Port, WsPort]),
    {Port, WsPort}.

%% runs on the peer
serve(Port, WsPort) ->
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(Port))/binary>>,
        ws => #{port => WsPort}
    }),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    chappe_sip:invite(fun ?MODULE:call/2).

call(Req, Res) ->
    case chappe_sip:location_target(?AOR) of
        {ok, Target} -> chappe_sip:proxy_request(Req, Target, #{});
        {error, not_found} -> chappe_sip_res:send(Res, 480)
    end.

%% a port in this lane's range (17000-17999) nothing holds
pick() ->
    pick(50).

pick(0) ->
    error(no_free_port);
pick(N) ->
    Port =
        17000 +
            (erlang:phash2(os:getpid(), 1000) +
                erlang:unique_integer([positive, monotonic])) rem 1000,
    case gen_udp:open(Port, [{ip, {127, 0, 0, 1}}]) of
        {ok, S} ->
            ok = gen_udp:close(S),
            case gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}]) of
                {ok, L} ->
                    ok = gen_tcp:close(L),
                    Port;
                {error, _} ->
                    pick(N - 1)
            end;
        {error, _} ->
            pick(N - 1)
    end.

wait_sweeper(Node) ->
    wait(
        fun() ->
            erpc:call(Node, chappe_cluster, whereis_singleton, [sweep_name()]) =/=
                none
        end,
        300
    ),
    erpc:call(Node, chappe_cluster, whereis_singleton, [sweep_name()]).

sweep_name() ->
    chappe_sip_registry_sweep.

wait_bindings(Node, N) ->
    wait(fun() ->
        length(erpc:call(Node, chappe_sip, bindings, [?AOR])) =:= N
    end),
    erpc:call(Node, chappe_sip, bindings, [?AOR]).

writable(Node) ->
    case erpc:call(Node, chappe_cluster, put, [<<"ct/writable">>, Node]) of
        {ok, _} -> true;
        _ -> false
    end.

wait(F) ->
    wait(F, 100).

wait(F, 0) ->
    ?assert(F());
wait(F, N) ->
    case
        try
            F()
        catch
            _:_ -> false
        end
    of
        true ->
            ok;
        _ ->
            timer:sleep(100),
            wait(F, N - 1)
    end.

key(Aor) ->
    {ok, A} = chappe_sip_uri:aor(chappe_sip_hdr:name_addr_uri(Aor)),
    <<"chappe_sip/aor/", A/binary>>.

%% ---- messages ----

aor() -> <<"<sip:alice@example.com>">>.
curi(N) -> <<"sip:alice@10.0.0.", (integer_to_binary(N))/binary>>.
contact(N, Exp) ->
    <<"<", (curi(N))/binary, ">;expires=", (integer_to_binary(Exp))/binary>>.

%% a REGISTER applied to the store on Node
reg(Node, Contacts, ExpiresHdr, CallId, CSeq) ->
    CS = integer_to_binary(CSeq),
    Raw = iolist_to_binary(
        [
            <<"REGISTER sip:example.com SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKreg\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: ">>,
            aor(),
            <<";tag=ft\r\n">>,
            <<"To: ">>,
            aor(),
            <<"\r\n">>,
            <<"Call-ID: ">>,
            CallId,
            <<"@ct\r\n">>,
            <<"CSeq: ">>,
            CS,
            <<" REGISTER\r\n">>,
            [[<<"Contact: ">>, C, <<"\r\n">>] || C <- Contacts],
            case ExpiresHdr of
                undefined -> [];
                E -> [<<"Expires: ">>, integer_to_binary(E), <<"\r\n">>]
            end,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ),
    {ok, Msg} = chappe_sip_msg:parse(Raw),
    erpc:call(
        Node,
        chappe_sip_registry,
        register_contacts,
        [chappe_sip_req:new(Msg, undefined, #{}), #{}]
    ).

own_contact(Sock) ->
    <<"<sip:alice@127.0.0.1:", (integer_to_binary(lport(Sock)))/binary, ">">>.

register_req(LP, Exp, CSeq, Contact) ->
    P = integer_to_binary(LP),
    CS = integer_to_binary(CSeq),
    iolist_to_binary(
        [
            <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKr",
                CS/binary, "\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: Alice <sip:alice@127.0.0.1>;tag=ft\r\n">>,
            <<"To: Alice <sip:alice@127.0.0.1>\r\n">>,
            <<"Contact: ">>,
            Contact,
            <<"\r\n">>,
            <<"Expires: ">>,
            integer_to_binary(Exp),
            <<"\r\n">>,
            <<"Call-ID: reg-">>,
            P,
            <<"@ct\r\n">>,
            <<"CSeq: ">>,
            CS,
            <<" REGISTER\r\nContent-Length: 0\r\n\r\n">>
        ]
    ).

tcp_register(LP, Contact, CSeq) ->
    P = integer_to_binary(LP),
    iolist_to_binary(
        [
            <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/TCP 127.0.0.1:", P/binary, ";branch=z9hG4bKt">>,
            integer_to_binary(CSeq),
            <<"\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: Alice <sip:alice@127.0.0.1>;tag=ft\r\n">>,
            <<"To: Alice <sip:alice@127.0.0.1>\r\n">>,
            <<"Contact: ">>,
            Contact,
            <<"\r\n">>,
            <<"Supported: outbound\r\n">>,
            <<"Expires: 3600\r\n">>,
            <<"Call-ID: treg-">>,
            P,
            <<"@ct\r\n">>,
            <<"CSeq: ">>,
            integer_to_binary(CSeq),
            <<" REGISTER\r\nContent-Length: 0\r\n\r\n">>
        ]
    ).

invite(LP, CallId) ->
    P = integer_to_binary(LP),
    <<
        "INVITE sip:alice@127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:",
        P/binary,
        ";rport;branch=z9hG4bKci",
        CallId/binary,
        "\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:bob@127.0.0.1>;tag=cb\r\n"
        "To: <sip:alice@127.0.0.1>\r\n"
        "Contact: <sip:bob@127.0.0.1:",
        P/binary,
        ">\r\n"
        "Call-ID: ",
        CallId/binary,
        "@ct\r\nCSeq: 1 INVITE\r\n"
        "Content-Length: 0\r\n\r\n"
    >>.

bye(LP, CallId, Routes) ->
    bye_to(LP, CallId, <<"sip:alice@192.0.2.50:5060">>, Routes).

bye_to(LP, CallId, Target, Routes) ->
    P = integer_to_binary(LP),
    iolist_to_binary(
        [
            <<"BYE ", Target/binary, " SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/UDP 127.0.0.1:", P/binary,
                ";rport;branch=z9hG4bKby", CallId/binary, "\r\n">>,
            [[<<"Route: ">>, R, <<"\r\n">>] || R <- Routes],
            <<"Max-Forwards: 70\r\n">>,
            <<"From: <sip:bob@127.0.0.1>;tag=cb\r\n">>,
            <<"To: <sip:alice@127.0.0.1>;tag=al\r\n">>,
            <<"Call-ID: ", CallId/binary, "@ct\r\nCSeq: 2 BYE\r\n">>,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ).

%% a 200 to M echoing its Vias and Record-Routes
ok_for(M, RRs) ->
    response(
        <<"200 OK">>,
        M,
        [[<<"Record-Route: ">>, R, <<"\r\n">>] || R <- RRs] ++
            [<<"Contact: <sip:alice@192.0.2.50:5060>\r\n">>]
    ).

busy(M) ->
    response(<<"486 Busy Here">>, M, []).

response(Status, M, Extra) ->
    Vias = [
        [<<"Via: ">>, V, <<"\r\n">>]
     || V <- chappe_sip_msg:get_all(<<"via">>, M)
    ],
    iolist_to_binary(
        [
            <<"SIP/2.0 ">>,
            Status,
            <<"\r\n">>,
            Vias,
            <<"From: ">>,
            chappe_sip_msg:get(<<"from">>, M),
            <<"\r\n">>,
            <<"To: ">>,
            chappe_sip_msg:get(<<"to">>, M),
            case chappe_sip_msg:to_tag(M) of
                undefined -> <<";tag=al">>;
                _ -> <<>>
            end,
            <<"\r\n">>,
            <<"Call-ID: ">>,
            chappe_sip_msg:call_id(M),
            <<"\r\n">>,
            <<"CSeq: ">>,
            chappe_sip_msg:get(<<"cseq">>, M),
            <<"\r\n">>,
            Extra,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ).

%% ---- WebSocket UA ----

ws_connect(WP) ->
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{
        handler => chappe_sip_ws_test_client,
        handler_opts => #{notify => self()},
        subprotocols => [<<"sip">>]
    }),
    C.

ws_contact_uri() ->
    <<"sip:alice@df7jal23ls0d.invalid;transport=ws">>.

ws_register() ->
    <<
        "REGISTER sip:127.0.0.1 SIP/2.0\r\n"
        "Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsreg\r\n"
        "Max-Forwards: 70\r\n"
        "From: <sip:alice@127.0.0.1>;tag=wsreg\r\n"
        "To: <sip:alice@127.0.0.1>\r\n"
        "Contact: <sip:alice@df7jal23ls0d.invalid;transport=ws>\r\n"
        "Call-ID: wsreg-call@ct\r\n"
        "CSeq: 1 REGISTER\r\nExpires: 3600\r\nContent-Length: 0\r\n\r\n"
    >>.

ws_ok_for(M, RRs) ->
    response(
        <<"200 OK">>,
        M,
        [[<<"Record-Route: ">>, R, <<"\r\n">>] || R <- RRs] ++
            [<<"Contact: <">>, ws_contact_uri(), <<">\r\n">>]
    ).

%% the UA's BYE: its route set is the Record-Route as it got it
ws_bye(CallerPort, CallId, RRs) ->
    P = integer_to_binary(CallerPort),
    iolist_to_binary(
        [
            <<"BYE sip:bob@127.0.0.1:", P/binary, " SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKwsbye",
                CallId/binary, "\r\n">>,
            [[<<"Route: ">>, R, <<"\r\n">>] || R <- RRs],
            <<"Max-Forwards: 70\r\n">>,
            <<"From: <sip:alice@127.0.0.1>;tag=al\r\n">>,
            <<"To: <sip:bob@127.0.0.1>;tag=cb\r\n">>,
            <<"Call-ID: ", CallId/binary, "@ct\r\nCSeq: 1 BYE\r\n">>,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ).

%% the next text frame starting with Prefix
recv_ws(Prefix) ->
    L = byte_size(Prefix),
    receive
        {ws_in, <<Prefix:L/binary, _/binary>> = Bin} -> Bin;
        {ws_in, _Other} -> recv_ws(Prefix)
    after 8000 -> ct:fail({no_ws_frame, Prefix})
    end.

%% ---- sockets ----

udp() ->
    gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]).

lport(Sock) ->
    {ok, P} = inet:port(Sock),
    P.

send(Sock, Port, Bin) ->
    ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, Bin).

recv_status(Sock, Code) ->
    recv_status(Sock, Code, 8000).

recv_status(Sock, Code, Timeout) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of
                CB -> Bin;
                _ -> recv_status(Sock, Code, Timeout)
            end
    after Timeout -> ct:fail({no_status, Code})
    end.

%% the next request of Method on Sock, and the port it came from
recv_req(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Port, <<Method:L/binary, " ", _/binary>> = Bin} ->
            {Bin, Port}
    after 8000 -> ct:fail({no_request, Method})
    end.

tcp_recv(T, Prefix) ->
    tcp_recv(T, Prefix, <<>>).

tcp_recv(T, Prefix, Buf) ->
    case tcp_frame(Buf) of
        {ok, Msg, Rest} ->
            L = byte_size(Prefix),
            case Msg of
                <<Prefix:L/binary, _/binary>> -> Msg;
                _ -> tcp_recv(T, Prefix, Rest)
            end;
        more ->
            case gen_tcp:recv(T, 0, 8000) of
                {ok, D} -> tcp_recv(T, Prefix, <<Buf/binary, D/binary>>);
                Err -> ct:fail({no_tcp_msg, Prefix, Err})
            end
    end.

tcp_frame(<<"\r\n", Rest/binary>>) ->
    tcp_frame(Rest);
tcp_frame(Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Tail] ->
            {ok, M} = chappe_sip_msg:parse(<<Head/binary, "\r\n\r\n">>),
            Len = binary_to_integer(
                chappe_sip_msg:get(<<"content-length">>, M)
            ),
            case Tail of
                <<Body:Len/binary, Rest/binary>> ->
                    {ok, <<Head/binary, "\r\n\r\n", Body/binary>>, Rest};
                _ ->
                    more
            end;
        _ ->
            more
    end.
