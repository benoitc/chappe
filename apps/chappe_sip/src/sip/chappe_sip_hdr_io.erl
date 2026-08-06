%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Header list serialization for outbound messages/responses.
-module(chappe_sip_hdr_io).

-export([join/1]).

%% [{Name, Value}] -> "Name: Value\r\n..." (<<>> for none)
-spec join([{iodata(), iodata()}]) -> binary().
join([]) ->
    <<>>;
join(Headers) ->
    iolist_to_binary([[N, ": ", V, "\r\n"] || {N, V} <- Headers]).
