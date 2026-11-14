%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc SIP URI parsing and formatting.
%%
%% Scope follows drachtio-sip: sip, sips and tel schemes, user:password,
%% host (name, IPv4, bracketed IPv6), port, params, raw headers part.
%% A parsed URI is a map:
%%   #{scheme := sip | sips | tel,
%%     user => binary(), password => binary(),
%%     host := binary(), port => 1..65535,
%%     params := #{binary() => binary() | true},
%%     headers => binary()}
%% format/1 reassembles; parse/1 then format/1 of an untouched URI is
%% byte-faithful except for parameter order, which is preserved via a
%% param list kept alongside the map.
-module(chappe_sip_uri).

-export([parse/1, format/1, same_authority/2, equal/2, equal_strict/2, aor/1]).
-export([take_param/2, is_sips/1, is_sips_unreliable/1, is_secure/1]).

-type uri() :: map().

-define(IS_HEX(C),
    ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse
        (C >= $A andalso C =< $F))
).
-export_type([uri/0]).

%% The scheme is case-insensitive (RFC 3261 19.1.4: SIP:ALICE@... is a sip
%% URI).
-spec parse(binary()) -> {ok, uri()} | {error, term()}.
parse(<<"<", Rest/binary>>) ->
    %% tolerate enclosed form
    case binary:split(Rest, <<">">>) of
        [In, _] -> parse(In);
        _ -> {error, bad_uri}
    end;
parse(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<":">>) of
        [Scheme, Rest] ->
            case chappe_sip_lib:lower(Scheme) of
                <<"sip">> -> parse_sip(sip, Rest);
                <<"sips">> -> parse_sip(sips, Rest);
                <<"tel">> -> parse_tel(Rest);
                _ -> {error, bad_scheme}
            end;
        [_] ->
            {error, bad_scheme}
    end;
parse(_) ->
    {error, bad_scheme}.

parse_tel(Rest) ->
    {Main, Params, ParamOrder} = split_params(Rest),
    {ok, #{
        scheme => tel,
        host => <<>>,
        user => Main,
        params => Params,
        '_porder' => ParamOrder
    }}.

%% The userinfo ends at the "@", before the uri-parameters are split off: a
%% user may carry ";" (RFC 3261 19.1.1, the RFC 4475 3.1.1.10 semiuri
%% vector sip:user;par=u%40example.net@example.com), while neither params
%% nor hostport may carry an unescaped "@".
parse_sip(Scheme, Rest) ->
    {Main0, Headers} =
        case binary:split(Rest, <<"?">>) of
            [M, H] -> {M, H};
            [M] -> {M, undefined}
        end,
    {UserPass, HostPart} =
        case binary:split(Main0, <<"@">>) of
            [U, H2] -> {U, H2};
            [H2] -> {undefined, H2}
        end,
    {HostPort, Params, ParamOrder} = split_params(HostPart),
    case parse_hostport(HostPort) of
        {error, _} = E ->
            E;
        {Host, Port} ->
            U0 = #{
                scheme => Scheme,
                host => Host,
                params => Params,
                '_porder' => ParamOrder
            },
            U1 = maybe_put(port, Port, U0),
            U2 =
                case UserPass of
                    undefined ->
                        U1;
                    _ ->
                        case binary:split(UserPass, <<":">>) of
                            [User, Pass] -> U1#{user => User, password => Pass};
                            [User] -> U1#{user => User}
                        end
                end,
            {ok, maybe_put(headers, Headers, U2)}
    end.

parse_hostport(<<"[", Rest/binary>>) ->
    %% bracketed IPv6
    case binary:split(Rest, <<"]">>) of
        [V6, <<>>] ->
            {<<"[", V6/binary, "]">>, undefined};
        [V6, <<":", P/binary>>] ->
            case to_port(P) of
                {ok, Port} -> {<<"[", V6/binary, "]">>, Port};
                error -> {error, bad_port}
            end;
        _ ->
            {error, bad_host}
    end;
parse_hostport(HostPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host] ->
            {Host, undefined};
        [Host, P] ->
            case to_port(P) of
                {ok, Port} -> {Host, Port};
                error -> {error, bad_port}
            end
    end.

to_port(P) ->
    try
        N = binary_to_integer(P),
        true = N >= 1 andalso N =< 65535,
        {ok, N}
    catch
        _:_ -> error
    end.

