%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Helpers shared by the app's processes: the pg scope, bounded sends and
%% stream tokens.
-module(chappe_audio_lib).

-export([start_scope/0, scope/0, send/3, token/0, token_hash/1, token_ok/2]).
-export([id/0]).

%% The cluster-wide scope chappe's lookups use (chappe-erlang-patterns).
-define(SCOPE, chappe).

-spec scope() -> atom().
scope() ->
    ?SCOPE.

%% Start the `chappe' pg scope unless another app of the node already
%% runs it (chappe_sip does); chappe_audio then joins that one. ignore
%% keeps the supervisor going with no child.
-spec start_scope() -> {ok, pid()} | ignore.
start_scope() ->
    case pg:start_link(?SCOPE) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, _}} -> ignore
    end.

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
