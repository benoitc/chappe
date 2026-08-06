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
        <<"Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256">>),
    ?assertEqual({error, {unsupported_algorithm, <<"SHA-256">>}},
                 chappe_sip_digest:credentials(
                   #{method => <<"INVITE">>, uri => <<"sip:x">>,
                     username => <<"u">>, password => <<"p">>,
                     challenge => Challenge})).
