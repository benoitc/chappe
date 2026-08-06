%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Structured parsers for the headers that need more than raw bytes.
%%
%% Everything else in a SIP message stays an opaque binary (the lazy
%% model: sofia already validated the message). Scope matches
%% drachtio-sip: via, cseq, name-addr headers (to, from, contact, route,
%% record-route, refer-to), and digest auth headers.
-module(chappe_sip_hdr).

-export([
    via/1,
    cseq/1,
    name_addr/1,
    name_addr_list/1,
    auth/1,
    params/1
]).

%% Via: SIP/2.0/UDP host:port;branch=...;rport
%% -> #{proto := binary(), host := binary(), port => 1..65535,
%%      params := #{binary() => binary() | true}}
-spec via(binary()) -> {ok, map()} | {error, term()}.
via(Bin0) ->
    Bin = trim(Bin0),
    case Bin of
        <<"SIP/2.0/", Rest/binary>> ->
            case binary:split(Rest, <<" ">>) of
                [Proto, HostPart0] ->
                    {HostPart, Params, _} = split_semi_params(trim(HostPart0)),
                    case parse_hostport(HostPart) of
                        {error, _} = E ->
                            E;
                        {Host, Port} ->
                            V0 = #{
                                proto => Proto,
                                host => Host,
                                params => Params
                            },
                            {ok, maybe_put(port, Port, V0)}
                    end;
                _ ->
                    {error, bad_via}
            end;
        _ ->
            {error, bad_via}
    end.

