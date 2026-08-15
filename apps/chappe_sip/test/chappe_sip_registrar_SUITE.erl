%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Registrar location store.
%%
%% The fake group drives chappe_sip_registry directly with constructed REGISTER
%% requests (no engine). The live group registers chappe_sip:registrar() as the
%% REGISTER handler and drives real REGISTERs over gen_udp.
-module(chappe_sip_registrar_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([add_and_lookup/1, refresh/1, add_second/1, remove_one/1,
         star_clear/1, expires_zero/1, query_bindings/1, reorder_rejected/1,
         read_time_expiry/1, survives_registry_crash/1,
         bindings_cap/1, aors_cap/1, malformed_contact_rejected/1]).
-export([live_register/1, live_register_auth/1, live_min_expires_423/1]).

all() ->
    [{group, fake}, {group, live}].

groups() ->
    [{fake, [], [add_and_lookup, refresh, add_second, remove_one, star_clear,
                 expires_zero, query_bindings, reorder_rejected,
                 read_time_expiry, survives_registry_crash,
                 bindings_cap, aors_cap, malformed_contact_rejected]},
     {live, [], [live_register, live_register_auth, live_min_expires_423]}].

init_per_suite(Config) ->
    application:set_env(chappe_sip, engine_mod, chappe_sip_nif,
                        [{persistent, true}]),
    {ok, _} = application:ensure_all_started(chappe_sip),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(chappe_sip),
    application:unset_env(chappe_sip, engine_mod, [{persistent, true}]),
    ok.

init_per_testcase(_Case, Config) ->
    ok = chappe_sip_registry:clear(),
    Config.

end_per_testcase(_Case, _Config) ->
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    application:unset_env(chappe_sip, registrar_max_bindings_per_aor),
    application:unset_env(chappe_sip, registrar_max_aors),
    application:unset_env(chappe_sip, registrar_min_expires),
    ok.

%% ---- fake group ----

add_and_lookup(_Config) ->
    {ok, Bs} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    ?assertEqual(1, length(Bs)),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())),
    [B] = chappe_sip_registry:bindings(aor()),
    ?assert(maps:get(expires, B) =< 3600 andalso maps:get(expires, B) > 3500).

%% the ETS is owned by chappe_sip_registry_keeper, so bindings survive a crash of
%% the chappe_sip_registry gen_server
survives_registry_crash(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())),
    Old = whereis(chappe_sip_registry),
    exit(Old, kill),
    ok = wait_restart(Old, 100),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())).

wait_restart(_Old, 0) -> ct:fail(no_restart);
wait_restart(Old, N) ->
    case whereis(chappe_sip_registry) of
        New when is_pid(New), New =/= Old -> ok;
        _ -> timer:sleep(20), wait_restart(Old, N - 1)
    end.

refresh(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [contact(1, 1800)], undefined, <<"c1">>, 2),
    ?assertEqual(1, length(Bs)),
    [B] = Bs,
    ?assert(maps:get(expires, B) =< 1800 andalso maps:get(expires, B) > 1700).

add_second(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [contact(2, 3600)], undefined, <<"c2">>, 1),
    ?assertEqual(2, length(Bs)),
    ?assertEqual(lists:sort([curi(1), curi(2)]),
                 lists:sort(chappe_sip_registry:lookup(aor()))).

remove_one(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, _} = reg(aor(), [contact(2, 3600)], undefined, <<"c2">>, 1),
    {ok, Bs} = reg(aor(), [contact(1, 0)], undefined, <<"c3">>, 1),
    ?assertEqual([curi(2)], [maps:get(contact, B) || B <- Bs]).

