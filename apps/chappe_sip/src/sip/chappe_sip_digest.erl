%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Client-side digest authentication (RFC 2617/7616, MD5, qop=auth).
%%
%% drachtio does digest in the client, not the SIP engine, and so do we:
%% the UAC fsm parses a 401/407 challenge with chappe_sip_hdr:auth/1 and calls
%% credentials/1 to build the Authorization or Proxy-Authorization value
%% for the retried request.
-module(chappe_sip_digest).

-export([credentials/1]).
-export([challenge/1, challenge/2, verify/1]).

-define(NONCE_SECRET_KEY, {chappe_sip_digest, nonce_secret}).
-define(NONCE_MAX_AGE_S, 300).

%% Args map:
%%   #{method := binary(), uri := binary(),
%%     username := binary(), password := binary(),
%%     challenge := map(),                 % from chappe_sip_hdr:auth/1
%%     nc => pos_integer(), cnonce => binary()}
-spec credentials(map()) -> {ok, binary()} | {error, term()}.
credentials(#{challenge := #{scheme := Scheme, params := P}} = Args) when
    Scheme =:= <<"Digest">>; Scheme =:= <<"digest">>
->
    case maps:get(<<"algorithm">>, P, <<"MD5">>) of
        A when A =:= <<"MD5">>; A =:= <<"md5">> ->
            build(Args, P);
        Other ->
            {error, {unsupported_algorithm, Other}}
    end;
credentials(_) ->
    {error, not_digest}.

build(
    #{
        method := Method,
        uri := Uri,
        username := User,
        password := Pass
    } = Args,
    P
) ->
    case qop(maps:get(<<"qop">>, P, undefined)) of
        {error, _} = Err ->
            %% the server offered qop but not "auth" (e.g. only auth-int):
            %% refuse rather than downgrade to the weaker RFC 2069 form
            Err;
        Qop ->
            build_1(Method, Uri, User, Pass, Args, P, Qop)
    end.

build_1(Method, Uri, User, Pass, Args, P, Qop) ->
    Realm = maps:get(<<"realm">>, P, <<>>),
    Nonce = maps:get(<<"nonce">>, P, <<>>),
    Opaque = maps:get(<<"opaque">>, P, undefined),
    Nc = nc_bin(maps:get(nc, Args, 1)),
    Cnonce = maps:get(cnonce, Args, gen_cnonce()),
    HA1 = md5hex([User, $:, Realm, $:, Pass]),
    HA2 = md5hex([Method, $:, Uri]),
    Response =
        case Qop of
            undefined ->
                md5hex([HA1, $:, Nonce, $:, HA2]);
            <<"auth">> ->
                md5hex([
                    HA1,
                    $:,
                    Nonce,
                    $:,
                    Nc,
                    $:,
                    Cnonce,
                    $:,
                    <<"auth">>,
                    $:,
                    HA2
                ])
        end,
    Fields0 =
        [
            ["username=\"", User, "\""],
            ["realm=\"", Realm, "\""],
            ["nonce=\"", Nonce, "\""],
            ["uri=\"", Uri, "\""],
            ["response=\"", Response, "\""],
            ["algorithm=MD5"]
        ],
    Fields1 =
        case Qop of
            undefined ->
                Fields0;
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

md5hex(IoData) ->
    binary:encode_hex(crypto:hash(md5, IoData), lowercase).

%% ---- server side (challenge / verify) ----

%% Build a WWW-Authenticate (or Proxy-Authenticate) value for Realm with a
%% fresh stateless nonce. challenge/2 sets stale=true so a client that used
%% an expired nonce re-authenticates without prompting the user.
-spec challenge(binary()) -> binary().
challenge(Realm) ->
    challenge(Realm, false).

-spec challenge(binary(), boolean()) -> binary().
challenge(Realm, Stale) ->
    Stale1 =
        case Stale of
            true -> <<", stale=true">>;
            false -> <<>>
        end,
    <<"Digest realm=\"", Realm/binary, "\", nonce=\"", (gen_nonce())/binary,
        "\", qop=\"auth\", algorithm=MD5", Stale1/binary>>.

