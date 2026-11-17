%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc What a UAC (chappe_sip_uac_fsm) decides on a 401, a 407 or a 3xx,
%% as pure functions of the response and what it holds: the challenges to
%% answer (RFC 3261 22.2, RFC 7616), the credentials for each, the
%% Authorization headers of the next request, and the redirect targets not
%% tried yet (RFC 3261 8.1.3.4).
%%
%% Auth is #{user, pass}, a list of them (one naming a realm answers only
%% that realm's challenges), or a fun the app picks them with per
%% challenge. A challenge is kept as {HeaderName, Challenge}, HeaderName
%% the header that answers it (Authorization or Proxy-Authorization).
-module(chappe_sip_uac_auth).

-export([usable/3, merge/3, credentials_for/2, headers/5]).
-export([redirect_targets/2]).

-export_type([challenge/0]).

-type challenge() :: {binary(), map()}.

%% The challenges of a 401 or 407 we have credentials for, digest ones the
%% digest module takes, and the name of the header that answers them.
-spec usable(401 | 407, chappe_sip_msg:msg(), term()) -> {binary(), [map()]}.
usable(Status, Msg, Auth) ->
    {ChalHdr, AuthHdrName} = challenge_header(Status),
    Parsed = [
        C
     || V <- chappe_sip_msg:get_all(ChalHdr, Msg),
        {ok, C} <- [chappe_sip_hdr:auth(V)]
    ],
    Usable = [
        C
     || C <- chappe_sip_digest:select(Parsed),
        credentials_for(C, Auth) =/= none
    ],
    {AuthHdrName, Usable}.

challenge_header(401) -> {<<"www-authenticate">>, <<"Authorization">>};
challenge_header(407) -> {<<"proxy-authenticate">>, <<"Proxy-Authorization">>}.

%% The challenges of this round on top of those of earlier rounds: a 407
%% then a 401 ends with both credentials on the request. A new challenge
%% for a realm we already answered means our credentials were refused,
%% unless it says stale=true (only the nonce expired: retry with the new
%% one, RFC 7616 3.3).
-spec merge(binary(), [map()], [challenge()]) ->
    {ok, [challenge()]} | {error, no_auth | rejected}.
merge(_Name, [], _Old) ->
    {error, no_auth};
merge(Name, New, Old) ->
    lists:foldl(
        fun
            (_C, {error, _} = Err) ->
                Err;
            (C, {ok, Acc}) ->
                Key = {Name, realm(C)},
                case [X || {N, X} <- Acc, {N, realm(X)} =:= Key] of
                    [] ->
                        {ok, Acc ++ [{Name, C}]};
                    [_ | _] ->
                        case is_stale(C) of
                            true -> {ok, replace(Key, C, Acc)};
                            false -> {error, rejected}
                        end
                end
        end,
        {ok, Old},
        New
    ).

replace({Name, Realm}, C, Cs) ->
    [
        case N =:= Name andalso realm(X) =:= Realm of
            true -> {N, C};
            false -> {N, X}
        end
     || {N, X} <- Cs
    ].

is_stale(#{params := P}) ->
    string:lowercase(maps:get(<<"stale">>, P, <<"false">>)) =:= <<"true">>.

realm(#{params := P}) -> maps:get(<<"realm">>, P, <<>>).

nonce(#{params := P}) -> maps:get(<<"nonce">>, P, <<>>).

%% The {User, Pass} that answers Chal, or none.
-spec credentials_for(map(), term()) -> {binary(), binary()} | none.
credentials_for(_Chal, undefined) ->
    none;
credentials_for(Chal, F) when is_function(F, 1) ->
    %% the app picks the credentials for this challenge
    try F(Chal) of
        Auth when is_map(Auth); is_list(Auth) -> credentials(Chal, Auth);
        _ -> none
    catch
        Class:Why ->
            logger:warning("chappe_sip_uac: auth fun failed: ~p:~p", [
                Class, Why
            ]),
            none
    end;
credentials_for(Chal, Auth) ->
    credentials(Chal, Auth).

credentials(Chal, #{} = A) ->
    credentials(Chal, [A]);
credentials(Chal, List) when is_list(List) ->
    Realm = realm(Chal),
    Named = [A || #{realm := R} = A <- List, R =:= Realm],
    Any = [A || A <- List, not maps:is_key(realm, A)],
    case Named ++ Any of
        [#{user := U, pass := P} | _] -> {U, P};
        _ -> none
    end.

%% The Authorization / Proxy-Authorization headers of the next request
%% (Method to Uri): one per challenge, each nonce counting its requests
%% (RFC 7616 3.4), and the nonce counts after it.
-spec headers([challenge()], term(), binary(), binary(), map()) ->
    {[{binary(), binary()}], map()}.
headers(Cs, Auth, Method, Uri, NonceCount) ->
    lists:foldl(
        fun({Name, Chal}, {HAcc, NAcc}) ->
            Nonce = nonce(Chal),
            N = maps:get(Nonce, NAcc, 0) + 1,
            {User, Pass} = credentials_for(Chal, Auth),
            case
                chappe_sip_digest:credentials(#{
                    method => Method,
                    uri => Uri,
                    username => User,
                    password => Pass,
                    challenge => Chal,
                    nc => N
                })
            of
                {ok, V} -> {HAcc ++ [{Name, V}], NAcc#{Nonce => N}};
                {error, _} -> {HAcc, NAcc}
            end
        end,
        {[], NonceCount},
        Cs
    ).

%% the 3xx Contacts not tried yet (chappe_sip_route:redirect_targets/1)
-spec redirect_targets(chappe_sip_msg:msg(), [binary()]) -> [binary()].
redirect_targets(Msg, Tried) ->
    [
        U
     || {U, _} <- chappe_sip_route:redirect_targets(Msg),
        not lists:member(U, Tried)
    ].
