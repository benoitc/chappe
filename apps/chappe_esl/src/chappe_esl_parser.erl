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

-export([new/0, feed/2, buffer/1]).

-export_type([parser/0, frame/0, headers/0]).

-define(SEP, <<"\n\n">>).

-record(parser, {buffer = <<>> :: binary()}).

-opaque parser() :: #parser{}.
-type headers() :: #{binary() => binary()}.
-type frame() :: #{headers := headers(), body := binary()}.

%% Start an empty parser.
-spec new() -> parser().
new() ->
    #parser{}.

%% The bytes buffered but not yet forming a complete frame. Useful in tests.
-spec buffer(parser()) -> binary().
buffer(#parser{buffer = Buf}) ->
    Buf.

%% Append bytes and peel off every complete frame. Returns the frames in
%% arrival order plus the parser holding the trailing partial bytes.
-spec feed(binary(), parser()) -> {[frame()], parser()}.
feed(Data, #parser{buffer = Buf}) ->
    {Frames, Rest} = parse_all(<<Buf/binary, Data/binary>>, []),
    {Frames, #parser{buffer = Rest}}.

%% internal

parse_all(Buf, Acc) ->
    case binary:split(Buf, ?SEP) of
        [_NoSepYet] ->
            %% Header block not terminated yet.
            {lists:reverse(Acc), Buf};
        [HeadersBin, Rest] ->
            Headers = parse_headers(HeadersBin),
            case content_length(Headers) of
                0 ->
                    Frame = #{headers => Headers, body => <<>>},
                    parse_all(Rest, [Frame | Acc]);
                Len when byte_size(Rest) >= Len ->
                    <<Body:Len/binary, Remainder/binary>> = Rest,
                    Frame = #{headers => Headers, body => Body},
                    parse_all(Remainder, [Frame | Acc]);
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
