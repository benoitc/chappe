%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Digest authentication (RFC 2617, RFC 7616, RFC 8760): MD5,
%% MD5-sess, SHA-256 and SHA-256-sess with qop=auth.
%%
%% drachtio does digest in the client, not the SIP engine, and so do we:
%% the UAC fsm parses each 401/407 challenge with chappe_sip_hdr:auth/1,
%% keeps the strongest one per realm (select/1) and calls credentials/1 to
%% build the Authorization or Proxy-Authorization value of every request
%% it sends with it.
%%
%% The server side (challenge/1,2, challenges/2, verify/1) issues stateless
%% HMAC nonces and remembers the highest nonce count seen per nonce in
%% chappe_sip_digest_nc, so a replayed response is refused.
-module(chappe_sip_digest).

-export([credentials/1, select/1, algorithm/1]).
-export([challenge/1, challenge/2, challenges/2, verify/1]).

-define(NONCE_SECRET_KEY, {chappe_sip_digest, nonce_secret}).
-define(NONCE_MAX_AGE_S, 300).
%% what a server accepts unless told otherwise
-define(SERVER_ALGORITHMS, [<<"SHA-256">>, <<"MD5">>]).

-type algorithm() :: binary().
-export_type([algorithm/0]).

%% Args map:
%%   #{method := binary(), uri := binary(),
%%     username := binary(), password := binary(),
%%     challenge := map(),                 % from chappe_sip_hdr:auth/1
%%     nc => pos_integer(), cnonce => binary()}
%% nc is the count of requests sent with this nonce, this one included: a
%% client reusing a nonce passes 2, 3... (RFC 7616 3.4).
-spec credentials(map()) -> {ok, binary()} | {error, term()}.
credentials(#{challenge := #{scheme := Scheme, params := P}} = Args) ->
    case is_digest(Scheme) of
        true ->
            case algorithm(P) of
                {ok, Alg} -> build(Args, P, Alg);
                {error, _} = Err -> Err
            end;
        false ->
            {error, not_digest}
    end;
credentials(_) ->
    {error, not_digest}.

%% The algorithm a challenge (or its params) names, in its canonical
%% spelling; MD5 when it names none (RFC 7616 3.3).
-spec algorithm(map()) -> {ok, algorithm()} | {error, term()}.
algorithm(#{params := P}) ->
    algorithm(P);
algorithm(P) when is_map(P) ->
    A = maps:get(<<"algorithm">>, P, <<"MD5">>),
    case string:uppercase(A) of
        <<"MD5">> -> {ok, <<"MD5">>};
        <<"MD5-SESS">> -> {ok, <<"MD5-sess">>};
        <<"SHA-256">> -> {ok, <<"SHA-256">>};
        <<"SHA-256-SESS">> -> {ok, <<"SHA-256-sess">>};
        _ -> {error, {unsupported_algorithm, A}}
    end.

%% RFC 8760 2.4 / RFC 7616 3.7: of the Digest challenges a response
%% carries, keep one per realm, the strongest algorithm we support (SHA-256
%% before MD5; on a tie the first, the server's preference). Challenges we
%% cannot answer are skipped.
-spec select([map()]) -> [map()].
select(Challenges) ->
    Usable = [
        {C, strength(A), realm(C)}
     || #{scheme := S} = C <- Challenges,
        is_digest(S),
        {ok, A} <- [algorithm(C)],
        qop(maps:get(<<"qop">>, maps:get(params, C), undefined)) =/=
            {error, unsupported_qop}
    ],
    Realms = lists:usort([R || {_, _, R} <- Usable]),
    [best([U || {_, _, R1} = U <- Usable, R1 =:= R]) || R <- Realms].

best([First | Rest]) ->
    {C, _, _} = lists:foldl(
        fun({_, S, _} = U, {_, Best, _} = Acc) ->
            case S > Best of
                true -> U;
                false -> Acc
            end
        end,
        First,
        Rest
    ),
    C.

strength(<<"SHA-256", _/binary>>) -> 2;
strength(_) -> 1.

realm(#{params := P}) -> maps:get(<<"realm">>, P, <<>>).

is_digest(Scheme) -> string:lowercase(Scheme) =:= <<"digest">>.

build(
    #{
        method := Method,
        uri := Uri,
        username := User,
        password := Pass
    } = Args,
    P,
    Alg
) ->
    case qop(maps:get(<<"qop">>, P, undefined)) of
        {error, _} = Err ->
            %% the server offered qop but not "auth" (e.g. only auth-int):
            %% refuse rather than downgrade to the weaker RFC 2069 form
            Err;
        undefined ->
            build_1(Method, Uri, User, Pass, Args, P, Alg, default_qop(Alg));
        Qop ->
            build_1(Method, Uri, User, Pass, Args, P, Alg, Qop)
    end.

%% RFC 8760 2.6 (8): a challenge without qop means auth, and the answer
%% carries it. Only a SHA-256 challenge gets that: an MD5 one without qop
%% comes from an RFC 2069 server, which takes the old form only.
default_qop(<<"SHA-256", _/binary>>) -> <<"auth">>;
default_qop(_) -> undefined.

build_1(Method, Uri, User, Pass, Args, P, Alg, Qop) ->
    Realm = maps:get(<<"realm">>, P, <<>>),
    Nonce = maps:get(<<"nonce">>, P, <<>>),
    Opaque = maps:get(<<"opaque">>, P, undefined),
    Nc = nc_bin(maps:get(nc, Args, 1)),
    Cnonce = maps:get(cnonce, Args, gen_cnonce()),
    H = hash_fun(Alg),
    HA1 = ha1(Alg, H([User, $:, Realm, $:, Pass]), Nonce, Cnonce),
    HA2 = H([Method, $:, Uri]),
    Response = response(H, HA1, HA2, Nonce, Qop, Nc, Cnonce),
    Fields0 =
        [
            ["username=\"", User, "\""],
            ["realm=\"", Realm, "\""],
            ["nonce=\"", Nonce, "\""],
            ["uri=\"", Uri, "\""],
            ["response=\"", Response, "\""],
            ["algorithm=", Alg]
        ],
    Fields1 =
        case {Qop, is_sess(Alg)} of
            {undefined, false} ->
                Fields0;
            {undefined, true} ->
                %% the session key needs the cnonce even without qop
                Fields0 ++ [["cnonce=\"", Cnonce, "\""]];
            _ ->
                Fields0 ++
                    [
                        ["qop=auth"],
                        ["nc=", Nc],
                        ["cnonce=\"", Cnonce, "\""]
                    ]
        end,
    Fields =
        case Opaque of
            undefined -> Fields1;
            _ -> Fields1 ++ [["opaque=\"", Opaque, "\""]]
        end,
    {ok,
        iolist_to_binary(
            ["Digest ", lists:join(", ", Fields)]
        )}.

%% RFC 7616 3.4.2: the -sess variants hash the nonces into HA1
ha1(Alg, HA1, Nonce, Cnonce) ->
    case is_sess(Alg) of
        true -> (hash_fun(Alg))([HA1, $:, Nonce, $:, Cnonce]);
        false -> HA1
    end.

is_sess(Alg) ->
    binary:longest_common_suffix([Alg, <<"-sess">>]) =:= 5.

response(H, HA1, HA2, Nonce, undefined, _Nc, _Cnonce) ->
    H([HA1, $:, Nonce, $:, HA2]);
response(H, HA1, HA2, Nonce, <<"auth">>, Nc, Cnonce) ->
    H([HA1, $:, Nonce, $:, Nc, $:, Cnonce, $:, <<"auth">>, $:, HA2]).

%% No qop is RFC 2069 (legacy). If the server offers qop it must include
%% "auth"; we do not implement auth-int, so an auth-int-only offer is an error
%% rather than a silent downgrade.
qop(undefined) ->
    undefined;
qop(QopList) ->
    Offered = binary:split(QopList, <<",">>, [global]),
    case lists:any(fun(Q) -> string:trim(Q) =:= <<"auth">> end, Offered) of
        true -> <<"auth">>;
        false -> {error, unsupported_qop}
    end.

nc_bin(N) ->
    iolist_to_binary(io_lib:format("~8.16.0b", [N])).

gen_cnonce() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

hash_fun(<<"SHA-256", _/binary>>) -> fun(IoData) -> hex(sha256, IoData) end;
hash_fun(_) -> fun(IoData) -> hex(md5, IoData) end.

hex(Type, IoData) ->
    binary:encode_hex(crypto:hash(Type, IoData), lowercase).

%% ---- server side (challenge / verify) ----

%% Build a WWW-Authenticate (or Proxy-Authenticate) value for Realm with a
%% fresh stateless nonce. challenge/2 sets stale=true so a client that used
%% an expired (or replayed) nonce re-authenticates without prompting the
%% user.
-spec challenge(binary()) -> binary().
challenge(Realm) ->
    challenge(Realm, false).

-spec challenge(binary(), boolean()) -> binary().
challenge(Realm, Stale) ->
    hd(challenges(Realm, #{stale => Stale, algorithms => [<<"MD5">>]})).

%% One challenge value per algorithm, in order of preference, all with the
%% same nonce. Opts: #{stale => boolean(), algorithms => [binary()]}
%% (default [<<"SHA-256">>, <<"MD5">>], RFC 8760 2.3: SHA-256 first, MD5
%% for older clients). Each value goes in its own WWW-Authenticate (or
%% Proxy-Authenticate) header.
-spec challenges(binary(), map()) -> [binary()].
challenges(Realm, Opts) ->
    Stale =
        case maps:get(stale, Opts, false) of
            true -> <<", stale=true">>;
            false -> <<>>
        end,
    Nonce = gen_nonce(),
    [
        <<"Digest realm=\"", Realm/binary, "\", nonce=\"", Nonce/binary,
            "\", qop=\"auth\", algorithm=", Alg/binary,
            Stale/binary>>
     || Alg <- maps:get(algorithms, Opts, ?SERVER_ALGORITHMS)
    ].

%% Verify an Authorization/Proxy-Authorization value against a password
%% lookup. Args:
%%   #{method := binary(), authorization := binary() | undefined,
%%     realm := binary(),
%%     secret := fun((User) -> {ok, Pass} | {ha1, HA1} | error),
%%     request_uri => binary(),        % the digest uri must name it
%%     algorithms => [binary()],       % accepted, default SHA-256 and MD5
%%     qop => boolean()}               % false: the challenge had no qop
%% A {ha1, HA1} secret is the hex H(user:realm:password) of the hash the
%% client answers with. Returns {ok, User} on success, stale when the nonce
%% expired or its count was already used (re-challenge with stale=true), or
%% {error, Reason}.
-spec verify(map()) ->
    {ok, binary()} | stale | {error, term()}.
verify(#{authorization := undefined}) ->
    {error, no_credentials};
verify(#{authorization := AuthHdr} = Args) ->
    case chappe_sip_hdr:auth(AuthHdr) of
        {ok, #{scheme := Scheme, params := P}} ->
            case is_digest(Scheme) of
                true -> verify_digest(Args, P);
                false -> {error, not_digest}
            end;
        _ ->
            {error, not_digest}
    end.

verify_digest(#{realm := Realm} = Args, P) ->
    Checks = [
        fun() -> check_realm(Realm, P) end,
        fun() -> check_algorithm(Args, P) end,
        fun() -> check_qop(Args, P) end,
        fun() -> check_uri(Args, P) end,
        fun() -> check_nonce(maps:get(<<"nonce">>, P, <<>>)) end
    ],
    case run_checks(Checks) of
        ok -> verify_response(Args, P);
        Other -> Other
    end.

run_checks([]) ->
    ok;
run_checks([F | Rest]) ->
    case F() of
        ok -> run_checks(Rest);
        Other -> Other
    end.

check_realm(Realm, P) ->
    case maps:get(<<"realm">>, P, <<>>) of
        Realm -> ok;
        _ -> {error, realm_mismatch}
    end.

check_algorithm(Args, P) ->
    Accepted = maps:get(algorithms, Args, ?SERVER_ALGORITHMS),
    case algorithm(P) of
        {ok, A} ->
            case lists:member(A, Accepted) of
                true -> ok;
                false -> {error, {unsupported_algorithm, A}}
            end;
        Err ->
            Err
    end.

%% RFC 7616 3.4: we offered qop=auth, so the response must use it; an
%% RFC 2069 answer (no qop) or another qop is refused, never computed the
%% old way
check_qop(Args, P) ->
    case {maps:get(qop, Args, true), maps:get(<<"qop">>, P, undefined)} of
        {true, <<"auth">>} -> ok;
        {true, undefined} -> {error, qop_missing};
        {false, undefined} -> ok;
        {_, _} -> {error, unsupported_qop}
    end.

%% RFC 2617 3.2.2.5: the digest-uri names the Request-URI
check_uri(#{request_uri := RUri}, P) ->
    case same_uri(maps:get(<<"uri">>, P, <<>>), RUri) of
        true -> ok;
        false -> {error, uri_mismatch}
    end;
check_uri(_Args, _P) ->
    ok.

same_uri(A, A) ->
    true;
same_uri(A, B) ->
    case {chappe_sip_uri:parse(A), chappe_sip_uri:parse(B)} of
        {{ok, UA}, {ok, UB}} -> uri_key(UA) =:= uri_key(UB);
        _ -> false
    end.

uri_key(U) ->
    {
        maps:get(scheme, U),
        maps:get(user, U, undefined),
        string:lowercase(maps:get(host, U, <<>>)),
        maps:get(port, U, undefined)
    }.

verify_response(#{method := Method, secret := PwFun} = Args, P) ->
    User = maps:get(<<"username">>, P, <<>>),
    {ok, Alg} = algorithm(P),
    H = hash_fun(Alg),
    case secret_ha1(PwFun(User), User, maps:get(realm, Args), H) of
        error ->
            {error, unknown_user};
        HA10 ->
            Nonce = maps:get(<<"nonce">>, P, <<>>),
            Cnonce = maps:get(<<"cnonce">>, P, <<>>),
            Nc = maps:get(<<"nc">>, P, <<>>),
            Qop = maps:get(<<"qop">>, P, undefined),
            HA1 = ha1(Alg, HA10, Nonce, Cnonce),
            HA2 = H([Method, $:, maps:get(<<"uri">>, P, <<>>)]),
            Expected = response(H, HA1, HA2, Nonce, Qop, Nc, Cnonce),
            case eq(maps:get(<<"response">>, P, <<>>), Expected) of
                true -> check_count(User, Nonce, Qop, Nc);
                false -> {error, bad_response}
            end
    end.

secret_ha1({ok, Pass}, User, Realm, H) ->
    H([User, $:, Realm, $:, Pass]);
secret_ha1({ha1, HA1}, _User, _Realm, H) ->
    %% the stored HA1 only answers the hash it was computed with
    case byte_size(HA1) =:= byte_size(H(<<>>)) of
        true -> string:lowercase(HA1);
        false -> error
    end;
secret_ha1(_, _User, _Realm, _H) ->
    error.

%% RFC 7616 3.4 / 5.4: each nonce count is accepted once and must grow; a
%% replayed or older one re-challenges with a fresh nonce
check_count(User, _Nonce, undefined, _Nc) ->
    {ok, User};
check_count(User, Nonce, _Qop, NcHex) ->
    try binary_to_integer(NcHex, 16) of
        N when N >= 1 ->
            case chappe_sip_digest_nc:use(Nonce, N, nonce_expiry(Nonce)) of
                ok -> {ok, User};
                replay -> stale
            end;
        _ ->
            {error, bad_nc}
    catch
        error:badarg -> {error, bad_nc}
    end.

%% constant-time compare that tolerates attacker-controlled lengths
%% (crypto:hash_equals/2 raises badarg when the sizes differ)
eq(A, B) when is_binary(A), is_binary(B) ->
    byte_size(A) =:= byte_size(B) andalso crypto:hash_equals(A, B);
eq(_, _) ->
    false.

%% Stateless nonce: <epoch>.<hmac(secret, epoch)>. No server store, so it
%% survives a restart only if secret is stable; a random per-node secret is
%% fine (an expired/foreign nonce just re-challenges). A random part keeps
%% two nonces of the same second apart, so their counts are tracked apart.
gen_nonce() ->
    T = integer_to_binary(erlang:system_time(second)),
    R = binary:encode_hex(crypto:strong_rand_bytes(6), lowercase),
    Stamp = <<T/binary, "-", R/binary>>,
    <<Stamp/binary, ".", (nonce_mac(Stamp))/binary>>.

check_nonce(Nonce) ->
    case binary:split(Nonce, <<".">>) of
        [Stamp, Mac] ->
            case eq(Mac, nonce_mac(Stamp)) of
                true -> nonce_age(Stamp);
                false -> {error, bad_nonce}
            end;
        _ ->
            {error, bad_nonce}
    end.

nonce_age(Stamp) ->
    case nonce_time(Stamp) of
        {ok, Ts} ->
            Age = erlang:system_time(second) - Ts,
            case Age >= 0 andalso Age =< ?NONCE_MAX_AGE_S of
                true -> ok;
                false -> stale
            end;
        error ->
            {error, bad_nonce}
    end.

nonce_time(Stamp) ->
    [T | _] = binary:split(Stamp, <<"-">>),
    try
        {ok, binary_to_integer(T)}
    catch
        _:_ -> error
    end.

%% when the count record of a (verified) nonce may go: once it is stale
nonce_expiry(Nonce) ->
    [Stamp | _] = binary:split(Nonce, <<".">>),
    case nonce_time(Stamp) of
        {ok, Ts} -> Ts + ?NONCE_MAX_AGE_S + 1;
        error -> erlang:system_time(second) + ?NONCE_MAX_AGE_S
    end.

nonce_mac(T) ->
    binary:encode_hex(
        crypto:macN(hmac, sha256, nonce_secret(), T, 12),
        lowercase
    ).

nonce_secret() ->
    case persistent_term:get(?NONCE_SECRET_KEY, undefined) of
        undefined ->
            S = crypto:strong_rand_bytes(32),
            persistent_term:put(?NONCE_SECRET_KEY, S),
            persistent_term:get(?NONCE_SECRET_KEY);
        S ->
            S
    end.
