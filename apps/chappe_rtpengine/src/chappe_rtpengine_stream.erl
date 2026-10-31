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
%% The work stays linear in the stream size, however the bytes are
%% fragmented. A resumable scanner walks each byte once to find where
%% the value ends: it keeps the open containers, the token in progress
%% (an integer, a string length, or the string bytes still to skip)
%% and the cookie phase across feeds. String bodies are skipped
%% without being read. The bytes of the current message are kept as
%% the list of chunks they arrived in, joined once its end is found
%% and decoded once (chappe_rtpengine_bencode:decode/1).
%%
%% The scanner checks what it can as the bytes arrive: type bytes,
%% canonical integers and string lengths, string dictionary keys and
%% nesting depth, so bytes that can never parse fail at once.
%%
%% Bounds: the un-consumed stream is capped at 4 MiB (a string that
%% announces more fails at once, without waiting for the bytes), and a
%% cookie at 256 bytes. Either limit, or bytes that can never parse,
%% is an error; the caller drops the connection.
-module(chappe_rtpengine_stream).

-export([new/0, feed/2]).

-define(MAX_STREAM_BYTES, (4 * 1024 * 1024)).
-define(MAX_COOKIE_BYTES, 256).
%% the decoder's nesting limit (chappe_rtpengine_bencode)
-define(MAX_DEPTH, 64).

-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).

%% Open containers, innermost first: a list, or a dictionary awaiting
%% a key (or its end) or a value.
-type frame() :: list | key | val.
%% The token being scanned.
-type token() ::
    none
    | int_start
    | int_minus
    | int_zero
    | int_digits
    | len_zero
    | {len, pos_integer()}
    | {str, pos_integer()}.

