%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Helpers shared by the app's processes: bounded sends and stream
%% tokens.
-module(chappe_audio_lib).

-export([send/3, limit/3, token/0, token_hash/1, token_ok/2]).
-export([id/0]).

%% Send Msg to Pid unless Pid already has Max messages waiting: a local
%% pid's queue is read directly; for a remote one the send is dropped
%% when the distribution buffer is full rather than blocking the sender
%% (nosuspend). Returns dropped when it did not send.
-spec send(pid(), term(), pos_integer()) -> ok | dropped.
send(Pid, Msg, Max) when node(Pid) =:= node() ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, N} when N >= Max ->
            dropped;
        {message_queue_len, _} ->
            Pid ! Msg,
            ok;
        undefined ->
            dropped
    end;
send(Pid, Msg, _Max) ->
    case erlang:send(Pid, Msg, [nosuspend, noconnect]) of
        ok -> ok;
        _ -> dropped
    end.

%% The message bound for a message of Size bytes: MaxMsgs, or fewer so
%% that about MaxBytes wait at most (one at least).
-spec limit(pos_integer(), pos_integer(), non_neg_integer()) -> pos_integer().
limit(MaxMsgs, MaxBytes, Size) ->
    max(1, min(MaxMsgs, MaxBytes div max(1, Size))).

%% A fresh stream token: 32 random bytes, base64url without padding, so
%% it fits a URL query unescaped.
-spec token() -> binary().
token() ->
    base64:encode(crypto:strong_rand_bytes(32), #{
        mode => urlsafe, padding => false
    }).

-spec token_hash(binary()) -> binary().
token_hash(Token) ->
    crypto:hash(sha256, Token).

%% Whether Token is the one hashed in Hash, in constant time.
-spec token_ok(binary() | undefined, binary()) -> boolean().
token_ok(undefined, _Hash) ->
    false;
token_ok(Token, Hash) ->
    crypto:hash_equals(token_hash(Token), Hash).

%% A random id, safe in a path segment and a file name.
-spec id() -> binary().
id() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