star_clear(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    {ok, Bs} = reg(aor(), [<<"*">>], 0, <<"c4">>, 2),
    ?assertEqual([], Bs),
    ?assertEqual([], chappe_sip_registry:lookup(aor())).

expires_zero(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    %% a contact with no expires param takes the header Expires (0) -> removed
    {ok, Bs} = reg(aor(), [bare_contact(1)], 0, <<"c5">>, 2),
    ?assertEqual([], Bs).

query_bindings(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 1),
    %% a REGISTER with no Contact returns current bindings unchanged
    {ok, Bs} = reg(aor(), [], undefined, <<"c6">>, 2),
    ?assertEqual([curi(1)], [maps:get(contact, B) || B <- Bs]).

reorder_rejected(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 5),
    ?assertEqual({error, 400},
                 reg(aor(), [contact(1, 3600)], undefined, <<"c1">>, 3)).

read_time_expiry(_Config) ->
    {ok, _} = reg(aor(), [contact(1, 1)], undefined, <<"c1">>, 1),
    ?assertEqual([curi(1)], chappe_sip_registry:lookup(aor())),
    timer:sleep(1100),
    ?assertEqual([], chappe_sip_registry:lookup(aor())).

%% F9: too many contacts on one AOR is rejected (403)
bindings_cap(_Config) ->
    application:set_env(chappe_sip, registrar_max_bindings_per_aor, 2),
    ?assertEqual({error, 403},
                 reg(aor(), [contact(1, 3600), contact(2, 3600),
                             contact(3, 3600)], undefined, <<"bc">>, 1)),
    ?assertEqual([], chappe_sip_registry:bindings(aor())).

%% F9: a new AOR past the distinct-AOR cap is rejected (503)
aors_cap(_Config) ->
    application:set_env(chappe_sip, registrar_max_aors, 1),
    ?assertMatch({ok, [_]},
                 reg(aor(), [bare_contact(1)], 3600, <<"ac1">>, 1)),
    ?assertEqual({error, 503},
                 reg(<<"<sip:bob@example.com>">>, [bare_contact(2)], 3600,
                     <<"ac2">>, 1)),
    ?assertEqual([], chappe_sip_registry:bindings(<<"<sip:bob@example.com>">>)).

%% F13: a malformed Contact rejects the REGISTER (400) instead of silently
%% dropping it and confirming the rest.
malformed_contact_rejected(_Config) ->
    ?assertEqual({error, 400},
                 reg(aor(), [<<"@@ not a contact @@">>], 3600, <<"mc">>, 1)),
    ?assertEqual([], chappe_sip_registry:bindings(aor())).

%% ---- live group ----

live_register(_Config) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    ok = chappe_sip:register(chappe_sip:registrar()),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    send(Sock, EP, register_req(LP, 3600, 1)),
    R1 = recv_status(Sock, 200),
    {_, _} = binary:match(R1, <<"expires=">>),
    %% the binding is now resolvable
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% a refresh with a higher CSeq is accepted
    send(Sock, EP, register_req(LP, 7200, 2)),
    _ = recv_status(Sock, 200),
    [Ct] = chappe_sip:location(<<"sip:alice@127.0.0.1">>),
    ?assertEqual(<<"sip:alice@127.0.0.1:", (integer_to_binary(LP))/binary>>, Ct),
    gen_udp:close(Sock).

%% RFC 3261 10.3 step 7: a REGISTER whose expiry is below the configured floor
%% is refused 423 with a Min-Expires header.
live_min_expires_423(_Config) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    application:set_env(chappe_sip, registrar_min_expires, 60),
    ok = chappe_sip:register(chappe_sip:registrar()),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    send(Sock, EP, register_req(LP, 30, 1)),        % 30 < 60
    R = recv_status(Sock, 423),
    {ok, M} = chappe_sip_msg:parse(R),
    ?assertEqual(<<"60">>, chappe_sip_msg:get(<<"min-expires">>, M)),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% at the floor it is accepted
    send(Sock, EP, register_req(LP, 60, 2)),
    _ = recv_status(Sock, 200),
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    gen_udp:close(Sock).

%% F9: a REGISTER must authenticate before it can write bindings, and an
%% authenticated user cannot register a different AOR.
live_register_auth(_Config) ->
    EP = pick(),
    ok = chappe_sip:start(#{contact => <<"sip:127.0.0.1:",
                                   (integer_to_binary(EP))/binary>>}),
    Auth = #{realm => <<"sip">>,
             secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                          (_) -> error end},
    ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})),
    {ok, Sock} = gen_udp:open(0, [binary, {active, true}, {ip, {127,0,0,1}}]),
    LP = lport(Sock),
    %% 1) an unauthenticated REGISTER is challenged and writes nothing
    send(Sock, EP, register_req(LP, 3600, 1)),
    R401 = recv_status(Sock, 401),
    {ok, Chal} = chappe_sip_hdr:auth(www_auth_of(R401)),
    ?assertEqual([], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% 2) an authenticated REGISTER binds the AOR
    Creds = client_creds(Chal, <<"alice">>, <<"secret">>),
    send(Sock, EP, register_auth_req(LP, 3600, 2, <<"alice">>, Creds)),
    _ = recv_status(Sock, 200),
    ?assertMatch([_], chappe_sip:location(<<"sip:alice@127.0.0.1">>)),
    %% 3) alice's credentials cannot register bob's AOR
    send(Sock, EP, register_auth_req(LP, 3600, 3, <<"bob">>, Creds)),
    _ = recv_status(Sock, 403),
    ?assertEqual([], chappe_sip:location(<<"sip:bob@127.0.0.1">>)),
    gen_udp:close(Sock).