%% Verify an Authorization/Proxy-Authorization value against a password
%% lookup. Args:
%%   #{method := binary(), authorization := binary() | undefined,
%%     realm := binary(),
%%     secret := fun((User) -> {ok, Pass} | {ha1, HA1} | error)}
%% Returns {ok, User} on success, stale when the nonce expired (re-challenge
%% with stale=true), or {error, Reason}.
-spec verify(map()) ->
    {ok, binary()} | stale | {error, term()}.
verify(#{authorization := undefined}) ->
    {error, no_credentials};
verify(#{
    method := Method,
    authorization := AuthHdr,
    realm := Realm,
    secret := PwFun
}) ->
    case chappe_sip_hdr:auth(AuthHdr) of
        {ok, #{scheme := Scheme, params := P}} when
            Scheme =:= <<"Digest">>; Scheme =:= <<"digest">>
        ->
            verify_digest(Method, Realm, PwFun, P);
        _ ->
            {error, not_digest}
    end.

verify_digest(Method, Realm, PwFun, P) ->
    User = maps:get(<<"username">>, P, <<>>),
    Nonce = maps:get(<<"nonce">>, P, <<>>),
    Uri = maps:get(<<"uri">>, P, <<>>),
    Given = maps:get(<<"response">>, P, <<>>),
    case maps:get(<<"realm">>, P, <<>>) of
        Realm ->
            case check_nonce(Nonce) of
                ok ->
                    verify_response(Method, Realm, User, Uri, Given, P, PwFun);
                stale ->
                    stale;
                Err ->
                    Err
            end;
        _ ->
            {error, realm_mismatch}
    end.

verify_response(Method, Realm, User, Uri, Given, P, PwFun) ->
    case PwFun(User) of
        error ->
            {error, unknown_user};
        Secret ->
            HA1 = ha1(User, Realm, Secret),
            HA2 = md5hex([Method, $:, Uri]),
            Expected = response(HA1, HA2, P),
            case eq(Given, Expected) of
                true -> {ok, User};
                false -> {error, bad_response}
            end
    end.

%% constant-time compare that tolerates attacker-controlled lengths
%% (crypto:hash_equals/2 raises badarg when the sizes differ)
eq(A, B) when is_binary(A), is_binary(B) ->
    byte_size(A) =:= byte_size(B) andalso crypto:hash_equals(A, B);
eq(_, _) ->
    false.

ha1(_User, _Realm, {ha1, HA1}) -> HA1;
ha1(User, Realm, {ok, Pass}) -> md5hex([User, $:, Realm, $:, Pass]).

%% qop=auth response when the client sent qop/nc/cnonce, else RFC 2069.
response(HA1, HA2, P) ->
    Nonce = maps:get(<<"nonce">>, P, <<>>),
    case maps:get(<<"qop">>, P, undefined) of
        <<"auth">> ->
            Nc = maps:get(<<"nc">>, P, <<>>),
            Cnonce = maps:get(<<"cnonce">>, P, <<>>),
            md5hex([HA1, $:, Nonce, $:, Nc, $:, Cnonce, $:, <<"auth">>, $:, HA2]);
        _ ->
            md5hex([HA1, $:, Nonce, $:, HA2])
    end.

%% Stateless nonce: <epoch>.<hmac(secret, epoch)>. No server store, so it
%% survives a restart only if secret is stable; a random per-node secret is
%% fine (an expired/foreign nonce just re-challenges).
gen_nonce() ->
    T = integer_to_binary(erlang:system_time(second)),
    <<T/binary, ".", (nonce_mac(T))/binary>>.

check_nonce(Nonce) ->
    case binary:split(Nonce, <<".">>) of
        [T, Mac] ->
            case eq(Mac, nonce_mac(T)) of
                true -> nonce_age(T);
                false -> {error, bad_nonce}
            end;
        _ ->
            {error, bad_nonce}
    end.

nonce_age(T) ->
    try binary_to_integer(T) of
        Ts ->
            Age = erlang:system_time(second) - Ts,
            case Age >= 0 andalso Age =< ?NONCE_MAX_AGE_S of
                true -> ok;
                false -> stale
            end
    catch
        _:_ ->
            {error, bad_nonce}
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
