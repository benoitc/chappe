%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Several listen addresses on one transport: a request is answered, and
%% record-routed, with the address it came to, the dialog it forms sends
%% from that address, and a request we originate leaves from the address
%% asked for (or the first of the target's family). The default group
%% listens on 127.0.0.1 and ::1; the second_v4 group adds 127.0.0.2, where
%% the host can bind it (Linux; macOS has only 127.0.0.1 by default), so two
%% addresses of one family are told apart.
-module(chappe_sip_multihome_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).
-export([answer_on_each_address/1, record_route_per_address/1,
         uac_by_family/1, single_contact/1, bad_contact/1,
         answer_on_second_v4/1, uac_local/1, udp_flow_local/1,
         public_advertised/1, public_local_nets/1, bad_public/1,
         double_record_route/1]).

-define(V4, {127, 0, 0, 1}).
-define(V4B, {127, 0, 0, 2}).
-define(V6, {0, 0, 0, 0, 0, 0, 0, 1}).

all() ->
    [answer_on_each_address, record_route_per_address, double_record_route,
     uac_by_family,
     single_contact, bad_contact, public_advertised, public_local_nets,
     bad_public, {group, second_v4}].

groups() ->
    [{second_v4, [], [answer_on_second_v4, uac_local, udp_flow_local]}].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_group(second_v4, Config) ->
    case gen_udp:open(0, [{ip, ?V4B}]) of
        {ok, S} ->
            gen_udp:close(S),
            Config;
        {error, _} ->
            {skip, "127.0.0.2 cannot be bound on this host"}
    end.

end_per_group(_, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    register(multihome_test, self()),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    _ = chappe_sip_registry:clear(),
    _ = (whereis(multihome_test) =:= self()) andalso unregister(multihome_test),
    ok.

%% ---- 127.0.0.1 and ::1 ----

%% req: R5658-01 R5658-02
%% A request that comes to the IPv4 address and leaves for an IPv6 peer
%% is record-routed twice (RFC 5658 5): the IPv6 address on top for the
%% callee, the IPv4 one below for the caller. The callee's BYE, routed
%% through both, reaches the caller with neither of our Routes left.
double_record_route(_Config) ->
    {P4, P6} = start_v4_v6(),
    Down = peer(?V6),
    DownUri = <<"sip:down@[::1]:", (integer_to_binary(port(Down)))/binary>>,
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, [DownUri], #{record_route => true})
    end),
    Up = peer(?V4),
    ok = send(Up, ?V4, P4, invite(Up, ?V4, P4)),
    {Fwd, DSrc} = recv_req(Down, <<"INVITE">>),
    {ok, M} = chappe_sip_msg:parse(Fwd),
    RRs = [V || H <- chappe_sip_msg:get_all(<<"record-route">>, M),
                V <- chappe_sip_hdr:split_list(H)],
    ct:log("Record-Route: ~p", [RRs]),
    P6B = integer_to_binary(P6),
    P4B = integer_to_binary(P4),
    ?assertMatch([<<"<sip:[::1]:", P6B:(byte_size(P6B))/binary, ";", _/binary>>,
                  <<"<sip:127.0.0.1:", P4B:(byte_size(P4B))/binary, ";", _/binary>>],
                 RRs),
    %% the callee answers, then hangs up through the route set it got
    {DIp, DPort} = DSrc,
    ok = send(Down, DIp, DPort, ok200(Fwd, Down, RRs)),
    {_Ok, _} = recv_resp(Up, 200),
    ok = send(Down, ?V6, P6, bye(Fwd, Down, RRs)),
    {Bye, _} = recv_req(Up, <<"BYE">>),
    {ok, BM} = chappe_sip_msg:parse(Bye),
    ?assertEqual([], chappe_sip_msg:get_all(<<"route">>, BM)),
    close(Up),
    close(Down).

%% An INVITE to each address: the 2xx Contact names that address, the
%% request meta says where it arrived, and the dialog's BYE leaves from it.
answer_on_each_address(_Config) ->
    {P4, P6} = start_v4_v6(),
    ok = answer(),
    lists:foreach(
        fun({Ip, Port}) ->
            Peer = peer(Ip),
            {Ok, Meta} = call(Peer, Ip, Port),
            ?assertEqual(addr(Ip), maps:get(local, Meta)),
            ?assertEqual(Port, maps:get(local_port, Meta)),
            ?assertEqual(<<"sip:", (host(Ip))/binary, ":",
                           (integer_to_binary(Port))/binary>>,
                         contact_uri(Ok)),
            %% the dialog hangs up: its BYE comes from that address
            hangup(),
            {Bye, From} = recv_req(Peer, <<"BYE">>),
            ?assertEqual({Ip, Port}, From),
            ok = reply(Peer, From, Bye, 200),
            close(Peer)
        end,
        [{?V4, P4}, {?V6, P6}]
    ).

%% A request proxied with record-routing carries a Record-Route with the
%% address it arrived on.
record_route_per_address(_Config) ->
    {P4, P6} = start_v4_v6(),
    Down = peer(?V4),
    DownUri = <<"sip:down@127.0.0.1:", (integer_to_binary(port(Down)))/binary>>,
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, [DownUri], #{record_route => true})
    end),
    lists:foreach(
        fun({Ip, Port}) ->
            Up = peer(Ip),
            ok = send(Up, Ip, Port, invite(Up, Ip, Port)),
            {Fwd, _} = recv_req(Down, <<"INVITE">>),
            {ok, M} = chappe_sip_msg:parse(Fwd),
            %% the address it arrived on is in the route set (alone, or
            %% under the outbound one when it leaves from another)
            RR = iolist_to_binary(
                lists:join(<<", ">>, chappe_sip_msg:get_all(<<"record-route">>, M))),
            ct:log("Record-Route via ~p: ~s", [Ip, RR]),
            Want = <<(host(Ip))/binary, ":", (integer_to_binary(Port))/binary>>,
            ?assertNotEqual(nomatch, binary:match(RR, Want)),
            close(Up)
        end,
        [{?V4, P4}, {?V6, P6}]
    ),
    close(Down).

