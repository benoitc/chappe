%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Small helpers shared by the chappe_mrf modules.
-module(chappe_mrf_lib).

-export([new_id/0, to_bin/1, destroy_dialog/1, destroy_later/1, done/1]).
-export([with_name/2, api_ok/1, playback_result/1]).

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

%% destroy_dialog/1 in a process of its own, for a caller that must not
%% wait: the BYE may wait for a transaction under way, then Timer F.
-spec destroy_later(chappe_sip_dialog:dialog()) -> ok.
destroy_later(D) ->
    _ = spawn(fun() -> destroy_dialog(D) end),
    ok.

%% The mixer join options JoinOpts with the name a join asked for (Opts'
%% name), as the mixer's SDES name of the leg.
-spec with_name(map(), map()) -> map().
with_name(#{name := N}, JoinOpts) -> JoinOpts#{name => to_bin(N)};
with_name(_Opts, JoinOpts) -> JoinOpts.

%% {ok, _} -> ok, anything else as is.
-spec done(term()) -> term().
done({ok, _}) -> ok;
done(Other) -> Other.

%% A playback's completion event as play_info/3 returns it.
-spec playback_result(chappe_esl_event:event()) ->
    {ok, #{ms := non_neg_integer() | undefined, response := binary()}}
    | {error, not_found | playback_error}.
playback_result(Ev) ->
    case chappe_esl_event:header(<<"Application-Response">>, Ev) of
        <<"FILE NOT FOUND">> ->
            {error, not_found};
        <<"PLAYBACK ERROR">> ->
            {error, playback_error};
        Response ->
            {ok, #{
                ms => int(
                    chappe_esl_event:header(<<"variable_playback_ms">>, Ev)
                ),
                response => to_bin(Response)
            }}
    end.

int(undefined) ->
    undefined;
int(Bin) ->
    try
        binary_to_integer(Bin)
    catch
        error:badarg -> undefined
    end.

%% An api reply: its -ERR text is an error.
-spec api_ok(term()) -> ok | {error, term()}.
api_ok({ok, <<"-ERR", _/binary>> = Err}) -> {error, Err};
api_ok({ok, _}) -> ok;
api_ok(Other) -> Other.
