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

-export([parse/1, format/1, same_authority/2, equal/2, aor/1]).

-type uri() :: map().
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
            case lower(Scheme) of
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
                            case binary:split(Part, <<"=">>) of
                                [K, V] -> {Acc#{K => V}, [K | Ord]};
                                [K] -> {Acc#{K => true}, [K | Ord]}
                            end
                    end,
                    {#{}, []},
                    Parts
                ),
            {Main, Params, lists:reverse(Order)}
    end.

maybe_put(_K, undefined, M) -> M;
maybe_put(K, V, M) -> M#{K => V}.

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
        lower(maps:get(host, U, <<>>)),
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
        lower(maps:get(host, A)) =:= lower(maps:get(host, B)) andalso
        maps:get(port, A, undefined) =:= maps:get(port, B, undefined) andalso
        params_equal(norm_params(A), norm_params(B)) andalso
        norm_headers(A) =:= norm_headers(B);
equal(#{} = A, #{} = B) ->
    format(A) =:= format(B).

userinfo(U) ->
    {
        unesc(maps:get(user, U, undefined)),
        unesc(maps:get(password, U, undefined))
    }.

norm_params(#{params := P}) ->
    maps:from_list([{lower(K), norm_value(V)} || K := V <- P]).

norm_value(true) -> true;
norm_value(V) -> lower(unesc(V)).

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
                    [N, V] -> {lower(unesc(N)), unesc(V)};
                    [N] -> {lower(unesc(N)), <<>>}
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
    case {hex(H), hex(L)} of
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

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(_) -> error.

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
                    atom_to_binary(Scheme), ":", UserPart, lower(Host), PortPart
                ])};
        _ ->
            error
    end.

lower(B) -> <<<<(lower_byte(C))>> || <<C>> <= B>>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

-spec format(uri()) -> binary().
format(#{scheme := tel, user := Num} = U) ->
    iolist_to_binary([<<"tel:">>, Num, format_params(U)]);
format(#{scheme := Scheme, host := Host} = U) ->
    SchemeBin = atom_to_binary(Scheme),
    UserPart =
        case U of
            #{user := User, password := Pass} -> [User, $:, Pass, $@];
            #{user := User} -> [User, $@];
            _ -> []
        end,
    PortPart =
        case U of
            #{port := Port} -> [$:, integer_to_binary(Port)];
            _ -> []
        end,
    HeadersPart =
        case U of
            #{headers := H} -> [$?, H];
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
    Order = maps:get('_porder', U, lists:sort(maps:keys(Params))),
    [
        case maps:get(K, Params, undefined) of
            undefined -> [];
            true -> [$;, K];
            V -> [$;, K, $=, V]
        end
     || K <- Order
    ].
