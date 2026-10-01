%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Host resolution for the NG client: a name or an address literal to one
%% address (IPv4 first, then IPv6), through inet or a caller-supplied
%% resolver fun, and the same lookup in a monitored helper process so the
%% client never blocks on DNS.
-module(chappe_rtpengine_resolve).

-export([resolve/2, is_name/1, async/2]).

-export_type([host/0, resolver/0]).

-type host() :: inet:ip_address() | string() | binary().
-type resolver() :: fun((host()) -> {ok, inet:ip_address()} | {error, term()}).

-spec resolve(resolver() | undefined, host()) ->
    {ok, inet:ip_address()} | {error, term()}.
resolve(undefined, Host) ->
    inet_resolve(Host);
resolve(Resolver, Host) ->
    Resolver(Host).

%% An address literal never moves; only names are worth looking up again.
-spec is_name(host()) -> boolean().
is_name(IP) when is_tuple(IP) ->
    false;
is_name(Host) when is_binary(Host) ->
    is_name(binary_to_list(Host));
is_name(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, _} -> false;
        {error, _} -> true
    end.

%% Look Host up in a monitored helper. The result arrives as
%% {chappe_rtpengine_resolved, Ref, Result}; a crashed lookup as the
%% 'DOWN' of MRef. Returns {Ref, MRef}.
-spec async(resolver() | undefined, host()) -> {reference(), reference()}.
async(Resolver, Host) ->
    Self = self(),
    Ref = make_ref(),
    {_Pid, MRef} = spawn_monitor(fun() ->
        Self ! {chappe_rtpengine_resolved, Ref, resolve(Resolver, Host)}
    end),
    {Ref, MRef}.

inet_resolve(IP) when is_tuple(IP) ->
    {ok, IP};
inet_resolve(Host) when is_binary(Host) ->
    inet_resolve(binary_to_list(Host));
inet_resolve(Host) when is_list(Host) ->
    case inet:parse_address(Host) of
        {ok, IP} ->
            {ok, IP};
        {error, _} ->
            case inet:getaddr(Host, inet) of
                {ok, IP} -> {ok, IP};
                {error, _} -> inet:getaddr(Host, inet6)
            end
    end.
