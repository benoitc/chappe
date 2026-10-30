%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Small helpers shared by the chappe_mrf modules.
-module(chappe_mrf_lib).

-export([new_id/0, to_bin/1, destroy_dialog/1, done/1, api_ok/1]).

%% A random id, hex: correlation ids, member ids, loopback tokens.
-spec new_id() -> binary().
new_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(10), lowercase).

-spec to_bin(binary() | atom() | integer() | iodata()) -> binary().
to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(L) -> iolist_to_binary(L).

%% Tear a dialog down; one already gone is fine.
-spec destroy_dialog(chappe_sip_dialog:dialog()) -> ok.
destroy_dialog(D) ->
    try chappe_sip_dialog:destroy(D) of
        _ -> ok
    catch
        exit:_ -> ok
    end.

%% {ok, _} -> ok, anything else as is.
-spec done(term()) -> term().
done({ok, _}) -> ok;
done(Other) -> Other.

%% An api reply: its -ERR text is an error.
-spec api_ok(term()) -> ok | {error, term()}.
api_ok({ok, <<"-ERR", _/binary>> = Err}) -> {error, Err};
api_ok({ok, _}) -> ok;
api_ok(Other) -> Other.