%% A request to an IPv6 target leaves from the IPv6 address, with a Via
%% naming it; one to an IPv4 target from the IPv4 address.
uac_by_family(_Config) ->
    {P4, P6} = start_v4_v6(),
    lists:foreach(
        fun({Ip, Port}) ->
            Peer = peer(Ip),
            Target = <<"sip:peer@", (host(Ip))/binary, ":",
                       (integer_to_binary(port(Peer)))/binary>>,
            {ok, Ref} = chappe_sip:request(Target, #{method => <<"OPTIONS">>}),
            {Opt, From} = recv_req(Peer, <<"OPTIONS">>),
            ?assertEqual({Ip, Port}, From),
            ?assertNotEqual(nomatch, binary:match(via(Opt), host(Ip))),
            ok = reply(Peer, From, Opt, 200),
            {ok, _} = chappe_sip_uac:await_response(Ref, 5000),
            close(Peer)
        end,
        [{?V4, P4}, {?V6, P6}]
    ).

%% With one contact nothing changes: no local in the request meta seen by
%% the engine, the 2xx Contact is the contact, and contacts/0 lists it.
single_contact(_Config) ->
    P = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => uri(?V4, P)}),
    ok = answer(),
    ?assertEqual([uri(?V4, P)], chappe_sip_binds:contacts()),
    Peer = peer(?V4),
    {Ok, Meta} = call(Peer, ?V4, P),
    ?assertEqual(undefined, chappe_sip_binds:local(Meta)),
    ?assertEqual(uri(?V4, P), contact_uri(Ok)),
    hangup(),
    {Bye, From} = recv_req(Peer, <<"BYE">>),
    ok = reply(Peer, From, Bye, 200),
    close(Peer).

