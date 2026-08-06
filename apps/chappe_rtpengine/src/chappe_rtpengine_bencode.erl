%% Copyright 2026 Benoit Chesneau
%% SPDX-License-Identifier: Apache-2.0
%%
%% Bencode codec for the rtpengine NG protocol.
%%
%% Encoding is canonical: dictionary keys are emitted in ascending raw
%% byte order, as required by bencode. Decoding is tolerant: unsorted
%% dictionaries are accepted and wire types are preserved (strings
%% decode to binaries, dictionaries to maps with binary keys).
-module(chappe_rtpengine_bencode).

-export([encode/1, encode_to_binary/1, decode/1, decode_prefix/1]).

-type value() ::
    integer()
    | binary()
    | atom()
    | [value()]
    | #{binary() | atom() => value()}.

-export_type([value/0]).

-spec encode(value()) -> iodata().
encode(I) when is_integer(I) ->
    [$i, integer_to_binary(I), $e];
encode(B) when is_binary(B) ->
    [integer_to_binary(byte_size(B)), $:, B];
encode(A) when is_atom(A) ->
    encode(atom_to_binary(A, utf8));
encode(M) when is_map(M) ->
    Pairs = lists:keysort(1, [{key_bin(K), V} || {K, V} <- maps:to_list(M)]),
    [$d, [[encode(K), encode(V)] || {K, V} <- Pairs], $e];
encode(L) when is_list(L) ->
    [$l, [encode(E) || E <- L], $e].

-spec encode_to_binary(value()) -> binary().
encode_to_binary(V) ->
    iolist_to_binary(encode(V)).

-spec decode(binary()) -> {ok, value()} | {error, term()}.
decode(Bin) when is_binary(Bin) ->
    try dec(Bin) of
        {Value, <<>>} -> {ok, Value};
        {_Value, Rest} -> {error, {trailing_bytes, byte_size(Rest)}}
    catch
        throw:Reason -> {error, Reason}
    end.

%% Decode one value from the head of a byte stream (NG over TCP):
%% returns the value and the unconsumed rest, `incomplete` when the
%% buffer ends mid-value, or an error for input that can never parse.
-spec decode_prefix(binary()) ->
    {ok, value(), binary()} | incomplete | {error, term()}.
decode_prefix(<<>>) ->
    incomplete;
decode_prefix(Bin) when is_binary(Bin) ->
    try dec(Bin) of
        {Value, Rest} -> {ok, Value, Rest}
    catch
        throw:Reason ->
            case incomplete_reason(Reason) of
                true -> incomplete;
                false -> {error, Reason}
            end
    end.

%% internal

incomplete_reason(unexpected_end) -> true;
incomplete_reason(truncated_string) -> true;
incomplete_reason(unterminated_integer) -> true;
incomplete_reason(unterminated_list) -> true;
incomplete_reason(unterminated_dict) -> true;
incomplete_reason(_) -> false.

key_bin(K) when is_binary(K) -> K;
key_bin(K) when is_atom(K) -> atom_to_binary(K, utf8).

dec(<<>>) ->
    throw(unexpected_end);
dec(<<$i, Rest/binary>>) ->
    dec_int(Rest);
dec(<<$l, Rest/binary>>) ->
    dec_list(Rest, []);
dec(<<$d, Rest/binary>>) ->
    dec_dict(Rest, #{});
dec(<<C, _/binary>> = Bin) when C >= $0, C =< $9 ->
    dec_str(Bin);
dec(_) ->
    throw(invalid).

dec_int(Bin) ->
    case binary:split(Bin, <<"e">>) of
        [Digits, Rest] ->
            try binary_to_integer(Digits) of
                I -> {I, Rest}
            catch
                error:badarg -> throw({bad_integer, Digits})
            end;
        [Digits] ->
            %% no terminator yet: only incomplete when what we have
            %% so far could still become a valid integer
            case int_prefix(Digits) of
                true -> throw(unterminated_integer);
                false -> throw({bad_integer, Digits})
            end
    end.

int_prefix(<<"-", Rest/binary>>) -> digits(Rest);
int_prefix(Rest) -> digits(Rest).

dec_str(Bin) ->
    case binary:split(Bin, <<":">>) of
        [Digits, Rest] ->
            Len =
                try binary_to_integer(Digits) of
                    N when N >= 0 -> N;
                    _ -> throw({bad_length, Digits})
                catch
                    error:badarg -> throw({bad_length, Digits})
                end,
            case Rest of
                <<Str:Len/binary, Tail/binary>> -> {Str, Tail};
                _ -> throw(truncated_string)
            end;
        [Digits] ->
            %% no colon yet: a pure-digit buffer is an unfinished
            %% length prefix, anything else can never parse
            case digits(Digits) of
                true -> throw(truncated_string);
                false -> throw(bad_string)
            end
    end.

digits(<<>>) -> true;
digits(<<C, Rest/binary>>) when C >= $0, C =< $9 -> digits(Rest);
digits(_) -> false.

dec_list(<<$e, Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
dec_list(<<>>, _Acc) ->
    throw(unterminated_list);
dec_list(Bin, Acc) ->
    {V, Rest} = dec(Bin),
    dec_list(Rest, [V | Acc]).

dec_dict(<<$e, Rest/binary>>, Acc) ->
    {Acc, Rest};
dec_dict(<<>>, _Acc) ->
    throw(unterminated_dict);
dec_dict(Bin, Acc) ->
    {K, Rest0} = dec(Bin),
    is_binary(K) orelse throw({bad_dict_key, K}),
    {V, Rest1} = dec(Rest0),
    dec_dict(Rest1, Acc#{K => V}).