client_creds(Chal, User, Pass) ->
    {ok, Creds} = chappe_sip_digest:credentials(
                    #{method => <<"REGISTER">>, uri => <<"sip:127.0.0.1">>,
                      username => User, password => Pass, challenge => Chal,
                      nc => 1, cnonce => <<"abcd1234">>}),
    Creds.

www_auth_of(Bin) ->
    {ok, M} = chappe_sip_msg:parse(Bin),
    chappe_sip_msg:get(<<"www-authenticate">>, M).

register_auth_req(LP, Exp, CSeq, User, Auth) ->
    P = integer_to_binary(LP),
    CS = integer_to_binary(CSeq),
    E = integer_to_binary(Exp),
    <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKa", CS/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: <sip:", User/binary, "@127.0.0.1>;tag=ft\r\n"
      "To: <sip:", User/binary, "@127.0.0.1>\r\n"
      "Contact: <sip:", User/binary, "@127.0.0.1:", P/binary, ">\r\n"
      "Authorization: ", Auth/binary, "\r\n"
      "Expires: ", E/binary, "\r\n"
      "Call-ID: rega-", P/binary, "@ct\r\n"
      "CSeq: ", CS/binary, " REGISTER\r\nContent-Length: 0\r\n\r\n">>.

%% ---- helpers ----

reg(Aor, Contacts, ExpiresHdr, CallId, CSeq) ->
    {ok, Msg} = chappe_sip_msg:parse(reg_raw(Aor, Contacts, ExpiresHdr, CallId, CSeq)),
    chappe_sip_registry:register_contacts(chappe_sip_req:new(Msg, undefined, #{}), #{}).

aor() -> <<"<sip:alice@example.com>">>.
curi(N) -> <<"sip:alice@10.0.0.", (integer_to_binary(N))/binary>>.
contact(N, Exp) ->
    <<"<", (curi(N))/binary, ">;expires=", (integer_to_binary(Exp))/binary>>.
bare_contact(N) -> <<"<", (curi(N))/binary, ">">>.

reg_raw(Aor, Contacts, ExpiresHdr, CallId, CSeq) ->
    CS = integer_to_binary(CSeq),
    ContactLines = [[<<"Contact: ">>, C, <<"\r\n">>] || C <- Contacts],
    ExpLine = case ExpiresHdr of
                  undefined -> [];
                  _ -> [<<"Expires: ">>, integer_to_binary(ExpiresHdr), <<"\r\n">>]
              end,
    iolist_to_binary(
      [<<"REGISTER sip:example.com SIP/2.0\r\n">>,
       <<"Via: SIP/2.0/UDP 127.0.0.1:5060;branch=z9hG4bKreg\r\n">>,
       <<"Max-Forwards: 70\r\n">>,
       <<"From: ">>, Aor, <<";tag=ft\r\n">>,
       <<"To: ">>, Aor, <<"\r\n">>,
       <<"Call-ID: ">>, CallId, <<"@ct\r\n">>,
       <<"CSeq: ">>, CS, <<" REGISTER\r\n">>,
       ContactLines, ExpLine,
       <<"Content-Length: 0\r\n\r\n">>]).

register_req(LP, Exp, CSeq) ->
    P = integer_to_binary(LP),
    CS = integer_to_binary(CSeq),
    E = integer_to_binary(Exp),
    <<"REGISTER sip:127.0.0.1 SIP/2.0\r\n"
      "Via: SIP/2.0/UDP 127.0.0.1:", P/binary, ";rport;branch=z9hG4bKr", CS/binary,
      "\r\nMax-Forwards: 70\r\n"
      "From: Alice <sip:alice@127.0.0.1>;tag=ft\r\n"
      "To: Alice <sip:alice@127.0.0.1>\r\n"
      "Contact: <sip:alice@127.0.0.1:", P/binary, ">\r\n"
      "Expires: ", E/binary, "\r\n"
      "Call-ID: reg-", P/binary, "@ct\r\n"
      "CSeq: ", CS/binary, " REGISTER\r\nContent-Length: 0\r\n\r\n">>.

pick() -> chappe_sip_test_port:pick().
lport(Sock) -> {ok, P} = inet:port(Sock), P.
send(Sock, Dst, Bin) -> gen_udp:send(Sock, {127,0,0,1}, Dst, Bin).

recv_status(Sock, Code) ->
    CB = integer_to_binary(Code),
    receive
        {udp, Sock, _, _, <<"SIP/2.0 ", C:3/binary, _/binary>> = Bin} ->
            case C of CB -> Bin; _ -> recv_status(Sock, Code) end
    after 6000 -> ct:fail({no_status, Code})
    end.
