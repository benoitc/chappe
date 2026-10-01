%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Incremental framer for NG over TCP: a pure module, no process.
%%
%% Each message on the stream is a cookie, one space, then exactly one
%% bencode value. feed/2 takes the next chunk of bytes and returns the
%% complete messages it closed, in order, with the framer state for
%% the rest.
%%
%% The work stays linear in the stream size. The cookie is split off
%% once and kept while its value is incomplete, and a partial value
%% reports a lower bound on the bytes it still needs
%% (chappe_rtpengine_bencode:decode_stream/1): chunks are only
%% collected until that many have arrived, then joined and parsed
%% once. A large reply arriving in many segments is not rescanned per
%% segment.
%%
%% Bounds: the un-consumed stream is capped at 4 MiB (a value that
%% announces more fails at once, without waiting for the bytes), and a
%% cookie at 256 bytes. Either limit, or bytes that can never parse,
%% is an error; the caller drops the connection.
-module(chappe_rtpengine_stream).

-export([new/0, feed/2]).

-define(MAX_STREAM_BYTES, (4 * 1024 * 1024)).
-define(MAX_COOKIE_BYTES, 256).

-record(stream, {
    %% bytes after the current cookie, or before it when cookie is
    %% undefined
    buffer = <<>> :: binary(),
    %% chunks received since the last parse, newest first
    chunks = [] :: [binary()],
    %% total size of buffer plus chunks
    buffered = 0 :: non_neg_integer(),
    %% buffered must reach this before parsing is worth trying again
    need = 0 :: non_neg_integer(),
    cookie :: binary() | undefined
}).

-opaque stream() :: #stream{}.
-type message() :: {Cookie :: binary(), chappe_rtpengine_bencode:value()}.

-export_type([stream/0, message/0]).

-spec new() -> stream().
new() ->
    #stream{}.

%% Messages completed by Data, oldest first. On error the messages
%% completed before the bad bytes are still returned.
-spec feed(binary(), stream()) ->
    {ok, [message()], stream()} | {error, term(), [message()]}.
feed(Data, #stream{} = S) ->
    Buffered = S#stream.buffered + byte_size(Data),
    Chunks = [Data | S#stream.chunks],
    case Buffered of
        _ when Buffered > ?MAX_STREAM_BYTES ->
            {error, {too_large, Buffered}, []};
        _ when Buffered < S#stream.need ->
            {ok, [], S#stream{chunks = Chunks, buffered = Buffered}};
        _ ->
            Buffer = iolist_to_binary([S#stream.buffer | lists:reverse(Chunks)]),
            parse(
                S#stream{buffer = Buffer, chunks = [], buffered = Buffered}, []
            )
    end.

%% internal

parse(#stream{cookie = undefined, buffer = Buffer} = S, Acc) ->
    case binary:match(Buffer, <<" ">>) of
        {Pos, 1} when Pos =< ?MAX_COOKIE_BYTES ->
            <<Cookie:Pos/binary, _, Rest/binary>> = Buffer,
            parse(
                S#stream{
                    cookie = Cookie, buffer = Rest, buffered = byte_size(Rest)
                },
                Acc
            );
        nomatch when byte_size(Buffer) =< ?MAX_COOKIE_BYTES ->
            {ok, lists:reverse(Acc), S#stream{need = byte_size(Buffer) + 1}};
        _ ->
            {error, cookie_too_long, lists:reverse(Acc)}
    end;
parse(#stream{cookie = Cookie, buffer = Buffer} = S, Acc) ->
    case chappe_rtpengine_bencode:decode_stream(Buffer) of
        {ok, Value, Rest} ->
            S1 = S#stream{
                cookie = undefined,
                buffer = Rest,
                buffered = byte_size(Rest),
                need = 0
            },
            parse(S1, [{Cookie, Value} | Acc]);
        {more, More} ->
            Need = byte_size(Buffer) + More,
            case Need > ?MAX_STREAM_BYTES of
                true -> {error, {too_large, Need}, lists:reverse(Acc)};
                false -> {ok, lists:reverse(Acc), S#stream{need = Need}}
            end;
        {error, Reason} ->
            {error, Reason, lists:reverse(Acc)}
    end.
