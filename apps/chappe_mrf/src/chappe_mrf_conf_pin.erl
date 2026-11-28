%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc The PIN a join asks for, on both backends: the endpoint the caller
%% is on plays pin_prompt and collects as many digits as the PIN has, at
%% most pin_tries times, each try waiting pin_timeout ms. It runs in the
%% process that drives the join: the caller of chappe_mrf_conf:join/3 on
%% fs (chappe_mrf_conf_fs_join), a helper the room watches on native
%% (chappe_mrf_conf_native), so a room never waits on a caller's digits.
%%
%% The join options:
%%   pin             the PIN: digits and *, as a binary or a string, or
%%                   an integer; no PIN, no prompt
%%   pin_prompt      the file asking for it (silence_stream://250)
%%   pin_tries       how many entries the caller has (3)
%%   pin_timeout     ms one entry may take (5000)
%%   pin_fail_prompt the file played to a caller whose tries ran out,
%%                   before the call ends (none); only where the room
%%                   made the endpoint, so ends the call
%%   join_fail_prompt native, a caller joined from its INVITE: the file
%%                   played when it does not get in for any other reason
%%                   (the room filled or locked meanwhile, the move into
%%                   the mixer failing, the deadline), before the call
%%                   ends; a busy tone by default
%%   pin_endpoint    native, a caller joined from its INVITE: the
%%                   connect_caller/3 options of the endpoint it enters
%%                   the PIN on (node, select, targets, user,
%%                   attach_timeout, anchor_params)
%%   endpoint        native, a call (chappe_sip_b2b:b2b()) joined with a
%%                   PIN: the endpoint the call is on, where the caller
%%                   enters it
-module(chappe_mrf_conf_pin).

-export([check_opts/1, check/2, refuse/3, turn_away/3, endpoint_opts/1]).

-define(PROMPT, <<"silence_stream://250">>).
-define(TRIES, 3).
-define(TIMEOUT, 5000).
%% a busy tone, 3 s: what a caller that did not get in hears by default
-define(JOIN_FAIL_PROMPT, <<"tone_stream://%(500,500,480,620);loops=3">>).
%% the connect_caller/3 options pin_endpoint may give
-define(ENDPOINT_KEYS, [
    node, select, targets, user, attach_timeout, anchor_params
]).

%% The PIN options of a join, checked in the caller before anything
%% starts: {error, {bad_option, Key}} for a value of the wrong kind.
-spec check_opts(map()) -> ok | {error, {bad_option, atom()}}.
check_opts(Opts) ->
    case [K || K := V <- Opts, not valid(K, V)] of
        [] -> ok;
        [K | _] -> {error, {bad_option, K}}
    end.

valid(pin, P) when is_integer(P), P >= 0 ->
    true;
valid(pin, P) ->
    %% digits and *: # ends an entry
    case text(P) of
        {ok, B} ->
            lists:all(
                fun(C) -> C =:= $* orelse (C >= $0 andalso C =< $9) end,
                binary_to_list(B)
            );
        error ->
            false
    end;
valid(K, N) when K =:= pin_tries; K =:= pin_timeout ->
    is_integer(N) andalso N > 0;
valid(K, F) when
    K =:= pin_prompt; K =:= pin_fail_prompt; K =:= join_fail_prompt
->
    text(F) =/= error;
valid(pin_endpoint, M) ->
    is_map(M);
valid(endpoint, Ep) ->
    is_pid(Ep);
valid(_Key, _Value) ->
    true.

%% a non-empty binary or string
text(T) when is_binary(T); is_list(T) ->
    try iolist_to_binary(T) of
        <<>> -> error;
        B -> {ok, B}
    catch
        error:badarg -> error
    end;
text(_T) ->
    error.

%% The caller on endpoint Ep enters the PIN of Opts: ok once it did,
%% {error, bad_pin} once its tries ran out, the endpoint's error when it
%% fails (hangup: the caller hung up). A join without pin asks none.
-spec check(chappe_mrf:endpoint(), map()) -> ok | {error, term()}.
check(Ep, #{pin := Pin} = Opts) ->
    Ask = #{
        file => maps:get(pin_prompt, Opts, ?PROMPT),
        timeout => maps:get(pin_timeout, Opts, ?TIMEOUT)
    },
    collect(
        Ep, chappe_mrf_lib:to_bin(Pin), Ask, maps:get(pin_tries, Opts, ?TRIES)
    );
check(_Ep, _Opts) ->
    ok.

collect(_Ep, _Pin, _Ask, 0) ->
    {error, bad_pin};
collect(Ep, Pin, Ask, Tries) ->
    Len = byte_size(Pin),
    case chappe_mrf:play_collect(Ep, Ask#{min => Len, max => Len}) of
        {ok, Pin} -> ok;
        {ok, _} -> collect(Ep, Pin, Ask, Tries - 1);
        {error, _} = Err -> Err
    end.

%% An endpoint made for a join that did not get in goes, and the call
%% on it: after a wrong PIN, its caller first hears pin_fail_prompt when
%% the join gave one.
-spec refuse(chappe_mrf:endpoint(), {error, term()}, map()) -> ok.
refuse(Ep, {error, bad_pin}, #{pin_fail_prompt := File}) ->
    _ = chappe_mrf:play(Ep, File),
    chappe_mrf:destroy(Ep);
refuse(Ep, _Error, _Opts) ->
    chappe_mrf:destroy(Ep).

%% A caller that dialed a native room and did not get in hears why on
%% its endpoint, then the call ends: pin_fail_prompt after a wrong PIN
%% (refuse/3), join_fail_prompt after any other failure. What the
%% endpoint still runs (the PIN's prompt, when the deadline came while
%% the caller typed) is stopped first.
-spec turn_away(chappe_mrf:endpoint(), {error, term()}, map()) -> ok.
turn_away(Ep, {error, bad_pin} = Error, Opts) ->
    refuse(Ep, Error, Opts);
turn_away(Ep, _Error, Opts) ->
    ok = break(Ep),
    _ = chappe_mrf:play(
        Ep, maps:get(join_fail_prompt, Opts, ?JOIN_FAIL_PROMPT)
    ),
    chappe_mrf:destroy(Ep).

%% uuid_break all: the media of what the channel runs stops, and what is
%% queued behind it goes
break(Ep) ->
    case chappe_mrf:uuid(Ep) of
        {ok, Uuid} ->
            _ = chappe_mrf:api(Ep, [<<"uuid_break ">>, Uuid, <<" all">>]),
            ok;
        {error, _} ->
            ok
    end.

%% The connect_caller/3 options pin_endpoint gives (the others are the
%% room's: owner, notify, transfer).
-spec endpoint_opts(map()) -> map().
endpoint_opts(Opts) ->
    maps:with(?ENDPOINT_KEYS, maps:get(pin_endpoint, Opts, #{})).
