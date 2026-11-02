%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% WebRTC gateway over WS - B2BUA both directions + response correctness.
%%
%% A ws:connect browser and a gen_udp peer, bridged by chappe_sip_b2b over the
%% multiplexed engine. The UDP->browser direction exercises outbound-to-WS
%% (WS client transactions).
-module(chappe_sip_webrtc_gateway_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([ws_received/1, b2b_browser_to_udp/1, b2b_udp_to_browser/1,
         proxy_browser_to_udp/1, proxy_udp_to_browser/1,
         proxy_callee_bye/1, b2b_server_bye_to_browser/1,
         b2b_browser_bye_over_ws/1, proxy_ws_to_ws/1]).
-export([fork_ws_udp_browser_wins/1, fork_ws_udp_phone_wins/1,
         replace_b_fork_ws_udp/1]).

all() ->
    [ws_received, b2b_browser_to_udp, b2b_udp_to_browser,
     proxy_browser_to_udp, proxy_udp_to_browser, proxy_callee_bye,
     b2b_server_bye_to_browser, b2b_browser_bye_over_ws, proxy_ws_to_ws,
     fork_ws_udp_browser_wins, fork_ws_udp_phone_wins, replace_b_fork_ws_udp].

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
    _ = case whereis(webrtc_test_rtpe) of
            undefined -> ok;
            Rtpe ->
                unregister(webrtc_test_rtpe),
                chappe_sip_test_rtpe:stop(Rtpe)
        end,
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    _ = chappe_sip_registry:clear(),
    ok.

%% a WS response's top Via carries received from the client peer, and the
%% rport value the client asked for with a bare rport (livery surfaces the
%% peer from the accepted socket).
%% req: R3581-009 R3261-360 R3261-361
ws_received(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:options(fun(_Req, Res) -> chappe_sip_res:send(Res, 200, #{}) end),
    C = connect(WP),
    ws:send(C, {text, options_req()}),
    R = recv_ws(200),
    {_, _} = binary:match(R, <<"received=127.0.0.1">>),
    {_, _} = binary:match(R, <<"rport=">>),
    ws:close(C, 1000).

%% browser(WS) -> UDP: the browser places a call, bridged to a gen_udp callee.
b2b_browser_to_udp(_Config) ->
    {EP, WP} = start(),
    CalleeP = pick(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, Res) ->
        case chappe_sip:create_b2bua(Req, Res, uctc(CalleeP), #{}) of
            {ok, Legs} -> Test ! b2b_up, chappe_sip_b2b:relay(Legs);
            {error, _} -> ok
        end
    end),
    %% gen_udp callee answers the B-leg
    udp_peer(CalleeP, fun(Sock) ->
        {Inv, Src} = urecv(Sock, <<"INVITE">>),
        usend(Sock, Src, uresp(Inv, 200, <<"OK">>, tag(),
                               [{<<"Contact">>, uctc(CalleeP)}], sdp())),
        {_Ack, _} = urecv(Sock, <<"ACK">>),
        Test ! callee_acked,
        {Bye, BSrc} = urecv(Sock, <<"BYE">>),
        usend(Sock, BSrc, uresp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! callee_byed
    end),
    _ = EP,
    C = connect(WP),
    ws:send(C, {text, invite_req(<<"wsA">>)}),
    R200 = recv_ws(200),
    TT = to_tag(R200),
    ws:send(C, {text, ack_req(<<"wsA">>, TT)}),
    ok = expect(callee_acked),
    ws:send(C, {text, bye_req(<<"wsA">>, TT)}),
    _ = recv_ws(200),
    ok = expect(callee_byed),
    ws:close(C, 1000).

%% UDP -> browser(WS): a gen_udp caller is bridged to the registered browser
%% over WS. Exercises outbound-to-WS.
b2b_udp_to_browser(_Config) ->
    {EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        case chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}) of
            {ok, Legs} -> Test ! b2b_up, chappe_sip_b2b:relay(Legs);
            {error, R} -> Test ! {b2b_err, R}
        end
    end),
    %% the browser registers, then acts as the B-leg UAS over WS
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    %% gen_udp caller places the call
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"udpA">>)),
        R200 = urecv_status(Sock, 200),
        TT = to_tag(R200),
        usend(Sock, EP, uack(Sock, <<"udpA">>, TT)),
        Test ! caller_acked
    end),
    %% browser (B-leg) receives the INVITE over WS and answers
    Inv = recv_ws_method(<<"INVITE">>),
    BTT = <<"bobtag">>,
    ViaB = top_via(Inv),
    ws:send(C, {text, ws_ok200(Inv, ViaB, BTT)}),
    _ = recv_ws_method(<<"ACK">>),          % ACK from the B2BUA over WS
    ok = expect(caller_acked),
    ws:close(C, 1000).

