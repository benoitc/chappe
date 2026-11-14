%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% A recording store for the SIPREC server cases, with the writing calls
%% of chappe_audio_store (open/2, write/2, close/2): each one is told to
%% the process named in persistent_term chappe_sip_test_store.
-module(chappe_sip_test_store).

-export([open/2, write/2, close/2]).

open(Meta, #{owner := Owner}) ->
    Ref = make_ref(),
    tell({store_open, Ref, Meta, Owner}),
    {ok, {?MODULE, Ref}}.

write({?MODULE, Ref}, Pcm) ->
    tell({store_write, Ref, iolist_to_binary(Pcm)}),
    ok.

close({?MODULE, Ref}, Extra) ->
    tell({store_close, Ref, Extra}),
    {ok, <<"rec-", (integer_to_binary(erlang:phash2(Ref)))/binary>>}.

tell(Msg) ->
    persistent_term:get(?MODULE) ! Msg.
