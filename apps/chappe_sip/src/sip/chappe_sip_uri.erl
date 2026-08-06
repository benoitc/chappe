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

-export([parse/1, format/1]).

-type uri() :: map().
-export_type([uri/0]).

-spec parse(binary()) -> {ok, uri()} | {error, term()}.
parse(<<"sip:", Rest/binary>>) ->
    parse_sip(sip, Rest);
parse(<<"sips:", Rest/binary>>) ->
    parse_sip(sips, Rest);
parse(<<"tel:", Rest/binary>>) ->
    parse_tel(Rest);
parse(<<"<", Rest/binary>>) ->
    %% tolerate enclosed form
    case binary:split(Rest, <<">">>) of
        [In, _] -> parse(In);
        _ -> {error, bad_uri}
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

parse_sip(Scheme, Rest) ->
    {Main0, Headers} =
        case binary:split(Rest, <<"?">>) of
            [M, H] -> {M, H};
            [M] -> {M, undefined}
        end,
    {Main, Params, ParamOrder} = split_params(Main0),
    {UserPass, HostPort} =
        case binary:split(Main, <<"@">>) of
            [U, H2] -> {U, H2};
            [H2] -> {undefined, H2}
        end,
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