%% M9: a server-initiated in-dialog request reaches a WS UA over its flow.
%% The b2bua bridges a UDP caller to the browser; when the caller hangs up, the
%% b2bua must send the BYE to the browser over its WS connection (its .invalid
%% Contact is not routable), not over UDP.
b2b_server_bye_to_browser(_Config) ->
    {EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        case chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}) of
            {ok, Legs} ->
                Test ! b2b_up,
                {done, Why} = chappe_sip_b2b:relay(Legs),
                Test ! {relay_done, Why};
            {error, R} -> Test ! {b2b_err, R}
        end
    end),
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"udpA">>)),
        R200 = urecv_status(Sock, 200),
        TT = to_tag(R200),
        usend(Sock, EP, uack(Sock, <<"udpA">>, TT)),
        Test ! caller_acked,
        %% caller hangs up: BYE to the b2bua A-leg
        usend(Sock, EP, ubye(Sock, <<"udpA">>, TT)),
        _ = urecv_status(Sock, 200),
        Test ! caller_byed
    end),
    Inv = recv_ws_method(<<"INVITE">>),
    ws:send(C, {text, ws_ok200(Inv, top_via(Inv), <<"bobtag">>)}),
    _ = recv_ws_method(<<"ACK">>),
    ok = expect(caller_acked),
    %% the browser receives the BYE over WS and answers 200
    Bye = recv_ws_method(<<"BYE">>),
    ws:send(C, {text, ws_200(Bye)}),
    ok = expect(caller_byed),
    ok = expect({relay_done, a_bye}),
    ws:close(C, 1000).

%% F7: a browser-originated in-dialog request matches the UAC-created (B-leg)
%% dialog leg over its WS flow. The b2bua bridges a UDP caller to the browser;
%% the browser hangs up, so its BYE arrives over WS and must match the B-leg
%% leg (which lives in the WS transport, not the sofia backend) for the b2bua
%% to relay the BYE to the UDP caller. Before the fix the leg was created on
%% the native backend, so the browser BYE matched no WS leg and never relayed.
b2b_browser_bye_over_ws(_Config) ->
    {EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        case chappe_sip:create_b2bua(Req, Res, Uri, #{flow => Flow}) of
            {ok, Legs} ->
                Test ! b2b_up,
                {done, Why} = chappe_sip_b2b:relay(Legs),
                Test ! {relay_done, Why};
            {error, R} -> Test ! {b2b_err, R}
        end
    end),
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"udpB">>)),
        R200 = urecv_status(Sock, 200),
        TT = to_tag(R200),
        usend(Sock, EP, uack(Sock, <<"udpB">>, TT)),
        Test ! caller_acked,
        %% the browser hangs up: the b2bua relays a BYE to this caller
        {Bye, _Src} = urecv(Sock, <<"BYE">>),
        usend(Sock, EP, uresp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! caller_got_bye
    end),
    Inv = recv_ws_method(<<"INVITE">>),
    ws:send(C, {text, ws_ok200(Inv, top_via(Inv), <<"bobtag">>)}),
    _ = recv_ws_method(<<"ACK">>),
    ok = expect(caller_acked),
    %% browser originates the in-dialog BYE over its flow
    ws:send(C, {text, ws_browser_bye(Inv, <<"bobtag">>)}),
    _ = recv_ws(200),                     % 200 to the browser BYE over WS
    ok = expect(caller_got_bye),
    ok = expect({relay_done, b_bye}),
    ws:close(C, 1000).

%% An anchored fork to a browser over its WS flow and a desk phone over
%% UDP: each branch gets its own rtpengine offer (WebRTC flags toward the
%% browser, plain RTP plus its anchor_params toward the phone), told apart
%% by via-branch, and the winner's answer goes under its to-tag and its
%% via-branch. The result names the winner.
fork_ws_udp_browser_wins(_Config) ->
    fork_ws_udp(browser).

fork_ws_udp_phone_wins(_Config) ->
    fork_ws_udp(phone).