%% split ";p=v;flag" params off a URI body, keeping order
split_params(Bin) ->
    case binary:split(Bin, <<";">>) of
        [Main] ->
            {Main, #{}, []};
        [Main, ParamsBin] ->
            Parts = binary:split(ParamsBin, <<";">>, [global]),
            {Params, Order} =
                lists:foldl(
                    fun
                        (<<>>, Acc) ->
                            Acc;
                        (Part, {Acc, Ord}) ->
                            %% a repeated name keeps its first place and
                            %% its last value, so format/1 writes it once
                            {K, V} =
                                case binary:split(Part, <<"=">>) of
                                    [K0, V0] -> {K0, V0};
                                    [K0] -> {K0, true}
                                end,
                            {Acc#{K => V}, add_once(K, Ord)}
                    end,
                    {#{}, []},
                    Parts
                ),
            {Main, Params, lists:reverse(Order)}
    end.

add_once(K, Ord) ->
    case lists:member(K, Ord) of
        true -> Ord;
        false -> [K | Ord]
    end.

maybe_put(_K, undefined, M) -> M;
maybe_put(K, V, M) -> M#{K => V}.

%% Take the parameter Name (case-insensitive) out of a sip or sips URI:
%% its value (true for a flag) and the URI without it. A URI without it,
%% or that does not parse, comes back untouched with undefined.
-spec take_param(binary(), binary()) -> {binary() | true | undefined, binary()}.
take_param(Uri, Name) ->
    case parse(Uri) of
        {ok, #{scheme := S, params := P} = U} when S =:= sip; S =:= sips ->
            case [K || K := _ <- P, chappe_sip_lib:lower(K) =:= Name] of
                [] ->
                    {undefined, Uri};
                Keys ->
                    V = maps:get(hd(Keys), P),
                    U1 = U#{
                        params := maps:without(Keys, P),
                        '_porder' => maps:get('_porder', U, []) -- Keys
                    },
                    {V, format(U1)}
            end;
        _ ->
            {undefined, Uri}
    end.

%% A URI with the sips scheme, checked on the raw bytes without a parse. The
%% scheme is case-insensitive (RFC 3261 19.1.4), so SIPS: and SiPs: count.
-spec is_sips(binary()) -> boolean().
is_sips(<<Scheme:4/binary, ":", _/binary>>) ->
    chappe_sip_lib:lower(Scheme) =:= <<"sips">>;
is_sips(_) ->
    false.

%% A URI reached over TLS: a SIPS URI (RFC 3261 19.1), or a sip one whose
%% transport parameter is tls or wss. A name-addr's URI counts too.
-spec is_secure(binary()) -> boolean().
is_secure(Uri0) ->
    Uri = chappe_sip_hdr:name_addr_uri(Uri0),
    is_sips(Uri) orelse
        case take_param(Uri, <<"transport">>) of
            {V, _} when is_binary(V) ->
                lists:member(chappe_sip_lib:lower(V), [<<"tls">>, <<"wss">>]);
            _ ->
                false
        end.

%% A SIPS URI whose transport parameter names an unreliable transport (RFC
%% 3261 19.1.1: it MUST name a reliable one).
-spec is_sips_unreliable(binary()) -> boolean().
is_sips_unreliable(Uri) ->
    case parse(Uri) of
        {ok, #{scheme := sips, params := P}} ->
            lists:any(
                fun({K, V}) ->
                    chappe_sip_lib:lower(K) =:= <<"transport">> andalso
                        is_binary(V) andalso
                        chappe_sip_lib:lower(V) =:= <<"udp">>
                end,
                maps:to_list(P)
            );
        _ ->
            false
    end.

%% Do two URIs name the same authority: scheme, host (case-insensitive)
%% and port? false when either does not parse, so a caller guarding
%% credentials errs on the side of not sending them.
-spec same_authority(binary(), binary()) -> boolean().
same_authority(A, B) ->
    case {parse(A), parse(B)} of
        {{ok, UA}, {ok, UB}} -> authority(UA) =:= authority(UB);
        _ -> false
    end.

authority(U) ->
    {
        maps:get(scheme, U),
        chappe_sip_lib:lower(maps:get(host, U, <<>>)),
        maps:get(port, U, undefined)
    }.

%% SIP/SIPS URI equality (RFC 3261 19.1.4): scheme, host, parameter names
%% and values, and header names compare case-insensitively, the userinfo
%% case-sensitively, escapes of unreserved characters equal the character,
%% the port and the user, ttl, method and maddr parameters must match when
%% either URI has them, other parameters only when both have them, and
%% headers must match as a set. Anything that does not parse as sip or sips
%% compares as raw bytes.
-spec equal(binary() | uri(), binary() | uri()) -> boolean().
equal(A, B) when is_binary(A) ->
    case parse(A) of
        {ok, UA} -> equal(UA, B);
        _ -> A =:= B
    end;
equal(A, B) when is_binary(B) ->
    case parse(B) of
        {ok, UB} -> equal(A, UB);
        _ -> false
    end;
equal(#{scheme := S} = A, #{scheme := S} = B) when S =:= sip; S =:= sips ->
    userinfo(A) =:= userinfo(B) andalso
        chappe_sip_lib:lower(maps:get(host, A)) =:=
            chappe_sip_lib:lower(maps:get(host, B)) andalso
        maps:get(port, A, undefined) =:= maps:get(port, B, undefined) andalso
        params_equal(norm_params(A), norm_params(B)) andalso
        norm_headers(A) =:= norm_headers(B);
equal(#{} = A, #{} = B) ->
    format(A) =:= format(B).

%% equal/2, and also the same parameter names and the same headers on both
%% sides: a parameter one URI carries and the other does not is a
%% difference here, where RFC 3261 19.1.4 ignores most of them. Use it where
%% a URI is checked against a signed copy of itself (the digest uri), since
%% any added parameter or header can change how the request is routed.
-spec equal_strict(binary() | uri(), binary() | uri()) -> boolean().
equal_strict(A, B) ->
    case {as_uri(A), as_uri(B)} of
        {{ok, #{scheme := S} = UA}, {ok, #{scheme := S} = UB}} when
            S =:= sip; S =:= sips
        ->
            equal(UA, UB) andalso
                maps:keys(norm_params(UA)) =:= maps:keys(norm_params(UB));
        _ ->
            equal(A, B)
    end.

as_uri(U) when is_binary(U) -> parse(U);
as_uri(#{} = U) -> {ok, U}.

userinfo(U) ->
    {
        unesc(maps:get(user, U, undefined)),
        unesc(maps:get(password, U, undefined))
    }.

norm_params(#{params := P}) ->
    maps:from_list([{chappe_sip_lib:lower(K), norm_value(V)} || K := V <- P]).

norm_value(true) -> true;
norm_value(V) -> chappe_sip_lib:lower(unesc(V)).

%% a user, ttl, method or maddr parameter in one URI only never matches;
%% transport is in the same set (19.1.4 names it with the default-value
%% components); any other parameter matters only when both carry it
params_equal(PA, PB) ->
    Strict = [
        <<"user">>, <<"ttl">>, <<"method">>, <<"maddr">>, <<"transport">>
    ],
    lists:all(
        fun(K) -> maps:get(K, PA, undefined) =:= maps:get(K, PB, undefined) end,
        Strict
    ) andalso
        lists:all(
            fun(K) ->
                case {maps:find(K, PA), maps:find(K, PB)} of
                    {{ok, V}, {ok, W}} -> V =:= W;
                    _ -> true
                end
            end,
            maps:keys(PA)
        ).

norm_headers(U) ->
    case maps:get(headers, U, undefined) of
        undefined ->
            [];
        H ->
            lists:sort([
                case binary:split(Part, <<"=">>) of
                    [N, V] -> {chappe_sip_lib:lower(unesc(N)), unesc(V)};
                    [N] -> {chappe_sip_lib:lower(unesc(N)), <<>>}
                end
             || Part <- binary:split(H, <<"&">>, [global]),
                Part =/= <<>>
            ])
    end.

%% %XX of a character outside the RFC 2396 reserved set is that character;
%% an escaped reserved character stays escaped (in uppercase hex)
unesc(undefined) ->
    undefined;
unesc(Bin) ->
    unesc(Bin, <<>>).

unesc(<<"%", H, L, Rest/binary>>, Acc) ->
    case {chappe_sip_lib:unhex(H), chappe_sip_lib:unhex(L)} of
        {Hi, Lo} when is_integer(Hi), is_integer(Lo) ->
            C = Hi * 16 + Lo,
            case lists:member(C, ";/?:@&=+$,") of
                true ->
                    unesc(
                        Rest,
                        <<Acc/binary, "%", (hexdigit(Hi)), (hexdigit(Lo))>>
                    );
                false ->
                    unesc(Rest, <<Acc/binary, C>>)
            end;
        _ ->
            unesc(<<L, Rest/binary>>, <<Acc/binary, "%", H>>)
    end;
unesc(<<C, Rest/binary>>, Acc) ->
    unesc(Rest, <<Acc/binary, C>>);
unesc(<<>>, Acc) ->
    Acc.

hexdigit(N) when N < 10 -> $0 + N;
hexdigit(N) -> $A + N - 10.

%% The canonical address-of-record of a To/From URI (RFC 3261 10.3 step
%% 5): parameters and headers removed, escapes of unreserved characters
%% undone, scheme and host lowercased; the port stays (19.1.4: sip:a@h and
%% sip:a@h:5060 differ). error when the URI is not sip, sips or tel.
-spec aor(binary()) -> {ok, binary()} | error.
aor(Uri) ->
    case parse(Uri) of
        {ok, #{scheme := tel, user := Num}} ->
            {ok, <<"tel:", (unesc(Num))/binary>>};
        {ok, #{scheme := Scheme, host := Host} = U} ->
            UserPart =
                case userinfo(U) of
                    {undefined, _} -> <<>>;
                    {User, undefined} -> <<User/binary, "@">>;
                    {User, Pass} -> <<User/binary, ":", Pass/binary, "@">>
                end,
            PortPart =
                case maps:get(port, U, undefined) of
                    undefined -> <<>>;
                    P -> <<":", (integer_to_binary(P))/binary>>
                end,
            {ok,
                iolist_to_binary([
                    atom_to_binary(Scheme),
                    ":",
                    UserPart,
                    chappe_sip_lib:lower(Host),
                    PortPart
                ])};
        _ ->
            error
    end.

%% Characters outside each component's set (RFC 3261 25.1) are
%% percent-escaped on the way out; an escape already there (%XX) is kept,
%% a lone % becomes %25. A URI that parsed is written back as it came.
-spec format(uri()) -> binary().
format(#{scheme := tel, user := Num} = U) ->
    iolist_to_binary([<<"tel:">>, escape(Num, user), format_params(U)]);
format(#{scheme := Scheme, host := Host} = U) ->
    SchemeBin = atom_to_binary(Scheme),
    UserPart =
        case U of
            #{user := User, password := Pass} ->
                [escape(User, user), $:, escape(Pass, password), $@];
            #{user := User} ->
                [escape(User, user), $@];
            _ ->
                []
        end,
    PortPart =
        case U of
            #{port := Port} -> [$:, integer_to_binary(Port)];
            _ -> []
        end,
    HeadersPart =
        case U of
            #{headers := H} -> [$?, format_headers(H)];
            _ -> []
        end,
    iolist_to_binary([
        SchemeBin,
        $:,
        UserPart,
        Host,
        PortPart,
        format_params(U),
        HeadersPart
    ]).

format_params(#{params := Params} = U) ->
    Order = lists:uniq(maps:get('_porder', U, lists:sort(maps:keys(Params)))),
    [
        case maps:get(K, Params, undefined) of
            undefined -> [];
            true -> [$;, escape(K, param)];
            V -> [$;, escape(K, param), $=, escape(V, param)]
        end
     || K <- Order
    ].

%% hname=hvalue pairs joined by &, each name and value escaped on its own
format_headers(H) ->
    lists:join($&, [
        case binary:split(Part, <<"=">>) of
            [N, V] -> [escape(N, header), $=, escape(V, header)];
            [N] -> escape(N, header)
        end
     || Part <- binary:split(H, <<"&">>, [global])
    ]).

escape(Bin, Set) ->
    escape(Bin, Set, <<>>).

escape(<<"%", H, L, Rest/binary>>, Set, Acc) when
    ?IS_HEX(H), ?IS_HEX(L)
->
    escape(Rest, Set, <<Acc/binary, "%", H, L>>);
escape(<<C, Rest/binary>>, Set, Acc) ->
    case allowed(C, Set) of
        true ->
            escape(Rest, Set, <<Acc/binary, C>>);
        false ->
            escape(
                Rest,
                Set,
                <<Acc/binary, "%", (hexdigit(C bsr 4)), (hexdigit(C band 15))>>
            )
    end;
escape(<<>>, _Set, Acc) ->
    Acc.

%% unreserved = alphanum / mark, plus the characters each rule adds:
%% user-unreserved ("?" escaped too, as it would start the headers),
%% the password's, param-unreserved and hnv-unreserved
allowed(C, _Set) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 ->
    true;
allowed(C, Set) ->
    lists:member(C, "-_.!~*'()") orelse lists:member(C, extra(Set)).

extra(user) -> "&=+$,;/";
extra(password) -> "&=+$,";
extra(param) -> "[]/:&+$";
extra(header) -> "[]/?:+$".
