%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc IP networks in CIDR notation, for the `allow' list of the outbound
%% listener. chappe_esl takes no umbrella dependency, so it keeps its own.
-module(chappe_esl_cidr).

-export([parse/1, parse_list/1, member/2]).
-export_type([net/0]).

-type net() :: {inet:ip_address(), 0..128}.

%% <<"10.1.0.0/16">>, "2001:db8::/32" or a bare address (the network of
%% that one address) as {Address, Bits}.
-spec parse(term()) -> {ok, net()} | error.
parse(Str) when is_list(Str) ->
    case io_lib:latin1_char_list(Str) of
        true -> parse(list_to_binary(Str));
        false -> error
    end;
parse(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<"/">>) of
        [Addr, Bits] -> with_bits(address(Addr), string:to_integer(Bits));
        [Addr] -> with_bits(address(Addr), full)
    end;
parse(_) ->
    error.

%% A whole list, or error when any entry is not a network.
-spec parse_list(term()) -> {ok, [net()]} | error.
parse_list(List) when is_list(List) ->
    Nets = [parse(N) || N <- List],
    case lists:all(fun(R) -> R =/= error end, Nets) of
        true -> {ok, [Net || {ok, Net} <- Nets]};
        false -> error
    end;
parse_list(_) ->
    error.

%% Whether Ip is in one of the networks. An IPv4-mapped IPv6 address
%% (a v4 peer on an IPv6 socket) is matched as the IPv4 address.
-spec member(inet:ip_address(), [net()]) -> boolean().
member({0, 0, 0, 0, 0, 16#ffff, AB, CD}, Nets) ->
    member({AB bsr 8, AB band 255, CD bsr 8, CD band 255}, Nets);
member(Ip, Nets) ->
    lists:any(fun(Net) -> in_net(Ip, Net) end, Nets).

%% internal

with_bits({ok, Ip}, full) ->
    {ok, {Ip, width(Ip)}};
with_bits({ok, Ip}, {N, <<>>}) when is_integer(N), N >= 0 ->
    case N =< width(Ip) of
        true -> {ok, {Ip, N}};
        false -> error
    end;
with_bits(_, _) ->
    error.

width(Ip) when tuple_size(Ip) =:= 4 -> 32;
width(_Ip) -> 128.

address(Bin) ->
    case inet:parse_strict_address(binary_to_list(Bin)) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> error
    end.

in_net(Ip, {Net, Bits}) when tuple_size(Ip) =:= tuple_size(Net) ->
    <<P:Bits/bitstring, _/bitstring>> = ip_bits(Ip),
    <<Q:Bits/bitstring, _/bitstring>> = ip_bits(Net),
    P =:= Q;
in_net(_Ip, _Net) ->
    false.

ip_bits(Ip) when tuple_size(Ip) =:= 4 ->
    <<<<O:8>> || O <- tuple_to_list(Ip)>>;
ip_bits(Ip) ->
    <<<<H:16>> || H <- tuple_to_list(Ip)>>.
