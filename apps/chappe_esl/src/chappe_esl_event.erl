%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc Decode a parsed frame into a typed value by its Content-Type.
%%
%% FreeSWITCH tags every frame with a Content-Type. command/reply and
%% api/response are answers to commands; the text/event-* types carry events;
%% text/disconnect-notice and log/data are out-of-band notices, and
%% text/rude-rejection is sent instead of auth/request when the ACL denies the
%% client (the body is the reason; the socket closes next). An event is a
%% map of header keys to values plus a decoded body. event-plain values are
%% URL-encoded (%XX, space is %20); event-json is a JSON object whose optional
%% "_body" field holds the body; event-xml is kept raw (no xmerl dependency).
%%
%% Decoding never throws on malformed input: a bad JSON body yields an event
%% with the raw bytes as its body and no headers.
-module(chappe_esl_event).

-export([decode/1, channel/1]).
-export([header/2, headers/1, body/1, name/1]).

-export_type([event/0, decoded/0]).

-type headers() :: chappe_esl_parser:headers().
-type event() :: #{headers := #{binary() => term()}, body := binary()}.

-type decoded() ::
    {auth_request, headers()}
    | {reply, binary(), headers()}
    | {api, binary()}
    | {event, event()}
    | {disconnect, headers(), binary()}
    | {log, headers(), binary()}
    | {rejected, binary()}
    | {unknown, headers(), binary()}.

%% Classify and decode one frame.
-spec decode(chappe_esl_parser:frame()) -> decoded().
decode(#{headers := H, body := B}) ->
    case maps:get(<<"Content-Type">>, H, undefined) of
        <<"auth/request">> ->
            {auth_request, H};
        <<"command/reply">> ->
            {reply, maps:get(<<"Reply-Text">>, H, <<>>), H};
        <<"api/response">> ->
            {api, B};
        <<"text/event-plain">> ->
            {event, decode_plain(B)};
        <<"text/event-json">> ->
            {event, decode_json(B)};
        <<"text/event-xml">> ->
            {event, #{headers => #{}, body => B}};
        <<"text/disconnect-notice">> ->
            {disconnect, H, B};
        <<"log/data">> ->
            {log, H, B};
        <<"text/rude-rejection">> ->
            {rejected, string:trim(B)};
        _Other ->
            {unknown, H, B}
    end.

%% Build a channel-data event from an outbound connect reply. The reply frame
%% carries the channel variables as header lines with URL-encoded values.
%% FreeSWITCH sends them as headers of a command/reply with no body (the connect
%% branch of mod_event_socket), so the body is kept as is, not merged.
-spec channel(chappe_esl_parser:frame()) -> event().
channel(#{headers := H, body := B}) ->
    #{headers => maps:map(fun(_K, V) -> url_decode(V) end, H), body => B}.

%% Accessors.

-spec header(binary(), event()) -> term() | undefined.
header(Key, #{headers := H}) ->
    maps:get(Key, H, undefined).

-spec headers(event()) -> #{binary() => term()}.
headers(#{headers := H}) ->
    H.

-spec body(event()) -> binary().
body(#{body := B}) ->
    B.

%% The Event-Name header, if present.
-spec name(event()) -> binary() | undefined.
name(Event) ->
    header(<<"Event-Name">>, Event).

%% internal

decode_plain(Body) ->
    {HdrBin, Rest} = split_block(Body),
    Headers = parse_event_headers(HdrBin),
    EventBody = event_body(Headers, Rest),
    #{headers => Headers, body => EventBody}.

decode_json(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            EventBody = to_binary(maps:get(<<"_body">>, Map, <<>>)),
            #{headers => maps:remove(<<"_body">>, Map), body => EventBody};
        _Other ->
            #{headers => #{}, body => Body}
    catch
        error:_ ->
            #{headers => #{}, body => Body}
    end.

split_block(Bin) ->
    case binary:split(Bin, <<"\n\n">>) of
        [Hdr, Rest] -> {Hdr, Rest};
        [Hdr] -> {Hdr, <<>>}
    end.

parse_event_headers(HdrBin) ->
    Lines = binary:split(HdrBin, <<"\n">>, [global]),
    lists:foldl(fun parse_event_line/2, #{}, Lines).

parse_event_line(<<>>, Acc) ->
    Acc;
parse_event_line(Line, Acc) ->
    case binary:split(Line, <<": ">>) of
        [Key, Value] -> Acc#{Key => url_decode(Value)};
        [Bare] -> Acc#{Bare => <<>>}
    end.

event_body(Headers, Rest) ->
    case maps:get(<<"Content-Length">>, Headers, undefined) of
        undefined ->
            <<>>;
        Bin ->
            case safe_int(Bin) of
                0 -> <<>>;
                N when N =< byte_size(Rest) -> binary:part(Rest, 0, N);
                _ -> Rest
            end
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

safe_int(Bin) ->
    try binary_to_integer(string:trim(Bin)) of
        N when N >= 0 -> N;
        _ -> 0
    catch
        error:badarg -> 0
    end.

url_decode(Bin) ->
    url_decode(Bin, <<>>).

url_decode(<<$%, H1, H0, Rest/binary>>, Acc) ->
    case {unhex(H1), unhex(H0)} of
        {N1, N0} when is_integer(N1), is_integer(N0) ->
            url_decode(Rest, <<Acc/binary, (N1 * 16 + N0)>>);
        _ ->
            url_decode(<<H1, H0, Rest/binary>>, <<Acc/binary, $%>>)
    end;
url_decode(<<C, Rest/binary>>, Acc) ->
    url_decode(Rest, <<Acc/binary, C>>);
url_decode(<<>>, Acc) ->
    Acc.

unhex(C) when C >= $0, C =< $9 -> C - $0;
unhex(C) when C >= $a, C =< $f -> C - $a + 10;
unhex(C) when C >= $A, C =< $F -> C - $A + 10;
unhex(_) -> not_hex.