-record(stream, {
    %% bytes of the current message (cookie included until it is
    %% split off), newest first
    chunks = [] :: [binary()],
    %% total size of chunks
    size = 0 :: non_neg_integer(),
    cookie :: binary() | undefined,
    stack = [] :: [frame()],
    token = none :: token()
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
feed(Data, #stream{size = Size} = S) ->
    case Size + byte_size(Data) of
        Buffered when Buffered > ?MAX_STREAM_BYTES ->
            {error, {too_large, Buffered}, []};
        _ ->
            frame(Data, S, [])
    end.

%% internal

frame(<<>>, S, Acc) ->
    {ok, lists:reverse(Acc), S};
frame(Bin, #stream{cookie = undefined, chunks = Chunks, size = Size} = S, Acc) ->
    case binary:match(Bin, <<" ">>) of
        {Pos, 1} when Size + Pos =< ?MAX_COOKIE_BYTES ->
            <<Head:Pos/binary, _, Rest/binary>> = Bin,
            Cookie = iolist_to_binary(lists:reverse(Chunks, [Head])),
            frame(Rest, #stream{cookie = Cookie}, Acc);
        nomatch when Size + byte_size(Bin) =< ?MAX_COOKIE_BYTES ->
            {ok, lists:reverse(Acc), keep(Bin, S)};
        _ ->
            {error, cookie_too_long, lists:reverse(Acc)}
    end;
frame(Bin, #stream{cookie = Cookie, stack = Stack, token = Token} = S, Acc) ->
    Base = S#stream.size + byte_size(Bin),
    case scan(Bin, Base, Token, Stack) of
        {done, Rest} ->
            Used = byte_size(Bin) - byte_size(Rest),
            Value = iolist_to_binary(
                lists:reverse(S#stream.chunks, [binary_part(Bin, 0, Used)])
            ),
            case chappe_rtpengine_bencode:decode(Value) of
                {ok, Decoded} ->
                    frame(Rest, #stream{}, [{Cookie, Decoded} | Acc]);
                {error, Reason} ->
                    {error, Reason, lists:reverse(Acc)}
            end;
        {more, Token1, Stack1} ->
            S1 = keep(Bin, S),
            {ok, lists:reverse(Acc), S1#stream{token = Token1, stack = Stack1}};
        {error, Reason} ->
            {error, Reason, lists:reverse(Acc)}
    end.

keep(Bin, #stream{chunks = Chunks, size = Size} = S) ->
    S#stream{chunks = [Bin | Chunks], size = Size + byte_size(Bin)}.

%% Scan the value from where the last feed stopped. Base is the size
%% of the value bytes seen so far once Bin is consumed, so the value
%% offset of a position is Base minus the bytes after it.
-spec scan(binary(), non_neg_integer(), token(), [frame()]) ->
    {done, binary()} | {more, token(), [frame()]} | {error, term()}.
scan(<<>>, _Base, Token, Stack) ->
    {more, Token, Stack};
scan(Bin, Base, none, Stack) ->
    start(Bin, Base, Stack);
scan(Bin, Base, {str, Left}, Stack) ->
    case Bin of
        <<_:Left/binary, Rest/binary>> ->
            done(Rest, Base, Stack);
        _ ->
            {more, {str, Left - byte_size(Bin)}, Stack}
    end;
scan(<<C, Rest/binary>>, Base, Token, Stack) ->
    case token(C, Token) of
        {next, Token1} ->
            scan(Rest, Base, Token1, Stack);
        value ->
            done(Rest, Base, Stack);
        {colon, 0} ->
            done(Rest, Base, Stack);
        {colon, Len} ->
            case Base - byte_size(Rest) + Len of
                Need when Need > ?MAX_STREAM_BYTES ->
                    {error, {too_large, Need}};
                _ ->
                    scan(Rest, Base, {str, Len}, Stack)
            end;
        {error, _} = Error ->
            Error
    end.

%% The first byte of a value, or the end of the open container.
start(<<>>, _Base, Stack) ->
    {more, none, Stack};
start(<<$e, Rest/binary>>, Base, [Open | Stack]) when
    Open =:= list; Open =:= key
->
    done(Rest, Base, Stack);
start(<<C, _/binary>>, _Base, [key | _]) when not ?IS_DIGIT(C) ->
    {error, bad_dict_key};
start(<<$i, Rest/binary>>, Base, Stack) ->
    scan(Rest, Base, int_start, Stack);
start(<<C, Rest/binary>>, Base, Stack) when C =:= $l; C =:= $d ->
    case length(Stack) >= ?MAX_DEPTH of
        true ->
            {error, too_deep};
        false ->
            Open =
                case C of
                    $l -> list;
                    $d -> key
                end,
            scan(Rest, Base, none, [Open | Stack])
    end;
start(<<$0, Rest/binary>>, Base, Stack) ->
    scan(Rest, Base, len_zero, Stack);
start(<<C, Rest/binary>>, Base, Stack) when ?IS_DIGIT(C) ->
    scan(Rest, Base, {len, C - $0}, Stack);
start(_Bin, _Base, _Stack) ->
    {error, invalid}.

%% A value just ended: the message is complete at the top level,
%% otherwise the enclosing container expects its next item.
done(Rest, _Base, []) ->
    {done, Rest};
done(Rest, Base, [key | Stack]) ->
    scan(Rest, Base, none, [val | Stack]);
done(Rest, Base, [val | Stack]) ->
    scan(Rest, Base, none, [key | Stack]);
done(Rest, Base, [list | _] = Stack) ->
    scan(Rest, Base, none, Stack).

%% One byte of an integer or a string length, canonical forms only.
token($-, int_start) ->
    {next, int_minus};
token($0, int_start) ->
    {next, int_zero};
token(C, int_start) when C >= $1, C =< $9 -> {next, int_digits};
token(C, int_minus) when C >= $1, C =< $9 -> {next, int_digits};
token($e, int_zero) ->
    value;
token($e, int_digits) ->
    value;
token(C, int_digits) when ?IS_DIGIT(C) -> {next, int_digits};
token($:, len_zero) ->
    {colon, 0};
token($:, {len, Len}) ->
    {colon, Len};
token(C, {len, Len}) when ?IS_DIGIT(C) ->
    case Len * 10 + C - $0 of
        Len1 when Len1 > ?MAX_STREAM_BYTES -> {error, {too_large, Len1}};
        Len1 -> {next, {len, Len1}}
    end;
token(_C, {len, _}) ->
    {error, bad_length};
token(_C, len_zero) ->
    {error, bad_length};
token(_C, _Int) ->
    {error, bad_integer}.
