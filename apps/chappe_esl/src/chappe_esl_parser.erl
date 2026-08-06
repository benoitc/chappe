%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Streaming frame decoder for the FreeSWITCH Event Socket protocol.
%%
%% The wire protocol is text. A frame is a header block terminated by a blank
%% line (two consecutive newlines). Header lines are "Key: Value" separated by
%% a single newline. If the header block carries a Content-Length, exactly that
%% many bytes of body follow the blank line; otherwise the frame has no body.
%%
%% TCP delivers this as an arbitrary byte stream: one read may hold a partial
%% frame, several frames, or a frame split anywhere including inside the body
%% or between the two separator newlines. feed/2 buffers whatever it is given
%% and returns every complete frame it can peel off, keeping the trailing
%% partial bytes for the next call. It never throws on malformed input.
-module(chappe_esl_parser).

-export([new/0, new/1, feed/2, buffer/1, overflowed/1]).

-export_type([parser/0, frame/0, headers/0]).

-define(SEP, <<"\n\n">>).
%% Cap on the bytes retained for a single not-yet-complete frame. A peer that
%% never terminates a header block, or advertises a huge Content-Length, would
%% otherwise grow the buffer without bound (memory exhaustion). Overridable per
%% node via the `chappe_esl' app env `max_frame_bytes'.
-define(DEFAULT_MAX_FRAME_BYTES, (10 * 1024 * 1024)).

-record(parser, {
    buffer = <<>> :: binary(),
    max = ?DEFAULT_MAX_FRAME_BYTES :: pos_integer() | infinity,
    overflow = false :: boolean()
}).

-opaque parser() :: #parser{}.
-type headers() :: #{binary() => binary()}.
-type frame() :: #{headers := headers(), body := binary()}.

%% Start an empty parser. The max retained-buffer size comes from the
%% `chappe_esl' app env `max_frame_bytes' (default 10 MiB).
-spec new() -> parser().
new() ->
    new(
        application:get_env(
            chappe_esl, max_frame_bytes, ?DEFAULT_MAX_FRAME_BYTES
        )
    ).

%% Start an empty parser with an explicit max retained-buffer size in bytes, or
%% `infinity' for no cap. When a partial frame exceeds it, the parser marks
%% itself overflowed and drops further input (see overflowed/1).
-spec new(pos_integer() | infinity) -> parser().
new(Max) ->
    #parser{max = Max}.

%% The bytes buffered but not yet forming a complete frame. Useful in tests.
-spec buffer(parser()) -> binary().
buffer(#parser{buffer = Buf}) ->
    Buf.

%% Whether a partial frame has exceeded the configured max size. Once true the
%% parser drops further input; the caller should close the connection.
-spec overflowed(parser()) -> boolean().
overflowed(#parser{overflow = Overflow}) ->
    Overflow.

%% Append bytes and peel off every complete frame. Returns the frames in
%% arrival order plus the parser holding the trailing partial bytes. If the
%% retained partial exceeds the max, the parser flips to overflowed and drops
%% the partial (and all subsequent input) so memory stays bounded.
-spec feed(binary(), parser()) -> {[frame()], parser()}.
feed(_Data, #parser{overflow = true} = P) ->
    {[], P};
feed(Data, #parser{buffer = Buf, max = Max} = P) ->
    case parse_all(<<Buf/binary, Data/binary>>, [], Max) of
        {Frames, overflow} ->
            {Frames, P#parser{buffer = <<>>, overflow = true}};
        {Frames, Rest} ->
            case over_cap(byte_size(Rest), Max) of
                true -> {Frames, P#parser{buffer = <<>>, overflow = true}};
                false -> {Frames, P#parser{buffer = Rest}}
            end
    end.

%% internal

over_cap(_Size, infinity) -> false;
over_cap(Size, Max) -> Size > Max.

parse_all(Buf, Acc, Max) ->
    case binary:split(Buf, ?SEP) of
        [_NoSepYet] ->
            %% Header block not terminated yet (over_cap catches runaway here).
            {lists:reverse(Acc), Buf};
        [HeadersBin, Rest] ->
            Headers = parse_headers(HeadersBin),
            case content_length(Headers) of
                0 ->
                    Frame = #{headers => Headers, body => <<>>},
                    parse_all(Rest, [Frame | Acc], Max);
                Len when Len > Max ->
                    %% Declared body can never fit the cap: reject now rather
                    %% than buffer toward it (Max = infinity never matches).
                    {lists:reverse(Acc), overflow};
                Len when byte_size(Rest) >= Len ->
                    <<Body:Len/binary, Remainder/binary>> = Rest,
                    Frame = #{headers => Headers, body => Body},
                    parse_all(Remainder, [Frame | Acc], Max);
                _Len ->
                    %% Body not fully arrived: keep the whole frame buffered.
                    {lists:reverse(Acc), Buf}
            end
    end.

parse_headers(HeadersBin) ->
    Lines = binary:split(HeadersBin, <<"\n">>, [global]),
    lists:foldl(fun parse_header_line/2, #{}, Lines).

parse_header_line(<<>>, Acc) ->
    Acc;
parse_header_line(Line, Acc) ->
    case binary:split(Line, <<": ">>) of
        [Key, Value] ->
            Acc#{Key => Value};
        [Only] ->
            case binary:split(Only, <<":">>) of
                [Key, Value] -> Acc#{Key => trim_leading(Value)};
                [Bare] -> Acc#{Bare => <<>>}
            end
    end.

trim_leading(<<$\s, Rest/binary>>) -> trim_leading(Rest);
trim_leading(Bin) -> Bin.

content_length(Headers) ->
    case maps:get(<<"Content-Length">>, Headers, undefined) of
        undefined -> 0;
        Bin -> safe_int(Bin)
    end.

safe_int(Bin) ->
    try binary_to_integer(string:trim(Bin)) of
        N when N >= 0 -> N;
        _ -> 0
    catch
        error:badarg -> 0
    end.
