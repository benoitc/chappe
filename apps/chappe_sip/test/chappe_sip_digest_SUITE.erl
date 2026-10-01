%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% Digest authentication as a server, on the wire (RFC 2617, RFC 7616,
%% RFC 8760): the registrar's checks of the Authorization a raw UDP peer
%% sends, and an app handler that challenges with SHA-256 and MD5.
-module(chappe_sip_digest_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-import(chappe_sip_core_peer, [open/0, port/1, send/3, recv/3, request/3,
                               hdr/2, hdrs/2, status/1]).

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([nonce_count_replay/1, uri_mismatch/1, qop_required/1,
         aor_domain_checked/1, sha256_and_md5_challenges/1]).

-define(REALM, <<"chappe.test">>).

all() ->
    [nonce_count_replay, uri_mismatch, qop_required, aor_domain_checked,
     sha256_and_md5_challenges].

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
    EP = chappe_sip_test_port:pick(),
    ok = chappe_sip:start(#{contact => chappe_sip_core_peer:contact(EP)}),
    [{ep, EP}, {sock, open()} | Config].

end_per_testcase(_Case, Config) ->
    chappe_sip_core_peer:close(?config(sock, Config)),
    _ = chappe_sip:stop(),
    _ = chappe_sip_engine:reset_routes(),
    ok.

%% The same Authorization twice: the second is a replay of nonce count 1
%% and gets 401 with stale=true; nonce count 2 on the same nonce passes.
%% req: R7616-08 R2617-01
nonce_count_replay(Config) ->
    {EP, Sock} = registrar(Config, #{}),
    Chal = challenge(Sock, EP, <<"alice">>),
    A1 = creds(Chal, #{nc => 1}),
    ?assertEqual(200, register(Sock, EP, <<"alice">>, A1, 2)),
    R = register_resp(Sock, EP, <<"alice">>, A1, 3, 401),
    ?assertMatch({_, _}, binary:match(hdr(<<"www-authenticate">>, R),
                                      <<"stale=true">>)),
    ?assertEqual(200, register(Sock, EP, <<"alice">>, creds(Chal, #{nc => 2}), 4)).

%% A digest uri naming another resource than the Request-URI: 400.
%% req: R7616-04 R2617-02 R8760-05
uri_mismatch(Config) ->
    {EP, Sock} = registrar(Config, #{}),
    Chal = challenge(Sock, EP, <<"alice">>),
    A = creds(Chal, #{uri => <<"sip:elsewhere.example">>}),
    ?assertEqual(400, register(Sock, EP, <<"alice">>, A, 2)).

%% Our challenge offers qop=auth: an RFC 2069 answer (no qop) or one with
%% a qop we did not offer is refused, not checked the old way.
%% req: R8760-06 R7616-09
qop_required(Config) ->
    {EP, Sock} = registrar(Config, #{}),
    Chal = challenge(Sock, EP, <<"alice">>),
    #{params := P} = Chal,
    Legacy = creds(Chal#{params := maps:remove(<<"qop">>, P)}, #{}),
    ?assertEqual(401, register(Sock, EP, <<"alice">>, Legacy, 2)),
    AuthInt = <<Legacy/binary, ", qop=auth-int, nc=00000001, cnonce=\"x\"">>,
    ?assertEqual(401, register(Sock, EP, <<"alice">>, AuthInt, 3)),
    ?assertEqual([], chappe_sip:location(aor(<<"alice">>, <<"127.0.0.1">>))).

%% alice's credentials register alice in the configured domain only.
aor_domain_checked(Config) ->
    {EP, Sock} = registrar(Config, #{}),
    Chal = challenge(Sock, EP, <<"alice">>),
    Other = register_req(Sock, <<"alice">>, <<"other.example">>,
                         creds(Chal, #{}), 2),
    send(Sock, EP, Other),
    {R, _} = recv(Sock, final, 3000),
    ?assertEqual(403, status(R)),
    ?assertEqual(200, register(Sock, EP, <<"alice">>, creds(Chal, #{nc => 2}), 3)).

%% An app challenges with challenges/2: one WWW-Authenticate per
%% algorithm, SHA-256 first, one nonce. An answer to either passes.
%% req: R8760-02 R8760-08 R7616-05 R7616-06 R7616-07
sha256_and_md5_challenges(Config) ->
    {EP, Sock} = {?config(ep, Config), ?config(sock, Config)},
    ok = chappe_sip:options(fun(Req, Res) ->
        Args = #{method => <<"OPTIONS">>, realm => ?REALM,
                 secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                              (_) -> error end,
                 request_uri => chappe_sip_req:uri(Req),
                 authorization => chappe_sip_req:get(<<"authorization">>, Req)},
        case chappe_sip_digest:verify(Args) of
            {ok, _} ->
                chappe_sip_res:send(Res, 200);
            _ ->
                Hdrs = [{<<"WWW-Authenticate">>, V}
                        || V <- chappe_sip_digest:challenges(?REALM, #{})],
                chappe_sip_res:send(Res, 401, #{headers => Hdrs})
        end
    end),
    RUri = <<"sip:app@127.0.0.1">>,
    Opt = fun(Hdrs, CSeq) ->
        request(<<"OPTIONS">>, RUri, #{port => port(Sock), headers => Hdrs,
                                       call_id => <<"dig-opt@ct">>,
                                       from_tag => <<"ft">>, cseq => CSeq})
    end,
    send(Sock, EP, Opt([], 1)),
    {R401, _} = recv(Sock, {status, 401}, 3000),
    [Sha, Md5] = hdrs(<<"www-authenticate">>, R401),
    ?assertMatch({_, _}, binary:match(Sha, <<"algorithm=SHA-256">>)),
    ?assertMatch({_, _}, binary:match(Md5, <<"algorithm=MD5">>)),
    {ok, ShaC} = chappe_sip_hdr:auth(Sha),
    {ok, Md5C} = chappe_sip_hdr:auth(Md5),
    ?assertEqual(nonce(ShaC), nonce(Md5C)),
    Answer = fun(C, Nc) ->
        {ok, V} = chappe_sip_digest:credentials(
            #{method => <<"OPTIONS">>, uri => RUri, username => <<"alice">>,
              password => <<"secret">>, challenge => C, nc => Nc}),
        [{<<"Authorization">>, V}]
    end,
    send(Sock, EP, Opt(Answer(ShaC, 1), 2)),
    {R1, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R1)),
    send(Sock, EP, Opt(Answer(Md5C, 2), 3)),
    {R2, _} = recv(Sock, final, 3000),
    ?assertEqual(200, status(R2)).

%% ---- helpers ----

registrar(Config, Extra) ->
    Auth = maps:merge(#{realm => ?REALM, domain => <<"127.0.0.1">>,
                        secret => fun(<<"alice">>) -> {ok, <<"secret">>};
                                     (_) -> error end}, Extra),
    ok = chappe_sip:register(chappe_sip:registrar(#{auth => Auth})),
    {?config(ep, Config), ?config(sock, Config)}.

%% an unauthenticated REGISTER: the challenge of its 401
challenge(Sock, EP, User) ->
    send(Sock, EP, register_req(Sock, User, <<"127.0.0.1">>, none, 1)),
    {R, _} = recv(Sock, {status, 401}, 3000),
    {ok, Chal} = chappe_sip_hdr:auth(hdr(<<"www-authenticate">>, R)),
    Chal.

creds(Chal, Opts) ->
    {ok, V} = chappe_sip_digest:credentials(maps:merge(
        #{method => <<"REGISTER">>, uri => <<"sip:127.0.0.1">>,
          username => <<"alice">>, password => <<"secret">>,
          challenge => Chal, nc => 1}, Opts)),
    V.

register(Sock, EP, User, Auth, CSeq) ->
    send(Sock, EP, register_req(Sock, User, <<"127.0.0.1">>, Auth, CSeq)),
    {R, _} = recv(Sock, final, 3000),
    status(R).

register_resp(Sock, EP, User, Auth, CSeq, Want) ->
    send(Sock, EP, register_req(Sock, User, <<"127.0.0.1">>, Auth, CSeq)),
    {R, _} = recv(Sock, {status, Want}, 3000),
    R.

register_req(Sock, User, Domain, Auth, CSeq) ->
    P = integer_to_binary(port(Sock)),
    Aor = <<"<sip:", User/binary, "@", Domain/binary, ">">>,
    AuthHdr = [{<<"Authorization">>, Auth} || Auth =/= none],
    request(<<"REGISTER">>, <<"sip:127.0.0.1">>, #{
        port => port(Sock), from => Aor, to => Aor, from_tag => <<"rt">>,
        call_id => <<"dig-reg-", P/binary, "@ct">>, cseq => CSeq,
        contact => <<"<sip:", User/binary, "@127.0.0.1:", P/binary, ">">>,
        headers => [{<<"Expires">>, <<"60">>} | AuthHdr]}).

aor(User, Domain) -> <<"sip:", User/binary, "@", Domain/binary>>.

nonce(#{params := P}) -> maps:get(<<"nonce">>, P).
