%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Byte helpers for SIP text, shared by the parsers and the modules
%% that read header values.
%%
%% Everything here works byte by byte: SIP tokens are ASCII (RFC 3261 25.1)
%% and a header value is not always valid UTF-8, so unlike string:lowercase/1
%% and string:trim/1 these never raise and never touch non-ASCII bytes.
-module(chappe_sip_lib).

-export([lower/1, upper/1, all_digits/1, trim/1, unhex/1, to_int/2]).
-export([delta_seconds/2, xml_escape/1]).

%% ASCII lowercase.
-spec lower(binary()) -> binary().
lower(B) -> <<<<(lower_byte(C))>> || <<C>> <= B>>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

%% ASCII uppercase.
-spec upper(binary()) -> binary().
upper(B) -> <<<<(upper_byte(C))>> || <<C>> <= B>>.

upper_byte(C) when C >= $a, C =< $z -> C - 32;
upper_byte(C) -> C.

%% One or more ASCII digits, nothing else.
-spec all_digits(binary()) -> boolean().
all_digits(<<>>) ->
    false;
all_digits(B) ->
    lists:all(fun(D) -> D >= $0 andalso D =< $9 end, binary_to_list(B)).

%% Strip leading and trailing SP and HTAB (OWS, RFC 3261 25.1).
-spec trim(binary()) -> binary().
trim(B) -> trim_trailing(trim_leading(B)).

trim_leading(<<C, R/binary>>) when C =:= $\s; C =:= $\t -> trim_leading(R);
trim_leading(B) -> B.

trim_trailing(<<>>) ->
    <<>>;
trim_trailing(B) ->
    case binary:last(B) of
        C when C =:= $\s; C =:= $\t ->
            trim_trailing(binary:part(B, 0, byte_size(B) - 1));
        _ ->
            B
    end.

%% The value of one hex digit, `error' for any other byte.
-spec unhex(byte()) -> 0..15 | error.
unhex(C) when C >= $0, C =< $9 -> C - $0;
unhex(C) when C >= $a, C =< $f -> C - $a + 10;
unhex(C) when C >= $A, C =< $F -> C - $A + 10;
unhex(_) -> error.

%% The integer in a header value, OWS trimmed, `Default' when there is none.
-spec to_int(binary(), Default) -> integer() | Default.
to_int(B, Default) ->
    try
        binary_to_integer(trim(B))
    catch
        error:badarg -> Default
    end.

%% A delta-seconds value (Expires, Session-Expires, Min-SE): a non-negative
%% integer, `Default' when the value is missing, negative or not a number.
-spec delta_seconds(binary(), Default) -> non_neg_integer() | Default.
delta_seconds(B, Default) ->
    case to_int(B, Default) of
        N when is_integer(N), N >= 0 -> N;
        _ -> Default
    end.

%% Text or an attribute value as XML character data: the markup
%% characters as entities, a raw tab or newline as a character reference
%% (an attribute would normalise it to a space), invalid UTF-8 and the
%% characters XML forbids as U+FFFD.
-spec xml_escape(binary()) -> iolist().
xml_escape(Bin) ->
    [escape_char(C) || C <- chars(Bin, [])].

escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($&) -> <<"&amp;">>;
escape_char($") -> <<"&quot;">>;
escape_char($') -> <<"&apos;">>;
%% in attributes a raw tab or newline would be normalised to a space
escape_char($\t) -> <<"&#9;">>;
escape_char($\n) -> <<"&#10;">>;
escape_char($\r) -> <<"&#13;">>;
escape_char(C) -> <<C/utf8>>.

%% code points of Bin; invalid UTF-8 and XML-forbidden characters become
%% U+FFFD
chars(<<C/utf8, Rest/binary>>, Acc) ->
    chars(Rest, [xml_char(C) | Acc]);
chars(<<_, Rest/binary>>, Acc) ->
    chars(Rest, [16#FFFD | Acc]);
chars(<<>>, Acc) ->
    lists:reverse(Acc).

xml_char(C) when C =:= 16#9; C =:= 16#A; C =:= 16#D -> C;
xml_char(C) when C < 16#20 -> 16#FFFD;
xml_char(C) when C =:= 16#FFFE; C =:= 16#FFFF -> 16#FFFD;
xml_char(C) -> C.