%% An empty or malformed contact list fails the start.
bad_contact(_Config) ->
    ?assertEqual({error, {contact, bad_contact}},
                 chappe_sip:start(#{contact => []})),
    ?assertEqual({error, {contact, bad_contact}},
                 chappe_sip:start(#{contact => [<<"sip:127.0.0.1">>, 5060]})).

%% ---- 1:1 NAT: a public address advertised, a local one bound ----

%% public => Host: the stack binds the local address and advertises the
%% public one. A peer outside local_nets gets it in the 2xx Contact, and
%% in the Via (RFC 3261 18.1.1 sent-by) and Contact of what we send.
public_advertised(_Config) ->
    P = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => #{uri => uri(?V4, P),
                                         public => <<"192.0.2.10">>,
                                         local_nets => [<<"10.0.0.0/8">>]}}),
    Public = <<"sip:192.0.2.10:", (integer_to_binary(P))/binary>>,
    ?assertEqual(Public, hd(binary:split(
        chappe_sip_hdr:name_addr_uri(chappe_sip_engine:contact()), <<";">>))),
    ok = answer(),
    Peer = peer(?V4),
    {Ok, _Meta} = call(Peer, ?V4, P),
    ?assertEqual(Public, contact_uri(Ok)),
    hangup(),
    {Bye, From} = recv_req(Peer, <<"BYE">>),
    %% sent from the bound address
    ?assertEqual({?V4, P}, From),
    ?assertNotEqual(nomatch, binary:match(via(Bye), <<"192.0.2.10:">>)),
    ok = reply(Peer, From, Bye, 200),
    {Opt, From2} = uac_options(Peer),
    ?assertEqual({?V4, P}, From2),
    ?assertNotEqual(nomatch, binary:match(via(Opt), <<"192.0.2.10:">>)),
    ?assertEqual(Public, contact_uri(Opt)),
    close(Peer).

%% A peer inside local_nets gets the local address in the Contact, both
%% on the 2xx we answer and on a request we send.
public_local_nets(_Config) ->
    P = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => #{uri => uri(?V4, P),
                                         public => <<"192.0.2.10">>,
                                         local_nets => [<<"127.0.0.0/8">>]}}),
    ok = answer(),
    Peer = peer(?V4),
    {Ok, _Meta} = call(Peer, ?V4, P),
    ?assertEqual(uri(?V4, P), contact_uri(Ok)),
    hangup(),
    {Bye, From} = recv_req(Peer, <<"BYE">>),
    ok = reply(Peer, From, Bye, 200),
    {Opt, _} = uac_options(Peer),
    ?assertEqual(uri(?V4, P), contact_uri(Opt)),
    close(Peer).

