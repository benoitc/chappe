%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Peers kept alive with OPTIONS (chappe_sip_peers), failover of a B2BUA
%% call across a peer group, and the registrar's keepalive of UDP
%% contacts (qualify), over real SIP on loopback. Each peer is a gen_udp
%% process answering OPTIONS as the case tells it: a status, or nothing.
-module(chappe_sip_peers_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    up_then_down_then_up/1,
    unavailable_is_down/1,
    alive_codes/1,
    select_policies/1,
    add_remove/1,
    env_peers/1,
    b2bua_peer_group_failover/1,
    b2bua_peer_group_none_up/1,
    registrar_qualify_drops_binding/1,
    registrar_qualify_reaches_nated_contact/1,
    b2bua_to_nated_callee/1,
    b2bua_uri_list_failover/1
]).

-define(UA, chappe_sip_test_ua).

all() ->
    [
        up_then_down_then_up,
        unavailable_is_down,
        alive_codes,
        select_policies,
        add_remove,
        env_peers,
        b2bua_peer_group_failover,
        b2bua_peer_group_none_up,
        registrar_qualify_drops_binding,
        registrar_qualify_reaches_nated_contact,
        b2bua_to_nated_callee,
        b2bua_uri_list_failover
    ].

init_per_suite(Config) ->
    application:set_env(
        chappe_sip,
        engine_mod,
        chappe_sip_nif,
        [{persistent, true}]
    ),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    EP = ?UA:pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>
    }),
    ok = chappe_sip:peer_subscribe(self()),
    [{ep, EP} | Config].

end_per_testcase(_Case, _Config) ->
    _ = [chappe_sip:peer_remove(N) || {N, _} <- chappe_sip:peers()],
    ok = chappe_sip_peers:unsubscribe(self()),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok = chappe_sip_registry:clear(),
    ok.

%% ---- cases ----

