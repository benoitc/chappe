%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

-module(chappe_sip_digest_tests).
-include_lib("eunit/include/eunit.hrl").

%% RFC 2617 3.5 example vector (the algorithm is method-agnostic; the
%% reference uses GET).
rfc2617_vector_test() ->
    {ok, Challenge} = chappe_sip_hdr:auth(
        <<"Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", "
          "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", "
          "opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"">>),
    {ok, Creds} = chappe_sip_digest:credentials(
        #{method => <<"GET">>,
          uri => <<"/dir/index.html">>,
          username => <<"Mufasa">>,
          password => <<"Circle Of Life">>,
          challenge => Challenge,
          nc => 1,
          cnonce => <<"0a4f113b">>}),
    ?assertMatch({_, _},
                 binary:match(Creds,
                              <<"response=\"6629fae49393a05397450978507c4ef1\"">>)),
    ?assertMatch({_, _}, binary:match(Creds, <<"qop=auth">>)),
    ?assertMatch({_, _}, binary:match(Creds, <<"nc=00000001">>)),
    ?assertMatch({_, _},
                 binary:match(Creds,
                              <<"opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"">>)).

no_qop_test() ->
    %% RFC 2069 style: response = md5(HA1:nonce:HA2), no nc/cnonce/qop
    {ok, Challenge} = chappe_sip_hdr:auth(
        <<"Digest realm=\"r\", nonce=\"n1\"">>),
    {ok, Creds} = chappe_sip_digest:credentials(
        #{method => <<"REGISTER">>, uri => <<"sip:r">>,
          username => <<"u">>, password => <<"p">>,
          challenge => Challenge}),
    HA1 = binary:encode_hex(crypto:hash(md5, <<"u:r:p">>), lowercase),
    HA2 = binary:encode_hex(crypto:hash(md5, <<"REGISTER:sip:r">>), lowercase),
    Want = binary:encode_hex(
             crypto:hash(md5, <<HA1/binary, ":n1:", HA2/binary>>), lowercase),
    ?assertMatch({_, _},
                 binary:match(Creds,
                              <<"response=\"", Want/binary, "\"">>)),
    ?assertEqual(nomatch, binary:match(Creds, <<"qop=">>)),
    ?assertEqual(nomatch, binary:match(Creds, <<"nc=">>)).

%% ---- server side (challenge / verify) ----

%% challenge -> client credentials -> server verify round-trips
server_verify_roundtrip_test() ->
    Realm = <<"testrealm">>,
    Auth = client_auth(Realm, <<"alice">>, <<"secret">>),
    ?assertEqual({ok, <<"alice">>},
                 chappe_sip_digest:verify(#{method => <<"REGISTER">>,
                                      authorization => Auth, realm => Realm,
                                      secret => pw(<<"alice">>, <<"secret">>)})).

server_verify_wrong_password_test() ->
    Realm = <<"testrealm">>,
    Auth = client_auth(Realm, <<"alice">>, <<"secret">>),
    ?assertEqual({error, bad_response},
                 chappe_sip_digest:verify(#{method => <<"REGISTER">>,
                                      authorization => Auth, realm => Realm,
                                      secret => pw(<<"alice">>, <<"wrong">>)})).

server_verify_unknown_user_test() ->
    Realm = <<"testrealm">>,
    Auth = client_auth(Realm, <<"mallory">>, <<"x">>),
    ?assertEqual({error, unknown_user},
                 chappe_sip_digest:verify(#{method => <<"REGISTER">>,
                                      authorization => Auth, realm => Realm,
                                      secret => fun(_) -> error end})).

server_verify_no_credentials_test() ->
    ?assertEqual({error, no_credentials},
                 chappe_sip_digest:verify(#{method => <<"REGISTER">>,
                                      authorization => undefined,
                                      realm => <<"r">>,
                                      secret => fun(_) -> error end})).

server_verify_forged_nonce_test() ->
    Realm = <<"testrealm">>,
    Auth0 = client_auth(Realm, <<"alice">>, <<"secret">>),
    %% tamper the nonce: its HMAC no longer matches
    Auth = binary:replace(Auth0, <<"nonce=\"">>, <<"nonce=\"deadbeef.">>),
    ?assertEqual({error, bad_nonce},
                 chappe_sip_digest:verify(#{method => <<"REGISTER">>,
                                      authorization => Auth, realm => Realm,
                                      secret => pw(<<"alice">>, <<"secret">>)})).

client_auth(Realm, User, Pass) ->
    {ok, Chal} = chappe_sip_hdr:auth(chappe_sip_digest:challenge(Realm)),
    {ok, Creds} = chappe_sip_digest:credentials(
                    #{method => <<"REGISTER">>, uri => <<"sip:r">>,
                      username => User, password => Pass,
                      challenge => Chal, nc => 1, cnonce => <<"0a4f113b">>}),
    Creds.

pw(User, Pass) -> fun(U) when U =:= User -> {ok, Pass}; (_) -> error end.