%% A bad public host, a bad network, local_nets without public or on a
%% wildcard bind, or a contact that already has maddr fails the start.
bad_public(_Config) ->
    U = uri(?V4, chappe_sip_test_port:pick()),
    [?assertEqual({error, {contact, Why}}, chappe_sip:start(#{contact => C}))
     || {C, Why} <- [
            {#{uri => U, public => <<"a b">>}, bad_public},
            {#{uri => U, public => <<"x;maddr=1">>}, bad_public},
            {#{uri => U, public => <<"1.2.3.4", 0>>}, bad_public},
            {#{uri => U, public => 42}, bad_public},
            {#{uri => U, local_nets => [<<"10.0.0.0/8">>]}, bad_public},
            {#{uri => U, public => <<"192.0.2.1">>, local_nets => [<<"x">>]},
             bad_local_nets},
            {#{uri => U, public => <<"192.0.2.1">>, local_nets => nope},
             bad_local_nets},
            {#{uri => <<"sip:0.0.0.0:5099">>, public => <<"192.0.2.1">>,
               local_nets => [<<"10.0.0.0/8">>]}, bad_public},
            {#{uri => <<U/binary, ";maddr=127.0.0.1">>,
               public => <<"192.0.2.1">>}, bad_public},
            {#{uri => <<"nope">>}, bad_contact}
        ]].

uac_options(Peer) ->
    Target = <<"sip:peer@127.0.0.1:", (integer_to_binary(port(Peer)))/binary>>,
    {ok, Ref} = chappe_sip:request(Target, #{method => <<"OPTIONS">>}),
    {Opt, From} = recv_req(Peer, <<"OPTIONS">>),
    ok = reply(Peer, From, Opt, 200),
    {ok, _} = chappe_sip_uac:await_response(Ref, 5000),
    {Opt, From}.

%% ---- 127.0.0.1 and 127.0.0.2 ----

%% Two addresses of one family: the call to the second is answered with
%% it, and its dialog's BYE leaves from it, not from the first.
answer_on_second_v4(_Config) ->
    {_P1, P2} = start_two_v4(),
    ok = answer(),
    Peer = peer(?V4),
    {Ok, Meta} = call(Peer, ?V4B, P2),
    ?assertEqual(<<"127.0.0.2">>, maps:get(local, Meta)),
    ?assertEqual(uri(?V4B, P2), contact_uri(Ok)),
    hangup(),
    {Bye, From} = recv_req(Peer, <<"BYE">>),
    ?assertEqual({?V4B, P2}, From),
    ok = reply(Peer, From, Bye, 200),
    close(Peer).

%% The local option picks the address a request leaves from, and the
%% Contact it carries; without it, the first address.
uac_local(_Config) ->
    {P1, P2} = start_two_v4(),
    Peer = peer(?V4),
    Target = <<"sip:peer@127.0.0.1:", (integer_to_binary(port(Peer)))/binary>>,
    lists:foreach(
        fun({Opts, Ip, Port}) ->
            {ok, Ref} = chappe_sip:request(
                Target, Opts#{method => <<"OPTIONS">>}
            ),
            {Opt, From} = recv_req(Peer, <<"OPTIONS">>),
            ?assertEqual({Ip, Port}, From),
            ?assertNotEqual(nomatch, binary:match(via(Opt), host(Ip))),
            ok = reply(Peer, From, Opt, 200),
            {ok, _} = chappe_sip_uac:await_response(Ref, 5000)
        end,
        [{#{local => <<"127.0.0.2">>}, ?V4B, P2},
         {#{local => {127, 0, 0, 2}}, ?V4B, P2},
         {#{}, ?V4, P1}]
    ),
    close(Peer).

%% RFC 5626 over UDP: a binding registered on the second address keeps
%% it, so a request for the AOR leaves from that socket, the one the UA's
%% NAT binding was opened to.
udp_flow_local(_Config) ->
    {P1, P2} = start_two_v4(),
    ok = chappe_sip:register(
        chappe_sip:registrar(#{allow_unauthenticated => true})
    ),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:alice@127.0.0.2">>),
        chappe_sip:proxy_request(Req, {flow, Uri, Flow}, #{})
    end),
    UA = peer(?V4),
    ok = send(UA, ?V4B, P2, register_req(UA, P2)),
    {_, _} = recv_resp(UA, 200),
    [B] = chappe_sip:bindings(<<"sip:alice@127.0.0.2">>),
    ?assertEqual({udp, <<"127.0.0.1">>, port(UA), <<"127.0.0.2">>},
                 maps:get(flow, B)),
    Caller = peer(?V4),
    ok = send(Caller, ?V4, P1, invite(Caller, ?V4, P1)),
    {_, From} = recv_req(UA, <<"INVITE">>),
    ?assertEqual({?V4B, P2}, From),
    close(Caller),
    close(UA).

%% ---- the node ----

start_v4_v6() ->
    P4 = chappe_sip_test_port:pick(),
    P6 = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => [uri(?V4, P4), uri(?V6, P6)]}),
    {P4, P6}.

start_two_v4() ->
    P1 = chappe_sip_test_port:pick(),
    P2 = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => [uri(?V4, P1), uri(?V4B, P2)]}),
    {P1, P2}.

%% answer every INVITE; the test is told the request meta and gets the
%% dialog to hang up
answer() ->
    chappe_sip:invite(fun(Req, Res) ->
        {ok, D} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()}),
        multihome_test ! {answered, chappe_sip_req:meta(Req), D},
        chappe_sip_dialog:wait(D)
    end).

hangup() ->
    receive
        {dialog, D} -> chappe_sip_dialog:destroy(D)
    after 5000 -> ct:fail(no_dialog)
    end.

%% INVITE, 200, ACK; returns the 200 and the request meta
call(Peer, Ip, Port) ->
    ok = send(Peer, Ip, Port, invite(Peer, Ip, Port)),
    {Ok, _} = recv_resp(Peer, 200),
    Meta =
        receive
            {answered, M, D} ->
                self() ! {dialog, D},
                M
        after 5000 -> ct:fail(not_answered)
        end,
    ok = send(Peer, Ip, Port, ack(Ok, Peer)),
    {Ok, Meta}.

%% ---- the peer: one UDP socket ----

peer(Ip) ->
    Fam =
        case tuple_size(Ip) of
            4 -> inet;
            8 -> inet6
        end,
    {ok, S} = gen_udp:open(0, [binary, Fam, {active, true}, {ip, Ip}]),
    #{sock => S, ip => Ip}.

port(#{sock := S}) ->
    {ok, P} = inet:port(S),
    P.

close(#{sock := S}) ->
    gen_udp:close(S).

send(#{sock := S}, Ip, Port, Bin) ->
    gen_udp:send(S, Ip, Port, Bin).

recv_req(#{sock := S}, Method) ->
    receive
        {udp, S, Ip, Port, <<M:(byte_size(Method))/binary, " ", _/binary>> = Bin}
                when M =:= Method ->
            {Bin, {Ip, Port}}
    after 5000 -> ct:fail({no_request, Method})
    end.

recv_resp(#{sock := S} = Peer, Status) ->
    receive
        {udp, S, Ip, Port, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case binary_to_integer(C) of
                Status -> {Bin, {Ip, Port}};
                _ -> recv_resp(Peer, Status)
            end
    after 5000 -> ct:fail({no_response, Status})
    end.

reply(Peer, {Ip, Port}, Req, Status) ->
    {ok, M} = chappe_sip_msg:parse(Req),
    Hdrs = [[N, ": ", V, "\r\n"]
            || N <- [<<"Via">>, <<"From">>, <<"To">>, <<"Call-ID">>, <<"CSeq">>],
               V <- chappe_sip_msg:get_all(string:lowercase(N), M)],
    send(Peer, Ip, Port, iolist_to_binary(
        ["SIP/2.0 ", integer_to_binary(Status), " OK\r\n", Hdrs,
         "Content-Length: 0\r\n\r\n"])).

invite(#{ip := Ip} = Peer, To, ToPort) ->
    Body = sdp(),
    iolist_to_binary([
        "INVITE sip:uas@", host(To), ":", integer_to_binary(ToPort),
        " SIP/2.0\r\n",
        "Via: SIP/2.0/UDP ", host(Ip), ":", integer_to_binary(port(Peer)),
        ";branch=z9hG4bK", hex(6), ";rport\r\n",
        "Max-Forwards: 70\r\n",
        "From: <sip:caller@example.com>;tag=", hex(4), "\r\n",
        "To: <sip:uas@example.com>\r\n",
        "Call-ID: ", hex(8), "\r\n",
        "CSeq: 1 INVITE\r\n",
        "Contact: <sip:caller@", host(Ip), ":", integer_to_binary(port(Peer)),
        ">\r\n",
        "Content-Type: application/sdp\r\n",
        "Content-Length: ", integer_to_binary(byte_size(Body)), "\r\n\r\n",
        Body
    ]).

ack(Ok, #{ip := Ip} = Peer) ->
    {ok, M} = chappe_sip_msg:parse(Ok),
    iolist_to_binary([
        "ACK ", contact_uri(Ok), " SIP/2.0\r\n",
        "Via: SIP/2.0/UDP ", host(Ip), ":", integer_to_binary(port(Peer)),
        ";branch=z9hG4bK", hex(6), ";rport\r\n",
        "Max-Forwards: 70\r\n",
        "From: ", chappe_sip_msg:get(<<"from">>, M), "\r\n",
        "To: ", chappe_sip_msg:get(<<"to">>, M), "\r\n",
        "Call-ID: ", chappe_sip_msg:call_id(M), "\r\n",
        "CSeq: 1 ACK\r\n",
        "Content-Length: 0\r\n\r\n"
    ]).

register_req(#{ip := Ip} = Peer, ToPort) ->
    LP = integer_to_binary(port(Peer)),
    iolist_to_binary([
        "REGISTER sip:127.0.0.2:", integer_to_binary(ToPort), " SIP/2.0\r\n",
        "Via: SIP/2.0/UDP ", host(Ip), ":", LP, ";branch=z9hG4bK", hex(6),
        ";rport\r\n",
        "Max-Forwards: 70\r\n",
        "From: <sip:alice@127.0.0.2>;tag=", hex(4), "\r\n",
        "To: <sip:alice@127.0.0.2>\r\n",
        "Call-ID: ", hex(8), "\r\n",
        "CSeq: 1 REGISTER\r\n",
        "Contact: <sip:alice@192.0.2.9:5070;ob>;+sip.instance=\"<urn:uuid:m1>\""
        ";reg-id=1\r\n",
        "Supported: outbound\r\n",
        "Expires: 3600\r\n",
        "Content-Length: 0\r\n\r\n"
    ]).

%% the callee's 200 to a forwarded INVITE, echoing its Record-Routes
ok200(Inv, Peer, RRs) ->
    {ok, M} = chappe_sip_msg:parse(Inv),
    iolist_to_binary(
        ["SIP/2.0 200 OK
",
         [["Via: ", V, "
"] || V <- chappe_sip_msg:get_all(<<"via">>, M)],
         [["Record-Route: ", R, "
"] || R <- RRs],
         "From: ", chappe_sip_msg:get(<<"from">>, M), "
",
         "To: ", chappe_sip_msg:get(<<"to">>, M), ";tag=callee
",
         "Call-ID: ", chappe_sip_msg:call_id(M), "
",
         "CSeq: 1 INVITE
",
         "Contact: <sip:down@[::1]:", integer_to_binary(port(Peer)), ">
",
         "Content-Length: 0

"]).

%% the callee's BYE through the route set it learned (top first)
bye(Inv, Peer, RRs) ->
    {ok, M} = chappe_sip_msg:parse(Inv),
    {ok, #{uri := Target}} =
        chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"contact">>, M)),
    iolist_to_binary(
        ["BYE ", Target, " SIP/2.0
",
         "Via: SIP/2.0/UDP [::1]:", integer_to_binary(port(Peer)),
         ";branch=z9hG4bK", hex(6), ";rport
",
         "Max-Forwards: 70
",
         [["Route: ", R, "
"] || R <- RRs],
         "From: ", chappe_sip_msg:get(<<"to">>, M), ";tag=callee
",
         "To: ", chappe_sip_msg:get(<<"from">>, M), "
",
         "Call-ID: ", chappe_sip_msg:call_id(M), "
",
         "CSeq: 2 BYE
",
         "Content-Length: 0

"]).

contact_uri(Msg) ->
    {ok, M} = chappe_sip_msg:parse(Msg),
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"contact">>, M)),
    hd(binary:split(U, <<";">>)).

via(Msg) ->
    {ok, M} = chappe_sip_msg:parse(Msg),
    chappe_sip_msg:get(<<"via">>, M).

uri(Ip, Port) ->
    <<"sip:", (host(Ip))/binary, ":", (integer_to_binary(Port))/binary>>.

host(Ip) when tuple_size(Ip) =:= 8 -> <<"[", (addr(Ip))/binary, "]">>;
host(Ip) -> addr(Ip).

addr(Ip) -> list_to_binary(inet:ntoa(Ip)).

sdp() ->
    <<"v=0\r\no=mh 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

hex(N) ->
    binary:encode_hex(crypto:strong_rand_bytes(N), lowercase).
