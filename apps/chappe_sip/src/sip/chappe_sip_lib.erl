%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0

%% @doc Byte helpers for SIP text, shared by the parsers and the modules
%% that read header values.
%%
%% Everything here works byte by byte: SIP tokens are ASCII (RFC 3261 25.1)
%% and a header value is not always valid UTF-8, so unlike string:lowercase/1
%% and string:trim/1 these never raise and never touch non-ASCII bytes.
-module(chappe_sip_lib).

-export([lower/1, trim/1, unhex/1, to_int/2, delta_seconds/2]).

%% ASCII lowercase.
-spec lower(binary()) -> binary().
lower(B) -> <<<<(lower_byte(C))>> || <<C>> <= B>>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

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