%% a server offering only auth-int (which we do not implement) must fail
%% rather than silently downgrade to the weaker no-qop form
unsupported_qop_test() ->
    {ok, Challenge} = chappe_sip_hdr:auth(
        <<"Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\"">>),
    ?assertEqual({error, unsupported_qop},
                 chappe_sip_digest:credentials(
                   #{method => <<"INVITE">>, uri => <<"sip:x">>,
                     username => <<"u">>, password => <<"p">>,
                     challenge => Challenge})).

unsupported_algorithm_test() ->
    {ok, Challenge} = chappe_sip_hdr:auth(
        <<"Digest realm=\"r\", nonce=\"n\", algorithm=SHA-512-256">>),
    ?assertEqual({error, {unsupported_algorithm, <<"SHA-512-256">>}},
                 chappe_sip_digest:credentials(
                   #{method => <<"INVITE">>, uri => <<"sip:x">>,
                     username => <<"u">>, password => <<"p">>,
                     challenge => Challenge})).

%% ---- RFC 7616 / RFC 8760 algorithms ----

%% RFC 7616 3.9.1: the same request answered with SHA-256 and MD5
rfc7616_vectors_test() ->
    Base = <<"Digest realm=\"http-auth@example.org\", qop=\"auth\", "
             "nonce=\"7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v\", "
             "opaque=\"FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS\"">>,
    Creds = fun(Alg) ->
        {ok, C} = chappe_sip_hdr:auth(<<Base/binary, ", algorithm=", Alg/binary>>),
        {ok, V} = chappe_sip_digest:credentials(
            #{method => <<"GET">>, uri => <<"/dir/index.html">>,
              username => <<"Mufasa">>, password => <<"Circle of Life">>,
              challenge => C, nc => 1,
              cnonce => <<"f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ">>}),
        V
    end,
    Sha = Creds(<<"SHA-256">>),
    ?assertMatch({_, _}, binary:match(Sha,
        <<"response=\"753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1\"">>)),
    ?assertMatch({_, _}, binary:match(Sha, <<"algorithm=SHA-256">>)),
    Md5 = Creds(<<"MD5">>),
    ?assertMatch({_, _}, binary:match(Md5,
        <<"response=\"8ca523f5e9506fed4657c9700eebdbec\"">>)).

%% RFC 7616 3.4.2: the -sess variants hash nonce and cnonce into HA1
sess_algorithms_test() ->
    [begin
         {ok, C} = chappe_sip_hdr:auth(
             <<"Digest realm=\"r\", nonce=\"n\", qop=\"auth\", algorithm=",
               Alg/binary>>),
         {ok, V} = chappe_sip_digest:credentials(
             #{method => <<"INVITE">>, uri => <<"sip:x">>, username => <<"u">>,
               password => <<"p">>, challenge => C, nc => 1, cnonce => <<"c">>}),
         H = fun(D) -> binary:encode_hex(crypto:hash(Type, D), lowercase) end,
         HA1 = H(<<(H(<<"u:r:p">>))/binary, ":n:c">>),
         HA2 = H(<<"INVITE:sip:x">>),
         Want = H(<<HA1/binary, ":n:00000001:c:auth:", HA2/binary>>),
         ?assertMatch({_, _}, binary:match(V, <<"response=\"", Want/binary, "\"">>)),
         ?assertMatch({_, _}, binary:match(V, <<"algorithm=", Alg/binary>>))
     end || {Alg, Type} <- [{<<"MD5-sess">>, md5}, {<<"SHA-256-sess">>, sha256}]].

%% the count of requests sent with one nonce is the nc the client sends
nonce_count_test() ->
    {ok, C} = chappe_sip_hdr:auth(<<"Digest realm=\"r\", nonce=\"n\", qop=auth">>),
    {ok, V} = chappe_sip_digest:credentials(
        #{method => <<"INVITE">>, uri => <<"sip:x">>, username => <<"u">>,
          password => <<"p">>, challenge => C, nc => 3}),
    ?assertMatch({_, _}, binary:match(V, <<"nc=00000003">>)).

%% RFC 8760 2.4: one challenge per realm, SHA-256 before MD5 whatever the
%% order; an algorithm we lack is skipped
select_strongest_test() ->
    P = fun(V) -> {ok, C} = chappe_sip_hdr:auth(V), C end,
    Md5 = P(<<"Digest realm=\"a\", nonce=\"1\", algorithm=MD5">>),
    Sha = P(<<"Digest realm=\"a\", nonce=\"1\", algorithm=SHA-256">>),
    Odd = P(<<"Digest realm=\"b\", nonce=\"2\", algorithm=SHA-512-256">>),
    Other = P(<<"Digest realm=\"b\", nonce=\"3\"">>),
    ?assertEqual([Sha, Other], chappe_sip_digest:select([Md5, Odd, Sha, Other])),
    ?assertEqual([], chappe_sip_digest:select([Odd])).

%% ---- server checks (RFC 2617 3.2.2, RFC 7616 3.4) ----