%% An answered OPTIONS makes the peer up; two unanswered ones in a row make
%% it down; answers again bring it back.
%% req: R3261-11-1
up_then_down_then_up(_Config) ->
    {Port, P} = responder(200),
    ok = chappe_sip:peer_add(fs1, opts(Port, #{})),
    ok = ?UA:expect({chappe_sip_peer, fs1, up}, 3000),
    {ok, #{state := up, last_status := 200}} = chappe_sip:peer_status(fs1),
    P ! {mode, silent},
    ok = ?UA:expect({chappe_sip_peer, fs1, down}, 4000),
    {ok, #{state := down, last_status := timeout}} = chappe_sip:peer_status(
        fs1
    ),
    P ! {mode, 200},
    ok = ?UA:expect({chappe_sip_peer, fs1, up}, 3000).

%% 503 (and 408) are not answers: the peer goes down.
%% req: R3261-11-1
unavailable_is_down(_Config) ->
    {Port, _} = responder(503),
    ok = chappe_sip:peer_add(fs1, opts(Port, #{})),
    ok = ?UA:expect({chappe_sip_peer, fs1, down}, 4000),
    {ok, #{last_status := 503}} = chappe_sip:peer_status(fs1).

%% Any other final is an answer (a 404 from a proxy that does not serve
%% OPTIONS), unless alive_codes says otherwise.
%% req: R3261-11-1
alive_codes(_Config) ->
    {Port, _} = responder(404),
    ok = chappe_sip:peer_add(lax, opts(Port, #{})),
    ok = chappe_sip:peer_add(strict, opts(Port, #{alive_codes => [200]})),
    ok = ?UA:expect({chappe_sip_peer, lax, up}, 3000),
    ok = ?UA:expect({chappe_sip_peer, strict, down}, 4000).

%% priority picks the lowest number, round_robin takes turns, weighted
%% only picks up peers, and an empty group has none.
select_policies(_Config) ->
    {P1, _} = responder(200),
    {P2, _} = responder(200),
    ok = chappe_sip:peer_add(a, opts(P1, #{group => g, priority => 1})),
    ok = chappe_sip:peer_add(b, opts(P2, #{group => g, priority => 5})),
    ok = ?UA:expect({chappe_sip_peer, a, up}, 3000),
    ok = ?UA:expect({chappe_sip_peer, b, up}, 3000),
    UriA = uri(P1),
    UriB = uri(P2),
    ?assertEqual({ok, UriA}, chappe_sip:peer_select(g, priority)),
    RR = [
        element(2, chappe_sip:peer_select(g, round_robin))
     || _ <- lists:seq(1, 4)
    ],
    ?assertEqual(lists:sort([UriA, UriA, UriB, UriB]), lists:sort(RR)),
    {ok, W} = chappe_sip:peer_select(g, weighted),
    ?assert(lists:member(W, [UriA, UriB])),
    ?assertEqual([UriA, UriB], chappe_sip_peers:candidates(g, priority)),
    ?assertEqual({error, none_up}, chappe_sip:peer_select(nogroup, priority)).

%% A name is taken once; removing a peer forgets it.
add_remove(_Config) ->
    {Port, _} = responder(200),
    ok = chappe_sip:peer_add(x, opts(Port, #{})),
    ?assertEqual(
        {error, already_exists}, chappe_sip:peer_add(x, opts(Port, #{}))
    ),
    ?assertEqual(
        {error, bad_uri}, chappe_sip:peer_add(y, #{uri => <<"nope">>})
    ),
    ?assertMatch([{x, #{uri := _}}], chappe_sip:peers()),
    ok = chappe_sip:peer_remove(x),
    ?assertEqual({error, not_found}, chappe_sip:peer_status(x)),
    ?assertEqual({error, not_found}, chappe_sip:peer_remove(x)).

%% Peers of the `peers' setting are added when the application starts.
env_peers(_Config) ->
    {Port, _} = responder(200),
    application:set_env(chappe_sip, peers, [{envpeer, opts(Port, #{})}]),
    try
        ignore = chappe_sip_peers:load_env(),
        ok = ?UA:expect({chappe_sip_peer, envpeer, up}, 3000)
    after
        application:unset_env(chappe_sip, peers)
    end.

%% A call to a peer group goes to the best up peer; its 503 moves the
%% call to the next one.
%% req: R3263-4.3-1
b2bua_peer_group_failover(Config) ->
    EP = ?config(ep, Config),
    {P1, _} = responder(200, #{invite => 503}),
    {P2, _} = responder(200, #{invite => 200}),
    ok = chappe_sip:peer_add(fs1, opts(P1, #{group => fs, priority => 1})),
    ok = chappe_sip:peer_add(fs2, opts(P2, #{group => fs, priority => 2})),
    ok = ?UA:expect({chappe_sip_peer, fs1, up}, 3000),
    ok = ?UA:expect({chappe_sip_peer, fs2, up}, 3000),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {b2b, chappe_sip:create_b2bua(Req, Res, {peer_group, fs}, #{})}
    end),
    R = call(EP),
    ?assertEqual(200, ?UA:status(R)),
    ok = ?UA:expect({invited, P1}),
    ok = ?UA:expect({invited, P2}),
    receive
        {b2b, {ok, _}} -> ok
    after 5000 -> ct:fail(no_b2b)
    end.

%% A list of URIs is tried in turn the same way, and b_headers go on
%% every INVITE to B.
%% req: R3263-4.3-1
b2bua_uri_list_failover(Config) ->
    EP = ?config(ep, Config),
    {P1, _} = responder(200, #{invite => 503}),
    {P2, _} = responder(200, #{invite => 200}),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test !
            {b2b,
                chappe_sip:create_b2bua(
                    Req,
                    Res,
                    [uri(P1), uri(P2)],
                    #{b_headers => [{<<"X-Chappe-Call">>, <<"c-1">>}]}
                )}
    end),
    ?assertEqual(200, ?UA:status(call(EP))),
    ok = ?UA:expect({x_chappe_call, P1, <<"c-1">>}),
    ok = ?UA:expect({x_chappe_call, P2, <<"c-1">>}),
    receive
        {b2b, {ok, _}} -> ok
    after 5000 -> ct:fail(no_b2b)
    end.

%% No peer of the group is up: 503 before anything is sent.
b2bua_peer_group_none_up(Config) ->
    EP = ?config(ep, Config),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test !
            {b2b, chappe_sip:create_b2bua(Req, Res, {peer_group, empty}, #{})}
    end),
    ?assertEqual(503, ?UA:status(call(EP))),
    receive
        {b2b, R} -> ?assertEqual({error, none_up}, R)
    after 5000 -> ct:fail(no_b2b)
    end.

%% qualify_interval_ms: a contact registered over UDP gets OPTIONS; once it
%% stops answering, its binding goes and the subscribers hear of it.
%% req: R3261-11-1
registrar_qualify_drops_binding(Config) ->
    EP = ?config(ep, Config),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{
            allow_unauthenticated => true,
            domains => any,
            qualify_interval_ms => 300,
            qualify_down_after => 2,
            qualify_timeout_ms => 300
        })
    ),
    {Port, P} = responder(200),
    Contact = uri(Port),
    P ! {register, EP, Contact},
    receive
        {reg_status, 200} -> ok
    after 5000 -> ct:fail(not_registered)
    end,
    ?assertEqual([Contact], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    ok = ?UA:expect({options, Port}, 3000),
    P ! {mode, silent},
    receive
        {chappe_sip_qualify, _Aor, C, unreachable} -> ?assertEqual(Contact, C)
    after 5000 -> ct:fail(no_qualify_event)
    end,
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)).

%% A UA behind a NAT registers a private Contact it cannot be reached
%% at: the keepalive goes where its REGISTER came from, so the binding
%% stays.
%% req: R3261-11-1
registrar_qualify_reaches_nated_contact(Config) ->
    EP = ?config(ep, Config),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{
            allow_unauthenticated => true,
            domains => any,
            qualify_interval_ms => 300,
            qualify_down_after => 2,
            qualify_timeout_ms => 300
        })
    ),
    {Port, P} = responder(200),
    P ! {register, EP, <<"sip:alice@10.99.99.99:5999">>},
    receive
        {reg_status, 200} -> ok
    after 5000 -> ct:fail(not_registered)
    end,
    ok = ?UA:expect({options, Port}, 3000),
    ok = ?UA:expect({options, Port}, 3000),
    timer:sleep(1000),
    ?assertEqual(
        [<<"sip:alice@10.99.99.99:5999">>],
        chappe_sip:location(<<"sip:alice@127.0.0.1">>)
    ).

%% A call to that UA, through location_flow/1, reaches it at its source,
%% and so does the BYE of its dialog.
%% req: R3261-12.2.2-1
b2bua_to_nated_callee(Config) ->
    EP = ?config(ep, Config),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{
            allow_unauthenticated => true, domains => any
        })
    ),
    {Port, P} = responder(200, #{invite => 200}),
    P ! {register, EP, <<"sip:alice@10.99.99.99:5999">>},
    receive
        {reg_status, 200} -> ok
    after 5000 -> ct:fail(not_registered)
    end,
    {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@127.0.0.1">>),
    ?assertMatch({udp, <<"127.0.0.1">>, Port}, Flow),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}),
        Test ! b2b_up,
        chappe_sip_b2b:relay(Legs)
    end),
    {Caller, CallerDialog} = call_keep(EP),
    ok = ?UA:expect({invited, Port}),
    ok = ?UA:expect(b2b_up),
    Caller ! {bye, CallerDialog},
    ok = ?UA:expect({bye, Port}, 5000).

%% ---- helpers ----

opts(Port, Extra) ->
    maps:merge(
        #{
            uri => uri(Port),
            interval_ms => 300,
            timeout_ms => 300,
            up_after => 1,
            down_after => 2
        },
        Extra
    ).

uri(Port) -> <<"sip:peer@127.0.0.1:", (integer_to_binary(Port))/binary>>.

responder(Status) -> responder(Status, #{}).

%% A UDP peer answering OPTIONS with Mode (a status or silent); an INVITE
%% gets maps:get(invite, How) (then the call is ACKed and left up).
responder(Status, How) ->
    Test = self(),
    Port = ?UA:pick(),
    Pid = ?UA:peer(Port, fun(Sock) ->
        respond_loop(Sock, Port, Status, How, Test)
    end),
    {Port, Pid}.

respond_loop(Sock, Port, Mode, How, Test) ->
    receive
        {mode, M} ->
            respond_loop(Sock, Port, M, How, Test);
        {register, EP, Contact} ->
            ?UA:send(Sock, EP, register_req(Sock, Contact)),
            respond_loop(Sock, Port, Mode, How, Test);
        {udp, Sock, _, _, <<"SIP/2.0 ", _/binary>> = R} ->
            _ =
                case ?UA:cseq(R) of
                    #{method := <<"REGISTER">>} ->
                        Test ! {reg_status, ?UA:status(R)};
                    _ ->
                        ok
                end,
            respond_loop(Sock, Port, Mode, How, Test);
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = Req} ->
            Test ! {bye, Port},
            ?UA:send(Sock, Src, ?UA:resp(Req, 200, <<"OK">>, <<>>, [], <<>>)),
            respond_loop(Sock, Port, Mode, How, Test);
        {udp, Sock, _, Src, <<"OPTIONS ", _/binary>> = Req} ->
            Test ! {options, Port},
            _ =
                case Mode of
                    silent ->
                        ok;
                    St ->
                        ?UA:send(
                            Sock,
                            Src,
                            ?UA:resp(Req, St, <<"X">>, ?UA:tag(), [], <<>>)
                        )
                end,
            respond_loop(Sock, Port, Mode, How, Test);
        {udp, Sock, _, Src, <<"INVITE ", _/binary>> = Req} ->
            Test ! {invited, Port},
            Test ! {x_chappe_call, Port, ?UA:hdr(Req, <<"x-chappe-call">>)},
            St = maps:get(invite, How, 486),
            Body =
                case St of
                    200 -> ?UA:sdp(<<"callee">>);
                    _ -> <<>>
                end,
            Contact = {<<"Contact">>, <<"<", (uri(Port))/binary, ">">>},
            ?UA:send(
                Sock,
                Src,
                ?UA:resp(Req, St, <<"X">>, ?UA:tag(), [Contact], Body)
            ),
            respond_loop(Sock, Port, Mode, How, Test);
        {udp, Sock, _, _, _} ->
            respond_loop(Sock, Port, Mode, How, Test)
    end.

%% INVITE the stack from a fresh caller; the first final response
call(EP) ->
    Test = self(),
    ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => ?UA:tag()
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_any(Sock, 8000),
        _ =
            case ?UA:status(R) of
                200 -> ?UA:ack(?UA:dialog_from_2xx(Sock, Inv, R), EP);
                _ -> ok
            end,
        Test ! {final, R},
        timer:sleep(infinity)
    end),
    receive
        {final, R} -> R
    after 10000 -> ct:fail(no_final)
    end.

%% INVITE the stack and keep the call; {bye, D} from the test sends the BYE
call_keep(EP) ->
    Test = self(),
    Pid = ?UA:peer(0, fun(Sock) ->
        Inv = ?UA:invite(Sock, EP, #{
            call_id => ?UA:callid(), from_tag => ?UA:tag()
        }),
        ?UA:send(Sock, EP, Inv),
        R = ?UA:recv_status(Sock, 200, 8000),
        D = ?UA:dialog_from_2xx(Sock, Inv, R),
        ?UA:ack(D, EP),
        Test ! {caller_up, D},
        receive
            {bye, _} ->
                {Bye, _} = ?UA:in_dialog(D, <<"BYE">>, [], <<>>),
                ?UA:send(Sock, EP, Bye)
        end,
        timer:sleep(infinity)
    end),
    receive
        {caller_up, D} -> {Pid, D}
    after 10000 -> ct:fail(no_caller)
    end.

register_req(Sock, Contact) ->
    P = integer_to_binary(?UA:lport(Sock)),
    iolist_to_binary(
        [
            <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n">>,
            <<"Via: SIP/2.0/UDP 127.0.0.1:">>,
            P,
            <<";rport;branch=">>,
            ?UA:branch(),
            <<"\r\n">>,
            <<"Max-Forwards: 70\r\n">>,
            <<"From: <sip:alice@127.0.0.1>;tag=">>,
            ?UA:tag(),
            <<"\r\n">>,
            <<"To: <sip:alice@127.0.0.1>\r\n">>,
            <<"Call-ID: ">>,
            ?UA:callid(),
            <<"\r\n">>,
            <<"CSeq: 1 REGISTER\r\n">>,
            <<"Contact: <">>,
            Contact,
            <<">\r\n">>,
            <<"Expires: 600\r\n">>,
            <<"Content-Length: 0\r\n\r\n">>
        ]
    ).
