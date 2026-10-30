%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc IP networks in CIDR notation, for the media topology
%% (chappe_sip_media:bypass/2) and the source filters of chappe_sip_guard.
-module(chappe_sip_net).

-export([cidr/1, in_net/2, address/1]).
-export_type([net/0]).

-type net() :: {inet:ip_address(), 0..128}.

%% <<"10.1.0.0/16">> or <<"2001:db8::/32">> as {Address, Bits}; a bare
%% address is the network of that one address.
-spec cidr(term()) -> {ok, net()} | error.
cidr(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<"/">>) of
        [Addr, Bits] ->
            case {address(Addr), string:to_integer(Bits)} of
                {{ok, Ip}, {N, <<>>}} when
                    is_integer(N) andalso N >= 0 andalso
                        (N =< 32 orelse (tuple_size(Ip) =:= 8 andalso N =< 128))
                ->
                    {ok, {Ip, N}};
                _ ->
                    error
            end;
        [Addr] ->
            case address(Addr) of
                {ok, Ip} -> {ok, {Ip, full(Ip)}};
                error -> error
            end
    end;
cidr(_) ->
    error.

full(Ip) when tuple_size(Ip) =:= 4 -> 32;
full(_Ip) -> 128.

%% Whether Ip is in the network; never across address families.
-spec in_net(inet:ip_address(), net()) -> boolean().
in_net(Ip, {Net, Bits}) when tuple_size(Ip) =:= tuple_size(Net) ->
    <<P:Bits/bitstring, _/bitstring>> = ip_bits(Ip),
    <<Q:Bits/bitstring, _/bitstring>> = ip_bits(Net),
    P =:= Q;
in_net(_Ip, _Net) ->
    false.

%% An IP literal (a source address, an SDP c= address).
-spec address(binary() | undefined) -> {ok, inet:ip_address()} | error.
address(undefined) ->
    error;
address(Bin) ->
    case inet:parse_strict_address(binary_to_list(Bin)) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> error
    end.

ip_bits(Ip) when tuple_size(Ip) =:= 4 ->
    <<<<O:8>> || O <- tuple_to_list(Ip)>>;
ip_bits(Ip) ->
    <<<<H:16>> || H <- tuple_to_list(Ip)>>.