verify_args(Auth) ->
    #{method => <<"REGISTER">>, authorization => Auth, realm => <<"testrealm">>,
      secret => pw(<<"alice">>, <<"secret">>)}.

%% the same response twice is a replay: the second gets stale (a fresh
%% nonce); a higher nonce count on the same nonce is accepted
server_nonce_count_replay_test() ->
    {ok, Chal} = chappe_sip_hdr:auth(chappe_sip_digest:challenge(<<"testrealm">>)),
    Auth = fun(Nc) ->
        {ok, V} = chappe_sip_digest:credentials(
            #{method => <<"REGISTER">>, uri => <<"sip:r">>, username => <<"alice">>,
              password => <<"secret">>, challenge => Chal, nc => Nc}),
        V
    end,
    A1 = Auth(1),
    ?assertEqual({ok, <<"alice">>}, chappe_sip_digest:verify(verify_args(A1))),
    ?assertEqual(stale, chappe_sip_digest:verify(verify_args(A1))),
    ?assertEqual({ok, <<"alice">>}, chappe_sip_digest:verify(verify_args(Auth(2)))),
    ?assertEqual(stale, chappe_sip_digest:verify(verify_args(Auth(2)))).

%% RFC 2617 3.2.2.5: the digest uri must name the Request-URI
server_uri_mismatch_test() ->
    Auth = client_auth(<<"testrealm">>, <<"alice">>, <<"secret">>),
    Args = verify_args(Auth),
    ?assertEqual({error, uri_mismatch},
                 chappe_sip_digest:verify(Args#{request_uri => <<"sip:other">>})),
    ?assertEqual({ok, <<"alice">>},
                 chappe_sip_digest:verify(Args#{request_uri => <<"sip:R">>})).

%% we offered qop=auth: a response without qop, or with auth-int, is
%% refused instead of checked with the RFC 2069 hash
server_qop_checks_test() ->
    {ok, Chal} = chappe_sip_hdr:auth(chappe_sip_digest:challenge(<<"testrealm">>)),
    Legacy = Chal#{params := maps:remove(<<"qop">>, maps:get(params, Chal))},
    {ok, NoQop} = chappe_sip_digest:credentials(
        #{method => <<"REGISTER">>, uri => <<"sip:r">>, username => <<"alice">>,
          password => <<"secret">>, challenge => Legacy}),
    ?assertEqual({error, qop_missing}, chappe_sip_digest:verify(verify_args(NoQop))),
    AuthInt = <<NoQop/binary, ", qop=auth-int">>,
    ?assertEqual({error, unsupported_qop},
                 chappe_sip_digest:verify(verify_args(AuthInt))),
    %% a server that challenged without qop still takes the RFC 2069 form
    ?assertEqual({ok, <<"alice">>},
                 chappe_sip_digest:verify((verify_args(NoQop))#{qop => false})).

%% RFC 8760 2.3: challenges/2 offers SHA-256 then MD5 with one nonce, and
%% the server takes an answer to either
server_sha256_test() ->
    [ShaV, Md5V] = chappe_sip_digest:challenges(<<"testrealm">>, #{}),
    ?assertMatch({_, _}, binary:match(ShaV, <<"algorithm=SHA-256">>)),
    ?assertMatch({_, _}, binary:match(Md5V, <<"algorithm=MD5">>)),
    [begin
         {ok, C} = chappe_sip_hdr:auth(V),
         {ok, A} = chappe_sip_digest:credentials(
             #{method => <<"REGISTER">>, uri => <<"sip:r">>, username => <<"alice">>,
               password => <<"secret">>, challenge => C, nc => Nc}),
         ?assertEqual({ok, <<"alice">>}, chappe_sip_digest:verify(verify_args(A)))
     end || {V, Nc} <- [{ShaV, 1}, {Md5V, 2}]],
    %% a server limited to MD5 refuses SHA-256
    {ok, C2} = chappe_sip_hdr:auth(
        hd(chappe_sip_digest:challenges(<<"testrealm">>, #{}))),
    {ok, A2} = chappe_sip_digest:credentials(
        #{method => <<"REGISTER">>, uri => <<"sip:r">>, username => <<"alice">>,
          password => <<"secret">>, challenge => C2}),
    ?assertEqual({error, {unsupported_algorithm, <<"SHA-256">>}},
                 chappe_sip_digest:verify((verify_args(A2))#{algorithms => [<<"MD5">>]})).

%% RFC 8760 2.6: a SHA-256 challenge without qop is answered with
%% qop=auth; an MD5 one without qop keeps the RFC 2069 form (no_qop_test)
sha256_default_qop_test() ->
    {ok, C} = chappe_sip_hdr:auth(
        <<"Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256">>),
    {ok, V} = chappe_sip_digest:credentials(
        #{method => <<"INVITE">>, uri => <<"sip:x">>, username => <<"u">>,
          password => <<"p">>, challenge => C}),
    ?assertMatch({_, _}, binary:match(V, <<"qop=auth">>)),
    ?assertMatch({_, _}, binary:match(V, <<"nc=00000001">>)).
