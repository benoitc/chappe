%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Header list serialization for outbound messages/responses.
-module(chappe_sip_hdr_io).

-export([join/1, content_type/2]).

%% [{Name, Value}] -> "Name: Value\r\n..." (<<>> for none)
-spec join([{iodata(), iodata()}]) -> binary().
join([]) ->
    <<>>;
join(Headers) ->
    iolist_to_binary([[N, ": ", V, "\r\n"] || {N, V} <- Headers]).

%% The Content-Type header of an outbound body: none without a type (an
%% empty body, or one the caller sends untyped), else the type given.
-spec content_type(binary() | undefined, iodata()) -> [{binary(), binary()}].
content_type(undefined, <<>>) -> [];
content_type(undefined, _Body) -> [];
content_type(CT, _Body) -> [{<<"Content-Type">>, CT}].
