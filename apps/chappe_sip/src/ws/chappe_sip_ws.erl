%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc WebSocket-transport handle helpers.
%%
%% WS-side transactions and legs get integer handles in a distinct high
%% range so chappe_sip_engine can route an operation to the WS transport
%% (chappe_sip_ws_transport) or the sofia NIF by the handle's magnitude alone.
-module(chappe_sip_ws).

-export([is_ws/1, base/0]).

-define(WS_BASE, 16#4000000000000000).

%% True for a handle owned by the WS transport.
-spec is_ws(term()) -> boolean().
is_ws(H) when is_integer(H) -> H >= ?WS_BASE;
is_ws(_) -> false.

-spec base() -> pos_integer().
base() -> ?WS_BASE.