fork_ws_udp(Winner) ->
    {EP, WP} = start(),
    register(webrtc_test_rtpe, chappe_sip_test_rtpe:start(self())),
    PhoneP = pick(),
    Phone = uctc(PhoneP),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    PhoneOpts = #{anchor_params => #{b => #{<<"x-leg">> => <<"phone">>}}},
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        Dests = [{Uri, #{flow => Flow}}, {Phone, PhoneOpts}],
        case chappe_sip:create_b2bua(Req, Res, {parallel, Dests},
                                     #{media => anchor}) of
            {ok, Legs} ->
                #{winner := #{index := I}} = Legs,
                Test ! {winner, I},
                chappe_sip_b2b:relay(Legs);
            {error, R} -> Test ! {b2b_err, R}
        end
    end),
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    udp_peer(PhoneP, fun(Sock) ->
        {Inv, Src} = urecv(Sock, <<"INVITE">>),
        Test ! {phone_invite, Inv},
        case Winner of
            phone ->
                timer:sleep(200),
                usend(Sock, Src, uresp(Inv, 200, <<"OK">>, <<"phonetag">>,
                                       [{<<"Contact">>, Phone}], sdp())),
                {_, _} = urecv(Sock, <<"ACK">>);
            browser ->
                {Cancel, CSrc} = urecv(Sock, <<"CANCEL">>),
                usend(Sock, CSrc, uresp(Cancel, 200, <<"OK">>, <<"phonetag">>,
                                        [], <<>>)),
                usend(Sock, Src, uresp(Inv, 487, <<"Request Terminated">>,
                                       <<"phonetag">>, [], <<>>))
        end,
        timer:sleep(infinity)
    end),
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"udpA">>)),
        R200 = urecv_status(Sock, 200),
        usend(Sock, EP, uack(Sock, <<"udpA">>, to_tag(R200))),
        Test ! {a_200, R200},
        timer:sleep(infinity)
    end),
    Inv = recv_ws_method(<<"INVITE">>),
    case Winner of
        browser ->
            timer:sleep(200),
            ws:send(C, {text, ws_ok200(Inv, top_via(Inv), <<"bobtag">>)}),
            _ = recv_ws_method(<<"ACK">>);
        phone ->
            %% a WS client transaction CANCELs once it got a provisional
            ws:send(C, {text, uresp(Inv, 180, <<"Ringing">>, <<"bobtag">>,
                                    [], <<>>)}),
            Cancel = recv_ws_method(<<"CANCEL">>),
            ws:send(C, {text, ws_200(Cancel)}),
            ws:send(C, {text, uresp(Inv, 487, <<"Request Terminated">>,
                                    <<"bobtag">>, [], <<>>)})
    end,
    PhoneInv = got(phone_invite),
    A200 = got(a_200),
    {WinTag, WinIndex} =
        case Winner of
            browser -> {<<"bobtag">>, 1};
            phone -> {<<"phonetag">>, 2}
        end,
    ?assertEqual(WinIndex, got(winner)),
    Cmds = drain_rtpe(),
    Offers = [Cmd || #{<<"command">> := <<"offer">>} = Cmd <- Cmds],
    [BrowserOffer] = [O || O <- Offers,
                           maps:get(<<"transport-protocol">>, O, <<>>)
                               =:= <<"UDP/TLS/RTP/SAVPF">>],
    [PhoneOffer] = [O || O <- Offers,
                         maps:get(<<"transport-protocol">>, O, <<>>)
                             =:= <<"RTP/AVP">>],
    ?assertEqual(2, length(Offers)),
    ?assertEqual(<<"phone">>, maps:get(<<"x-leg">>, PhoneOffer)),
    ?assertNot(maps:is_key(<<"x-leg">>, BrowserOffer)),
    BVia = maps:get(<<"via-branch">>, BrowserOffer),
    PVia = maps:get(<<"via-branch">>, PhoneOffer),
    ?assertNotEqual(BVia, PVia),
    %% each branch got the SDP of its own offer
    ?assert(has(Inv, <<"a=rtpe-via:", BVia/binary>>)),
    ?assert(has(PhoneInv, <<"a=rtpe-via:", PVia/binary>>)),
    WinVia = case Winner of browser -> BVia; phone -> PVia end,
    [Answer] = [Cmd || #{<<"command">> := <<"answer">>} = Cmd <- Cmds],
    ?assertEqual(WinTag, maps:get(<<"to-tag">>, Answer)),
    ?assertEqual(WinVia, maps:get(<<"via-branch">>, Answer)),
    ?assert(has(A200, <<"a=rtpe-answer:", WinTag/binary>>)),
    ws:close(C, 1000).

%% After a call is up, chappe_sip_b2b:replace_b/3 forks to a browser over
%% its WS flow and a desk phone over UDP: each branch has its own offer,
%% with its own flags, and the browser's answer goes under its To-tag and
%% its via-branch.
replace_b_fork_ws_udp(_Config) ->
    {EP, WP} = start(),
    register(webrtc_test_rtpe, chappe_sip_test_rtpe:start(self())),
    OldP = pick(),
    PhoneP = pick(),
    Old = uctc(OldP),
    Phone = uctc(PhoneP),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, Res) ->
        {ok, #{b2b := B2b} = Legs} =
            chappe_sip:create_b2bua(Req, Res, Old, #{media => anchor}),
        Test ! {b2b, B2b},
        chappe_sip_b2b:relay(Legs)
    end),
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    udp_peer(OldP, fun(Sock) ->
        {Inv, Src} = urecv(Sock, <<"INVITE">>),
        usend(Sock, Src, uresp(Inv, 200, <<"OK">>, <<"oldtag">>,
                               [{<<"Contact">>, Old}], sdp())),
        {_, _} = urecv(Sock, <<"ACK">>),
        {Bye, BS} = urecv(Sock, <<"BYE">>),
        usend(Sock, BS, uresp(Bye, 200, <<"OK">>, <<"oldtag">>, [], <<>>)),
        Test ! {old_bye, true},
        timer:sleep(infinity)
    end),
    udp_peer(PhoneP, fun(Sock) ->
        {Inv, Src} = urecv(Sock, <<"INVITE">>),
        Test ! {phone_invite, Inv},
        {Cancel, CSrc} = urecv(Sock, <<"CANCEL">>),
        usend(Sock, CSrc, uresp(Cancel, 200, <<"OK">>, <<"phonetag">>, [], <<>>)),
        usend(Sock, Src, uresp(Inv, 487, <<"Request Terminated">>,
                               <<"phonetag">>, [], <<>>)),
        timer:sleep(infinity)
    end),
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"udpA">>)),
        R200 = urecv_status(Sock, 200),
        usend(Sock, EP, uack(Sock, <<"udpA">>, to_tag(R200))),
        timer:sleep(infinity)
    end),
    B2b = got(b2b),
    _ = drain_rtpe(),
    {ok, Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
    PhoneOpts = #{anchor_params => #{b => #{<<"x-leg">> => <<"phone">>}}},
    Dests = [{Uri, #{flow => Flow}}, {Phone, PhoneOpts}],
    spawn_link(fun() ->
        Test ! {replaced, chappe_sip_b2b:replace_b(B2b, {parallel, Dests}, #{})}
    end),
    Inv = recv_ws_method(<<"INVITE">>),
    PhoneInv = got(phone_invite),
    timer:sleep(200),
    ws:send(C, {text, ws_ok200(Inv, top_via(Inv), <<"bobtag">>)}),
    _ = recv_ws_method(<<"ACK">>),
    ?assertMatch({ok, #{winner := #{index := 1, uri := Uri}}}, got(replaced)),
    true = got(old_bye),
    Cmds = drain_rtpe(),
    [Offer1, Offer2] = [Cmd || #{<<"command">> := <<"offer">>} = Cmd <- Cmds],
    ?assertMatch(#{<<"transport-protocol">> := <<"UDP/TLS/RTP/SAVPF">>,
                   <<"via-branch">> := <<"chappe-1">>}, Offer1),
    ?assertMatch(#{<<"transport-protocol">> := <<"RTP/AVP">>,
                   <<"via-branch">> := <<"chappe-2">>,
                   <<"x-leg">> := <<"phone">>}, Offer2),
    ?assertNot(maps:is_key(<<"x-leg">>, Offer1)),
    ?assert(has(Inv, <<"a=rtpe-via:chappe-1">>)),
    ?assert(has(PhoneInv, <<"a=rtpe-via:chappe-2">>)),
    [Answer] = [Cmd || #{<<"command">> := <<"answer">>} = Cmd <- Cmds],
    ?assertEqual(<<"bobtag">>, maps:get(<<"to-tag">>, Answer)),
    ?assertEqual(<<"chappe-1">>, maps:get(<<"via-branch">>, Answer)),
    ws:close(C, 1000).

drain_rtpe() ->
    receive {rtpe_cmd, Cmd} -> [Cmd | drain_rtpe()] after 300 -> [] end.

got(Tag) ->
    receive {Tag, V} -> V after 6000 -> ct:fail({missing, Tag}) end.

has(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%% proxy browser(WS) -> UDP: full call. Record-Route so the browser's ACK
%% and BYE traverse the proxy to the UDP callee. (WS -> UDP in-dialog.)
proxy_browser_to_udp(_Config) ->
    {_EP, WP} = start(),
    CalleeP = pick(),
    Test = self(),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        chappe_sip:proxy_request(Req, uctc(CalleeP), #{record_route => true})
    end),
    udp_peer(CalleeP, fun(Sock) ->
        {Inv, Src} = urecv(Sock, <<"INVITE">>),
        usend(Sock, Src, uresp(Inv, 200, <<"OK">>, tag(),
                               [{<<"Contact">>, uctc(CalleeP)}], sdp())),
        {_Ack, _} = urecv(Sock, <<"ACK">>),
        Test ! callee_acked,
        {Bye, BSrc} = urecv(Sock, <<"BYE">>),
        usend(Sock, BSrc, uresp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! callee_byed
    end),
    C = connect(WP),
    ws:send(C, {text, invite_req(<<"wsP">>)}),
    R200 = recv_ws(200),
    {_, _} = binary:match(R200, <<"v=0">>),
    RR = record_route_of(R200),
    TT = to_tag(R200),
    Target = uctc(CalleeP),                       % remote target = callee Contact
    ws:send(C, {text, ws_indialog(<<"ACK">>, <<"wsP">>, TT, RR, 1, Target)}),
    ok = expect(callee_acked),
    ws:send(C, {text, ws_indialog(<<"BYE">>, <<"wsP">>, TT, RR, 2, Target)}),
    _ = recv_ws(200),
    ok = expect(callee_byed),
    ws:close(C, 1000).

%% proxy UDP -> browser(WS): full call. The caller's ACK and BYE route to
%% the browser over WS via the record-route flow token. (UDP -> WS in-dialog.)
proxy_udp_to_browser(_Config) ->
    {EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {ok, _Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        chappe_sip:proxy_request(Req, {ws, Flow}, #{record_route => true})
    end),
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"udpP">>)),
        R200 = urecv_status(Sock, 200),
        RR = record_route_of(R200),
        TT = to_tag(R200),
        usend(Sock, EP, uindialog(Sock, <<"ACK">>, <<"udpP">>, TT, RR, 1)),
        Test ! caller_acked,
        usend(Sock, EP, uindialog(Sock, <<"BYE">>, <<"udpP">>, TT, RR, 2)),
        _ = urecv_status(Sock, 200),
        Test ! caller_byed
    end),
    Inv = recv_ws_method(<<"INVITE">>),
    ws:send(C, {text, ws_ok200(Inv, top_via(Inv), <<"bobP">>)}),
    ok = expect(caller_acked),
    _ = recv_ws_method(<<"ACK">>),                % ACK forwarded over WS
    Bye = recv_ws_method(<<"BYE">>),              % BYE forwarded over WS
    ws:send(C, {text, ws_resp200(Bye)}),          % browser 200s the BYE
    ok = expect(caller_byed),
    ws:close(C, 1000).

%% proxy UDP -> browser(WS): the browser (callee) initiates the BYE, which
%% routes back to the UDP caller. (WS -> UDP in-dialog, reverse.)
proxy_callee_bye(_Config) ->
    {EP, WP} = start(),
    Test = self(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {ok, _Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        chappe_sip:proxy_request(Req, {ws, Flow}, #{record_route => true})
    end),
    C = connect(WP),
    ws:send(C, {text, register_bob()}),
    _ = recv_ws(200),
    udp_peer(0, fun(Sock) ->
        usend(Sock, EP, uinvite(Sock, <<"cb">>)),
        R200 = urecv_status(Sock, 200),
        RR = record_route_of(R200),
        TT = to_tag(R200),
        usend(Sock, EP, uindialog(Sock, <<"ACK">>, <<"cb">>, TT, RR, 1)),
        Test ! caller_acked,
        {Bye, _Src} = urecv(Sock, <<"BYE">>),     % callee BYE reaches caller
        usend(Sock, EP, uresp(Bye, 200, <<"OK">>, tag(), [], <<>>)),
        Test ! caller_relayed_bye
    end),
    Inv = recv_ws_method(<<"INVITE">>),
    RRb = record_route_of(Inv),
    CallerContact = contact_uri_of(Inv),          % caller's Contact (its port)
    ws:send(C, {text, ws_ok200(Inv, top_via(Inv), <<"bobP">>)}),
    ok = expect(caller_acked),
    _ = recv_ws_method(<<"ACK">>),
    %% callee (browser) sends BYE toward the caller, routed via the proxy
    ws:send(C, {text, ws_callee_bye(RRb, CallerContact)}),
    _ = recv_ws(200),                             % 200 to the BYE over WS
    ok = expect(caller_relayed_bye),
    ws:close(C, 1000).

%% proxy browser(WS) -> browser(WS): the Record-Route carries a flow token
%% for each leg, so the caller's ACK reaches the callee over its connection
%% and the callee's BYE reaches the caller over the caller's.
proxy_ws_to_ws(_Config) ->
    {_EP, WP} = start(),
    ok = chappe_sip:register(chappe_sip:registrar(#{allow_unauthenticated => true})),
    ok = chappe_sip:invite(fun(Req, _Res) ->
        {ok, _Uri, Flow} = chappe_sip:location_flow(<<"sip:bob@127.0.0.1">>),
        chappe_sip:proxy_request(Req, {ws, Flow}, #{record_route => true})
    end),
    Test = self(),
    %% the callee's frames come tagged so they are told from the caller's
    Tagger = spawn_link(fun Loop() ->
        receive {ws_in, B} -> Test ! {ws_bob, B}, Loop() end
    end),
    Bob = connect_as(WP, Tagger),
    ws:send(Bob, {text, register_bob()}),
    _ = recv_bob(<<"SIP/2.0 200">>),
    Alice = connect(WP),
    ws:send(Alice, {text, invite_req(<<"w2w">>)}),
    Inv = recv_bob(<<"INVITE">>),
    ws:send(Bob, {text, ws_ok200(Inv, top_via(Inv), <<"bobW">>)}),
    R200 = recv_ws(200),
    RR = record_route_of(R200),
    TT = to_tag(R200),
    Bob1 = <<"sip:bob@df7jal.invalid;transport=ws">>,
    ws:send(Alice, {text, ws_indialog(<<"ACK">>, <<"w2w">>, TT, RR, 1, Bob1)}),
    _ = recv_bob(<<"ACK">>),
    %% the callee hangs up: its BYE goes to the caller's connection
    ws:send(Bob, {text, ws_w2w_bye(RR, TT)}),
    Bye = recv_ws_method(<<"BYE">>),
    ws:send(Alice, {text, ws_resp200(Bye)}),
    _ = recv_bob(<<"SIP/2.0 200">>),
    ws:close(Alice, 1000),
    ws:close(Bob, 1000).

%% ---- helpers ----

connect_as(WP, Notify) ->
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{handler => chappe_sip_ws_test_client,
                                handler_opts => #{notify => Notify},
                                subprotocols => [<<"sip">>]}),
    C.

%% the next frame the callee got that starts with Prefix
recv_bob(Prefix) ->
    L = byte_size(Prefix),
    receive
        {ws_bob, <<P:L/binary, _/binary>> = Bin} when P =:= Prefix -> Bin;
        {ws_bob, _} -> recv_bob(Prefix)
    after 6000 -> ct:fail({no_bob_frame, Prefix})
    end.

%% the callee's BYE toward the caller, routed through our record-route
ws_w2w_bye(RR, BobTag) ->
    <<"BYE sip:alice@df7jal.invalid;transport=ws SIP/2.0\r\n"
      "Via: SIP/2.0/WS bobhost.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: <sip:app@127.0.0.1>;tag=", BobTag/binary, "\r\n"
      "To: Browser <sip:alice@127.0.0.1>;tag=w2w\r\n"
      "Call-ID: wscallA@ct\r\nCSeq: 7 BYE\r\nContent-Length: 0\r\n\r\n">>.

start() ->
    EP = pick(),
    WP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>,
                      ws => #{port => WP}}),
    {EP, WP}.

connect(WP) ->
    Url = <<"ws://127.0.0.1:", (integer_to_binary(WP))/binary, "/ws">>,
    {ok, C} = ws:connect(Url, #{handler => chappe_sip_ws_test_client,
                                handler_opts => #{notify => self()},
                                subprotocols => [<<"sip">>]}),
    C.

recv_ws(Code) ->
    CB = integer_to_binary(Code),
    receive
        {ws_in, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of CB -> Bin; _ -> recv_ws(Code) end;
        {ws_in, _} -> recv_ws(Code)
    after 6000 -> ct:fail({no_ws_status, Code})
    end.

recv_ws_method(Method) ->
    L = byte_size(Method),
    receive
        {ws_in, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method -> Bin;
        {ws_in, _} -> recv_ws_method(Method)
    after 6000 -> ct:fail({no_ws_req, Method})
    end.

expect(Msg) -> receive Msg -> ok after 6000 -> ct:fail({expected, Msg}) end.

pick() -> chappe_sip_test_port:pick().
tag() -> binary:encode_hex(crypto:strong_rand_bytes(5), lowercase).
uctc(P) -> <<"sip:x@127.0.0.1:", (integer_to_binary(P))/binary>>.
sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.
to_tag(Resp) -> {ok, M} = chappe_sip_msg:parse(Resp), chappe_sip_msg:to_tag(M).
top_via(Bin) -> {ok, M} = chappe_sip_msg:parse(Bin), chappe_sip_msg:get(<<"via">>, M).
record_route_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin), chappe_sip_msg:get(<<"record-route">>, M).
contact_uri_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    case chappe_sip_hdr:name_addr(chappe_sip_msg:get(<<"contact">>, M)) of
        {ok, #{uri := Uri}} -> Uri;
        _ -> chappe_sip_msg:get(<<"contact">>, M)
    end.

%% ---- gen_udp peer ----

udp_peer(Port, Fun) ->
    Parent = self(),
    Pid = spawn_link(fun() ->
        {ok, Sock} = gen_udp:open(Port, [binary, {active, true},
                                         {ip, {127,0,0,1}}]),
        Parent ! {upeer_ready, self()},
        Fun(Sock)
    end),
    receive {upeer_ready, Pid} -> ok after 2000 -> ct:fail(peer_not_ready) end,
    Pid.

uport(Sock) -> {ok, P} = inet:port(Sock), P.
usend(Sock, Dst, Bin) -> gen_udp:send(Sock, {127,0,0,1}, Dst, Bin).
branch() ->
    <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>.

urecv(Sock, Method) ->
    L = byte_size(Method),
    receive
        {udp, Sock, _, Src, <<M:L/binary, " ", _/binary>> = Bin} when M =:= Method ->
            {Bin, Src};
        {udp, Sock, _, _, _} -> urecv(Sock, Method)
    after 6000 -> ct:fail({no_udp_req, Method})
    end.

urecv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of CB -> Bin; _ -> urecv_status(Sock, Code) end
    after 6000 -> ct:fail({no_udp_status, Code})
    end.

%% ---- WS-client (browser) messages ----

options_req() ->
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;rport;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1>;tag=o1\r\nTo: <sip:app@127.0.0.1>\r\n"
      "Call-ID: wsopt@ct\r\nCSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>.

register_bob() ->
    <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:bob@127.0.0.1>;tag=bobreg\r\nTo: <sip:bob@127.0.0.1>\r\n"
      "Contact: <sip:bob@df7jal.invalid;transport=ws>\r\n"
      "Call-ID: bobreg@ct\r\nCSeq: 1 REGISTER\r\nExpires: 3600\r\n"
      "Content-Length: 0\r\n\r\n">>.

invite_req(FT) ->
    S = sdp(), L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Browser <sip:alice@127.0.0.1>;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:alice@df7jal.invalid;transport=ws>\r\n"
      "Call-ID: wscallA@ct\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\nContent-Length: ", L/binary,
      "\r\n\r\n", S/binary>>.

ack_req(FT, TT) ->
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Browser <sip:alice@127.0.0.1>;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: wscallA@ct\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

bye_req(FT, TT) ->
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: Browser <sip:alice@127.0.0.1>;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: wscallA@ct\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% a browser (WS) in-dialog request routed through the proxy: R-URI is the
%% remote target (callee Contact), top Route is our record-route so the proxy
%% forwards it onward.
ws_indialog(Method, FT, TT, RR, CSeq, RURI) ->
    CS = integer_to_binary(CSeq),
    <<Method/binary, " ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: Browser <sip:alice@127.0.0.1>;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: wscallA@ct\r\nCSeq: ", CS/binary, " ", Method/binary, "\r\n"
      "Content-Length: 0\r\n\r\n">>.

%% browser (B-leg UAS) originates an in-dialog BYE from the INVITE it answered:
%% From/To swap and the browser's To-tag becomes the From-tag so match_leg
%% keys on {Call-ID, our-tag, browser-tag}. Routed over the WS flow, so the
%% R-URI is cosmetic (use the b2bua's From URI).
ws_browser_bye(Inv, BTag) ->
    {ok, M} = chappe_sip_msg:parse(Inv),
    From = chappe_sip_msg:get(<<"from">>, M),   % b2bua incl. its tag -> our To
    To0 = chappe_sip_msg:get(<<"to">>, M),      % browser target (no tag) -> our From
    Call = chappe_sip_msg:call_id(M),
    RURI = case chappe_sip_hdr:name_addr(From) of
               {ok, #{uri := U}} -> U;
               _ -> <<"sip:127.0.0.1">>
           end,
    <<"BYE ", RURI/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: ", To0/binary, ";tag=", BTag/binary, "\r\n"
      "To: ", From/binary, "\r\n"
      "Call-ID: ", Call/binary, "\r\n"
      "CSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% callee (browser) originates a BYE toward the caller through the proxy:
%% R-URI is the caller's Contact, From is the browser, To is the caller.
ws_callee_bye(RR, CallerContact) ->
    <<"BYE ", CallerContact/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/WS df7jal.invalid;branch=", (branch())/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: <sip:bob@127.0.0.1>;tag=bobP\r\n"
      "To: Caller <sip:caller@127.0.0.1>;tag=cb\r\n"
      "Call-ID: udpcallA@ct\r\nCSeq: 5 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% 200 to an in-dialog request received over WS (echo Vias, keep tags)
ws_resp200(ReqBin) ->
    {ok, M} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, M),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    iolist_to_binary(
      [<<"SIP/2.0 200 OK\r\n">>, ViaLines,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, M), <<"\r\n">>,
       <<"To: ">>, chappe_sip_msg:get(<<"to">>, M), <<"\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(M), <<"\r\n">>,
       <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, M), <<"\r\n">>,
       <<"Content-Length: 0\r\n\r\n">>]).

%% browser answers an incoming (B-leg) INVITE: echo Vias, add To-tag+SDP
ws_ok200(ReqBin, _Via, ToTag) ->
    {ok, M} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, M),
    From = chappe_sip_msg:get(<<"from">>, M),
    To0 = chappe_sip_msg:get(<<"to">>, M),
    Call = chappe_sip_msg:call_id(M),
    CSeq = chappe_sip_msg:get(<<"cseq">>, M),
    S = sdp(),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    RRLines = [[<<"Record-Route: ">>, RR, <<"\r\n">>]
               || RR <- chappe_sip_msg:get_all(<<"record-route">>, M)],
    iolist_to_binary(
      [<<"SIP/2.0 200 OK\r\n">>, ViaLines, RRLines,
       <<"From: ">>, From, <<"\r\n">>,
       <<"To: ">>, To0, <<";tag=">>, ToTag, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>,
       <<"Contact: <sip:bob@df7jal.invalid;transport=ws>\r\n">>,
       <<"Content-Type: application/sdp\r\n">>,
       <<"Content-Length: ">>, integer_to_binary(byte_size(S)),
       <<"\r\n\r\n">>, S]).

%% ---- UDP-caller messages ----

uinvite(Sock, FT) ->
    P = integer_to_binary(uport(Sock)),
    S = sdp(), L = integer_to_binary(byte_size(S)),
    <<"INVITE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: udpcallA@ct\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\nContent-Length: ", L/binary,
      "\r\n\r\n", S/binary>>.

uack(Sock, FT, TT) ->
    P = integer_to_binary(uport(Sock)),
    <<"ACK sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: udpcallA@ct\r\nCSeq: 1 ACK\r\nContent-Length: 0\r\n\r\n">>.

ubye(Sock, FT, TT) ->
    P = integer_to_binary(uport(Sock)),
    <<"BYE sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: udpcallA@ct\r\nCSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n">>.

%% a bare 200 to a request received over WS (echoes the dialog headers)
ws_200(ReqBin) ->
    {ok, M} = chappe_sip_msg:parse(ReqBin),
    Via = chappe_sip_msg:get(<<"via">>, M),
    From = chappe_sip_msg:get(<<"from">>, M),
    To = chappe_sip_msg:get(<<"to">>, M),
    Call = chappe_sip_msg:call_id(M),
    CSeq = chappe_sip_msg:get(<<"cseq">>, M),
    <<"SIP/2.0 200 OK\r\nVia: ", Via/binary, "\r\nFrom: ", From/binary,
      "\r\nTo: ", To/binary, "\r\nCall-ID: ", Call/binary,
      "\r\nCSeq: ", CSeq/binary, "\r\nContent-Length: 0\r\n\r\n">>.

%% a UDP caller's in-dialog request routed through the proxy (Route = our RR)
uindialog(Sock, Method, FT, TT, RR, CSeq) ->
    P = integer_to_binary(uport(Sock)),
    CS = integer_to_binary(CSeq),
    <<Method/binary, " sip:bob@df.invalid;transport=ws SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";branch=", (branch())/binary,
      "\r\nMax-Forwards: 70\r\n"
      "Route: ", RR/binary, "\r\n"
      "From: Caller <sip:caller@127.0.0.1:", P/binary, ">;tag=", FT/binary, "\r\n"
      "To: <sip:app@127.0.0.1>;tag=", TT/binary, "\r\n"
      "Call-ID: udpcallA@ct\r\nCSeq: ", CS/binary, " ", Method/binary,
      "\r\nContent-Length: 0\r\n\r\n">>.

uresp(ReqBin, Status, Reason, ToTag, ExtraHeaders, Body) ->
    {ok, Msg} = chappe_sip_msg:parse(ReqBin),
    Vias = chappe_sip_msg:get_all(<<"via">>, Msg),
    From = chappe_sip_msg:get(<<"from">>, Msg),
    To0 = chappe_sip_msg:get(<<"to">>, Msg),
    To = case chappe_sip_msg:to_tag(Msg) of
             undefined when Status > 100 -> <<To0/binary, ";tag=", ToTag/binary>>;
             _ -> To0
         end,
    Call = chappe_sip_msg:call_id(Msg),
    CSeq = chappe_sip_msg:get(<<"cseq">>, Msg),
    ViaLines = [[<<"Via: ">>, V, <<"\r\n">>] || V <- Vias],
    %% a UAS echoes Record-Route into its response (RFC 3261 12.1.1)
    RRLines = [[<<"Record-Route: ">>, RR, <<"\r\n">>]
               || RR <- chappe_sip_msg:get_all(<<"record-route">>, Msg)],
    Extra = [[N, <<": ">>, Val, <<"\r\n">>] || {N, Val} <- ExtraHeaders],
    CL = integer_to_binary(byte_size(Body)),
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
       ViaLines, RRLines,
       <<"From: ">>, From, <<"\r\n">>, <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, Call, <<"\r\n">>, <<"CSeq: ">>, CSeq, <<"\r\n">>, Extra,
       <<"Content-Length: ">>, CL, <<"\r\n\r\n">>, Body]).
