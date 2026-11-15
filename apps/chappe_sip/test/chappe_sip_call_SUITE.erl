%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Call correlation: one call_ref per call, on the request, on every leg
%% the call creates (X-Chappe-Call), in the call records and in HEP, and
%% the processes serving the call found by it from any node (pg).
-module(chappe_sip_call_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([lookup_asks_named_node/1]).
-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([b_leg_carries_ref/1, app_ref/1, bad_app_ref/1, uac_ref/1,
         lookup_while_up/1, owner_death_leaves/1, relay_crash_leaves/1,
         async_relay_moves/1, peer_node_lookup/1, hep_correlates/1,
         anchored_media_found/1, scope_owned_by_app/1]).

-import(chappe_sip_test_ua, [peer/2, expect/1, recv_req/2, recv_status/2,
                             send/3, lport/1, resp/6, sdp/1, tag/0, callid/0,
                             pick/0, hdr/2, hdrs/2, to_tag/1]).

all() ->
    [b_leg_carries_ref, app_ref, bad_app_ref, uac_ref, lookup_while_up,
     owner_death_leaves, relay_crash_leaves, async_relay_moves,
     peer_node_lookup, hep_correlates, anchored_media_found,
     scope_owned_by_app, lookup_asks_named_node].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = case whereis(call_test_rtpe) of
            undefined -> ok;
            Rtpe -> unregister(call_test_rtpe), chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    _ = chappe_sip_cdr:unsubscribe(self()),
    ok.

%% The handler's request carries a call_ref; the INVITE to B carries it as
%% X-Chappe-Call (A's own X-Chappe-Call is not copied, even with
%% proxy_request_headers => all), both call records and info/1 carry it.
b_leg_carries_ref(_Config) ->
    {EP, CP} = setup(),
    ok = chappe_sip_cdr:subscribe(self()),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Ref = chappe_sip_req:call_ref(Req),
        {ok, #{b2b := B2b, call_ref := Ref} = Legs} =
            chappe_sip:create_b2bua(Req, Res, uri(CP),
                                    #{proxy_request_headers => all}),
        Test ! {ref, Ref, B2b},
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CP, fun(Sock, Inv, Src) ->
        Test ! {b_refs, hdrs(Inv, <<"x-chappe-call">>)},
        answer(Sock, Inv, Src)
    end),
    A = call(EP, [{<<"X-Chappe-Call">>, <<"upstream-1">>}]),
    {Ref, B2b} = receive {ref, R, B} -> {R, B} after 6000 -> ct:fail(no_ref) end,
    {match, _} = re:run(Ref, "^[0-9a-f]{24}$"),
    receive {b_refs, Bs} -> [Ref] = Bs after 6000 -> ct:fail(no_b) end,
    #{call_ref := Ref, related := undefined} = chappe_sip_b2b:info(B2b),
    hangup(A),
    Stops = stops(2),
    [b2b_a, b2b_b] = lists:sort([maps:get(role, S) || S <- Stops]),
    [Ref, Ref] = [maps:get(call_ref, S) || S <- Stops].

%% call_ref => Bin: the app's ref names the call everywhere instead.
app_ref(_Config) ->
    {EP, CP} = setup(),
    ok = chappe_sip_cdr:subscribe(self()),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, #{call_ref := <<"up-42">>} = Legs} =
            chappe_sip:create_b2bua(Req, Res, uri(CP),
                                    #{call_ref => <<"up-42">>}),
        Test ! up,
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CP, fun(Sock, Inv, Src) ->
        Test ! {b_ref, hdr(Inv, <<"x-chappe-call">>)},
        answer(Sock, Inv, Src)
    end),
    A = call(EP, []),
    ok = expect(up),
    ok = expect({b_ref, <<"up-42">>}),
    {ok, #{b2b := [_], dialogs := [_, _]}} =
        chappe_sip:calls(#{call_ref => <<"up-42">>}),
    hangup(A),
    [<<"up-42">>, <<"up-42">>] = [maps:get(call_ref, S) || S <- stops(2)].

%% A call_ref that is no token never reaches a leg: {error, badarg}, 500.
bad_app_ref(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        Test ! {result, chappe_sip:create_b2bua(Req, Res, uri(CP),
                                                #{call_ref => <<"a\r\nb">>})}
    end),
    peer(CP, fun(Sock) ->
        receive {udp, Sock, _, _, _} -> Test ! b_called
        after 1500 -> ok
        end
    end),
    caller(fun(Sock) ->
        send(Sock, EP, invite(Sock, callid(), tag(), [])),
        _ = recv_status(Sock, 500),
        Test ! got_500
    end),
    ok = expect({result, {error, badarg}}),
    ok = expect(got_500),
    receive b_called -> ct:fail(b_called) after 1600 -> ok end,
    {error, badarg} = chappe_sip:calls(#{call_ref => 42}).

%% create_uac: an INVITE serves a call of its own, named in X-Chappe-Call
%% (the caller's ref, or a new one); one only, and none on request.
uac_ref(_Config) ->
    {_EP, CP} = setup(),
    Test = self(),
    callee_loop(CP, fun(Inv) -> Test ! {refs, hdrs(Inv, <<"x-chappe-call">>)} end),
    Uri = uri(CP),
    {ok, D1} = chappe_sip:create_uac(Uri, #{local_sdp => sdp(<<"u">>)}),
    R1 = receive {refs, [R]} -> R after 6000 -> ct:fail(no_invite) end,
    {match, _} = re:run(R1, "^[0-9a-f]{24}$"),
    {ok, #{dialogs := [D1]}} = chappe_sip:calls(#{call_ref => R1}),
    {ok, _} = chappe_sip:create_uac(Uri, #{local_sdp => sdp(<<"u">>),
                                          call_ref => <<"given">>}),
    ok = expect({refs, [<<"given">>]}),
    {ok, _} = chappe_sip:create_uac(Uri, #{local_sdp => sdp(<<"u">>),
                                          call_ref => <<"given">>,
                                          call_ref_header => false}),
    ok = expect({refs, []}),
    {ok, _} = chappe_sip:create_uac(Uri, #{
        local_sdp => sdp(<<"u">>), call_ref => <<"given">>,
        headers => [{<<"X-Chappe-Call">>, <<"mine">>}]}),
    ok = expect({refs, [<<"mine">>]}),
    {error, badarg} = chappe_sip:create_uac(Uri, #{call_ref => <<>>}),
    {error, badarg} = chappe_sip:create_uac(Uri, #{related => <<"a b">>}).

%% While the call is up its B2BUA (a live handle), both dialogs and no
%% media session (direct media) are found; once it ends, nothing.
lookup_while_up(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, uri(CP), #{}),
        Test ! {up, chappe_sip_req:call_ref(Req)},
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CP, fun answer/3),
    A = call(EP, []),
    Ref = receive {up, R} -> R after 6000 -> ct:fail(no_up) end,
    {ok, #{b2b := [B2b], dialogs := [_, _], media := []}} =
        chappe_sip:calls(#{call_ref => Ref}),
    #{call_ref := Ref, media := direct} = chappe_sip_b2b:info(B2b),
    hangup(A),
    ok = gone(Ref).

%% The owner of the call (the request worker running the relay) dies: its
%% dialogs hang up both parties and the call leaves the lookup.
owner_death_leaves(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, _Legs} = chappe_sip:create_b2bua(Req, Res, uri(CP), #{}),
        Test ! {up, self(), chappe_sip_req:call_ref(Req)},
        receive never -> ok end
    end),
    callee(CP, fun(Sock, Inv, Src) ->
        {ToTag, _} = answer_only(Sock, Inv, Src),
        {Bye, BSrc} = recv_req(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! b_byed
    end),
    _A = call(EP, []),
    {Worker, Ref} = receive {up, W, R} -> {W, R} after 6000 -> ct:fail(no_up) end,
    {ok, #{b2b := [_], dialogs := [_, _]}} = chappe_sip:calls(#{call_ref => Ref}),
    exit(Worker, kill),
    ok = expect(b_byed),
    ok = gone(Ref).

%% The relay process crashes: the call leaves the lookup and both legs go.
relay_crash_leaves(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, uri(CP), #{}),
        {ok, {Pid, _} = B2b} = chappe_sip_b2b:relay_async(Legs, #{}),
        Test ! {up, B2b, chappe_sip_req:call_ref(Req)},
        _ = monitor(process, Pid),
        receive {'DOWN', _, process, Pid, _} -> ok end
    end),
    callee(CP, fun(Sock, Inv, Src) ->
        {ToTag, _} = answer_only(Sock, Inv, Src),
        {Bye, BSrc} = recv_req(Sock, <<"BYE">>),
        send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
        Test ! b_byed
    end),
    _A = call(EP, []),
    {{Pid, _} = B2b, Ref} =
        receive {up, B, R} -> {B, R} after 6000 -> ct:fail(no_up) end,
    {ok, #{b2b := [B2b]}} = chappe_sip:calls(#{call_ref => Ref}),
    exit(Pid, kill),
    ok = expect(b_byed),
    ok = gone(Ref).

%% relay_async/2: the relay process serves the call, the worker no more.
async_relay_moves(_Config) ->
    {EP, CP} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Legs} = chappe_sip:create_b2bua(Req, Res, uri(CP), #{}),
        {ok, B2b} = chappe_sip_b2b:relay_async(Legs, #{notify => Test}),
        Test ! {up, self(), B2b, chappe_sip_req:call_ref(Req)},
        receive stop -> ok end
    end),
    callee(CP, fun answer/3),
    A = call(EP, []),
    {Worker, {Pid, _} = B2b, Ref} =
        receive {up, W, B, R} -> {W, B, R} after 6000 -> ct:fail(no_up) end,
    true = Pid =/= Worker,
    {ok, #{b2b := [B2b]}} = chappe_sip:calls(#{call_ref => Ref}),
    hangup(A),
    ok = gone(Ref),
    Worker ! stop.

%% The lookup scope is chappe_sip's own: a child of its supervisor, so it
%% lives and stops with the app, and no other app's scope is shared.
scope_owned_by_app(_Config) ->
    chappe_sip = chappe_sip_call:scope(),
    Pid = whereis(chappe_sip),
    true = is_pid(Pid),
    {chappe_sip_pg, Pid, worker, _} =
        lists:keyfind(chappe_sip_pg, 1, supervisor:which_children(chappe_sip_sup)),
    undefined = whereis(chappe).

%% A process that has just joined a call on another node may not be in this
%% node's pg view yet: lookup/2 asks the node named for it all the same
%% (the attended transfer names the node of the dialog it found).
lookup_asks_named_node(_Config) ->
    ok = chappe_sip_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(),
                                         args => Paths}),
    try
        {ok, _} = erpc:call(Node, application, ensure_all_started, [chappe_sip]),
        Ref = chappe_sip_call:new_ref(),
        Holder = erpc:call(Node, erlang, spawn, [timer, sleep, [infinity]]),
        %% recorded as serving the call, its pg join not seen here yet
        true = erpc:call(Node, ets, insert,
                         [chappe_sip_call_members, {{Ref, b2b, Holder}, held}]),
        ?assertMatch(#{b2b := []}, chappe_sip_call:lookup(Ref)),
        ?assertMatch(#{b2b := [held]}, chappe_sip_call:lookup(Ref, [Node]))
    after
        peer:stop(Peer)
    end.

%% A peer node finds the call through pg, reads it with info/1 and ends it
%% with hangup/2: handles work across nodes.
peer_node_lookup(_Config) ->
    ok = chappe_sip_test_dist:ensure(),
    Paths = lists:append([["-pa", P] || P <- code:get_path()]),
    {ok, Peer, Node} = peer:start_link(#{name => peer:random_name(),
                                         args => Paths}),
    try
        %% the peer runs no chappe_sip: it holds only the lookup scope
        {ok, _} = erpc:call(Node, pg, start, [chappe_sip]),
        {EP, CP} = setup(),
        Test = self(),
        ok = chappe_sip:invite(fun(Req, Res) ->
            {ok, Legs} = chappe_sip:create_b2bua(Req, Res, uri(CP), #{}),
            Test ! {up, chappe_sip_req:call_ref(Req)},
            Test ! {relay, chappe_sip_b2b:relay(Legs)}
        end),
        callee(CP, fun(Sock, Inv, Src) ->
            {ToTag, _} = answer_only(Sock, Inv, Src),
            {Bye, BSrc} = recv_req(Sock, <<"BYE">>),
            send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)),
            Test ! b_byed
        end),
        _A = call(EP, []),
        Ref = receive {up, R} -> R after 6000 -> ct:fail(no_up) end,
        Found = wait_found(Node, Ref, 50),
        #{b2b := [B2b], dialogs := [_, _]} = Found,
        #{call_ref := Ref} = erpc:call(Node, chappe_sip_b2b, info, [B2b]),
        ok = erpc:call(Node, chappe_sip_b2b, hangup,
                       [B2b, #{reason => <<"Q.850;cause=16">>}]),
        ok = expect(caller_byed),
        ok = expect(b_byed),
        ok = expect({relay, {done, hangup}}),
        ok = gone(Ref)
    after
        peer:stop(Peer)
    end.

%% HEP: each Call-ID of a call gets two log packets naming its call_ref,
%% one under the Call-ID and one under the ref (correlation chunk 17).
hep_correlates(_Config) ->
    {ok, Coll} = gen_udp:open(0, [binary, {active, true}, {ip, {127, 0, 0, 1}}]),
    {ok, CollPort} = inet:port(Coll),
    {ok, Cfg} = chappe_sip_hep:validate(#{host => {127, 0, 0, 1},
                                          port => CollPort}),
    ok = chappe_sip_hep:configure(Cfg),
    try
        ok = chappe_sip_hep:correlate(<<"cid-1@h">>, <<"ref-1">>, uas),
        Logs = [P || P <- hep_packets(Coll, 2), maps:get(proto_type, P) =:= 100],
        [<<"cid-1@h">>, <<"ref-1">>] =
            lists:sort([maps:get(correlation_id, P) || P <- Logs]),
        [#{<<"call_ref">> := <<"ref-1">>, <<"call_id">> := <<"cid-1@h">>,
           <<"role">> := <<"uas">>}] =
            lists:usort([json:decode(maps:get(payload, P)) || P <- Logs]),
        ok = chappe_sip_hep:correlate(undefined, <<"ref-1">>, uas),
        receive {udp, Coll, _, _, _} -> ct:fail(unexpected_packet)
        after 300 -> ok
        end
    after
        ok = chappe_sip_hep:configure(undefined),
        gen_udp:close(Coll)
    end.

%% Anchored, the call's rtpengine session is found too, and is the one
%% info/1 names; it leaves with the call.
anchored_media_found(_Config) ->
    register(call_test_rtpe, chappe_sip_test_rtpe:start(self())),
    {EP, CP} = setup(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, #{b2b := B2b} = Legs} =
            chappe_sip:create_b2bua(Req, Res, uri(CP), #{media => anchor}),
        Test ! {up, B2b, chappe_sip_req:call_ref(Req)},
        {done, _} = chappe_sip_b2b:relay(Legs)
    end),
    callee(CP, fun answer/3),
    A = call(EP, []),
    {B2b, Ref} = receive {up, B, R} -> {B, R} after 6000 -> ct:fail(no_up) end,
    {ok, #{b2b := [B2b], media := [S]}} = chappe_sip:calls(#{call_ref => Ref}),
    #{session := S, media := anchor} = chappe_sip_b2b:info(B2b),
    hangup(A),
    ok = gone(Ref).

%% ---- helpers ----

setup() ->
    EP = pick(),
    CP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                         (integer_to_binary(EP))/binary>>}),
    {EP, CP}.

uri(Port) -> <<"sip:callee@127.0.0.1:", (integer_to_binary(Port))/binary>>.

ctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.

caller(Fun) -> peer(0, Fun).

%% the callee peer: Fun(Sock, Invite, Src) once the INVITE arrives
callee(Port, Fun) ->
    peer(Port, fun(Sock) ->
        {Inv, Src} = recv_req(Sock, <<"INVITE">>),
        Fun(Sock, Inv, Src)
    end).

%% a callee answering every INVITE, after Fun(Invite)
callee_loop(Port, Fun) ->
    peer(Port, fun(Sock) -> callee_loop_1(Sock, Fun) end).

callee_loop_1(Sock, Fun) ->
    {Inv, Src} = recv_req(Sock, <<"INVITE">>),
    Fun(Inv),
    _ = answer_only(Sock, Inv, Src),
    callee_loop_1(Sock, Fun).

answer_only(Sock, Inv, Src) ->
    ToTag = tag(),
    send(Sock, Src, resp(Inv, 200, <<"OK">>, ToTag,
                         [{<<"Contact">>, ctc(lport(Sock))}],
                         sdp(<<"callee">>))),
    {ToTag, Src}.

%% answer, then take the BYE
answer(Sock, Inv, Src) ->
    {ToTag, _} = answer_only(Sock, Inv, Src),
    {Bye, BSrc} = recv_req(Sock, <<"BYE">>),
    send(Sock, BSrc, resp(Bye, 200, <<"OK">>, ToTag, [], <<>>)).

%% (a peer's Src is the port its datagram came from, on loopback)

%% the caller peer: INVITE, 200, ACK; then it answers a BYE (the test
%% gets caller_byed) or sends one on hangup/1
call(EP, Hdrs) ->
    Test = self(),
    caller(fun(Sock) ->
        Call = callid(),
        FT = tag(),
        send(Sock, EP, invite(Sock, Call, FT, Hdrs)),
        TT = to_tag(recv_status(Sock, 200)),
        send(Sock, EP, ack(Sock, Call, FT, TT)),
        Test ! {caller_up, self()},
        caller_wait(Sock, EP, Test, Call, FT, TT)
    end),
    receive {caller_up, Pid} -> Pid after 6000 -> ct:fail(caller_not_up) end.

caller_wait(Sock, EP, Test, Call, FT, TT) ->
    receive
        {udp, Sock, _, Src, <<"BYE ", _/binary>> = Bye} ->
            send(Sock, Src, resp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
            Test ! caller_byed;
        hangup ->
            send(Sock, EP, bye(Sock, Call, FT, TT)),
            _ = recv_status(Sock, 200),
            Test ! caller_hung_up;
        {udp, Sock, _, _, _} ->
            caller_wait(Sock, EP, Test, Call, FT, TT)
    end.

hangup(Caller) ->
    Caller ! hangup,
    ok = expect(caller_hung_up).

invite(Sock, Call, FT, Hdrs) ->
    P = integer_to_binary(lport(Sock)),
    S = sdp(<<"caller">>),
    iolist_to_binary(
      [<<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
         "Via: SIP/2.0/UDP 127.0.0.1:">>, P, <<";rport;branch=">>, branch(),
       <<"\r\nMax-Forwards: 70\r\n"
         "From: Caller <sip:caller@127.0.0.1:">>, P, <<">;tag=">>, FT, <<"\r\n"
         "To: <sip:app@127.0.0.1>\r\n"
         "Contact: <sip:caller@127.0.0.1:">>, P, <<">\r\n"
         "Call-ID: ">>, Call, <<"\r\nCSeq: 1 INVITE\r\n">>,
       [[N, <<": ">>, V, <<"\r\n">>] || {N, V} <- Hdrs],
       <<"Content-Type: application/sdp\r\nContent-Length: ">>,
       integer_to_binary(byte_size(S)), <<"\r\n\r\n">>, S]).

ack(Sock, Call, FT, TT) -> in_dialog(Sock, <<"ACK">>, 1, Call, FT, TT).

bye(Sock, Call, FT, TT) -> in_dialog(Sock, <<"BYE">>, 2, Call, FT, TT).

in_dialog(Sock, Method, N, Call, FT, TT) ->
    P = integer_to_binary(lport(Sock)),
    iolist_to_binary(
      [Method, <<" sip:app@127.0.0.1 SIP/2.0\r\n"
                 "Via: SIP/2.0/UDP 127.0.0.1:">>, P, <<";rport;branch=">>,
       branch(), <<"\r\nMax-Forwards: 70\r\n"
                   "From: Caller <sip:caller@127.0.0.1:">>, P, <<">;tag=">>,
       FT, <<"\r\nTo: <sip:app@127.0.0.1>;tag=">>, TT, <<"\r\nCall-ID: ">>,
       Call, <<"\r\nCSeq: ">>, integer_to_binary(N), <<" ">>, Method,
       <<"\r\nContent-Length: 0\r\n\r\n">>]).

branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

%% the next N call records stopped
stops(0) -> [];
stops(N) ->
    receive {chappe_sip_cdr, stop, R} -> [R | stops(N - 1)]
    after 6000 -> ct:fail({no_cdr_stop, N})
    end.

%% nothing serves the call any more (the dialogs end after their BYE)
gone(Ref) -> gone(Ref, 50).

gone(Ref, 0) ->
    ct:fail({still_found, Ref, chappe_sip:calls(#{call_ref => Ref})});
gone(Ref, N) ->
    case
        {chappe_sip:calls(#{call_ref => Ref}),
         pg:get_members(chappe_sip, {chappe_sip_call, Ref})}
    of
        {{ok, #{b2b := [], dialogs := [], media := []}}, []} ->
            ok;
        _ ->
            timer:sleep(100),
            gone(Ref, N - 1)
    end.

%% (erpc: peer:call/4 over a distribution connection fails here with
%% noconnection while the node answers pings)
wait_found(_Node, Ref, 0) -> ct:fail({not_found_from_peer, Ref});
wait_found(Node, Ref, N) ->
    case erpc:call(Node, chappe_sip, calls, [#{call_ref => Ref}]) of
        {ok, #{b2b := [_], dialogs := [_, _]} = Found} -> Found;
        _ -> timer:sleep(100), wait_found(Node, Ref, N - 1)
    end.


hep_packets(_Sock, 0) -> [];
hep_packets(Sock, N) ->
    receive
        {udp, Sock, _, _, Bin} ->
            {ok, P} = chappe_sip_hep:decode(Bin),
            [P | hep_packets(Sock, N - 1)]
    after 3000 -> ct:fail({no_hep, N})
    end.
