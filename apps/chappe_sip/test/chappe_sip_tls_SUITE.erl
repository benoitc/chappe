%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% TLS contact.
%%
%% Start the engine with a secondary TLS listener (its own port), then drive
%% requests over real TLS sockets: the listener answers, refuses TLS 1.0/1.1
%% and, when asked, a client without a certificate; outbound connections
%% check the server certificate (RFC 5922); a request that came over TLS is
%% record-routed and answered with our sips URI (RFC 5630). Skipped if
%% openssl is not on PATH to generate throwaway certificates.
-module(chappe_sip_tls_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([tls_options/1, udp_still_works/1, tls_bad_verify/1,
         verify_none_needs_insecure/1, old_versions_refused/1,
         client_cert_required/1, outbound_verified/1, outbound_untrusted/1,
         record_route_sips/1, record_route_tls_to_sip/1,
         sip_request_to_sips_target/1, sips_request_to_sip_target/1,
         uas_contact_sips/1, forked_2xx_over_tls/1,
         sips_request_sips_contact/1, subscribe_notify_over_tls/1]).
-export([uac_secure_contact/1, uac_dialog_sips_contact/1,
         sips_ruri_via_sip_proxy/1, sips_transport_udp_refused/1]).

all() ->
    [tls_options, udp_still_works, tls_bad_verify, verify_none_needs_insecure,
     old_versions_refused, client_cert_required, outbound_verified,
     outbound_untrusted, record_route_sips, record_route_tls_to_sip,
     sip_request_to_sips_target, sips_request_to_sip_target,
     uas_contact_sips, forked_2xx_over_tls, sips_request_sips_contact,
     subscribe_notify_over_tls, uac_secure_contact,
     uac_dialog_sips_contact, sips_ruri_via_sip_proxy,
     sips_transport_udp_refused].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    {ok, _} = application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% OPTIONS over TLS is answered on the same connection.
tls_options(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "tlscerts"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    case gen_certs(CertDir) of
        {error, no_openssl} ->
            {skip, "openssl not available"};
        ok ->
            EP = pick(),
            TP = pick(),
            ok = chappe_sip:start(#{
                contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
                tls => #{contact => <<"sips:127.0.0.1:",
                                      (integer_to_binary(TP))/binary,
                                      ";transport=tls">>,
                         cert_dir => list_to_binary(CertDir),
                         verify => none,
                         allow_insecure => true}}),
            ok = chappe_sip:options(fun(_Req, Res) ->
                chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
            end),
            {ok, S} = ssl:connect("127.0.0.1", TP,
                                  [{verify, verify_none}, binary,
                                   {active, false}, {versions, ['tlsv1.2']}],
                                  5000),
            ok = ssl:send(S, options_req()),
            {ok, Data} = ssl:recv(S, 0, 5000),
            ?assertMatch(<<"SIP/2.0 200", _/binary>>, Data),
            ok = ssl:close(S)
    end.

%% F11: an unrecognised TLS verify value is rejected, not silently treated as
%% no verification.
tls_bad_verify(_Config) ->
    EP = pick(),
    TP = pick(),
    R = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        tls => #{contact => <<"sips:127.0.0.1:", (integer_to_binary(TP))/binary,
                              ";transport=tls">>,
                 verify => banana}}),
    ?assertMatch({error, {tls, {bad_verify, banana}}}, R).

%% Turning certificate verification off takes an explicit allow_insecure:
%% verify => none alone fails the start.
%% req: R5922-03
verify_none_needs_insecure(_Config) ->
    EP = pick(),
    TP = pick(),
    R = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        tls => #{contact => <<"sips:127.0.0.1:", (integer_to_binary(TP))/binary,
                              ";transport=tls">>,
                 verify => none}}),
    ?assertMatch({error, {tls, insecure_verify_none}}, R).