%% CSeq: 314159 INVITE -> #{seq := integer(), method := binary()}
-spec cseq(binary()) -> {ok, map()} | {error, term()}.
cseq(Bin) ->
    case binary:split(trim(Bin), <<" ">>) of
        [SeqBin, Method] ->
            try binary_to_integer(trim(SeqBin)) of
                %% RFC 3261 8.1.1.5: 0 =< CSeq < 2^31
                Seq when Seq >= 0, Seq < (1 bsl 31) ->
                    {ok, #{seq => Seq, method => trim(Method)}};
                _ ->
                    {error, bad_cseq}
            catch
                _:_ -> {error, bad_cseq}
            end;
        _ ->
            {error, bad_cseq}
    end.

%% name-addr or addr-spec with header params:
%%   "Display" <sip:a@b>;tag=x  |  <sip:a@b>;x  |  sip:a@b;tag=x
%% -> #{display => binary(), uri := binary(), params := map()}
%% Note: for the bare addr-spec form, ";" params belong to the HEADER,
%% not the URI (RFC 3261 20.10 ambiguity resolved as drachtio does).
-spec name_addr(binary()) -> {ok, map()} | {error, term()}.
name_addr(Bin0) ->
    Bin = trim(Bin0),
    case Bin of
        <<"\"", Rest/binary>> ->
            %% quoted display name: close at the first UNescaped quote so a
            %% quoted-pair (\" \\) inside the name is not mistaken for the end
            case split_quoted(Rest) of
                {Display, After} ->
                    with_angle(trim(After), #{display => Display});
                error ->
                    {error, bad_name_addr}
            end;
        <<"<", _/binary>> ->
            with_angle(Bin, #{});
        _ ->
            case binary:match(Bin, <<"<">>) of
                {Pos, _} ->
                    %% unquoted display name up to <
                    Display = trim(binary:part(Bin, 0, Pos)),
                    Rest = binary:part(Bin, Pos, byte_size(Bin) - Pos),
                    with_angle(Rest, #{display => Display});
                nomatch ->
                    %% bare addr-spec; header params after first ;
                    {Uri, Params, _} = split_semi_params(Bin),
                    {ok, #{uri => Uri, params => Params}}
            end
    end.

with_angle(<<"<", Rest/binary>>, Acc) ->
    case binary:split(Rest, <<">">>) of
        [Uri, After] ->
            {_, Params, _} = split_semi_params(trim(After)),
            {ok, Acc#{uri => Uri, params => Params}};
        _ ->
            {error, bad_name_addr}
    end;
with_angle(_, _) ->
    {error, bad_name_addr}.

%% Comma-separated name-addr list (Contact, Route, Record-Route).
%% Commas inside quoted strings and inside <> are not separators.
-spec name_addr_list(binary()) -> {ok, [map()]} | {error, term()}.
name_addr_list(Bin) ->
    Parts = split_commas(Bin),
    Res = [name_addr(P) || P <- Parts, trim(P) =/= <<>>],
    case [E || {error, _} = E <- Res] of
        [] -> {ok, [M || {ok, M} <- Res]};
        [E | _] -> E
    end.

%% Digest challenge/credentials:
%%   Digest realm="r", nonce="n", qop="auth", algorithm=MD5
%% -> #{scheme := binary(), params := #{binary() => binary()}}
%% Quoted values are unquoted.
-spec auth(binary()) -> {ok, map()} | {error, term()}.
auth(Bin0) ->
    Bin = trim(Bin0),
    case binary:split(Bin, <<" ">>) of
        [Scheme, Rest] ->
            Pairs = split_commas(Rest),
            Params =
                lists:foldl(
                    fun(Pair, Acc) ->
                        case binary:split(trim(Pair), <<"=">>) of
                            [K, V] -> Acc#{lower(trim(K)) => unquote(trim(V))};
                            _ -> Acc
                        end
                    end,
                    #{},
                    Pairs
                ),
            {ok, #{scheme => Scheme, params => Params}};
        _ ->
            {error, bad_auth}
    end.

%% generic ;k=v;flag params of a header value -> map
-spec params(binary()) -> #{binary() => binary() | true}.
params(Bin) ->
    {_, Params, _} = split_semi_params(Bin),
    Params.

%% internal

split_semi_params(Bin) ->
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
                                [K, V] ->
                                    {Acc#{lower(trim(K)) => trim(V)}, [K | Ord]};
                                [K] ->
                                    {Acc#{lower(trim(K)) => true}, [K | Ord]}
                            end
                    end,
                    {#{}, []},
                    Parts
                ),
            {Main, Params, lists:reverse(Order)}
    end.

%% RFC 3261 quoted-string: close at the first quote not preceded by a
%% backslash; escaped bytes are kept verbatim (byte-faithful display name).
split_quoted(Bin) -> split_quoted(Bin, <<>>).

split_quoted(<<"\\", C, R/binary>>, Acc) ->
    split_quoted(R, <<Acc/binary, "\\", C>>);
split_quoted(<<"\"", R/binary>>, Acc) ->
    {Acc, R};
split_quoted(<<C, R/binary>>, Acc) ->
    split_quoted(R, <<Acc/binary, C>>);
split_quoted(<<>>, _Acc) ->
    error.

parse_hostport(<<"[", Rest/binary>>) ->
    case binary:split(Rest, <<"]">>) of
        [V6, <<>>] ->
            {<<"[", V6/binary, "]">>, undefined};
        [V6, <<":", P/binary>>] ->
            case port(P) of
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
            case port(trim(P)) of
                {ok, Port} -> {Host, Port};
                error -> {error, bad_port}
            end
    end.

%% a valid transport port (RFC 3261 uses 1..65535)
port(Bin) ->
    try binary_to_integer(Bin) of
        N when N >= 1, N =< 65535 -> {ok, N};
        _ -> error
    catch
        _:_ -> error
    end.

%% split on commas not inside quotes or <>
split_commas(Bin) ->
    split_commas(Bin, 0, 0, false, [], []).

split_commas(<<>>, _Start, _I, _Q, Cur, Acc) ->
    lists:reverse([iolist_to_binary(lists:reverse(Cur)) | Acc]);
split_commas(<<C, Rest/binary>>, Start, I, InQ, Cur, Acc) ->
    case C of
        $" ->
            split_commas(Rest, Start, I + 1, not InQ, [C | Cur], Acc);
        $< when not InQ -> split_angle(Rest, [C | Cur], Acc, Start, I);
        $, when not InQ ->
            split_commas(
                Rest,
                I + 1,
                I + 1,
                InQ,
                [],
                [iolist_to_binary(lists:reverse(Cur)) | Acc]
            );
        _ ->
            split_commas(Rest, Start, I + 1, InQ, [C | Cur], Acc)
    end.

split_angle(<<>>, Cur, Acc, _Start, _I) ->
    lists:reverse([iolist_to_binary(lists:reverse(Cur)) | Acc]);
split_angle(<<$>, Rest/binary>>, Cur, Acc, Start, I) ->
    split_commas(Rest, Start, I + 1, false, [$> | Cur], Acc);
split_angle(<<C, Rest/binary>>, Cur, Acc, Start, I) ->
    split_angle(Rest, [C | Cur], Acc, Start, I).

trim(B) -> string:trim(B, both, " \t").

lower(B) -> string:lowercase(B).

unquote(<<"\"", Rest/binary>>) ->
    case binary:split(Rest, <<"\"">>) of
        [V, _] -> V;
        _ -> Rest
    end;
unquote(B) ->
    B.

maybe_put(_K, undefined, M) -> M;
maybe_put(K, V, M) -> M#{K => V}.