%% The listener takes TLS 1.2 and up: a TLS 1.1 client is refused.
old_versions_refused(Config) ->
    with_ca(Config, "old", fun(Dir) ->
        TP = start_tls(Dir, #{}),
        Old = ssl:connect("127.0.0.1", TP,
                          [{verify, verify_none}, binary, {active, false},
                           {versions, ['tlsv1.1']},
                           {ciphers, ssl:cipher_suites(all, 'tlsv1.1')}],
                          5000),
        ?assertMatch({error, _}, Old),
        {ok, S} = ssl:connect("127.0.0.1", TP,
                              [{verify, verify_none}, binary, {active, false},
                               {versions, ['tlsv1.2']}], 5000),
        ok = ssl:close(S)
    end).

%% verify_clients => true: a client without a certificate the CA signed is
%% refused, one with it is served.
%% req: R5922-04
client_cert_required(Config) ->
    with_ca(Config, "cli", fun(Dir) ->
        TP = start_tls(Dir, #{verify_clients => true}),
        ok = chappe_sip:options(fun(_Req, Res) ->
            chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
        end),
        Base = [{verify, verify_none}, binary, {active, false},
                {versions, ['tlsv1.2']}],
        case ssl:connect("127.0.0.1", TP, Base, 5000) of
            {ok, Bare} ->
                %% the server's refusal may surface on the first read
                _ = ssl:send(Bare, options_req()),
                ?assertMatch({error, _}, ssl:recv(Bare, 0, 3000));
            {error, _} ->
                ok
        end,
        {ok, S} = ssl:connect("127.0.0.1", TP,
                              [{certfile, file(Dir, "client.pem")},
                               {keyfile, file(Dir, "client.key")} | Base],
                              5000),
        ok = ssl:send(S, options_req()),
        {ok, Data} = ssl:recv(S, 0, 5000),
        ?assertMatch(<<"SIP/2.0 200", _/binary>>, Data),
        ok = ssl:close(S)
    end).

%% An outbound sips request reaches a server whose certificate the CA
%% signed for the target host.
%% req: R5922-01 R5922-03 R3261-007
outbound_verified(Config) ->
    with_ca(Config, "outok", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        {SP, Got} = tls_server(file(Dir, "server.pem"), file(Dir, "server.key")),
        {ok, _} = chappe_sip:request(sips_uri(SP), #{}),
        ?assertMatch({data, <<"OPTIONS ", _/binary>>}, Got())
    end).

%% A server whose certificate no trusted CA signed gets no request: the
%% connection is closed after the handshake check.
%% req: R5922-02
outbound_untrusted(Config) ->
    with_ca(Config, "outbad", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        {SP, Got} = tls_server(file(Dir, "rogue.pem"), file(Dir, "rogue.key")),
        {ok, _} = chappe_sip:request(sips_uri(SP), #{}),
        ?assertNotMatch({data, <<"OPTIONS ", _/binary>>}, Got())
    end).

%% A SIPS request forwarded to a SIPS target is record-routed with our
%% sips (TLS) URI, after the target's certificate was checked.
%% req: R5630-01 R5630-03 R3261-P-009 R5922-05 R5922-06 R3261-384
record_route_sips(Config) ->
    with_ca(Config, "rr", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        {SP, Got} = tls_server(file(Dir, "server.pem"), file(Dir, "server.key")),
        ok = chappe_sip:invite(fun(Req, _Res) ->
            chappe_sip:proxy_request(Req, [sips_uri(SP)], #{record_route => true})
        end),
        EP = engine_port(),
        {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        ok = gen_udp:send(U, {127,0,0,1}, EP,
                          invite_udp(U, <<"sips:callee@127.0.0.1">>)),
        {data, Inv} = Got(),
        {ok, M} = chappe_sip_msg:parse(Inv),
        RR = chappe_sip_msg:get(<<"record-route">>, M),
        ?assertMatch(<<"<sips:127.0.0.1:", _/binary>>, RR),
        ?assertEqual(nomatch, binary:match(RR, <<"transport=tls">>)),
        {ok, #{uri := RRUri}} = chappe_sip_hdr:name_addr(RR),
        ?assertEqual([], chappe_sip_core_peer:repeated_uri_params(RRUri)),
        gen_udp:close(U)
    end).

%% RFC 5630 5.3: a SIP request for a SIPS target keeps a SIP Request-URI
%% and goes over TLS.
%% req: R5630-04
sip_request_to_sips_target(Config) ->
    with_ca(Config, "s2s", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        {SP, Got} = tls_server(file(Dir, "server.pem"), file(Dir, "server.key")),
        ok = chappe_sip:invite(fun(Req, _Res) ->
            chappe_sip:proxy_request(Req, [sips_uri(SP)], #{})
        end),
        {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        ok = gen_udp:send(U, {127,0,0,1}, engine_port(),
                          invite_udp(U, <<"sip:callee@127.0.0.1">>)),
        {data, Inv} = Got(),
        {ok, M} = chappe_sip_msg:parse(Inv),
        ?assertMatch(<<"sip:srv@127.0.0.1:", _/binary>>, chappe_sip_msg:uri(M)),
        gen_udp:close(U)
    end).

%% RFC 5630 5.3: a SIPS request is never forwarded to a SIP target: 480.
%% req: R5630-05
sips_request_to_sip_target(Config) ->
    with_ca(Config, "s2p", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        D = pick(),
        ok = chappe_sip:invite(fun(Req, _Res) ->
            chappe_sip:proxy_request(
                Req, [<<"sip:bob@127.0.0.1:", (integer_to_binary(D))/binary>>],
                #{})
        end),
        {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        ok = gen_udp:send(U, {127,0,0,1}, engine_port(),
                          invite_udp(U, <<"sips:callee@127.0.0.1">>)),
        Final = recv_udp_final(U),
        ?assertMatch(<<"SIP/2.0 480", _/binary>>, Final),
        gen_udp:close(U)
    end).

%% A request that came over TLS but goes on to a sip target is
%% record-routed with a sip URI (RFC 3261 16.6 step 4), and the 2xx going
%% back over TLS carries it rewritten to our sips URI (16.7 step 8).
%% req: R3261-P-009 R3261-P-029
record_route_tls_to_sip(Config) ->
    with_ca(Config, "rr2", fun(Dir) ->
        TP = start_tls(Dir, #{}),
        D = pick(),
        ok = chappe_sip:invite(fun(Req, _Res) ->
            chappe_sip:proxy_request(
                Req, [<<"127.0.0.1:", (integer_to_binary(D))/binary>>],
                #{record_route => true})
        end),
        {ok, U} = gen_udp:open(D, [binary, {active, true}, {ip, {127,0,0,1}}]),
        S = tls_client(TP),
        ok = ssl:send(S, invite_tls()),
        {Inv, Src} = receive
                         {udp, U, _, SrcP, <<"INVITE", _/binary>> = I} -> {I, SrcP}
                     after 5000 -> ct:fail(no_forwarded_invite)
                     end,
        {ok, M} = chappe_sip_msg:parse(Inv),
        RR = chappe_sip_msg:get(<<"record-route">>, M),
        ?assertMatch(<<"<sip:127.0.0.1:", _/binary>>, RR),
        ok = gen_udp:send(U, {127,0,0,1}, Src, ok200(M, RR)),
        R200 = recv_tls_final(S),
        {ok, M200} = chappe_sip_msg:parse(R200),
        ?assertMatch(<<"<sips:127.0.0.1:", _/binary>>,
                     chappe_sip_msg:get(<<"record-route">>, M200)),
        gen_udp:close(U),
        ssl:close(S)
    end).

%% A dialog formed over TLS gets a 2xx whose Contact is our sips URI.
%% req: R5630-02 R3261-007
uas_contact_sips(Config) ->
    with_ca(Config, "uas", fun(Dir) ->
        TP = start_tls(Dir, #{}),
        ok = chappe_sip:invite(fun(Req, Res) ->
            {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()}),
            receive stop -> ok after 3000 -> ok end
        end),
        S = tls_client(TP),
        ok = ssl:send(S, invite_tls()),
        R200 = recv_tls_final(S),
        {ok, M} = chappe_sip_msg:parse(R200),
        ?assertMatch(<<"<sips:127.0.0.1:", _/binary>>,
                     chappe_sip_msg:get(<<"contact">>, M)),
        ssl:close(S)
    end).

%% With a TLS listener, an INVITE over UDP whose Request-URI is sips, and
%% one whose top Record-Route is sips, each get a 200 whose Contact is our
%% sips URI; a plain sip one keeps a sip Contact (12.1.1). sips URIs are
%% taken and generated (26.4).
%% req: R3261-126 R3261-007
sips_request_sips_contact(Config) ->
    with_ca(Config, "sipsc", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        ok = chappe_sip:invite(fun(Req, Res) ->
            {ok, _} = chappe_sip:create_uas(Req, Res, #{local_sdp => sdp()})
        end),
        {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        LP = lport(U),
        Call = fun(RUri, Hdrs) ->
            Inv = chappe_sip_core_peer:request(
                    <<"INVITE">>, RUri,
                    #{port => LP, body => sdp(), headers => Hdrs,
                      to => <<"<sip:callee@127.0.0.1>">>}),
            ok = gen_udp:send(U, {127,0,0,1}, engine_port(), Inv),
            R200 = recv_udp_final(U),
            ?assertMatch(<<"SIP/2.0 200", _/binary>>, R200),
            ok = gen_udp:send(U, {127,0,0,1}, engine_port(),
                              chappe_sip_core_peer:ack_for(R200, #{port => LP})),
            {ok, M} = chappe_sip_msg:parse(R200),
            Contact = chappe_sip_msg:get(<<"contact">>, M),
            ct:log("~s -> Contact ~s", [RUri, Contact]),
            Contact
        end,
        ?assertMatch(<<"<sips:127.0.0.1:", _/binary>>,
                     Call(<<"sips:callee@127.0.0.1">>, [])),
        ?assertMatch(<<"<sips:127.0.0.1:", _/binary>>,
                     Call(<<"sip:callee@127.0.0.1">>,
                          [{<<"Record-Route">>,
                            <<"<sips:proxy.example.invalid;lr>">>},
                           {<<"Record-Route">>,
                            <<"<sip:inner.example.invalid;lr>">>}])),
        ?assertMatch(<<"<sip:127.0.0.1:", _/binary>>,
                     Call(<<"sip:callee@127.0.0.1">>,
                          [{<<"Record-Route">>,
                            <<"<sip:proxy.example.invalid;lr>">>}])),
        gen_udp:close(U)
    end).

%% A SUBSCRIBE over TLS with a sips Contact: the NOTIFYs of the
%% subscription come back over TLS, on the subscriber's connection, so
%% conference state and the Call-ID, CSeq, Subscription-State and body
%% are integrity protected hop by hop (RFC 4575 9, RFC 6665 9).
%% req: R4575-53 R6665-31
subscribe_notify_over_tls(Config) ->
    with_ca(Config, "subtls", fun(Dir) ->
        TP = start_tls(Dir, #{}),
        Test = self(),
        ok = chappe_sip:subscribe(fun(Req, Res) ->
            {ok, D} = chappe_sip:create_uas(Req, Res, #{expires => 600}),
            Test ! {notified, chappe_sip_dialog:notify(D, #{
                state => active, body => <<"<conference-info/>">>,
                content_type => <<"application/conference-info+xml">>})},
            receive stop -> ok after 5000 -> ok end
        end),
        S = tls_client(TP),
        {ok, {_, LP}} = ssl:sockname(S),
        P = integer_to_binary(LP),
        Sub = <<"SUBSCRIBE sips:conf@127.0.0.1 SIP/2.0\r\n"
                "Via: SIP/2.0/TLS 127.0.0.1:", P/binary, ";branch=z9hG4bK",
                (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary, "\r\n"
                "Max-Forwards: 70\r\n"
                "From: <sips:sub@127.0.0.1>;tag=st1\r\n"
                "To: <sips:conf@127.0.0.1>\r\n"
                "Contact: <sips:sub@127.0.0.1:", P/binary, ">\r\n"
                "Call-ID: subtls-", P/binary, "@ct\r\nCSeq: 1 SUBSCRIBE\r\n"
                "Event: conference\r\nExpires: 600\r\n"
                "Content-Length: 0\r\n\r\n">>,
        ok = ssl:send(S, Sub),
        {R200, Rest} = tls_next_msg(S, <<>>),
        ?assertMatch(<<"SIP/2.0 200", _/binary>>, R200),
        {ok, M200} = chappe_sip_msg:parse(R200),
        ?assertMatch(<<"<sips:", _/binary>>, chappe_sip_msg:get(<<"contact">>, M200)),
        {Notify, _} = tls_next_msg(S, Rest),
        ct:log("over TLS:~n~s", [Notify]),
        {ok, N} = chappe_sip_msg:parse(Notify),
        ?assertEqual(<<"NOTIFY">>, chappe_sip_msg:method(N)),
        ?assertEqual(<<"<conference-info/>">>, chappe_sip_msg:body(N)),
        ?assertMatch(<<"SIP/2.0/TLS ", _/binary>>, chappe_sip_msg:get(<<"via">>, N)),
        ok = ssl:send(S, resp_2xx(N, <<"st2">>)),
        receive {notified, R} -> ?assertMatch({ok, _}, R)
        after 5000 -> ct:fail(no_notify_result)
        end,
        ssl:close(S)
    end).

%% RFC 6026 over TLS: nta ends a reliable INVITE client transaction at the
%% first 2xx, yet a second 2xx with another To-tag on the same branch (a
%% fork past the TLS hop) still reaches the caller.
%% req: R6026-01 R6026-03
forked_2xx_over_tls(Config) ->
    with_ca(Config, "fork", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        {ok, L} = ssl:listen(0, [{certfile, file(Dir, "server.pem")},
                                 {keyfile, file(Dir, "server.key")}, binary,
                                 {active, false}, {reuseaddr, true}]),
        {ok, {_, SP}} = ssl:sockname(L),
        _ = spawn_link(fun() ->
            {ok, T} = ssl:transport_accept(L, 5000),
            {ok, S} = ssl:handshake(T, 5000),
            {ok, M} = chappe_sip_msg:parse(tls_recv_msg(S, <<>>)),
            ok = ssl:send(S, resp_2xx(M, <<"fa">>)),
            timer:sleep(300),
            ok = ssl:send(S, resp_2xx(M, <<"fb">>)),
            _ = ssl:recv(S, 0, 4000),
            ssl:close(L)
        end),
        ok = chappe_sip:invite(fun(Req, _Res) ->
            chappe_sip:proxy_request(Req, [sips_uri(SP)], #{})
        end),
        {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        ok = gen_udp:send(U, {127,0,0,1}, engine_port(),
                          invite_udp(U, <<"sip:callee@127.0.0.1">>)),
        ?assertEqual([<<"fa">>, <<"fb">>], lists:usort(udp_2xx_tags(U, [], 2))),
        gen_udp:close(U)
    end).

%% A request whose Request-URI, outbound proxy or first preloaded route is
%% a SIPS URI carries our sips Contact (RFC 3261 8.1.1.8).
%% req: R3261-026
uac_secure_contact(Config) ->
    with_ca(Config, "uacc", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        SP = tls_uas(Dir),
        Sip = <<"sip:srv@127.0.0.1:", (integer_to_binary(SP))/binary>>,
        Cases = [{sips_uri(SP), #{}},
                 {Sip, #{proxy => sips_uri(SP)}},
                 {<<"sip:srv@far.invalid">>,
                  #{route_set => [<<"<sips:127.0.0.1:",
                                    (integer_to_binary(SP))/binary, ";lr>">>]}}],
        [begin
             {ok, _} = chappe_sip:request(Uri, Opts),
             {S, M} = tls_next(<<"OPTIONS">>),
             ok = ssl:send(S, tls_resp(M, 200, <<"o1">>, <<>>, <<>>)),
             ?assertMatch(<<"<sips:", _/binary>>,
                          chappe_sip_msg:get(<<"contact">>, M))
         end || {Uri, Opts} <- Cases]
    end).

%% An INVITE to a sips target forms a secure dialog: the INVITE and the
%% re-INVITE that refreshes the target both carry a sips Contact (RFC 3261
%% 8.1.1.8, 12.2.1.1).
%% req: R3261-026 R3261-167
uac_dialog_sips_contact(Config) ->
    with_ca(Config, "uacd", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        SP = tls_uas(Dir),
        Me = <<"<sips:callee@127.0.0.1:", (integer_to_binary(SP))/binary, ">">>,
        Test = self(),
        _ = spawn_link(fun() ->
            Test ! {uac, chappe_sip:create_uac(sips_uri(SP),
                                               #{local_sdp => sdp(),
                                                 owner => Test})}
        end),
        {S, Inv} = tls_next(<<"INVITE">>),
        ?assertMatch(<<"<sips:", _/binary>>,
                     chappe_sip_msg:get(<<"contact">>, Inv)),
        ok = ssl:send(S, tls_resp(Inv, 200, <<"d1">>, Me, sdp())),
        D = receive {uac, {ok, D0}} -> D0 after 5000 -> ct:fail(no_dialog) end,
        {_, _} = tls_next(<<"ACK">>),
        _ = spawn_link(fun() -> Test ! {mod, chappe_sip_dialog:modify(D, sdp())} end),
        {S2, ReInv} = tls_next(<<"INVITE">>),
        ?assertMatch(<<"<sips:", _/binary>>,
                     chappe_sip_msg:get(<<"contact">>, ReInv)),
        ok = ssl:send(S2, tls_resp(ReInv, 200, <<>>, Me, sdp())),
        receive {mod, {ok, _}} -> ok after 5000 -> ct:fail(no_modify) end,
        {_, _} = tls_next(<<"ACK">>),
        _ = spawn_link(fun() -> Test ! {bye, chappe_sip_dialog:destroy(D)} end),
        {S3, Bye} = tls_next(<<"BYE">>),
        ok = ssl:send(S3, tls_resp(Bye, 200, <<>>, <<>>, <<>>)),
        receive {bye, _} -> ok after 5000 -> ct:fail(no_bye) end
    end).

%% A sips Request-URI sent through a sip: outbound proxy is resolved as
%% SIPS: it reaches the proxy over TLS, never over UDP (RFC 3261 8.1.2).
%% req: R3261-035
sips_ruri_via_sip_proxy(Config) ->
    with_ca(Config, "sipx", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        SP = tls_uas(Dir),
        {ok, U} = gen_udp:open(SP, [binary, {active, true},
                                    {ip, {127,0,0,1}}]),
        Proxy = <<"sip:127.0.0.1:", (integer_to_binary(SP))/binary>>,
        {ok, _} = chappe_sip:request(sips_uri(SP), #{proxy => Proxy}),
        {S, M} = tls_next(<<"OPTIONS">>),
        ok = ssl:send(S, tls_resp(M, 200, <<"p1">>, <<>>, <<>>)),
        ?assertEqual(sips_uri(SP), chappe_sip_msg:uri(M)),
        receive
            {udp, U, _, _, Got} -> ct:fail({sent_over_udp, Got})
        after 500 -> ok
        end,
        gen_udp:close(U)
    end).

%% A SIPS URI whose transport parameter names UDP is refused, by the UAC
%% and by the proxy: nothing goes out (RFC 3261 19.1.1).
%% req: R3261-385
sips_transport_udp_refused(Config) ->
    with_ca(Config, "sudp", fun(Dir) ->
        _ = start_tls(Dir, #{}),
        {ok, T} = gen_udp:open(0, [binary, {active, true},
                                   {ip, {127,0,0,1}}]),
        Bad = <<"sips:bob@127.0.0.1:", (integer_to_binary(lport(T)))/binary,
                ";transport=udp">>,
        ?assertMatch({error, _}, chappe_sip:request(Bad, #{})),
        ?assertMatch({error, _}, chappe_sip:create_uac(Bad, #{})),
        ok = chappe_sip:invite(fun(Req, _Res) ->
            chappe_sip:proxy_request(Req, [Bad], #{})
        end),
        {ok, U} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
        ok = gen_udp:send(U, {127,0,0,1}, engine_port(),
                          invite_udp(U, <<"sips:callee@127.0.0.1">>)),
        ?assertMatch(<<"SIP/2.0 480", _/binary>>, recv_udp_final(U)),
        receive
            {udp, T, _, _, Got} -> ct:fail({sent_over_udp, Got})
        after 500 -> ok
        end,
        gen_udp:close(U),
        gen_udp:close(T)
    end).

%% the primary UDP transport still works alongside the TLS listener.
udp_still_works(Config) ->
    CertDir = filename:join(?config(priv_dir, Config), "tlscerts2"),
    ok = filelib:ensure_dir(filename:join(CertDir, "x")),
    case gen_certs(CertDir) of
        {error, no_openssl} ->
            {skip, "openssl not available"};
        ok ->
            EP = pick(),
            TP = pick(),
            ok = chappe_sip:start(#{
                contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
                tls => #{contact => <<"sips:127.0.0.1:",
                                      (integer_to_binary(TP))/binary,
                                      ";transport=tls">>,
                         cert_dir => list_to_binary(CertDir)}}),
            ok = chappe_sip:options(fun(_Req, Res) ->
                chappe_sip_res:send(Res, 200, #{reason => <<"OK">>})
            end),
            {ok, Sock} = gen_udp:open(0, [binary, {active, true},
                                          {ip, {127,0,0,1}}]),
            P = integer_to_binary(lport(Sock)),
            gen_udp:send(Sock, {127,0,0,1}, EP, options_udp(P)),
            receive
                {udp, Sock, _, _, <<"SIP/2.0 200", _/binary>>} -> ok
            after 5000 -> ct:fail(no_udp_answer)
            end,
            gen_udp:close(Sock)
    end.

%% ---- helpers ----

%% a test CA, a server and a client certificate it signed (CN 127.0.0.1),
%% and a self-signed rogue certificate; agent.pem/cafile.pem for sofia
with_ca(Config, Name, Fun) ->
    Dir = filename:join(?config(priv_dir, Config), "ca_" ++ Name),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    case gen_ca(Dir) of
        {error, no_openssl} -> {skip, "openssl not available"};
        ok -> Fun(Dir)
    end.

gen_ca(Dir) ->
    F = fun(N) -> file(Dir, N) end,
    Run = fun(Fmt, Args) ->
        os:cmd(lists:flatten(io_lib:format(Fmt, Args)) ++ " 2>/dev/null")
    end,
    _ = Run("openssl req -x509 -newkey rsa:2048 -keyout ~ts -out ~ts -days 2 "
            "-nodes -subj '/CN=chappe test CA'", [F("ca.key"), F("ca.pem")]),
    Ext = F("ext.cnf"),
    %% sofia matches the target host against the DNS and URI subjectAltNames
    %% (RFC 5922 7.1), not IP ones
    ok = file:write_file(Ext, "subjectAltName=URI:sip:127.0.0.1,DNS:localhost\n"),
    Sign = fun(Who, CN) ->
        _ = Run("openssl req -newkey rsa:2048 -keyout ~ts -out ~ts -nodes "
                "-subj '/CN=~ts'", [F(Who ++ ".key"), F(Who ++ ".csr"), CN]),
        Run("openssl x509 -req -in ~ts -CA ~ts -CAkey ~ts -CAcreateserial "
            "-out ~ts -days 2 -extfile ~ts",
            [F(Who ++ ".csr"), F("ca.pem"), F("ca.key"), F(Who ++ ".pem"), Ext])
    end,
    _ = Sign("server", "127.0.0.1"),
    _ = Sign("client", "client"),
    _ = Run("openssl req -x509 -newkey rsa:2048 -keyout ~ts -out ~ts -days 2 "
            "-nodes -subj '/CN=127.0.0.1'", [F("rogue.key"), F("rogue.pem")]),
    case lists:all(fun filelib:is_file/1,
                   [F("ca.pem"), F("server.pem"), F("client.pem"),
                    F("rogue.pem")]) of
        false ->
            {error, no_openssl};
        true ->
            {ok, Cert} = file:read_file(F("server.pem")),
            {ok, Key} = file:read_file(F("server.key")),
            {ok, Ca} = file:read_file(F("ca.pem")),
            ok = file:write_file(F("agent.pem"), [Cert, Key]),
            ok = file:write_file(F("cafile.pem"), Ca)
    end.

file(Dir, Name) -> filename:join(Dir, Name).

%% start chappe with a TLS listener on the CA-signed server certificate
start_tls(Dir, Extra) ->
    EP = pick(),
    TP = pick(),
    ok = chappe_sip:start(#{
        contact => <<"sip:127.0.0.1:", (integer_to_binary(EP))/binary>>,
        tls => maps:merge(#{contact => <<"sips:127.0.0.1:",
                                          (integer_to_binary(TP))/binary,
                                          ";transport=tls">>,
                            cert_dir => list_to_binary(Dir)}, Extra)}),
    TP.

tls_client(TP) ->
    {ok, S} = ssl:connect("127.0.0.1", TP,
                          [{verify, verify_none}, binary, {active, false},
                           {versions, ['tlsv1.2']}], 5000),
    S.

recv_tls_final(S) ->
    case ssl:recv(S, 0, 5000) of
        {ok, <<"SIP/2.0 1", _/binary>>} -> recv_tls_final(S);
        {ok, Bin} -> Bin;
        Err -> ct:fail({no_final, Err})
    end.

%% a TLS server on a free port; Got() returns what the first connection
%% sent: {data, Bin}, or the error
tls_server(Cert, Key) ->
    {ok, L} = ssl:listen(0, [{certfile, Cert}, {keyfile, Key}, binary,
                             {active, false}, {reuseaddr, true}]),
    {ok, {_, Port}} = ssl:sockname(L),
    Parent = self(),
    Ref = make_ref(),
    _ = spawn_link(fun() ->
        R = case ssl:transport_accept(L, 5000) of
                {ok, T} ->
                    case ssl:handshake(T, 5000) of
                        {ok, S} ->
                            case ssl:recv(S, 0, 3000) of
                                {ok, D} -> {data, D};
                                E -> E
                            end;
                        E -> E
                    end;
                E -> E
            end,
        Parent ! {Ref, R},
        ssl:close(L)
    end),
    {Port, fun() -> receive {Ref, R} -> R after 9000 -> timeout end end}.

%% A TLS UAS on a free port with the CA-signed certificate: every message
%% of every connection reaches the test as {tls_msg, Sock, Bin}.
tls_uas(Dir) ->
    {ok, L} = ssl:listen(0, [{certfile, file(Dir, "server.pem")},
                             {keyfile, file(Dir, "server.key")}, binary,
                             {active, false}, {reuseaddr, true}]),
    {ok, {_, Port}} = ssl:sockname(L),
    Test = self(),
    _ = spawn_link(fun() -> tls_accept(L, Test) end),
    Port.

tls_accept(L, Test) ->
    case ssl:transport_accept(L, 20000) of
        {ok, T} ->
            case ssl:handshake(T, 5000) of
                {ok, S} ->
                    Pid = spawn(fun() ->
                        receive go -> tls_read(S, Test, <<>>) end
                    end),
                    ok = ssl:controlling_process(S, Pid),
                    Pid ! go;
                _ ->
                    ok
            end,
            tls_accept(L, Test);
        _ ->
            ssl:close(L)
    end.

tls_read(S, Test, Buf) ->
    case tls_frame(Buf) of
        {Msg, Rest} ->
            Test ! {tls_msg, S, Msg},
            tls_read(S, Test, Rest);
        more ->
            case ssl:recv(S, 0, 20000) of
                {ok, D} -> tls_read(S, Test, <<Buf/binary, D/binary>>);
                _ -> ok
            end
    end.

%% one message off the front of Buf, framed by Content-Length
tls_frame(Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Tail] ->
            {ok, M} = chappe_sip_msg:parse(<<Head/binary, "\r\n\r\n">>),
            Len = binary_to_integer(chappe_sip_msg:get(<<"content-length">>, M)),
            case Tail of
                <<Body:Len/binary, Rest/binary>> ->
                    {<<Head/binary, "\r\n\r\n", Body/binary>>, Rest};
                _ ->
                    more
            end;
        _ ->
            more
    end.

%% the next request of Method the TLS UAS got, as {Sock, Msg}
tls_next(Method) ->
    receive
        {tls_msg, _, <<"SIP/2.0", _/binary>>} ->
            tls_next(Method);
        {tls_msg, S, Bin} ->
            {ok, M} = chappe_sip_msg:parse(Bin),
            case chappe_sip_msg:method(M) of
                Method -> {S, M};
                _ -> tls_next(Method)
            end
    after 5000 -> ct:fail({no_tls_request, Method})
    end.

%% a response to M over TLS; ToTag <<>> keeps the To as it is, Contact
%% <<>> sends none
tls_resp(M, Status, ToTag, Contact, Body) ->
    Vias = [[<<"Via: ">>, V, <<"\r\n">>] || V <- chappe_sip_msg:get_all(<<"via">>, M)],
    To = case ToTag of
             <<>> -> chappe_sip_msg:get(<<"to">>, M);
             _ -> <<(chappe_sip_msg:get(<<"to">>, M))/binary, ";tag=", ToTag/binary>>
         end,
    iolist_to_binary(
      [<<"SIP/2.0 ">>, integer_to_binary(Status), <<" OK\r\n">>, Vias,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, M), <<"\r\n">>,
       <<"To: ">>, To, <<"\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(M), <<"\r\n">>,
       <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, M), <<"\r\n">>,
       [[<<"Contact: ">>, Contact, <<"\r\n">>] || Contact =/= <<>>],
       [<<"Content-Type: application/sdp\r\n">> || Body =/= <<>>],
       <<"Content-Length: ">>, integer_to_binary(byte_size(Body)),
       <<"\r\n\r\n">>, Body]).

sips_uri(Port) ->
    <<"sips:srv@127.0.0.1:", (integer_to_binary(Port))/binary>>.

%% a callee 200 to the forwarded INVITE M, echoing its Record-Route
ok200(M, RR) ->
    Vias = [[<<"Via: ">>, V, <<"\r\n">>] || V <- chappe_sip_msg:get_all(<<"via">>, M)],
    iolist_to_binary(
      [<<"SIP/2.0 200 OK\r\n">>, Vias,
       <<"Record-Route: ">>, RR, <<"\r\n">>,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, M), <<"\r\n">>,
       <<"To: ">>, chappe_sip_msg:get(<<"to">>, M), <<";tag=cal\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(M), <<"\r\n">>,
       <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, M), <<"\r\n">>,
       <<"Contact: <sip:callee@127.0.0.1:9>\r\nContent-Length: 0\r\n\r\n">>]).

%% the To-tags of the 2xx the caller gets, until N distinct ones
udp_2xx_tags(U, Acc, N) ->
    case length(lists:usort(Acc)) >= N of
        true ->
            Acc;
        false ->
            receive
                {udp, U, _, _, <<"SIP/2.0 2", _/binary>> = B} ->
                    {ok, M} = chappe_sip_msg:parse(B),
                    udp_2xx_tags(U, [chappe_sip_msg:to_tag(M) | Acc], N);
                {udp, U, _, _, _} ->
                    udp_2xx_tags(U, Acc, N)
            after 5000 -> Acc
            end
    end.

%% one SIP message off a TLS connection, framed by Content-Length
tls_recv_msg(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Tail] ->
            {ok, M} = chappe_sip_msg:parse(<<Head/binary, "\r\n\r\n">>),
            Len = binary_to_integer(
                    chappe_sip_msg:get(<<"content-length">>, M)),
            case Tail of
                <<Body:Len/binary, _/binary>> ->
                    <<Head/binary, "\r\n\r\n", Body/binary>>;
                _ ->
                    tls_recv_more(S, Buf)
            end;
        _ ->
            tls_recv_more(S, Buf)
    end.

%% the next SIP message off a TLS connection and the bytes after it
tls_next_msg(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Tail] ->
            {ok, M} = chappe_sip_msg:parse(<<Head/binary, "\r\n\r\n">>),
            Len = binary_to_integer(
                    chappe_sip_msg:get(<<"content-length">>, M)),
            case Tail of
                <<Body:Len/binary, Rest/binary>> ->
                    {<<Head/binary, "\r\n\r\n", Body/binary>>, Rest};
                _ ->
                    {ok, D} = ssl:recv(S, 0, 5000),
                    tls_next_msg(S, <<Buf/binary, D/binary>>)
            end;
        _ ->
            {ok, D} = ssl:recv(S, 0, 5000),
            tls_next_msg(S, <<Buf/binary, D/binary>>)
    end.

tls_recv_more(S, Buf) ->
    {ok, D} = ssl:recv(S, 0, 5000),
    tls_recv_msg(S, <<Buf/binary, D/binary>>).

%% a callee 2xx to the forwarded INVITE M with To-tag Tag
resp_2xx(M, Tag) ->
    Vias = [[<<"Via: ">>, V, <<"\r\n">>] || V <- chappe_sip_msg:get_all(<<"via">>, M)],
    iolist_to_binary(
      [<<"SIP/2.0 200 OK\r\n">>, Vias,
       <<"From: ">>, chappe_sip_msg:get(<<"from">>, M), <<"\r\n">>,
       <<"To: ">>, chappe_sip_msg:get(<<"to">>, M), <<";tag=">>, Tag, <<"\r\n">>,
       <<"Call-ID: ">>, chappe_sip_msg:call_id(M), <<"\r\n">>,
       <<"CSeq: ">>, chappe_sip_msg:get(<<"cseq">>, M), <<"\r\n">>,
       <<"Contact: <sips:callee@127.0.0.1:9>\r\nContent-Length: 0\r\n\r\n">>]).

recv_udp_final(U) ->
    receive
        {udp, U, _, _, <<"SIP/2.0 1", _/binary>>} -> recv_udp_final(U);
        {udp, U, _, _, <<"SIP/2.0 ", _/binary>> = B} -> B
    after 5000 -> ct:fail(no_udp_final)
    end.

%% the UDP port of the running engine
engine_port() ->
    {ok, #{port := P}} =
        chappe_sip_uri:parse(strip(chappe_sip_engine:contact())),
    P.

strip(C) ->
    {ok, #{uri := U}} = chappe_sip_hdr:name_addr(C),
    U.

invite_udp(Sock, RUri) ->
    {ok, Port} = inet:port(Sock),
    P = integer_to_binary(Port),
    S = sdp(),
    <<"INVITE ", RUri/binary, " SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bK",
      (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:caller@127.0.0.1>;tag=ru1\r\n"
      "To: <sip:callee@127.0.0.1>\r\n"
      "Contact: <sip:caller@127.0.0.1:", P/binary, ">\r\n"
      "Call-ID: rrs-", P/binary, "@ct\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", (integer_to_binary(byte_size(S)))/binary,
      "\r\n\r\n", S/binary>>.

sdp() ->
    <<"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\n"
      "t=0 0\r\nm=audio 40000 RTP/AVP 0\r\n">>.

invite_tls() ->
    S = sdp(),
    Call = <<"tls-", (binary:encode_hex(crypto:strong_rand_bytes(4)))/binary,
             "@ct">>,
    Br = <<"z9hG4bK", (binary:encode_hex(crypto:strong_rand_bytes(6)))/binary>>,
    <<"INVITE sip:callee@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/TLS 127.0.0.1:12345;branch=", Br/binary, "\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:caller@127.0.0.1>;tag=tl1\r\n"
      "To: <sip:callee@127.0.0.1>\r\n"
      "Contact: <sips:caller@127.0.0.1:12345>\r\n"
      "Call-ID: ", Call/binary, "\r\nCSeq: 1 INVITE\r\n"
      "Content-Type: application/sdp\r\n"
      "Content-Length: ", (integer_to_binary(byte_size(S)))/binary,
      "\r\n\r\n", S/binary>>.

gen_certs(Dir) ->
    Key = filename:join(Dir, "key.pem"),
    Cert = filename:join(Dir, "cert.pem"),
    Cmd = lists:flatten(io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -keyout ~ts -out ~ts -days 2 "
        "-nodes -subj '/CN=127.0.0.1' 2>/dev/null", [Key, Cert])),
    _ = os:cmd(Cmd),
    case filelib:is_file(Cert) andalso filelib:is_file(Key) of
        false ->
            {error, no_openssl};
        true ->
            {ok, CertBin} = file:read_file(Cert),
            {ok, KeyBin} = file:read_file(Key),
            ok = file:write_file(filename:join(Dir, "agent.pem"),
                                 [CertBin, KeyBin]),
            ok = file:write_file(filename:join(Dir, "cafile.pem"), CertBin),
            ok
    end.

pick() -> chappe_sip_test_port:pick().
lport(Sock) -> {ok, P} = inet:port(Sock), P.

options_req() ->
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/TLS 127.0.0.1:12345;branch=z9hG4bKtls1\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1>;tag=t1\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: tls-test@ct\r\n"
      "CSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>.

options_udp(P) ->
    <<"OPTIONS sip:app@127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKu1\r\n"
      "Max-Forwards: 70\r\n"
      "From: <sip:p@127.0.0.1:", P/binary, ">;tag=t2\r\n"
      "To: <sip:app@127.0.0.1>\r\n"
      "Call-ID: udp-test-", P/binary, "@ct\r\n"
      "CSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n">>.
